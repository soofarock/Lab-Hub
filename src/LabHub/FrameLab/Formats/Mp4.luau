--!native
--!optimize 2
-- MP4 / MOV (ISO base media) demuxer: finds the video track and lists its samples (frames) with their byte ranges
-- and timestamps, plus the decoder setup (avcC for H.264, hvcC for H.265, av1C for AV1).
--
--   local m = Mp4.parse(bytes)
--   m.video = { codec = "avc1", width, height, timescale, duration (s), samples = { { pos, size, dts, pts, sync } } (decode
--               order, times in seconds), avcC = { nalLength, sps = { buffer }, pps = { buffer }, profile, level } }
--               H.265 / HEVC: codec "hvc1" / "hev1", hvcC = the hvcC box's payload (buffer)
--               AV1: codec "av01", av1C = the av1C box's payload (buffer)
--               MPEG-4 Part 2 video: codec "mp4v", config = its VOL headers (from the esds; an MPEG-1 / MPEG-2 track in
--               the same box is named "m2v1")
--   m.audio = { codec = "mp4a", channels, sampleRate, timescale, samples, esds = { oti, asc = buffer } (mp4a: oti 0x40 / 0x66-0x68
--               = AAC, 0x69 / 0x6B = MP3), dOps = buffer (codec "Opus": the Opus setup box), skip = samples of encoder
--               delay to drop (from the edit list) } or nil
--   Mp4.isMp4(bytes)

local Mp4 = {}

local readu8, readu32 = buffer.readu8, buffer.readu32
local function be32(b, o)
	return readu8(b, o) * 16777216 + readu8(b, o + 1) * 65536 + readu8(b, o + 2) * 256 + readu8(b, o + 3)
end
local function be16(b, o)
	return readu8(b, o) * 256 + readu8(b, o + 1)
end
local function be64(b, o)
	return be32(b, o) * 4294967296 + be32(b, o + 4)
end
local function s32(v)
	return v >= 2147483648 and v - 4294967296 or v
end

local function fail(msg)
	error("MP4: " .. msg, 0)
end

function Mp4.isMp4(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if buffer.len(b) < 12 then
		return false
	end
	local t = buffer.readstring(b, 4, 4)
	return t == "ftyp" or t == "moov" or t == "mdat" or t == "free" or t == "wide" or t == "skip"
end

-- boxes in [pos, stop): calls fn(type, start of payload, end of payload)
local function boxes(b, pos, stop, fn)
	while pos + 8 <= stop do
		local size = be32(b, pos)
		local t = buffer.readstring(b, pos + 4, 4)
		local head = 8
		if size == 1 then
			if pos + 16 > stop then
				break
			end
			size = be64(b, pos + 8)
			head = 16
		elseif size == 0 then
			size = stop - pos
		end
		if size < head then
			fail("a damaged box (" .. t .. ")")
		end
		local e = math.min(pos + size, stop)
		if fn(t, pos + head, e, pos + size > stop) == false then
			return
		end
		pos += size
	end
end

local function parseTrack(b, s, e)
	local tr = { stts = {}, ctts = nil, stsc = {}, sizes = nil, chunks = {}, sync = nil }
	local function walk(t, p, q)
		if t == "mdia" or t == "minf" or t == "stbl" or t == "edts" then
			boxes(b, p, q, walk)
		elseif t == "tkhd" then
			local v = readu8(b, p)
			local o = p + (v == 1 and 84 or 72)
			if o + 8 <= q then
				tr.tkWidth = be32(b, o) / 65536
				tr.tkHeight = be32(b, o + 4) / 65536
			end
		elseif t == "mdhd" then
			local v = readu8(b, p)
			if v == 1 then
				tr.timescale = be32(b, p + 20)
				tr.mediaDuration = be64(b, p + 24)
			else
				tr.timescale = be32(b, p + 12)
				tr.mediaDuration = be32(b, p + 16)
			end
		elseif t == "hdlr" then
			-- (the media's handler: a QuickTime file has a second one, for its data reference, inside minf)
			tr.handler = tr.handler or buffer.readstring(b, p + 8, 4)
		elseif t == "elst" then
			local v = readu8(b, p)
			local n = be32(b, p + 4)
			tr.edits = {}
			local o = p + 8
			for _ = 1, n do
				if v == 1 then
					table.insert(tr.edits, { duration = be64(b, o), mediaTime = be64(b, o + 8) })
					o += 20
				else
					table.insert(tr.edits, { duration = be32(b, o), mediaTime = s32(be32(b, o + 4)) })
					o += 12
				end
			end
		elseif t == "stsd" then
			local n = be32(b, p + 4)
			if n >= 1 then
				local o = p + 8
				local size = be32(b, o)
				local fmt = buffer.readstring(b, o + 4, 4)
				tr.codec = fmt
				if tr.handler == "vide" or fmt == "avc1" or fmt == "avc3" or fmt == "hvc1" or fmt == "hev1" or fmt == "av01" then
					tr.width = be16(b, o + 32)
					tr.height = be16(b, o + 34)
					boxes(b, o + 86, math.min(o + size, q), function(ct, cp, cq)
						if ct == "esds" then
							tr.esds = Mp4.readEsds(b, cp + 4, cq)
							tr.config = tr.esds.asc
							local oti = tr.esds.oti or 0x20
							if fmt == "mp4v" and ((oti >= 0x60 and oti <= 0x65) or oti == 0x6A) then
								tr.codec = "m2v1"
							end
						elseif ct == "avcC" then
							local nalLength = bit32.band(readu8(b, cp + 4), 3) + 1
							local cfg = { nalLength = nalLength, sps = {}, pps = {}, profile = readu8(b, cp + 1), level = readu8(b, cp + 3) }
							local c = cp + 5
							local ns = bit32.band(readu8(b, c), 31)
							c += 1
							for _ = 1, ns do
								local l = be16(b, c)
								local nb = buffer.create(l)
								buffer.copy(nb, 0, b, c + 2, l)
								table.insert(cfg.sps, nb)
								c += 2 + l
							end
							local np = readu8(b, c)
							c += 1
							for _ = 1, np do
								local l = be16(b, c)
								local nb = buffer.create(l)
								buffer.copy(nb, 0, b, c + 2, l)
								table.insert(cfg.pps, nb)
								c += 2 + l
							end
							tr.avcC = cfg
						elseif ct == "hvcC" then
							local nb = buffer.create(cq - cp)
							buffer.copy(nb, 0, b, cp, cq - cp)
							tr.hvcC = nb
						elseif ct == "av1C" then
							local nb = buffer.create(cq - cp)
							buffer.copy(nb, 0, b, cp, cq - cp)
							tr.av1C = nb
						end
					end)
				else
					tr.channels = be16(b, o + 24)
					tr.sampleRate = be32(b, o + 32) / 65536
					-- children after the AudioSampleEntry fields (QuickTime versions 1 and 2 add 16 / 36 bytes)
					local version = be16(b, o + 16)
					local child = o + 36 + (version == 1 and 16 or (version == 2 and 36 or 0))
					local function findEsds(p0, p1)
						boxes(b, p0, p1, function(ct, cp, cq)
							if ct == "esds" then
								tr.esds = Mp4.readEsds(b, cp + 4, cq)
								return false
							elseif ct == "dOps" then
								local nb = buffer.create(cq - cp)
								buffer.copy(nb, 0, b, cp, cq - cp)
								tr.dOps = nb
								return false
							elseif ct == "dfLa" then
								local nb = buffer.create(cq - cp)
								buffer.copy(nb, 0, b, cp, cq - cp)
								tr.dfLa = nb -- (FLAC: version and flags, then the metadata blocks)
								return false
							elseif ct == "wave" then
								findEsds(cp, cq)
							end
							return nil
						end)
					end
					if child < math.min(o + size, q) then
						findEsds(child, math.min(o + size, q))
					end
				end
			end
		elseif t == "stts" then
			local n = be32(b, p + 4)
			for i = 0, n - 1 do
				table.insert(tr.stts, { be32(b, p + 8 + i * 8), be32(b, p + 12 + i * 8) })
			end
		elseif t == "ctts" then
			local v = readu8(b, p)
			local n = be32(b, p + 4)
			tr.ctts = {}
			for i = 0, n - 1 do
				local off = be32(b, p + 12 + i * 8)
				table.insert(tr.ctts, { be32(b, p + 8 + i * 8), v == 1 and s32(off) or s32(off) })
			end
		elseif t == "stsc" then
			local n = be32(b, p + 4)
			for i = 0, n - 1 do
				table.insert(tr.stsc, { be32(b, p + 8 + i * 12), be32(b, p + 12 + i * 12) })
			end
		elseif t == "stsz" then
			local fixed = be32(b, p + 4)
			local n = be32(b, p + 8)
			tr.count = n
			if fixed == 0 then
				local sizes = table.create(n, 0)
				for i = 0, n - 1 do
					sizes[i + 1] = be32(b, p + 12 + i * 4)
				end
				tr.sizes = sizes
			else
				tr.fixedSize = fixed
			end
		elseif t == "stco" then
			local n = be32(b, p + 4)
			for i = 0, n - 1 do
				tr.chunks[i + 1] = be32(b, p + 8 + i * 4)
			end
		elseif t == "co64" then
			local n = be32(b, p + 4)
			for i = 0, n - 1 do
				tr.chunks[i + 1] = be64(b, p + 8 + i * 8)
			end
		elseif t == "stss" then
			local n = be32(b, p + 4)
			tr.sync = {}
			for i = 0, n - 1 do
				tr.sync[be32(b, p + 8 + i * 4)] = true
			end
		end
	end
	boxes(b, s, e, walk)
	return tr
end

-- MPEG-4 descriptors in an 'esds' box -> { oti = object type indication, asc = DecoderSpecificInfo bytes (buffer) }
function Mp4.readEsds(b, p, q)
	local out = {}
	local function descLen(o)
		local n = 0
		for _ = 1, 4 do
			local c = readu8(b, o)
			o += 1
			n = n * 128 + bit32.band(c, 127)
			if c < 128 then
				break
			end
		end
		return n, o
	end
	local function walk(o, stop)
		while o + 2 <= stop do
			local tag = readu8(b, o)
			local len, body = descLen(o + 1)
			local e = math.min(body + len, stop)
			if tag == 3 then -- ES_Descriptor
				local flags = readu8(b, body + 2)
				local c = body + 3
				if bit32.band(flags, 0x80) ~= 0 then
					c += 2
				end
				if bit32.band(flags, 0x40) ~= 0 then
					c += 1 + readu8(b, c)
				end
				if bit32.band(flags, 0x20) ~= 0 then
					c += 2
				end
				walk(c, e)
			elseif tag == 4 then -- DecoderConfigDescriptor
				out.oti = readu8(b, body)
				walk(body + 13, e)
			elseif tag == 5 then -- DecoderSpecificInfo
				local nb = buffer.create(math.max(0, e - body))
				buffer.copy(nb, 0, b, body, e - body)
				out.asc = nb
			end
			o = e
		end
	end
	walk(p, q)
	return out
end

-- sample list (decode order) of a parsed track
local function samplesOf(tr, fileLen)
	local n = tr.count or 0
	local ts = tr.timescale or 1
	local list = table.create(n)
	-- positions: chunks and samples-per-chunk
	local si = 1
	local stsc = tr.stsc
	for ci = 1, #tr.chunks do
		local per = 0
		for k = #stsc, 1, -1 do
			if stsc[k][1] <= ci then
				per = stsc[k][2]
				break
			end
		end
		local pos = tr.chunks[ci]
		for _ = 1, per do
			if si > n then
				break
			end
			local size = tr.sizes and tr.sizes[si] or tr.fixedSize
			list[si] = { pos = pos, size = size }
			pos += size
			si += 1
		end
	end
	if si <= n then
		fail(("the sample table is damaged (%d of %d frames located)"):format(si - 1, n))
	end
	-- times
	local dts = 0
	local k = 1
	for _, e in ipairs(tr.stts) do
		for _ = 1, e[1] do
			if k > n then
				break
			end
			list[k].dts = dts
			dts += e[2]
			k += 1
		end
	end
	for i = k, n do
		list[i].dts = dts
	end
	k = 1
	if tr.ctts then
		for _, e in ipairs(tr.ctts) do
			for _ = 1, e[1] do
				if k > n then
					break
				end
				list[k].cts = e[2]
				k += 1
			end
		end
	end
	local minPts = math.huge
	for i = 1, n do
		local s = list[i]
		s.pts = s.dts + (s.cts or 0)
		if s.pts < minPts then
			minPts = s.pts
		end
		s.sync = (tr.sync == nil) or tr.sync[i] == true
		if s.pos + s.size > fileLen then
			s.cut = true
		end
	end
	for i = 1, n do
		local s = list[i]
		s.pts = (s.pts - minPts) / ts
		s.dts = s.dts / ts
	end
	return list
end

function Mp4.parse(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local len = buffer.len(b)
	local moov, fragmented
	boxes(b, 0, len, function(t, p, q)
		if t == "moov" then
			moov = { p, q }
		elseif t == "moof" then
			fragmented = true
		end
	end)
	if not moov then
		if fragmented then
			fail("this is a fragmented MP4 (a streaming segment), which isn't supported; save the whole video as a normal MP4")
		end
		fail("no movie header (moov) found: the file is cut off or not a complete MP4")
	end
	local out = {}
	boxes(b, moov[1], moov[2], function(t, p, q)
		if t == "mvex" then
			fragmented = true
		elseif t == "trak" then
			local tr = parseTrack(b, p, q)
			if tr.handler == "vide" and not out.video then
				out.video = tr
			elseif tr.handler == "soun" and not out.audio then
				out.audio = tr
			end
		end
	end)
	-- the sound (if any)
	local a = out.audio
	if a and (a.count or 0) > 0 and #a.chunks > 0 then
		local ok, list = pcall(samplesOf, a, len)
		if ok then
			a.samples = list
			a.duration = (a.mediaDuration or 0) / (a.timescale or 1)
			-- encoder delay: the first non-empty edit's media time (in the track's timescale, normally the sample rate)
			local e
			for _, ed in ipairs(a.edits or {}) do
				if ed.mediaTime >= 0 then
					e = ed
					break
				end
			end
			if e and e.mediaTime > 0 and a.timescale then
				a.skip = math.floor(e.mediaTime * (a.sampleRate or a.timescale) / a.timescale + 0.5)
			end
		end
	end
	local v = out.video
	if not v then
		if a and a.samples then
			return out -- sound only (M4A)
		end
		fail("the file has no video track")
	end
	if (v.count or 0) == 0 then
		if fragmented then
			fail("this is a fragmented MP4 (a streaming segment), which isn't supported; save the whole video as a normal MP4")
		end
		fail("the video track has no frames")
	end
	v.samples = samplesOf(v, len)
	v.duration = (v.mediaDuration or 0) / (v.timescale or 1)
	if v.duration <= 0 then
		local last = v.samples[#v.samples]
		v.duration = last.pts
	end
	return out
end

return Mp4
