--!native
--!optimize 2
-- FrameLab video stream ("FLV1"): the pictures a player needs, in a form that is cheap to apply. The player fits GUI
-- strips to them at runtime (so quality can change live); this stream only says what the picture is.
--
--   Frames are cut into 8 x 8 blocks. A keyframe stores every block; any other frame stores only the blocks that
--   changed (more than ChangeTol on any channel), plus a slide: when the whole picture moved (a camera pan), the last
--   picture is shifted first and the player moves its whole canvas with one property write instead of redrawing.
--   Colours are stored at 6 bits per channel (strips are fitted within a larger tolerance anyway); zstd squeezes it.
--   Frames are grouped in chunks that start with a keyframe (KeyEvery frames, default 2 s): a player decompresses one
--   chunk at a time, and seeking starts from a chunk.
--
-- Writing (importer):
--   local w = Stream.writer(width, height, fps, { KeyEvery, ChangeTol, Compress = function(buf) -> buf })
--   w:add(image)            -- RGBA image of exactly width x height
--   local bytes, stats = w:finish()
-- Reading (player):
--   local r = Stream.reader(bytes, { Decompress = function(buf, rawSize) -> buf })
--       (FLV2 videos and FLV2 rendition sets, "FLVS", open with Video.Flv2's reader: a set at the size
--       Stream.deviceLines() picks, or options.Rendition)
--   r.width, r.height, r.fps, r.frameCount, r.pw (padded width: the row stride of r.rgba is pw * 4)
--   local info = r:advance()       -- applies the next frame to r.rgba; info = { key, dx, dy, blocks = { block ids } }
--   r:seek(frame)                  -- 0-based; applies the chunk's keyframe and the frames after it
--   r.frame                        -- index of the frame now in r.rgba (-1 before the first)

local Stream = {}
Stream.Magic = "FLV1"
local HEADER = 20
local DIR_ENTRY = 16
local BLOCK_BYTES = 192

-- growable byte writer
local function newOut(cap)
	return { buf = buffer.create(cap), n = 0 }
end
local function ensure(o, extra)
	local cap = buffer.len(o.buf)
	if o.n + extra > cap then
		while o.n + extra > cap do
			cap *= 2
		end
		local nb = buffer.create(cap)
		buffer.copy(nb, 0, o.buf, 0, o.n)
		o.buf = nb
	end
end

local function q(v)
	return bit32.bor(bit32.band(v, 0xFC), 2) -- 6-bit, centred in its step
end

function Stream.writer(width, height, fps, options)
	options = options or {}
	local w = {}
	local BW, BH = math.ceil(width / 8), math.ceil(height / 8)
	local PW, PH = BW * 8, BH * 8
	w.width, w.height, w.fps = width, height, math.clamp(math.floor(fps + 0.5), 1, 60)
	w.keyEvery = options.KeyEvery or w.fps * 2
	w.changeTol = options.ChangeTol or 8
	w.compress = options.Compress
	w.frames = 0
	w.chunks = {} -- { raw = buffer, rawSize, firstFrame }
	local recon = buffer.create(PW * PH * 3) -- what a player shows (RGB, padded)
	local prevLuma, curLuma = nil, nil
	local src = buffer.create(PW * PH * 3) -- this frame, padded by repeating the edge pixels
	local chunk
	local stats = { keyframes = 0, blocks = 0, slides = 0, sameFrames = 0 }

	local function loadSource(image)
		local data = image.data
		for y = 0, PH - 1 do
			local sy = math.min(y, height - 1)
			for x = 0, PW - 1 do
				local sx = math.min(x, width - 1)
				local i = (sy * width + sx) * 4
				local o = (y * PW + x) * 3
				buffer.writeu8(src, o, buffer.readu8(data, i))
				buffer.writeu8(src, o + 1, buffer.readu8(data, i + 1))
				buffer.writeu8(src, o + 2, buffer.readu8(data, i + 2))
			end
		end
		-- luma at half resolution for the slide search
		local lw, lh = width // 2, height // 2
		curLuma = table.create(lw * lh, 0)
		for y = 0, lh - 1 do
			for x = 0, lw - 1 do
				local i = (y * 2 * width + x * 2) * 4
				curLuma[y * lw + x + 1] = buffer.readu8(data, i) * 0.3 + buffer.readu8(data, i + 1) * 0.59 + buffer.readu8(data, i + 2) * 0.11
			end
		end
	end

	-- best whole-picture shift (in source pixels, even) between the last frame and this one, or 0, 0
	local function findSlide()
		if not prevLuma then
			return 0, 0
		end
		local lw, lh = width // 2, height // 2
		local R = math.min(12, lw // 4, lh // 4)
		local function err(dx, dy)
			local s, n = 0, 0
			for y = math.max(0, -dy), math.min(lh, lh - dy) - 1, 2 do
				local row, prow = y * lw, (y + dy) * lw
				for x = math.max(0, -dx), math.min(lw, lw - dx) - 1 do
					s += math.abs(curLuma[row + x + 1] - prevLuma[prow + x + dx + 1])
					n += 1
				end
			end
			return n > 0 and s / n or math.huge
		end
		local e0 = err(0, 0)
		if e0 < 1.5 then
			return 0, 0 -- still picture
		end
		local bx, be = 0, e0
		for dx = -R, R do
			if dx ~= 0 then
				local e = err(dx, 0)
				if e < be then
					bx, be = dx, e
				end
			end
		end
		local by = 0
		for dy = -R, R do
			if dy ~= 0 then
				local e = err(bx, dy)
				if e < be then
					by, be = dy, e
				end
			end
		end
		if (bx ~= 0 or by ~= 0) and be < 0.5 * e0 then
			return bx * 2, by * 2
		end
		return 0, 0
	end

	-- shift recon so that recon'(x, y) = recon(x + dx, y + dy) (areas shifted in from outside keep old pixels; the
	-- blocks there differ from the source and get sent)
	local function shiftRecon(dx, dy)
		local tmp = buffer.create(PW * PH * 3)
		buffer.copy(tmp, 0, recon, 0)
		for y = 0, PH - 1 do
			local sy = y + dy
			if sy >= 0 and sy < PH then
				local x0 = math.max(0, -dx)
				local x1 = math.min(PW, PW - dx)
				if x1 > x0 then
					buffer.copy(recon, (y * PW + x0) * 3, tmp, (sy * PW + x0 + dx) * 3, (x1 - x0) * 3)
				end
			end
		end
	end

	local function startChunk()
		chunk = { out = newOut(64 * 1024), firstFrame = w.frames }
		table.insert(w.chunks, chunk)
	end

	function w:add(image)
		assert(image.width == width and image.height == height, "Stream: frame size differs from the stream's")
		loadSource(image)
		local key = (w.frames % w.keyEvery) == 0
		local dx, dy = 0, 0
		if key then
			startChunk()
			stats.keyframes += 1
		else
			dx, dy = findSlide()
			if dx ~= 0 or dy ~= 0 then
				shiftRecon(dx, dy)
				stats.slides += 1
			end
		end
		-- which blocks to send
		local list = {}
		local tol = w.changeTol
		for by = 0, BH - 1 do
			for bx = 0, BW - 1 do
				local send = key
				if not send then
					for y = by * 8, by * 8 + 7 do
						local o = (y * PW + bx * 8) * 3
						for k = 0, 23 do
							if math.abs(buffer.readu8(src, o + k) - buffer.readu8(recon, o + k)) > tol then
								send = true
								break
							end
						end
						if send then
							break
						end
					end
				end
				if send then
					table.insert(list, by * BW + bx)
				end
			end
		end
		if #list == 0 and dx == 0 and dy == 0 then
			stats.sameFrames += 1
		end
		local o = chunk.out
		ensure(o, 5 + #list * (2 + BLOCK_BYTES))
		buffer.writeu8(o.buf, o.n, key and 0 or 1)
		buffer.writei8(o.buf, o.n + 1, dx)
		buffer.writei8(o.buf, o.n + 2, dy)
		buffer.writeu16(o.buf, o.n + 3, #list)
		o.n += 5
		if not key then
			for _, id in ipairs(list) do
				buffer.writeu16(o.buf, o.n, id)
				o.n += 2
			end
		end
		for _, id in ipairs(list) do
			local bx, by = id % BW, id // BW
			for y = by * 8, by * 8 + 7 do
				local p = (y * PW + bx * 8) * 3
				for k = 0, 23 do
					local v = q(buffer.readu8(src, p + k))
					buffer.writeu8(o.buf, o.n, v)
					buffer.writeu8(recon, p + k, v)
					o.n += 1
				end
			end
		end
		stats.blocks += #list
		prevLuma = curLuma
		w.frames += 1
	end

	function w:finish()
		local payloads, total = {}, 0
		for i, c in ipairs(w.chunks) do
			local raw = buffer.create(c.out.n)
			buffer.copy(raw, 0, c.out.buf, 0, c.out.n)
			local stored = w.compress and w.compress(raw) or raw
			payloads[i] = { data = stored, raw = c.out.n, first = c.firstFrame }
			total += buffer.len(stored)
		end
		local dirSize = #payloads * DIR_ENTRY
		local out = buffer.create(HEADER + dirSize + total)
		buffer.writestring(out, 0, Stream.Magic)
		buffer.writeu8(out, 4, 1)
		buffer.writeu8(out, 5, w.fps)
		buffer.writeu16(out, 6, width)
		buffer.writeu16(out, 8, height)
		buffer.writeu32(out, 10, w.frames)
		buffer.writeu16(out, 14, w.keyEvery)
		buffer.writeu16(out, 16, #payloads)
		buffer.writeu8(out, 18, w.compress and 1 or 0)
		local off = 0
		for i, p in ipairs(payloads) do
			local d = HEADER + (i - 1) * DIR_ENTRY
			buffer.writeu32(out, d, off)
			buffer.writeu32(out, d + 4, buffer.len(p.data))
			buffer.writeu32(out, d + 8, p.raw)
			buffer.writeu32(out, d + 12, p.first)
			buffer.copy(out, HEADER + dirSize + off, p.data, 0)
			off += buffer.len(p.data)
		end
		stats.frames = w.frames
		stats.bytes = buffer.len(out)
		stats.seconds = w.frames / w.fps
		stats.bytesPerSecond = stats.bytes / math.max(stats.seconds, 1e-9)
		stats.blocksPerFrame = stats.blocks / math.max(w.frames, 1)
		stats.blocksPerPicture = BW * BH
		return out, stats
	end

	return w
end

function Stream.isStream(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return buffer.len(b) >= HEADER and buffer.readstring(b, 0, 4) == Stream.Magic
end

-- how fast this device runs Luau (ms for a fixed loop; worked out once): Roblox servers and Studio run scripts as
-- native code, most player devices don't (about 6x slower), and decoding a video is that much work
local benchMs
function Stream.benchmark()
	if benchMs then
		return benchMs
	end
	local b = buffer.create(4096)
	for i = 0, 4095 do
		buffer.writeu8(b, i, i % 251)
	end
	local best = math.huge
	for _ = 1, 3 do
		local t0 = os.clock()
		local s = 0
		for _ = 1, 60 do
			for i = 0, 4094 do
				local v = buffer.readu8(b, i) * 3 + buffer.readu8(b, i + 1)
				s += (v > 255) and (v // 2) or v
			end
		end
		best = math.min(best, (os.clock() - t0) * 1000 + s * 0)
	end
	benchMs = best
	return best
end

-- the most picture lines (the short side) this device plays, for videos imported at several sizes:
-- Config.VideoRendition "high" (the largest) / "low" (the smallest) / "auto" (default: 180 on every device: redrawing
-- a 360p picture's thousands of GUI objects keeps the game's frames long even where decoding is fast).
-- Stream.stepDown (lines): set for the session when a screen here fell behind at a larger size
Stream.stepDown = nil

-- whether this client decodes streams (HLS addresses, MP4s in stream mode) itself (Video.DirectReader) rather than
-- showing the server's work: Config.VideoDecode "auto" (default: computers yes, until a screen here falls behind doing
-- it; phones and tablets no), "client" or "server"
Stream.directOff = false
function Stream.decodeStreams()
	local ok, Config = pcall(function()
		return require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	end)
	local mode = ok and Config.VideoDecode or "auto"
	if mode == "client" then
		return true
	elseif mode == "server" then
		return false
	end
	local UIS = game:GetService("UserInputService")
	if UIS.TouchEnabled and not UIS.KeyboardEnabled then
		return false
	end
	return not Stream.directOff
end

-- a stream this client doesn't decode comes as the server's block picture (Video.BlockStream: only the blocks that
-- change are set here), unless that failed here (Stream.blocksOff: then the server's converted copy)
Stream.blocksOff = false
function Stream.blockStreams()
	return not Stream.blocksOff
end
function Stream.deviceLines()
	local ok, Config = pcall(function()
		return require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	end)
	local mode = ok and Config.VideoRendition or "auto"
	if mode == "high" then
		return math.huge
	elseif mode == "low" then
		return 0
	end
	local lines = 180
	return Stream.stepDown and math.min(lines, Stream.stepDown) or lines
end

-- the lines a stream this client decodes itself is shown at (Video.DirectReader): its blocks are worked out on worker
-- threads too, so a computer shows 360 with Config.VideoRendition "auto" (phones and tablets, and a client that stepped
-- down, 180); "high" / "low" as for deviceLines
function Stream.directLines()
	local lines = Stream.deviceLines()
	local ok, Config = pcall(function()
		return require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	end)
	if (ok and Config.VideoRendition or "auto") ~= "auto" then
		return lines
	end
	local UIS = game:GetService("UserInputService")
	if UIS.TouchEnabled and not UIS.KeyboardEnabled then
		return lines
	end
	return Stream.stepDown and math.min(360, Stream.stepDown) or 360
end

function Stream.reader(bytes, options)
	options = options or {}
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if buffer.len(b) >= 4 and buffer.readstring(b, 0, 4) == "FLVS" then
		-- one video at several sizes: the one for this device (options.Rendition: its index)
		local Flv2 = require(script.Parent.Flv2)
		local list = Flv2.readSet(b)
		local i = options.Rendition or Flv2.pick(list, Stream.deviceLines())
		local e = list[math.clamp(i, 1, #list)]
		local sub = buffer.create(e.size)
		buffer.copy(sub, 0, b, e.offset, e.size)
		local r = Flv2.reader(sub, options)
		r.renditions, r.rendition = list, i
		return r
	end
	if buffer.len(b) >= 4 and buffer.readstring(b, 0, 4) == "FLV2" then
		return require(script.Parent.Flv2).reader(b, options) -- the small-file codec (same reader interface, plus render())
	end
	if not Stream.isStream(b) then
		error("not a FrameLab video stream")
	end
	local r = {}
	r.fps = buffer.readu8(b, 5)
	r.width, r.height = buffer.readu16(b, 6), buffer.readu16(b, 8)
	r.frameCount = buffer.readu32(b, 10)
	r.keyEvery = buffer.readu16(b, 14)
	local nChunks = buffer.readu16(b, 16)
	local compressed = buffer.readu8(b, 18) == 1
	local dataStart = HEADER + nChunks * DIR_ENTRY
	r.chunks = {}
	for i = 1, nChunks do
		local d = HEADER + (i - 1) * DIR_ENTRY
		r.chunks[i] = { off = dataStart + buffer.readu32(b, d), size = buffer.readu32(b, d + 4), raw = buffer.readu32(b, d + 8), first = buffer.readu32(b, d + 12) }
	end
	r.duration = r.frameCount / r.fps
	local BW, BH = math.ceil(r.width / 8), math.ceil(r.height / 8)
	local PW, PH = BW * 8, BH * 8
	r.bw, r.bh, r.pw, r.ph = BW, BH, PW, PH
	r.rgba = buffer.create(PW * PH * 4)
	buffer.fill(r.rgba, 0, 255)
	r.frame = -1
	local chunkIndex, raw, pos = 0, nil, 0
	local tmp = buffer.create(PW * PH * 4)

	local function openChunk(i)
		local c = r.chunks[i]
		local data = buffer.create(c.size)
		buffer.copy(data, 0, b, c.off, c.size)
		if compressed then
			if not options.Decompress then
				error("FrameLab video: this stream is compressed and no decompressor was given")
			end
			data = options.Decompress(data, c.raw)
		end
		chunkIndex, raw, pos = i, data, 0
	end

	local function slide(dx, dy)
		buffer.copy(tmp, 0, r.rgba, 0)
		for y = 0, PH - 1 do
			local sy = y + dy
			if sy >= 0 and sy < PH then
				local x0, x1 = math.max(0, -dx), math.min(PW, PW - dx)
				if x1 > x0 then
					buffer.copy(r.rgba, (y * PW + x0) * 4, tmp, (sy * PW + x0 + dx) * 4, (x1 - x0) * 4)
				end
			end
		end
	end

	function r:advance()
		if r.frame + 1 >= r.frameCount then
			return nil
		end
		local nextFrame = r.frame + 1
		local ci = chunkIndex
		if ci == 0 or (r.chunks[ci + 1] and nextFrame >= r.chunks[ci + 1].first) then
			openChunk(ci + 1)
		end
		local kind = buffer.readu8(raw, pos)
		local dx, dy = buffer.readi8(raw, pos + 1), buffer.readi8(raw, pos + 2)
		local n = buffer.readu16(raw, pos + 3)
		pos += 5
		local blocks = table.create(n)
		if kind == 0 then
			for i = 1, n do
				blocks[i] = i - 1
			end
		else
			for i = 1, n do
				blocks[i] = buffer.readu16(raw, pos)
				pos += 2
			end
		end
		if dx ~= 0 or dy ~= 0 then
			slide(dx, dy)
		end
		local rgba = r.rgba
		for i = 1, n do
			local id = blocks[i]
			local bx, by = id % BW, id // BW
			for y = by * 8, by * 8 + 7 do
				local o = (y * PW + bx * 8) * 4
				for x = 0, 7 do
					buffer.writeu8(rgba, o, buffer.readu8(raw, pos))
					buffer.writeu8(rgba, o + 1, buffer.readu8(raw, pos + 1))
					buffer.writeu8(rgba, o + 2, buffer.readu8(raw, pos + 2))
					o += 4
					pos += 3
				end
			end
		end
		r.frame = nextFrame
		return { key = kind == 0, dx = dx, dy = dy, blocks = blocks }
	end

	function r:seek(frame)
		frame = math.clamp(frame, 0, r.frameCount - 1)
		local ci = 1
		for i, c in ipairs(r.chunks) do
			if c.first <= frame then
				ci = i
			end
		end
		openChunk(ci)
		r.frame = r.chunks[ci].first - 1
		chunkIndex = ci
		local info
		while r.frame < frame do
			info = r:advance()
		end
		return info
	end

	return r
end

return Stream
