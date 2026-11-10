-- FrameLab streams: a video from an HLS address (.m3u8) that is never downloaded whole. The server fetches and converts
-- only the parts (the playlist's segments) near where it is being watched, on the import workers (Tools.ImportPool),
-- and keeps the most recently used few; clients stream the converted chunks like any other video (Tools.Net). A segment
-- is cut into FLV2 chunks of at most PART seconds, each made by its own worker (a long segment is ready sooner), so a
-- jump goes straight to the part it needs; the chunk asked for is made first. The picture only, for now: no sound.
--   Live.isPlaylist(text) -> true for an HLS playlist
--   local live = Live.open(url, text, options)   (yields: reads the playlists, probes the first segment)
--       options: Lines (the variant picked from a master playlist: the largest at most this tall), Sizes(w, h) ->
--       { { w, h, kbps } ... } (the sizes kept, largest first), Fps (24), MaxSeconds, Workers
--   live.fps, live.frames, live.seconds, live.width, live.height (the source's), live.sizes, live.held() (bytes in memory)
--   live.hasSound; live.sound(si) -> the sound of part si (rawHead's parts) as an AudioLab clip (RBA3) and the stream time
--       it starts at; nil while it is being made, nil, "none" for a part without sound (made on an import worker; asking
--       also starts the next part's)
--   live.head(rendition) -> the FLV2 header and chunk directory (chunk sizes 0: each chunk's come with it)
--   live.chunk(rendition, ci) -> bytes (the chunk's two coder streams), sizeA, sizeB; nil while it is being made, or
--       nil, message when it failed. Asking for a chunk also starts the few after it.
-- An MP4 / MOV at an address that sends byte ranges streams the same way (Live.openMp4): its sample tables (moov)
-- first, then each stretch from one keyframe to the next as it is watched, as access units (Ts.packUnits).
--   local live = Live.openMp4(url, options)   (yields; options as for open, and MaxLines: a taller source is refused
--       with a message saying it is imported whole instead)
-- A WebM (VP9 or VP8) at such an address streams alike (Live.openWebm, which openMp4 hands it to): its header and cue index
-- first, then each stretch from one cued key frame to a later one (Formats.Webm.packPart), with its Opus / Vorbis sound.
-- One without a cue index is refused with a message saying it is imported whole instead.
--   local live = Live.openWebm(url, options, firstBytes, fileSize)
-- Unconverted, for clients that decode the H.264 themselves (Video.DirectReader):
--   live.rawHead() -> a directory in the same form: one entry a segment (its first frame), the source's size
--   live.rawChunk(si) -> the segment's bytes (MPEG-TS), its offset (seconds from the segment's start to its first
--       frame); nil while it downloads, nil, message when that failed. Asking also fetches the next two.
-- As the block player's own picture, for clients that don't decode (phones; Video.BlockStream):
--   live.blocksHead() -> a directory in the same form: one entry a piece (its first frame), the picture's size
--   live.blockPiece(pi) -> the piece's bytes (Zstd); nil while it is being made, nil, message when that failed
local Live = {}

local HttpService = game:GetService("HttpService")
local EncodingService = game:GetService("EncodingService")
local FrameLab = script:FindFirstAncestor("FrameLab")
local Ts = require(FrameLab.Formats.Ts)
local ImportJob = require(FrameLab.Tools.ImportJob)
local ImportPool = require(FrameLab.Tools.ImportPool)
local Mp4 = require(FrameLab.Formats.Mp4)
local Webm = require(FrameLab.Formats.Webm)
local BlockStream = require(FrameLab.Video.BlockStream)

local AHEAD = 4 -- chunks made ahead of the one asked for
local KEEP = 40 -- converted chunks kept (the least recently asked for go first)
local PART = 4 -- longest chunk (seconds)
local KEEP_SEGMENTS = 12 -- downloaded segments kept (chunks are made from them; clients decoding themselves fetch them)
local KEEP_SOUNDS = 12 -- parts' sound clips kept
local BLOCK_LINES = 180 -- the block stream's picture (its short side)
local BLOCK_PIECE = 2 -- seconds a piece of it lasts (about)
local KEEP_PIECES = 40 -- block stream pieces kept

local function get(url)
	local ok, r = pcall(HttpService.RequestAsync, HttpService, { Url = url, Method = "GET" })
	if not ok then
		error("the download failed (" .. tostring(r) .. ")", 0)
	end
	if not r.Success then
		error(("the stream's server answered %d"):format(r.StatusCode), 0)
	end
	return r.Body
end

function Live.isPlaylist(text)
	return type(text) == "string" and string.find(string.sub(text, 1, 64), "#EXTM3U", 1, true) ~= nil
end

function Live.open(url, text, options)
	options = options or {}
	local pl = Ts.playlist(text, url)
	if #pl.variants > 0 then
		local v = Ts.pickVariant(pl.variants, options.Lines or 360)
		url = v.url
		pl = Ts.playlist(get(url), url)
	end
	if #pl.segments == 0 then
		error("the playlist lists no video parts", 0)
	end
	if not pl.ended then
		error("that's a live broadcast (its playlist isn't finished): only whole videos can be streamed", 0)
	end
	local firstBytes = buffer.fromstring(get(pl.segments[1].url))
	local w, h, hasAudio = ImportJob.probeTs(firstBytes)
	local o = table.clone(options)
	o.HasSound = hasAudio == true
	return Live.fromSegments(pl.segments, firstBytes, w, h, o)
end

-- the stream from its parts: srcSegments = { { start, duration, url or fetch = function() -> buffer } ... } (MPEG-TS,
-- or access units: Ts.packUnits); firstBytes: the first one's bytes; w, h: the picture's size
function Live.fromSegments(srcSegments, firstBytes, w, h, options)
	options = options or {}
	local self = { width = w, height = h }
	local fps = options.Fps or 24
	self.fps = fps
	self.sizes = options.Sizes and options.Sizes(w, h) or { { w = w, h = h, kbps = 60 } }
	local maxSeconds = options.MaxSeconds or 7200
	-- the chunks: each segment cut into pieces of at most PART seconds (frames [k0, k1); offset: seconds from the
	-- segment's start to frame k0)
	local segments = {}
	local frames = 0
	for si, sg in ipairs(srcSegments) do
		if sg.start >= maxSeconds then
			break
		end
		local k0 = math.ceil(sg.start * fps - 1e-6)
		local k1 = math.ceil(math.min(sg.start + sg.duration, maxSeconds) * fps - 1e-6)
		local pieces = math.max(1, math.ceil((k1 - k0) / (PART * fps)))
		for p = 0, pieces - 1 do
			local a = k0 + (k1 - k0) * p // pieces
			local b = k0 + (k1 - k0) * (p + 1) // pieces
			if b > a then
				table.insert(segments, { src = sg, segment = si, k0 = a, k1 = b, offset = a / fps - sg.start })
				frames = b
			end
		end
	end
	self.frames, self.seconds = frames, frames / fps
	self.segments = segments
	-- the segments whole (for clients decoding themselves)
	local raw = {}
	for _, sg in ipairs(srcSegments) do
		local k0 = math.ceil(sg.start * fps - 1e-6)
		if k0 >= frames then
			break
		end
		table.insert(raw, { src = sg, k0 = k0, offset = k0 / fps - sg.start })
	end
	self.raw = raw
	local workers = math.max(1, options.Workers or 4)

	-- the FLV2 header and directory of each size
	local heads = {}
	function self.head(r)
		if heads[r] then
			return heads[r]
		end
		local sz = self.sizes[r]
		local b = buffer.create(24 + #segments * 16)
		buffer.writestring(b, 0, "FLV2")
		buffer.writeu8(b, 4, 1)
		buffer.writeu8(b, 5, fps)
		buffer.writeu16(b, 6, sz.w)
		buffer.writeu16(b, 8, sz.h)
		buffer.writeu32(b, 10, frames)
		buffer.writeu16(b, 14, math.min(65535, fps * 4))
		buffer.writeu16(b, 16, #segments)
		buffer.writeu8(b, 18, 2)
		for i, sg in ipairs(segments) do
			buffer.writeu32(b, 24 + (i - 1) * 16 + 12, sg.k0)
		end
		heads[r] = b
		return b
	end

	-- converted chunks: cache[ci] = { [rendition] = { data, sizeA, sizeB } }, most recently used last in `order`
	local cache, order, busy, failed = {}, {}, {}, {}
	local running = 0
	-- downloaded segments (a segment's chunks share one download): segBytes[si] = buffer, or `true` while it downloads
	local segBytes, segOrder = { [1] = firstBytes }, { 1 }
	local function segment(si, src)
		while segBytes[si] == true do
			task.wait(0.05)
		end
		local b = segBytes[si]
		if not b then
			segBytes[si] = true
			local ok, res = pcall(function()
				return src.fetch and src.fetch() or buffer.fromstring(get(src.url))
			end)
			if not ok then
				segBytes[si] = nil
				error(res, 0)
			end
			b = res
			segBytes[si] = b
			table.insert(segOrder, si)
			while #segOrder > KEEP_SEGMENTS do
				local old = table.remove(segOrder, 1)
				if segBytes[old] ~= true then
					segBytes[old] = nil
				end
			end
		end
		return b
	end
	function self.rawHead()
		if heads.raw then
			return heads.raw
		end
		local b = buffer.create(24 + #raw * 16)
		buffer.writestring(b, 0, "FLV2")
		buffer.writeu8(b, 4, 1)
		buffer.writeu8(b, 5, fps)
		buffer.writeu16(b, 6, w)
		buffer.writeu16(b, 8, h)
		buffer.writeu32(b, 10, frames)
		buffer.writeu16(b, 14, math.min(65535, fps * 4))
		buffer.writeu16(b, 16, #raw)
		buffer.writeu8(b, 18, 2)
		for i, sg in ipairs(raw) do
			buffer.writeu32(b, 24 + (i - 1) * 16 + 12, sg.k0)
		end
		heads.raw = b
		return b
	end
	local rawFailed = {}
	local function fetchRaw(si)
		local ok, err = pcall(segment, si, raw[si].src)
		if not ok then
			rawFailed[si] = tostring(err)
		end
	end
	function self.rawChunk(si)
		local sg = raw[si]
		if not sg then
			return nil, "no such part"
		end
		if segBytes[si] == nil and not rawFailed[si] then
			task.spawn(fetchRaw, si)
		elseif typeof(segBytes[si]) == "buffer" then
			-- (the next two once this one is here, one download at a time: a jump's own part gets the whole connection)
			for k = si + 1, math.min(si + 2, #raw) do
				if segBytes[k] == true then
					break
				elseif segBytes[k] == nil and not rawFailed[k] then
					task.spawn(fetchRaw, k)
					break
				end
			end
		end
		local b = segBytes[si]
		if typeof(b) == "buffer" then
			return b, sg.offset
		end
		if rawFailed[si] then
			local why = rawFailed[si]
			rawFailed[si] = nil
			return nil, why
		end
		return nil
	end

	local function touch(ci)
		local i = table.find(order, ci)
		if i then
			table.remove(order, i)
		end
		table.insert(order, ci)
		while #order > KEEP do
			cache[table.remove(order, 1)] = nil
		end
	end
	local function make(ci)
		local sg = segments[ci]
		local ok, err = pcall(function()
			local bytes = segment(sg.segment, sg.src)
			local job = { kind = "ts", bytes = bytes, k0 = sg.k0, k1 = sg.k1, offset = sg.offset, fps = fps, sizes = self.sizes,
				layers = 2 }
			local parts
			if ImportPool.available() then
				local res, why = ImportPool.submit(job, workers)
				if not res then
					error(why, 0)
				end
				parts = res
			else
				parts = ImportJob.encodeTsSegment(job, function()
					task.wait()
				end)
			end
			local entry = {}
			for r, p in ipairs(parts) do
				local c = p.chunks[1]
				local a, b = c.a, c.b
				local data = buffer.create(buffer.len(a) + buffer.len(b))
				buffer.copy(data, 0, a)
				buffer.copy(data, buffer.len(a), b)
				entry[r] = { data = data, sizeA = buffer.len(a), sizeB = buffer.len(b) }
			end
			cache[ci] = entry
			touch(ci)
		end)
		if not ok then
			failed[ci] = tostring(err)
		end
		busy[ci] = nil
		running -= 1
	end
	local function start(ci)
		busy[ci] = true
		running += 1
		task.spawn(make, ci)
	end
	-- the chunk asked for first (alone, so nothing else slows it down); the ones after it once it is made
	local function schedule(from)
		if not cache[from] then
			if not busy[from] and not failed[from] then
				start(from)
			end
			return
		end
		for ci = from + 1, math.min(from + AHEAD, #segments) do
			if running >= workers then
				break
			end
			if not cache[ci] and not busy[ci] and not failed[ci] then
				start(ci)
			end
		end
	end
	self.schedule = schedule

	-- the sound: each part's own AudioLab clip, made from its downloaded bytes on an import worker
	self.hasSound = options.HasSound == true
	local sounds, soundBusy, soundFailed, soundOrder = {}, {}, {}, {}
	local function makeSound(si)
		local ok, err = pcall(function()
			local bytes = segment(si, raw[si].src)
			local clip, start
			if ImportPool.available() then
				clip, start = ImportPool.submit({ bytes = bytes, start = raw[si].src.start }, workers, "sound")
				if clip == nil and start ~= nil then
					error(start, 0)
				end
			else
				clip, start = ImportJob.tsSound(bytes, raw[si].src.start, function()
					task.wait()
				end)
			end
			sounds[si] = clip and { clip = clip, start = start } or false
			table.insert(soundOrder, si)
			while #soundOrder > KEEP_SOUNDS do
				sounds[table.remove(soundOrder, 1)] = nil
			end
		end)
		if not ok then
			soundFailed[si] = tostring(err)
		end
		soundBusy[si] = nil
	end
	function self.sound(si)
		if not raw[si] then
			return nil, "no such part"
		end
		for k = si, math.min(si + 1, #raw) do
			if sounds[k] == nil and not soundBusy[k] and not soundFailed[k] then
				soundBusy[k] = true
				task.spawn(makeSound, k)
			end
		end
		local s = sounds[si]
		if s then
			return s.clip, s.start
		elseif s == false then
			return nil, "none"
		end
		if soundFailed[si] then
			local why = soundFailed[si]
			soundFailed[si] = nil
			return nil, why
		end
		return nil
	end

	-- the block stream (Video.BlockStream): the block player's own picture at BLOCK_LINES, for clients that don't decode
	-- the video themselves (phones). Made on the import workers a segment at a time, as it is asked for, in pieces of
	-- about BLOCK_PIECE seconds (a chunk each for the clients); a segment carries on from where the one before ended, and
	-- the next one is started as soon as one is done while the stream is being watched
	local BW, BH = BlockStream.size(w, h, BLOCK_LINES)
	self.blockWidth, self.blockHeight = BW, BH
	local pieces, segPieces = {}, {}
	for si, rs in ipairs(raw) do
		local k0 = rs.k0
		local k1 = raw[si + 1] and raw[si + 1].k0 or frames
		if k1 > k0 then
			local n = math.max(1, math.floor((k1 - k0) / (BLOCK_PIECE * fps) + 0.5))
			local cuts = {}
			for p = 0, n - 1 do
				local a = k0 + (k1 - k0) * p // n
				table.insert(cuts, a)
				table.insert(pieces, { seg = si, i = p + 1, k0 = a })
			end
			segPieces[si] = { first = #pieces - n + 1, cuts = cuts, k1 = k1 }
		end
	end
	function self.blocksHead()
		if heads.blocks then
			return heads.blocks
		end
		local b = buffer.create(24 + #pieces * 16)
		buffer.writestring(b, 0, "FLV2")
		buffer.writeu8(b, 4, 1)
		buffer.writeu8(b, 5, fps)
		buffer.writeu16(b, 6, BW)
		buffer.writeu16(b, 8, BH)
		buffer.writeu32(b, 10, frames)
		buffer.writeu16(b, 14, math.min(65535, fps * 4))
		buffer.writeu16(b, 16, #pieces)
		buffer.writeu8(b, 18, 2)
		for i, pc in ipairs(pieces) do
			buffer.writeu32(b, 24 + (i - 1) * 16 + 12, pc.k0)
		end
		heads.blocks = b
		return b
	end
	local blockData, blockOrder, blockFailed, blockJobs, blockEnd, blockEndOrder, blockAsked = {}, {}, {}, {}, {}, {}, {}
	-- (a piece of segment si is being made: a job on it started at or before that piece)
	local function covered(si, i)
		for _, j in ipairs(blockJobs[si] or {}) do
			if j.from <= i then
				return true
			end
		end
		return false
	end
	local function makeBlocks(si, from)
		local sp = segPieces[si]
		local rec = { from = from }
		blockJobs[si] = blockJobs[si] or {}
		table.insert(blockJobs[si], rec)
		local ok, err = pcall(function()
			local bytes = segment(si, raw[si].src)
			local job = { bytes = bytes, k0 = raw[si].k0, k1 = sp.k1, offset = raw[si].offset, fps = fps, w = BW, h = BH,
				cuts = sp.cuts, from = from, state = from == 1 and blockEnd[si - 1] or nil }
			local function onPart(kind, a, b)
				if kind == "piece" then
					local pi = sp.first + a - 1
					blockData[pi] = EncodingService:CompressBuffer(b, Enum.CompressionAlgorithm.Zstd, 6)
					blockFailed[pi] = nil
					table.insert(blockOrder, pi)
					while #blockOrder > KEEP_PIECES do
						blockData[table.remove(blockOrder, 1)] = nil
					end
				elseif kind == "state" then
					blockEnd[si] = a
					table.insert(blockEndOrder, si)
					while #blockEndOrder > 3 do
						blockEnd[table.remove(blockEndOrder, 1)] = nil
					end
				end
			end
			if ImportPool.available() then
				local res, why = ImportPool.submit(job, workers, "blocks", onPart)
				if res == nil and why then
					error(why, 0)
				end
			else
				BlockStream.encodeSegment(job, function()
					task.wait()
				end, onPart)
			end
		end)
		local list = blockJobs[si]
		table.remove(list, table.find(list, rec))
		if #list == 0 then
			blockJobs[si] = nil
		end
		if not ok then
			for i = from, #sp.cuts do
				local pi = sp.first + i - 1
				if not blockData[pi] then
					blockFailed[pi] = tostring(err)
				end
			end
			return
		end
		local nextSp = segPieces[si + 1]
		if nextSp and os.clock() - (blockAsked[si] or -math.huge) < 20 and not blockData[nextSp.first] and not covered(si + 1, 1) then
			task.spawn(makeBlocks, si + 1, 1)
		end
	end
	function self.blockPiece(pi)
		local pc = pieces[pi]
		if not pc then
			return nil, "no such part"
		end
		blockAsked[pc.seg] = os.clock()
		local d = blockData[pi]
		if d then
			return d
		end
		if blockFailed[pi] then
			local why = blockFailed[pi]
			blockFailed[pi] = nil -- (asked again: made again)
			return nil, why
		end
		if not covered(pc.seg, pc.i) then
			task.spawn(makeBlocks, pc.seg, pc.i)
		end
		return nil
	end

	-- bytes this stream holds in the server's memory now (downloaded parts, converted chunks)
	function self.held()
		local n = 0
		for _, b in pairs(segBytes) do
			if typeof(b) == "buffer" then
				n += buffer.len(b)
			end
		end
		for _, e in pairs(cache) do
			for _, c in pairs(e) do
				n += buffer.len(c.data)
			end
		end
		for _, s in pairs(sounds) do
			if s then
				n += buffer.len(s.clip)
			end
		end
		for _, d in pairs(blockData) do
			n += buffer.len(d)
		end
		return n
	end

	function self.chunk(r, ci)
		if not segments[ci] then
			return nil, "no such part"
		end
		schedule(ci)
		local e = cache[ci]
		if e and e[r] then
			touch(ci)
			return e[r].data, e[r].sizeA, e[r].sizeB
		end
		if failed[ci] then
			local why = failed[ci]
			failed[ci] = nil -- (asked again: tried again)
			return nil, why
		end
		return nil
	end

	schedule(1)
	return self
end

-- part of a file at an address: bytes [a, b] (a string) and the file's whole size; error when the site sends no ranges
local function range(url, a, b)
	local ok, r = pcall(HttpService.RequestAsync, HttpService, { Url = url, Method = "GET",
		Headers = { Range = ("bytes=%d-%d"):format(a, b) } })
	if not ok then
		error("the download failed (" .. tostring(r) .. ")", 0)
	end
	if r.StatusCode == 200 then
		error("that site doesn't send parts of a file (no byte ranges), so it can't be streamed", 0)
	elseif r.StatusCode ~= 206 then
		error(("the video's site answered %d"):format(r.StatusCode), 0)
	end
	local total
	for k, v in pairs(r.Headers or {}) do
		if string.lower(k) == "content-range" then
			total = tonumber(string.match(v, "/(%d+)"))
		end
	end
	return r.Body, total
end

local function be32(s, o)
	return string.byte(s, o + 1) * 16777216 + string.byte(s, o + 2) * 65536 + string.byte(s, o + 3) * 256 + string.byte(s, o + 4)
end

function Live.openMp4(url, options)
	options = options or {}
	-- the top-level boxes up to the sample tables (moov: at the start of a file made for the web, else after the media)
	local head, total = range(url, 0, 65535)
	total = total or #head
	if string.sub(head, 1, 4) == "\26\69\223\163" then
		return Live.openWebm(url, options, head, total)
	end
	local moovAt, moovSize
	local pos = 0
	for _ = 1, 64 do
		if pos + 8 > total then
			break
		end
		local h = (pos + 16 <= #head) and string.sub(head, pos + 1, pos + 16) or range(url, pos, math.min(pos + 15, total - 1))
		local size, t = be32(h, 0), string.sub(h, 5, 8)
		if size == 1 and #h >= 16 then
			size = be32(h, 8) * 4294967296 + be32(h, 12)
		elseif size == 0 then
			size = total - pos
		end
		if size < 8 then
			error("the file isn't a readable MP4 (a damaged box)", 0)
		elseif t == "moov" then
			moovAt, moovSize = pos, size
			break
		elseif t == "moof" then
			error("this is a fragmented MP4 (made for streaming sites), which can't be streamed here: import it instead", 0)
		end
		pos += size
	end
	if not moovAt then
		error("no movie header (moov) found: this isn't an MP4 / MOV, or the file is cut off", 0)
	end
	if moovSize > 48 * 1048576 then
		error("the video's header is too big to stream", 0)
	end
	local moov = (moovAt + moovSize <= #head) and string.sub(head, moovAt + 1, moovAt + moovSize)
		or range(url, moovAt, moovAt + moovSize - 1)
	local m = Mp4.parse(buffer.fromstring(moov))
	local v = m.video
	if not v.avcC then
		error(("the video is %s: only H.264 can be streamed"):format(tostring(v.codec)), 0)
	end
	local maxLines = options.MaxLines or 400
	if math.min(v.width or 0, v.height or 0) > maxLines then
		error(("%dx%d is more than stream mode's %dp, so it is imported whole instead (shrunk to fit)"):format(v.width or 0,
			v.height or 0, maxLines), 0)
	end
	local samples = v.samples
	for _, s in ipairs(samples) do
		s.cut = nil -- (located in the file, not in the header this was read from)
	end
	local nalLength = v.avcC.nalLength
	local params = {}
	for _, p in ipairs(v.avcC.sps) do
		table.insert(params, p)
	end
	for _, p in ipairs(v.avcC.pps) do
		table.insert(params, p)
	end
	-- one access unit with start codes from a sample (length-prefixed NAL units); the parameter sets before the first
	local function unitOf(body, a, s, first)
		local off, stop = s.pos - a + 1, s.pos - a + s.size
		local nals = {}
		local p = off
		while p + nalLength - 1 <= stop do
			local n = 0
			for k = 0, nalLength - 1 do
				n = n * 256 + string.byte(body, p + k)
			end
			p += nalLength
			if n <= 0 or p + n - 1 > stop then
				break
			end
			table.insert(nals, { p, n })
			p += n
		end
		local size = 0
		if first then
			for _, x in ipairs(params) do
				size += 4 + buffer.len(x)
			end
		end
		for _, x in ipairs(nals) do
			size += 4 + x[2]
		end
		local out = buffer.create(size)
		local o = 0
		if first then
			for _, x in ipairs(params) do
				buffer.writeu32(out, o, 0x01000000) -- (00 00 00 01)
				buffer.copy(out, o + 4, x)
				o += 4 + buffer.len(x)
			end
		end
		for _, x in ipairs(nals) do
			buffer.writeu32(out, o, 0x01000000)
			buffer.writestring(out, o + 4, string.sub(body, x[1], x[1] + x[2] - 1))
			o += 4 + x[2]
		end
		return out
	end
	-- the sound, when it is AAC: its samples (in time order) and the ADTS header each one is sent with
	local aSamples, adtsHeader
	local au = m.audio
	local asc = au and au.esds and au.esds.asc
	local oti = au and au.esds and au.esds.oti
	if au and au.samples and asc and buffer.len(asc) >= 2 and (oti == 0x40 or (oti and oti >= 0x66 and oti <= 0x68)) then
		local b0, b1 = buffer.readu8(asc, 0), buffer.readu8(asc, 1)
		local objType = bit32.rshift(b0, 3)
		local freqIdx = bit32.bor(bit32.lshift(bit32.band(b0, 7), 1), bit32.rshift(b1, 7))
		local chan = bit32.band(bit32.rshift(b1, 3), 15)
		local profile = math.clamp((objType == 5 or objType == 29) and 1 or objType - 1, 0, 3) -- (HE-AAC: its LC core)
		if freqIdx < 13 and chan > 0 then
			aSamples = table.clone(au.samples)
			for _, s in ipairs(aSamples) do
				s.cut = nil
			end
			table.sort(aSamples, function(x, y)
				return x.pts < y.pts
			end)
			function adtsHeader(f, size)
				local len = size + 7
				buffer.writeu8(f, 0, 0xFF)
				buffer.writeu8(f, 1, 0xF1)
				buffer.writeu8(f, 2, bit32.bor(bit32.lshift(profile, 6), bit32.lshift(freqIdx, 2), bit32.rshift(chan, 2)))
				buffer.writeu8(f, 3, bit32.bor(bit32.lshift(bit32.band(chan, 3), 6), bit32.band(bit32.rshift(len, 11), 3)))
				buffer.writeu8(f, 4, bit32.band(bit32.rshift(len, 3), 0xFF))
				buffer.writeu8(f, 5, bit32.bor(bit32.lshift(bit32.band(len, 7), 5), 0x1F))
				buffer.writeu8(f, 6, 0xFC)
			end
		end
	end
	-- the parts: from each keyframe to the next (decode order)
	local keys = {}
	for i, s in ipairs(samples) do
		if s.sync or i == 1 then
			table.insert(keys, i)
		end
	end
	local srcSegments = {}
	for k, i0 in ipairs(keys) do
		local i1 = (keys[k + 1] or (#samples + 1)) - 1
		local start, a, b = math.huge, math.huge, 0
		for i = i0, i1 do
			local s = samples[i]
			start = math.min(start, s.pts)
			a = math.min(a, s.pos)
			b = math.max(b, s.pos + s.size - 1)
		end
		local sg = { start = start, a = a, b = b }
		function sg.fetch()
			local body = range(url, sg.a, sg.b)
			if #body < sg.b - sg.a + 1 then
				error("the video's site sent less than was asked for", 0)
			end
			local units = table.create(i1 - i0 + 1)
			for i = i0, i1 do
				units[i - i0 + 1] = { pts = samples[i].pts, data = unitOf(body, sg.a, samples[i], i == i0) }
			end
			local audio
			if sg.audio then
				audio = {}
				for j = sg.audio[1], sg.audio[2] do
					local s = aSamples[j]
					local f = buffer.create(7 + s.size)
					adtsHeader(f, s.size)
					buffer.writestring(f, 7, string.sub(body, s.pos - sg.a + 1, s.pos - sg.a + s.size))
					table.insert(audio, { pts = s.pts, data = f })
				end
			end
			return Ts.packUnits(units, audio)
		end
		table.insert(srcSegments, sg)
	end
	table.sort(srcSegments, function(x, y)
		return x.start < y.start
	end)
	for k, sg in ipairs(srcSegments) do
		local nextStart = srcSegments[k + 1] and srcSegments[k + 1].start or v.duration
		sg.duration = math.max(0, nextStart - sg.start)
	end
	-- the sound (AAC): each part carries the samples of its own stretch of time, as ADTS frames (Ts.packUnits)
	if aSamples then
		local j = 1
		for k, sg in ipairs(srcSegments) do
			local stop = srcSegments[k + 1] and srcSegments[k + 1].start or math.huge
			local j0 = j
			while aSamples[j] and aSamples[j].pts < stop do
				local s = aSamples[j]
				sg.a = math.min(sg.a, s.pos)
				sg.b = math.max(sg.b, s.pos + s.size - 1)
				j += 1
			end
			if j > j0 then
				sg.audio = { j0, j - 1 }
			end
		end
	end
	local firstBytes = srcSegments[1].fetch()
	local w, h, hasAudio = ImportJob.probeTs(firstBytes)
	-- (the video's own rate, at most 24)
	local srcFps = #samples / math.max(v.duration, 1e-3)
	local o = table.clone(options)
	o.Fps = o.Fps or math.max(1, math.floor(math.min(24, srcFps) + 0.5))
	o.HasSound = hasAudio == true
	local live = Live.fromSegments(srcSegments, firstBytes, w, h, o)
	live.mp4 = true
	return live
end

function Live.openWebm(url, options, first, total)
	options = options or {}
	if not first then
		first, total = range(url, 0, 65535)
	end
	total = total or #first
	local head = Webm.readHead(buffer.fromstring(first))
	if not head.firstCluster and #first < total then
		-- (a long header: read again, more of it)
		first = range(url, 0, math.min(total, 2097152) - 1)
		head = Webm.readHead(buffer.fromstring(first))
	end
	local vt = head.video
	if not vt then
		error("the WebM has no video track", 0)
	elseif vt.codecId ~= "V_VP9" and vt.codecId ~= "V_VP8" then
		local names = { V_AV1 = "AV1", ["V_MPEG4/ISO/AVC"] = "H.264", ["V_MPEGH/ISO/HEVC"] = "H.265" }
		error(("the video is %s: only VP9 and VP8 WebM can be streamed (import it instead)"):format(names[vt.codecId] or vt.codecId), 0)
	elseif vt.encoded then
		error("the WebM's tracks are compressed or encrypted, so it can't be streamed", 0)
	end
	local maxLines = options.MaxLines or 400
	if math.min(vt.width or 0, vt.height or 0) > maxLines then
		error(("%dx%d is more than stream mode's %dp, so it is imported whole instead (shrunk to fit)"):format(vt.width or 0,
			vt.height or 0, maxLines), 0)
	end
	local cues = head.cues
	if (not cues or #cues == 0) and head.cuesPos and head.cuesPos < total then
		local piece = range(url, head.cuesPos, math.min(total, head.cuesPos + 4194304) - 1)
		cues = Webm.readCuesAt(buffer.fromstring(piece), head.cuesPos, head.segStart, head.timescale, head.cuesPos)
	end
	if not cues or #cues == 0 then
		error("the WebM has no index (cues), so it can't be streamed in parts: it is imported whole instead", 0)
	end
	local plan = Webm.planParts(head, cues, total, 2)
	local t0 = plan[1].start
	local srcSegments = {}
	for k, p in ipairs(plan) do
		local sg = { start = p.start - t0, a = p.a, b = p.b }
		local nextStart = plan[k + 1] and plan[k + 1].start or math.max(head.duration, p.start + 1)
		sg.duration = math.max(0, nextStart - p.start)
		function sg.fetch()
			local body = range(url, sg.a, sg.b)
			if #body < sg.b - sg.a + 1 then
				error("the video's site sent less than was asked for", 0)
			end
			return Webm.packPart(buffer.fromstring(body), sg.a, head)
		end
		table.insert(srcSegments, sg)
	end
	local firstBytes = srcSegments[1].fetch()
	local w, h, hasAudio = ImportJob.probeTs(firstBytes)
	-- (the video's own rate, at most 24: from the track's frame duration, else from the first part)
	local srcFps
	if vt.defaultDuration and vt.defaultDuration > 0 then
		srcFps = 1e9 / vt.defaultDuration
	else
		local units = Webm.unpackPart(firstBytes).video.units
		srcFps = #units / math.max(srcSegments[1].duration, 1e-3)
	end
	local o = table.clone(options)
	o.Fps = o.Fps or math.max(1, math.floor(math.min(24, srcFps) + 0.5))
	o.HasSound = hasAudio == true
	local live = Live.fromSegments(srcSegments, firstBytes, w, h, o)
	live.webm = true
	return live
end

return Live
