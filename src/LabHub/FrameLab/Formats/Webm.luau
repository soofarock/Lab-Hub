--!native
--!optimize 2
-- WebM / Matroska (EBML) demuxer: finds the first video and sound tracks and lists their frames (byte ranges and
-- times), in the same shape as Formats.Mp4, so the same import path reads both. Video: VP9 (codec "vp09"), VP8
-- ("vp08"), AV1 ("av01", av1C = CodecPrivate), H.264 ("avc1", with its avcC from CodecPrivate), H.265
-- ("hvc1", hvcC = CodecPrivate), MPEG-4 Part 2 ("mp4v", config: its VOL headers; also from an AVI-style V_MS/VFW/FOURCC track). Sound: Opus ("Opus", with a dOps-style setup
-- and the codec delay as `skip`), Vorbis ("vorbis", its three setup packets in `vorbisHeaders`), AAC ("mp4a", esds.asc)
-- and MP3 (".mp3"). Laced blocks are split into their frames. A file cut off part way keeps the frames that arrived.
--
--   local m = Webm.parse(bytes)               -- m.video, m.audio as Formats.Mp4.parse
--   Webm.isWebm(bytes)
--   local head = Webm.readHead(bytes, len)     -- the part before the first cluster (for streaming):
--       head = { segStart, timescale (ns per tick), duration (s), tracks = { video, audio }, cues = { { time (s),
--               pos (byte offset in the file) } ... } or nil, firstCluster (byte offset), headerEnd }
--   Webm.readClusters(bytes, from, to, head, fileOffset?) -> video samples, audio samples (the clusters in [from, to)
--       of a piece of the file that starts at fileOffset; sample pos are offsets in `bytes`, times in seconds from the
--       segment's start)
-- Streaming (Tools.Live.openWebm) - a stretch of the file from one keyframe to a later one, fetched by byte range:
--   local parts = Webm.planParts(head, cues, fileSize, minSeconds?)  -> { { start (s), a, b (byte range, inclusive) } }
--   local seg = Webm.packPart(body, a, head)   the clusters of body (the file's bytes a ..) -> a stream part (buffer):
--       its VP9 / VP8 frames and its sound packets, readable with Webm.unpackPart (the same shape as Formats.Ts.parse:
--       { video = { codec = "vp9" / "vp8", units = { { pts, data } } }, audio = { codec = "opus" / "vorbis", frames, dOps,
--       skip, vorbisHeaders, start } })
--   Webm.isPart(bytes)

local Webm = {}

local readu8 = buffer.readu8

local function fail(msg)
	error("WebM: " .. msg, 0)
end

local IDS = {
	EBML = 0x1A45DFA3,
	Segment = 0x18538067,
	SeekHead = 0x114D9B74,
	Info = 0x1549A966,
	TimecodeScale = 0x2AD7B1,
	Duration = 0x4489,
	Tracks = 0x1654AE6B,
	TrackEntry = 0xAE,
	TrackNumber = 0xD7,
	TrackType = 0x83,
	CodecID = 0x86,
	CodecPrivate = 0x63A2,
	CodecDelay = 0x56AA,
	DefaultDuration = 0x23E383,
	Video = 0xE0,
	PixelWidth = 0xB0,
	PixelHeight = 0xBA,
	Audio = 0xE1,
	SamplingFrequency = 0xB5,
	Channels = 0x9F,
	ContentEncodings = 0x6D80,
	Cues = 0x1C53BB6B,
	CuePoint = 0xBB,
	CueTime = 0xB3,
	CueTrackPositions = 0xB7,
	CueTrack = 0xF7,
	CueClusterPosition = 0xF1,
	Cluster = 0x1F43B675,
	Timecode = 0xE7,
	SimpleBlock = 0xA3,
	BlockGroup = 0xA0,
	Block = 0xA1,
	ReferenceBlock = 0xFB,
	Tags = 0x1254C367,
	Chapters = 0x1043A770,
	Attachments = 0x1941A469,
}
-- elements directly in the Segment (an unknown-size cluster ends where one of these starts)
local TOP = {
	[IDS.Cluster] = true, [IDS.Cues] = true, [IDS.Tags] = true, [IDS.Chapters] = true, [IDS.Attachments] = true,
	[IDS.Info] = true, [IDS.Tracks] = true, [IDS.SeekHead] = true,
}

function Webm.isWebm(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return buffer.len(b) >= 4 and buffer.readu32(b, 0) == 0xA3DF451A
end

-- an element ID at p (its marker bits kept) -> id, next position; nil past the end
local function readId(b, p, len)
	if p >= len then
		return nil
	end
	local c = readu8(b, p)
	local n = c >= 0x80 and 1 or (c >= 0x40 and 2 or (c >= 0x20 and 3 or (c >= 0x10 and 4 or 0)))
	if n == 0 then
		fail("broken data (an element ID)")
	end
	if p + n > len then
		return nil
	end
	local v = c
	for i = 1, n - 1 do
		v = v * 256 + readu8(b, p + i)
	end
	return v, p + n
end

-- an element size -> size (nil: unknown), next position
local function readSize(b, p, len)
	if p >= len then
		return false
	end
	local c = readu8(b, p)
	local n = 1
	local mask = 0x80
	while n <= 8 and bit32.band(c, mask) == 0 do
		n += 1
		mask //= 2
	end
	if n > 8 then
		fail("broken data (an element size)")
	end
	if p + n > len then
		return false
	end
	local v = bit32.band(c, mask - 1)
	local allOnes = v == mask - 1
	for i = 1, n - 1 do
		local x = readu8(b, p + i)
		if x ~= 255 then
			allOnes = false
		end
		v = v * 256 + x
	end
	if allOnes then
		return nil, p + n
	end
	return v, p + n
end

local function readUint(b, p, n)
	local v = 0
	for i = 0, n - 1 do
		v = v * 256 + readu8(b, p + i)
	end
	return v
end

local function readFloat(b, p, n)
	if n == 4 then
		local t = buffer.create(4)
		for i = 0, 3 do
			buffer.writeu8(t, i, readu8(b, p + 3 - i))
		end
		return buffer.readf32(t, 0)
	elseif n == 8 then
		local t = buffer.create(8)
		for i = 0, 7 do
			buffer.writeu8(t, i, readu8(b, p + 7 - i))
		end
		return buffer.readf64(t, 0)
	end
	return 0
end

-- children of [p, stop): fn(id, data start, data end (clipped), size or nil)
local function children(b, p, stop, fn)
	while p < stop do
		local id, q = readId(b, p, stop)
		if not id then
			return
		end
		local size, d = readSize(b, q, stop)
		if size == false then
			return
		end
		local e = size and math.min(d + size, stop) or stop
		if fn(id, d, e, size, p) == false then
			return
		end
		if not size then
			return
		end
		p = d + size
	end
end

local VIDEO_CODECS = { V_VP9 = "vp09", V_VP8 = "vp08", V_AV1 = "av01", ["V_MPEG4/ISO/AVC"] = "avc1", ["V_MPEGH/ISO/HEVC"] = "hvc1",
	V_THEORA = "theora", ["V_MPEG4/ISO/ASP"] = "mp4v" }
-- MPEG-4 Part 2 FourCCs of AVI-style tracks (upper case)
local VFW_MPEG4 = { XVID = true, XVIX = true, DIVX = true, DX50 = true, DX40 = true, FMP4 = true, MP4V = true, MP4S = true,
	M4S2 = true, ["3IV2"] = true, RMP4 = true, ZMP4 = true, SIPP = true, UMP4 = true, WV1F = true, BLZ0 = true, DXGM = true,
	EM4A = true, GEOV = true, SMP4 = true, LMP4 = true, DIGI = true, PVMM = true, SEDG = true, M4CC = true, ["3IVD"] = true,
	FFDS = true, FVFW = true, DM4V = true, DMK2 = true, HDX4 = true, MVXM = true, NDIG = true, QMP4 = true }

local function readTrack(b, p, e)
	local t = { number = 0, kind = 0, codecId = "" }
	children(b, p, e, function(id, d, q)
		if id == IDS.TrackNumber then
			t.number = readUint(b, d, q - d)
		elseif id == IDS.TrackType then
			t.kind = readUint(b, d, q - d)
		elseif id == IDS.CodecID then
			t.codecId = string.gsub(buffer.readstring(b, d, q - d), "%z+$", "")
		elseif id == IDS.CodecPrivate then
			local nb = buffer.create(q - d)
			buffer.copy(nb, 0, b, d, q - d)
			t.private = nb
		elseif id == IDS.CodecDelay then
			t.codecDelay = readUint(b, d, q - d)
		elseif id == IDS.DefaultDuration then
			t.defaultDuration = readUint(b, d, q - d)
		elseif id == IDS.ContentEncodings then
			t.encoded = true
		elseif id == IDS.Video then
			children(b, d, q, function(cid, cd, cq)
				if cid == IDS.PixelWidth then
					t.width = readUint(b, cd, cq - cd)
				elseif cid == IDS.PixelHeight then
					t.height = readUint(b, cd, cq - cd)
				end
				return nil
			end)
		elseif id == IDS.Audio then
			children(b, d, q, function(cid, cd, cq)
				if cid == IDS.SamplingFrequency then
					t.sampleRate = readFloat(b, cd, cq - cd)
				elseif cid == IDS.Channels then
					t.channels = readUint(b, cd, cq - cd)
				end
				return nil
			end)
		end
		return nil
	end)
	return t
end

-- Xiph lacing in CodecPrivate (Vorbis): count - 1, sizes of all but the last, then the packets
local function xiphPackets(priv)
	local n = readu8(priv, 0) + 1
	local p = 1
	local sizes = {}
	for i = 1, n - 1 do
		local s = 0
		repeat
			local c = readu8(priv, p)
			p += 1
			s += c
		until c < 255
		sizes[i] = s
	end
	local out = {}
	for i = 1, n do
		local s = sizes[i] or (buffer.len(priv) - p)
		local nb = buffer.create(s)
		buffer.copy(nb, 0, priv, p, s)
		out[i] = nb
		p += s
	end
	return out
end

-- an OpusHead -> the MP4 'dOps' layout Formats.Opus reads (big-endian fields, no magic)
local function opusHeadToDops(h)
	if buffer.len(h) < 19 or buffer.readstring(h, 0, 8) ~= "OpusHead" then
		return nil
	end
	local extra = buffer.len(h) - 19
	local d = buffer.create(11 + extra)
	buffer.writeu8(d, 0, 0)
	buffer.writeu8(d, 1, readu8(h, 9))
	local preSkip = buffer.readu16(h, 10)
	buffer.writeu8(d, 2, preSkip // 256)
	buffer.writeu8(d, 3, preSkip % 256)
	local rate = buffer.readu32(h, 12)
	for i = 0, 3 do
		buffer.writeu8(d, 4 + i, (rate // 256 ^ (3 - i)) % 256)
	end
	local gain = buffer.readu16(h, 16)
	buffer.writeu8(d, 8, gain // 256)
	buffer.writeu8(d, 9, gain % 256)
	buffer.writeu8(d, 10, readu8(h, 18))
	if extra > 0 then
		buffer.copy(d, 11, h, 19, extra)
	end
	return d, preSkip
end

-- the Cues element's payload [d, e) -> { { time (s), pos (file offset of the cluster) } ... } in time order
function Webm.readCues(bytes, d, e, segStart, timescale)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local cues = {}
	children(b, d, e, function(cid, cd, cq)
		if cid == IDS.CuePoint then
			local time, pos
			children(b, cd, cq, function(xid, xd, xq)
				if xid == IDS.CueTime then
					time = readUint(b, xd, xq - xd)
				elseif xid == IDS.CueTrackPositions then
					children(b, xd, xq, function(yid, yd, yq)
						if yid == IDS.CueClusterPosition then
							pos = pos or readUint(b, yd, yq - yd)
						end
						return nil
					end)
				end
				return nil
			end)
			if time and pos then
				table.insert(cues, { time = time * timescale / 1e9, pos = segStart + pos })
			end
		end
		return nil
	end)
	table.sort(cues, function(x, y)
		return x.time < y.time
	end)
	return cues
end

-- a Cues element at pos (as the SeekHead says) inside a piece of the file starting at fileOffset -> the cue list
function Webm.readCuesAt(bytes, pos, segStart, timescale, fileOffset)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local p = pos - (fileOffset or 0)
	local id, q = readId(b, p, buffer.len(b))
	if id ~= IDS.Cues then
		fail("the cue list is not where the file says")
	end
	local size, d = readSize(b, q, buffer.len(b))
	if not size then
		fail("the cue list is cut off")
	end
	return Webm.readCues(b, d, math.min(d + size, buffer.len(b)), segStart, timescale)
end

function Webm.readHead(bytes, len)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	len = len or buffer.len(b)
	if not Webm.isWebm(b) then
		fail("not a WebM / Matroska file")
	end
	local head = { timescale = 1000000, duration = 0 }
	children(b, 0, len, function(id, d, e)
		if id == IDS.Segment then
			head.segStart = d
			head.segEnd = e
			head.segEndFile = size and d + size or nil
			return false
		end
		return nil
	end)
	if not head.segStart then
		fail("no Segment found: the file is cut off or not a complete WebM")
	end
	local tracks = {}
	local durationTicks
	children(b, head.segStart, head.segEnd, function(id, d, e, size, start)
		if id == IDS.Info then
			children(b, d, e, function(cid, cd, cq)
				if cid == IDS.TimecodeScale then
					head.timescale = readUint(b, cd, cq - cd)
				elseif cid == IDS.Duration then
					durationTicks = readFloat(b, cd, cq - cd)
				end
				return nil
			end)
		elseif id == IDS.Tracks then
			children(b, d, e, function(cid, cd, cq)
				if cid == IDS.TrackEntry then
					table.insert(tracks, readTrack(b, cd, cq))
				end
				return nil
			end)
		elseif id == IDS.Cues and size then
			head.cues = Webm.readCues(b, d, e, head.segStart, head.timescale)
		elseif id == IDS.SeekHead then
			-- where the Cues are (often after the clusters)
			children(b, d, e, function(cid, cd, cq)
				if cid == 0x4DBB then -- Seek
					local sid, spos
					children(b, cd, cq, function(xid, xd, xq)
						if xid == 0x53AB then
							sid = readUint(b, xd, xq - xd)
						elseif xid == 0x53AC then
							spos = readUint(b, xd, xq - xd)
						end
						return nil
					end)
					if sid == IDS.Cues and spos then
						head.cuesPos = head.segStart + spos
					end
				end
				return nil
			end)
		elseif id == IDS.Cluster then
			head.firstCluster = start
			return false
		end
		return nil
	end)
	for _, t in ipairs(tracks) do
		if t.kind == 1 and not head.video then
			head.video = t
		elseif t.kind == 2 and not head.audio then
			head.audio = t
		end
	end
	head.tracks = tracks
	local ts = head.timescale
	if durationTicks then
		head.duration = durationTicks * ts / 1e9
	end
	return head
end

-- the frames of one block (lacing split) -> list of { pos, size }
local function blockFrames(b, p, e, lacing)
	if lacing == 0 then
		return { { p, e - p } }
	end
	local count = readu8(b, p) + 1
	p += 1
	local sizes = table.create(count, 0)
	if lacing == 1 then -- Xiph
		for i = 1, count - 1 do
			local s = 0
			repeat
				local c = readu8(b, p)
				p += 1
				s += c
			until c < 255
			sizes[i] = s
		end
	elseif lacing == 3 then -- EBML: first size, then signed differences
		local first, q = readSize(b, p, e)
		if not first then
			fail("broken data (lacing)")
		end
		p = q
		sizes[1] = first
		for i = 2, count - 1 do
			local raw, q2 = readSize(b, p, e)
			if raw == false or raw == nil then
				fail("broken data (lacing)")
			end
			local n = q2 - p
			local bias = 2 ^ (7 * n - 1) - 1
			sizes[i] = sizes[i - 1] + (raw - bias)
			p = q2
		end
	else -- fixed
		local each = (e - p) // count
		for i = 1, count do
			sizes[i] = each
		end
	end
	local used = 0
	for i = 1, count - 1 do
		used += sizes[i]
	end
	sizes[count] = (e - p) - used
	local out = table.create(count)
	for i = 1, count do
		out[i] = { p, sizes[i] }
		p += sizes[i]
	end
	return out
end

local function isVp9Key(b, p, size)
	if size < 1 then
		return false
	end
	local c = readu8(b, p)
	if bit32.rshift(c, 6) ~= 2 then
		return false
	end
	local profile = bit32.band(bit32.rshift(c, 5), 1) + 2 * bit32.band(bit32.rshift(c, 4), 1)
	local bit = 3
	if profile == 3 then
		bit = 2
	end
	-- show_existing_frame, then frame_type (0 = key)
	if bit32.band(bit32.rshift(c, bit), 1) == 1 then
		return false
	end
	return bit32.band(bit32.rshift(c, bit - 1), 1) == 0
end

-- a VP8 frame's tag: bit 0 clear on a key frame
local function isVp8Key(b, p, size)
	return size >= 3 and bit32.band(readu8(b, p), 1) == 0
end

function Webm.readClusters(bytes, from, to, head, fileOffset)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	fileOffset = fileOffset or 0
	local vt, at = head.video, head.audio
	local vnum, anum = vt and vt.number, at and at.number
	local ts = head.timescale / 1e9
	local vsamples, asamples = {}, {}
	local vp9 = vt and vt.codecId == "V_VP9"
	local vp8 = vt and vt.codecId == "V_VP8"
	local function block(p, e, clusterTime, isSimple, refFound)
		local tn, q = readSize(b, p, e)
		if not tn or q + 3 > e then
			return
		end
		local rel = readu8(b, q) * 256 + readu8(b, q + 1)
		if rel >= 32768 then
			rel -= 65536
		end
		local flags = readu8(b, q + 2)
		local lacing = bit32.band(bit32.rshift(flags, 1), 3)
		local time = (clusterTime + rel) * ts
		local key = isSimple and bit32.band(flags, 0x80) ~= 0 or (not isSimple and not refFound)
		if tn == vnum then
			for _, f in ipairs(blockFrames(b, q + 3, e, lacing)) do
				local sync = key
				if vp9 then
					sync = isVp9Key(b, f[1], f[2])
				elseif vp8 then
					sync = isVp8Key(b, f[1], f[2])
				end
				table.insert(vsamples, { pos = f[1], size = f[2], pts = time, dts = time, sync = sync })
			end
		elseif tn == anum then
			local frames = blockFrames(b, q + 3, e, lacing)
			for _, f in ipairs(frames) do
				table.insert(asamples, { pos = f[1], size = f[2], pts = time, dts = time, sync = true })
			end
		end
	end
	local len = math.min(to, buffer.len(b))
	local p = from
	while p < len do
		local id, q = readId(b, p, len)
		if not id then
			break
		end
		local size, d = readSize(b, q, len)
		if size == false then
			break
		end
		if id ~= IDS.Cluster then
			if not size then
				break
			end
			p = d + size
			continue
		end
		local cut = size and d + size > len
		local stop = size and math.min(d + size, len) or len
		local clusterTime = 0
		local cp = d
		while cp < stop do
			local cid, cq = readId(b, cp, stop)
			if not cid then
				break
			end
			if not size and TOP[cid] then
				break -- (an unknown-size cluster ends here)
			end
			local csize, cd = readSize(b, cq, stop)
			if csize == false or csize == nil then
				break
			end
			local ce = cd + csize
			if ce > stop then
				-- the file ends inside this block: the frame is incomplete
				if cid == IDS.SimpleBlock or cid == IDS.BlockGroup then
					local n = #vsamples
					block(cd, stop, clusterTime, cid == IDS.SimpleBlock, false)
					for i = n + 1, #vsamples do
						vsamples[i].cut = true
					end
				end
				break
			end
			if cid == IDS.Timecode then
				clusterTime = readUint(b, cd, csize)
			elseif cid == IDS.SimpleBlock then
				block(cd, ce, clusterTime, true, false)
			elseif cid == IDS.BlockGroup then
				local bp, be, ref = nil, nil, false
				children(b, cd, ce, function(xid, xd, xq)
					if xid == IDS.Block then
						bp, be = xd, xq
					elseif xid == IDS.ReferenceBlock then
						ref = true
					end
					return nil
				end)
				if bp then
					block(bp, be, clusterTime, false, ref)
				end
			end
			cp = ce
		end
		if cut or not size then
			p = cp
			if cut then
				break
			end
		else
			p = d + size
		end
	end
	if fileOffset ~= 0 then
		for _, s in ipairs(vsamples) do
			s.filePos = s.pos + fileOffset
		end
	end
	return vsamples, asamples
end

-- a track's description in Formats.Mp4's shape
local function videoInfo(t)
	local v = { codec = VIDEO_CODECS[t.codecId] or t.codecId, codecId = t.codecId, width = t.width, height = t.height }
	if v.codec == "mp4v" then
		v.config = t.private -- (MPEG-4 Part 2: its VOL headers)
	elseif t.codecId == "V_MS/VFW/FOURCC" and t.private and buffer.len(t.private) >= 40 then
		-- (an AVI-style track: a BITMAPINFOHEADER, then the codec's setup)
		local fourcc = buffer.readstring(t.private, 16, 4)
		if VFW_MPEG4[string.upper(fourcc)] then
			v.codec, v.fourcc = "mp4v", fourcc
			if buffer.len(t.private) > 40 then
				v.config = buffer.create(buffer.len(t.private) - 40)
				buffer.copy(v.config, 0, t.private, 40)
			end
		else
			v.codec = fourcc
		end
	end
	if v.codec == "avc1" and t.private and buffer.len(t.private) >= 7 then
		local b = t.private
		local cfg = { nalLength = bit32.band(readu8(b, 4), 3) + 1, sps = {}, pps = {}, profile = readu8(b, 1), level = readu8(b, 3) }
		local c = 5
		local ns = bit32.band(readu8(b, c), 31)
		c += 1
		for _ = 1, ns do
			local l = readu8(b, c) * 256 + readu8(b, c + 1)
			local nb = buffer.create(l)
			buffer.copy(nb, 0, b, c + 2, l)
			table.insert(cfg.sps, nb)
			c += 2 + l
		end
		local np = readu8(b, c)
		c += 1
		for _ = 1, np do
			local l = readu8(b, c) * 256 + readu8(b, c + 1)
			local nb = buffer.create(l)
			buffer.copy(nb, 0, b, c + 2, l)
			table.insert(cfg.pps, nb)
			c += 2 + l
		end
		v.avcC = cfg
	end
	if v.codec == "hvc1" and t.private then
		v.hvcC = t.private
	end
	if v.codec == "av01" and t.private then
		v.av1C = t.private
	end
	return v
end
Webm.videoInfo = videoInfo

local function audioInfo(t)
	local a = { codecId = t.codecId, channels = t.channels or 2, sampleRate = t.sampleRate or 48000 }
	local id = t.codecId
	if id == "A_OPUS" then
		a.codec = "Opus"
		local preSkip
		if t.private then
			a.dOps, preSkip = opusHeadToDops(t.private)
		end
		if t.codecDelay and t.codecDelay > 0 then
			a.skip = math.floor(t.codecDelay * 48000 / 1e9 + 0.5)
		else
			a.skip = preSkip
		end
	elseif id == "A_VORBIS" then
		a.codec = "vorbis"
		if t.private then
			a.vorbisHeaders = xiphPackets(t.private)
		end
	elseif id == "A_AAC" or string.sub(id, 1, 6) == "A_AAC/" then
		a.codec = "mp4a"
		a.esds = { oti = 0x40, asc = t.private }
	elseif id == "A_MPEG/L3" then
		a.codec = ".mp3"
	elseif id == "A_FLAC" then
		a.codec = "fLaC"
		a.flacHeader = t.private -- ("fLaC" and the metadata blocks)
	elseif id == "A_AC3" then
		a.codec = "ac-3"
	elseif id == "A_EAC3" then
		a.codec = "ec-3"
	else
		a.codec = id
	end
	return a
end
Webm.audioInfo = audioInfo

function Webm.parse(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local len = buffer.len(b)
	local head = Webm.readHead(b, len)
	if not head.video and not head.audio then
		fail("the file has no video or sound track")
	end
	for _, t in ipairs({ head.video, head.audio }) do
		if t and t.encoded then
			fail("the file's tracks are compressed or encrypted (ContentEncoding), which isn't supported")
		end
	end
	if not head.firstCluster then
		fail("the file has no frames (no clusters)")
	end
	local vs, as = Webm.readClusters(b, head.firstCluster, len, head)
	local out = {}
	if head.audio then
		local a = audioInfo(head.audio)
		if #as > 0 then
			local t0 = as[1].pts
			for _, s in ipairs(as) do
				s.pts -= t0
				s.dts = s.pts
			end
			a.samples = as
			a.duration = head.duration
			out.audio = a
		end
	end
	if head.video then
		local v = videoInfo(head.video)
		if #vs == 0 then
			fail("the video track has no frames")
		end
		local t0 = math.huge
		for _, s in ipairs(vs) do
			t0 = math.min(t0, s.pts)
		end
		for _, s in ipairs(vs) do
			s.pts -= t0
			s.dts = s.pts
		end
		v.samples = vs
		v.duration = head.duration
		if v.duration <= 0 and #vs > 1 then
			local last = vs[#vs].pts
			v.duration = last + last / (#vs - 1)
		end
		out.video = v
	end
	out.head = head
	return out
end

-- stream parts: from each cue (a cluster that starts with a key frame) to a later one, at least minSeconds long
function Webm.planParts(head, cues, fileSize, minSeconds)
	minSeconds = minSeconds or 2
	local list = {}
	for _, c in ipairs(cues) do
		if #list == 0 or c.pos > list[#list].pos then
			table.insert(list, c)
		end
	end
	local stop = math.min(fileSize, head.segEndFile or fileSize)
	local parts = {}
	local i = 1
	while i <= #list do
		local j = i + 1
		while list[j] and list[j].time - list[i].time < minSeconds do
			j += 1
		end
		local b = list[j] and (list[j].pos - 1) or (stop - 1)
		table.insert(parts, { start = list[i].time, a = list[i].pos, b = b })
		i = j
	end
	return parts
end

local MAGIC = "VPS1" -- (a part of a VP9 video)
local MAGIC8 = "VPS8" -- (a part of a VP8 video)
function Webm.isPart(bytes)
	if buffer.len(bytes) < 4 then
		return false
	end
	local m = buffer.readstring(bytes, 0, 4)
	return m == MAGIC or m == MAGIC8
end

-- Opus samples (48 kHz) in one packet, from its TOC byte
local function opusSamples(b, p, size)
	if size < 1 then
		return 0
	end
	local toc = readu8(b, p)
	local config = bit32.rshift(toc, 3)
	local ms
	if config < 12 then
		ms = ({ 10, 20, 40, 60 })[config % 4 + 1]
	elseif config < 16 then
		ms = ({ 10, 20 })[config % 2 + 1]
	else
		ms = ({ 2.5, 5, 10, 20 })[config % 4 + 1]
	end
	local c = bit32.band(toc, 3)
	local count = c == 0 and 1 or (c == 3 and (size > 1 and bit32.band(readu8(b, p + 1), 63) or 0) or 2)
	return math.floor(48 * ms * count + 0.5)
end
Webm.opusSamples = opusSamples

function Webm.packPart(body, a, head)
	local b = type(body) == "string" and buffer.fromstring(body) or body
	local vs, as = Webm.readClusters(b, 0, buffer.len(b), head, a)
	local at = head.audio and audioInfo(head.audio)
	local useAudio = at and (at.codec == "Opus" or at.codec == "vorbis") and #as > 0
	local size = 64
	for _, s in ipairs(vs) do
		size += 12 + s.size
	end
	if useAudio then
		for _, s in ipairs(as) do
			size += 12 + s.size
		end
		size += at.dOps and buffer.len(at.dOps) or 0
		for _, h in ipairs(at.vorbisHeaders or {}) do
			size += 4 + buffer.len(h)
		end
	end
	local out = buffer.create(size)
	local o = 0
	local function u8(v)
		buffer.writeu8(out, o, v)
		o += 1
	end
	local function u32(v)
		buffer.writeu32(out, o, v)
		o += 4
	end
	local function f64(v)
		buffer.writef64(out, o, v)
		o += 8
	end
	local function bytes(src, p, n)
		buffer.copy(out, o, src, p, n)
		o += n
	end
	buffer.writestring(out, 0, head.video and head.video.codecId == "V_VP8" and MAGIC8 or MAGIC)
	o = 4
	u32(#vs)
	for _, s in ipairs(vs) do
		f64(s.pts)
		u32(s.size)
		bytes(b, s.pos, s.size)
	end
	if not useAudio then
		u8(0)
	else
		u8(at.codec == "Opus" and 1 or 2)
		if at.codec == "Opus" then
			local d = at.dOps
			u32(d and buffer.len(d) or 0)
			if d then
				bytes(d, 0, buffer.len(d))
			end
			-- (each part starts a fresh decoder: its start-up delay is dropped)
			local preSkip = d and (readu8(d, 2) * 256 + readu8(d, 3)) or 312
			u32(preSkip)
		else
			u8(#at.vorbisHeaders)
			for _, h in ipairs(at.vorbisHeaders) do
				u32(buffer.len(h))
				bytes(h, 0, buffer.len(h))
			end
		end
		u32(#as)
		for _, s in ipairs(as) do
			f64(s.pts)
			u32(s.size)
			bytes(b, s.pos, s.size)
		end
	end
	local r = buffer.create(o)
	buffer.copy(r, 0, out, 0, o)
	return r
end

function Webm.unpackPart(bytes)
	local b = bytes
	if not Webm.isPart(b) then
		fail("not a stream part")
	end
	local o = 4
	local function u8()
		local v = readu8(b, o)
		o += 1
		return v
	end
	local function u32()
		local v = buffer.readu32(b, o)
		o += 4
		return v
	end
	local function f64()
		local v = buffer.readf64(b, o)
		o += 8
		return v
	end
	local function take(n)
		local nb = buffer.create(n)
		buffer.copy(nb, 0, b, o, n)
		o += n
		return nb
	end
	local units = {}
	for i = 1, u32() do
		local pts = f64()
		units[i] = { pts = pts, data = take(u32()) }
	end
	local out = { video = { codec = buffer.readstring(b, 0, 4) == MAGIC8 and "vp8" or "vp9", units = units }, audio = {} }
	local kind = u8()
	if kind ~= 0 then
		local a = out.audio
		if kind == 1 then
			a.codec = "opus"
			local n = u32()
			a.dOps = n > 0 and take(n) or nil
			a.skip = u32()
		else
			a.codec = "vorbis"
			a.vorbisHeaders = {}
			for i = 1, u8() do
				a.vorbisHeaders[i] = take(u32())
			end
		end
		a.frames = {}
		for i = 1, u32() do
			local pts = f64()
			a.frames[i] = { pts = pts, data = take(u32()) }
		end
		a.start = a.frames[1] and a.frames[1].pts
	end
	return out
end

return Webm
