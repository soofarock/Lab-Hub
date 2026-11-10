--!native
--!optimize 2
-- FrameLab import work on MP4 / MOV (H.264, H.265, AV1 or MPEG-4 Part 2), WebM / Matroska (VP9, VP8, AV1, H.264, H.265
-- or MPEG-4 Part 2), AVI (MPEG-4 Part 2: Xvid, DivX) and MPEG (MPEG-1 / MPEG-2, or H.264 / H.265 in a transport stream) video that
-- can be split up: any run
-- of output frames is decoded from the sync sample (keyframe) before it, so parts of one video can be encoded at the
-- same time (Tools.ImportPool runs them on Actors) and put together with Flv2.assemble.
--
--   local m = ImportJob.parse(bytes)   the file's tracks (Formats.Mp4.parse, Formats.Webm.parse for WebM / MKV, or
--       Formats.Mpg.parse for MPEG program / transport streams: their video's samples are in its elementary stream, v.data;
--       Formats.Avi.parse for AVI: its MPEG-4 video and its MP3 / MP2 / AC-3 sound)
--
--   local t = ImportJob.mp4Timing(videoTrack, maxFps, maxSeconds)
--       t.fps, t.count (output frames), t.seconds, t.duration, t.srcFps, t.sourceIndex(k) -> display index of the
--       source frame shown at output frame k
--   ImportJob.mp4Frames(buf, videoTrack, t, k0, k1, sizes, onFrame, yield)
--       decodes output frames [k0, k1); onFrame(k, images) gets one RGBA image per size ({ w, h }) for each
--   local parts = ImportJob.encodeSegment(job, yield, progress)
--       job = { bytes (the MP4), k0, k1, sizes = { { w, h, kbps } ... }, maxFps, maxSeconds, layers, keyEvery }
--       -> one Flv2 part (w:finishPart()) per size; progress(framesDone) now and then
--   ImportJob.yuvToImages(dec, pic, sizes) -> one RGBA image per size ({ w, h }) of a decoded picture, box-filtered
--   ImportJob.yuvToImage(dec, pic, w, h) -> the same at one size
--   local part, info = ImportJob.encodeTsSegment(job, yield)   one HLS segment (MPEG-TS, H.264) -> one Flv2 part per size
--       job = { bytes (the segment), k0, k1 (its output frames in the whole video), offset (seconds from the segment's
--       start to frame k0), fps, sizes, layers }; the part is a single chunk starting at frame k0
--       info = { audio = Formats.Ts audio track (ADTS frames) or nil }
--   ImportJob.probeTs(bytes) -> width, height, hasAudio (a segment's picture size: its first frame is decoded)
--   (a stream part is an HLS segment (MPEG-TS, H.264), or a WebM stretch packed by Formats.Webm.packPart (VP9 / VP8))
--   ImportJob.tsFrames(bytes, k0, k1, offset, fps, sizes, onFrame(k, images), yield, from) -> audio track or nil
--       the decoded frames of one HLS segment, every one in [from or k0, k1) in order (clients decoding a stream
--       themselves; decoding starts at the last keyframe before `from`)
--   ImportJob.tsSound(bytes, segStart, yield, Encoder) -> clip, start   the sound of one stream part (AAC, MP3, Opus or Vorbis) as an
--       AudioLab clip (RBA3) and the stream time it starts at; nil when it has none (Encoder: AudioLab's Codec.Encoder,
--       required beforehand where this runs in parallel)

local FrameLab = script:FindFirstAncestor("FrameLab")
local Mp4 = require(FrameLab.Formats.Mp4)
local H264 = require(FrameLab.Video.H264)
local Hevc = require(FrameLab.Video.Hevc)
local Av1 = require(FrameLab.Video.Av1)
local Flv2 = require(FrameLab.Video.Flv2)
local Ts = require(FrameLab.Formats.Ts)
local Webm = require(FrameLab.Formats.Webm)
local Vp9 = require(FrameLab.Video.Vp9)
local Vp8 = require(FrameLab.Video.Vp8)
local Mpg = require(FrameLab.Formats.Mpg)
local Mpeg2 = require(FrameLab.Video.Mpeg2)
local Mpeg4 = require(FrameLab.Video.Mpeg4)
local Avi = require(FrameLab.Formats.Avi)

local Job = {}

-- a stream part: an MPEG-TS segment, or a WebM stretch (Formats.Webm.packPart), in the same shape
local function parseSegment(bytes)
	if Webm.isPart(bytes) then
		return Webm.unpackPart(bytes)
	end
	return Ts.parse(bytes)
end

function Job.parse(buf)
	if Avi.isAvi(buf) then
		local avi = Avi.parse(buf)
		return { container = "AVI", video = avi.video, audio = avi.track }
	end
	if Webm.isWebm(buf) then
		return Webm.parse(buf)
	end
	if Mpg.isMpg(buf) then
		return Mpg.parse(buf)
	end
	return Mp4.parse(buf)
end

do
	local readu8, writeu8, readu16, readu32, writeu32 = buffer.readu8, buffer.writeu8, buffer.readu16, buffer.readu32, buffer.writeu32
	local band, rshift = bit32.band, bit32.rshift

	local function colour(dec)
		local kr, kb = 0.299, 0.114
		if dec.bt709 then
			kr, kb = 0.2126, 0.0722
		end
		local kg = 1 - kr - kb
		local ys0, yscale, cscale = 16, 255 / 219, 255 / 224
		if dec.fullRange then
			ys0, yscale, cscale = 0, 1, 1
		end
		return ys0, yscale, 2 * (1 - kr) * cscale, 2 * (1 - kb) * cscale, 2 * (1 - kb) * kb / kg * cscale, 2 * (1 - kr) * kr / kg * cscale
	end

	-- box filter straight from the planes (any size)
	local MASKS = { 0x000000ff, 0x0000ffff, 0x00ffffff, 0xffffffff }
	local function direct(dec, pic, w: number, h: number)
		local W, Hh = dec.width, dec.height
		local cx, cy = dec.cropX or 0, dec.cropY or 0
		local Yp: buffer, Up: buffer, Vp: buffer = pic.Y, pic.U, pic.V
		local ys: number, cs: number, yo: number, co: number = pic.ys, pic.cs, pic.yo, pic.co
		local ylen = buffer.len(Yp)
		local out = buffer.create(w * h * 4)
		local ys0, yscale, rv, bu, gu, gv = colour(dec)
		local x0s, x1s, ms = table.create(w, 0), table.create(w, 0), table.create(w, 0)
		local c0s, c1s = table.create(w, 0), table.create(w, 0)
		for ox = 0, w - 1 do
			local x0 = ox * W // w
			local x1 = math.max(x0 + 1, (ox + 1) * W // w)
			x0s[ox + 1], x1s[ox + 1] = x0 + cx, x1 + cx
			ms[ox + 1] = x1 - x0 <= 4 and MASKS[x1 - x0] or 0
			c0s[ox + 1], c1s[ox + 1] = (x0 + cx) // 2, (x1 - 1 + cx) // 2 + 1
		end
		local SY = table.create(w, 0)
		local o = 0
		for oy = 0, h - 1 do
			local y0 = oy * Hh // h
			local y1 = math.max(y0 + 1, (oy + 1) * Hh // h)
			for ox = 1, w do
				SY[ox] = 0
			end
			for yy = y0, y1 - 1 do
				local row = yo + (yy + cy) * ys
				local safe = row + x1s[w] + 4 <= ylen
				for ox = 1, w do
					local a, b = row + x0s[ox], row + x1s[ox]
					local m = ms[ox]
					local s = 0
					if m ~= 0 and safe then
						local v = band(readu32(Yp, a), m)
						local t = band(v, 0x00ff00ff) + band(rshift(v, 8), 0x00ff00ff)
						s = band(t, 0xffff) + rshift(t, 16)
					else
						for p = a, b - 1 do
							s += readu8(Yp, p)
						end
					end
					SY[ox] += s
				end
			end
			local cyA, cyB = (y0 + cy) // 2, (y1 - 1 + cy) // 2
			local ny, nc = y1 - y0, cyB - cyA + 1
			for ox = 1, w do
				local ca, cb = c0s[ox], c1s[ox]
				local su, sv = 0, 0
				for yy = cyA, cyB do
					local row = co + yy * cs
					for p = row + ca, row + cb - 1 do
						su += readu8(Up, p)
						sv += readu8(Vp, p)
					end
				end
				local Y = (SY[ox] / ((x1s[ox] - x0s[ox]) * ny) - ys0) * yscale
				local m = (cb - ca) * nc
				local U = su / m - 128
				local V = sv / m - 128
				writeu32(out, o, math.clamp(math.floor(Y + rv * V + 0.5), 0, 255) + 256 * math.clamp(math.floor(Y - gu * U - gv * V + 0.5), 0, 255)
					+ 65536 * math.clamp(math.floor(Y + bu * U + 0.5), 0, 255) + 0xFF000000)
				o += 4
			end
		end
		return { width = w, height = h, data = out, hasAlpha = false }
	end

	-- the luma summed over 2 x 2 squares (one per chroma sample), as 16-bit values: W2 x H2
	local binBuf = buffer.create(4)
	local function binLuma(pic, cx: number, cy: number, W2: number, H2: number): buffer
		local Yp: buffer, ys: number = pic.Y, pic.ys
		local need = W2 * H2 * 2 + 4
		if buffer.len(binBuf) < need then
			binBuf = buffer.create(need)
		end
		local B = binBuf
		local quads = W2 // 2 -- (two squares, four pixels, at a time)
		for y2 = 0, H2 - 1 do
			local r0 = pic.yo + (2 * y2 + cy) * ys + cx
			local r1 = r0 + ys
			local o = y2 * W2 * 2
			for k = 0, quads - 1 do
				local a, b = readu32(Yp, r0 + 4 * k), readu32(Yp, r1 + 4 * k)
				writeu32(B, o + 4 * k, band(a, 0x00ff00ff) + band(rshift(a, 8), 0x00ff00ff) + band(b, 0x00ff00ff)
					+ band(rshift(b, 8), 0x00ff00ff))
			end
			if W2 % 2 == 1 then
				local x = 2 * (W2 - 1)
				buffer.writeu16(B, o + 2 * (W2 - 1), readu8(Yp, r0 + x) + readu8(Yp, r0 + x + 1) + readu8(Yp, r1 + x) + readu8(Yp, r1 + x + 1))
			end
		end
		return B
	end

	-- from the 2 x 2 squares (each output pixel at least one square wide and tall)
	local function binned(dec, pic, B: buffer, W2: number, H2: number, w: number, h: number)
		local cx, cy = dec.cropX or 0, dec.cropY or 0
		local Up: buffer, Vp: buffer = pic.U, pic.V
		local cs: number = pic.cs
		local cbase: number = pic.co + (cy // 2) * cs + cx // 2
		local out = buffer.create(w * h * 4)
		local ys0, yscale, rv, bu, gu, gv = colour(dec)
		local x0s, x1s = table.create(w, 0), table.create(w, 0)
		for ox = 0, w - 1 do
			local x0 = ox * W2 // w
			x0s[ox + 1] = x0
			x1s[ox + 1] = math.max(x0 + 1, (ox + 1) * W2 // w)
		end
		local SY, SU, SV = table.create(w, 0), table.create(w, 0), table.create(w, 0)
		local o = 0
		for oy = 0, h - 1 do
			local y0 = oy * H2 // h
			local y1 = math.max(y0 + 1, (oy + 1) * H2 // h)
			for ox = 1, w do
				SY[ox], SU[ox], SV[ox] = 0, 0, 0
			end
			for yy = y0, y1 - 1 do
				local lrow = yy * W2 * 2
				local crow = cbase + yy * cs
				for ox = 1, w do
					local a, b = x0s[ox], x1s[ox]
					local sy, su, sv = 0, 0, 0
					for x = a, b - 1 do
						sy += readu16(B, lrow + 2 * x)
						su += readu8(Up, crow + x)
						sv += readu8(Vp, crow + x)
					end
					SY[ox] += sy
					SU[ox] += su
					SV[ox] += sv
				end
			end
			local ny = y1 - y0
			for ox = 1, w do
				local m = (x1s[ox] - x0s[ox]) * ny
				local Y = (SY[ox] / (4 * m) - ys0) * yscale
				local U = SU[ox] / m - 128
				local V = SV[ox] / m - 128
				writeu8(out, o, math.clamp(math.floor(Y + rv * V + 0.5), 0, 255))
				writeu8(out, o + 1, math.clamp(math.floor(Y - gu * U - gv * V + 0.5), 0, 255))
				writeu8(out, o + 2, math.clamp(math.floor(Y + bu * U + 0.5), 0, 255))
				writeu8(out, o + 3, 255)
				o += 4
			end
		end
		return { width = w, height = h, data = out, hasAlpha = false }
	end

	-- a decoded picture (YUV 4:2:0) -> RGBA at each size { w, h } of sizes (box filter: each output pixel averages its
	-- source area); for small sizes the luma is first summed over the 2 x 2 squares that share a chroma sample, once for
	-- all of them
	function Job.yuvToImages(dec, pic, sizes)
		local W, Hh = dec.width, dec.height
		local cx, cy = dec.cropX or 0, dec.cropY or 0
		local W2, H2 = W // 2, Hh // 2
		local even = cx % 2 == 0 and cy % 2 == 0
		local out = table.create(#sizes)
		local B
		for i, sz in ipairs(sizes) do
			-- (from the squares when that is exact - a whole number of them per output pixel - or for a size at most a quarter
			-- of the picture's, where an output pixel spans several and their edges barely show)
			local exact = W % (2 * sz.w) == 0 and Hh % (2 * sz.h) == 0
			if even and (exact or (W >= 4 * sz.w and Hh >= 4 * sz.h)) then
				B = B or binLuma(pic, cx, cy, W2, H2)
				out[i] = binned(dec, pic, B, W2, H2, sz.w, sz.h)
			else
				out[i] = direct(dec, pic, sz.w, sz.h)
			end
		end
		return out
	end

	function Job.yuvToImage(dec, pic, w, h)
		return Job.yuvToImages(dec, pic, { { w = w, h = h } })[1]
	end
end

-- is this MP4 sample a picture other pictures predict from? (nal_ref_idc of its first slice)
local function isReferenceSample(buf, pos, size, nalLength)
	local stop = pos + size
	while pos + nalLength < stop do
		local n = 0
		for k = 0, nalLength - 1 do
			n = n * 256 + buffer.readu8(buf, pos + k)
		end
		pos += nalLength
		if n <= 0 or pos >= stop then
			break
		end
		local hdr = buffer.readu8(buf, pos)
		local t = bit32.band(hdr, 31)
		if t == 1 or t == 5 then
			return bit32.band(hdr, 0x60) ~= 0
		end
		pos += n
	end
	return true
end

-- does this MP4 sample hold an IDR picture (a clean start: nothing after it leans on the pictures before it)?
local function isIdrSample(buf, pos, size, nalLength)
	local stop = pos + size
	while pos + nalLength < stop do
		local n = 0
		for k = 0, nalLength - 1 do
			n = n * 256 + buffer.readu8(buf, pos + k)
		end
		pos += nalLength
		if n <= 0 or pos >= stop then
			break
		end
		local t = bit32.band(buffer.readu8(buf, pos), 31)
		if t == 5 then
			return true
		elseif t == 1 then
			return false
		end
		pos += n
	end
	return false
end

-- the same for an access unit with start codes (MPEG-TS)
local function isIdrUnit(buf, pos, size)
	local stop = pos + size - 3
	local p = pos
	while p < stop do
		if buffer.readu8(buf, p) == 0 and buffer.readu8(buf, p + 1) == 0 and buffer.readu8(buf, p + 2) == 1 then
			local t = bit32.band(buffer.readu8(buf, p + 3), 31)
			if t == 5 then
				return true
			elseif t == 1 then
				return false
			end
			p += 3
		else
			p += 1
		end
	end
	return false
end

-- H.265: the type of the first picture slice in a sample (length-prefixed units, or start codes when nalLength is nil)
local function hevcPictureType(buf, pos, size, nalLength)
	local stop = pos + size
	if not nalLength then
		local p = pos
		while p + 3 < stop do
			if buffer.readu8(buf, p) == 0 and buffer.readu8(buf, p + 1) == 0 and buffer.readu8(buf, p + 2) == 1 then
				local t = bit32.band(bit32.rshift(buffer.readu8(buf, p + 3), 1), 63)
				if t <= 21 then
					return t
				end
				p += 3
			else
				p += 1
			end
		end
		return nil
	end
	while pos + nalLength < stop do
		local n = 0
		for k = 0, nalLength - 1 do
			n = n * 256 + buffer.readu8(buf, pos + k)
		end
		pos += nalLength
		if n <= 0 or pos >= stop then
			break
		end
		local t = bit32.band(bit32.rshift(buffer.readu8(buf, pos), 1), 63)
		if t <= 21 then
			return t
		end
		pos += n
	end
	return nil
end
-- (IRAP: IDR, CRA or BLA - decoding can start there; the pictures after a CRA that lean on earlier ones show before it)
local function isHevcIrap(t)
	return t ~= nil and t >= 16 and t <= 21
end

-- display indices of the IDR samples, sorted (sync samples are checked: an "I" frame of an open GOP is listed as a sync
-- sample too, but the frames after it can still lean on older ones)
function Job.idrDisplay(buf, v, t)
	local list = {}
	if v.codec == "vp09" or v.codec == "vp08" or v.codec == "av01" or v.codec == "mpgv" or v.codec == "mp4v" or v.annexB then
		-- (a VP9 / VP8 / AV1 key frame always starts clean; MPEG streams list their key frames: Formats.Mpg; MPEG-4: its I pictures)
		for i, s in ipairs(v.samples) do
			if s.sync and not s.cut then
				table.insert(list, t.disp[i])
			end
		end
		table.sort(list)
		return list
	end
	if v.codec == "hvc1" or v.codec == "hev1" then
		local nalLength = Hevc.new(v.hvcC).nalLength
		for i, s in ipairs(v.samples) do
			if not s.cut and isHevcIrap(hevcPictureType(buf, s.pos, s.size, nalLength)) then
				table.insert(list, t.disp[i])
			end
		end
		table.sort(list)
		return list
	end
	local nalLength = H264.new(v.avcC).nalLength
	for i, s in ipairs(v.samples) do
		if (s.sync or i == 1) and not s.cut and isIdrSample(buf, s.pos, s.size, nalLength) then
			table.insert(list, t.disp[i])
		end
	end
	table.sort(list)
	return list
end

-- output frame ranges to encode apart: whole chunks (keyEvery frames), about `parts` of them, each starting soon after
-- an IDR picture (its decoding starts there; at most maxLead seconds before the part)
function Job.planSegments(t, idr, keyEvery, parts, maxLead)
	local count = t.count
	local chunks = math.ceil(count / keyEvery)
	local per = math.max(2, math.ceil(chunks / math.max(parts, 1)))
	maxLead = maxLead or 4
	local function lead(k)
		local si = t.sourceIndex(k)
		local best
		for _, d in ipairs(idr) do
			if d <= si then
				best = d
			else
				break
			end
		end
		if not best then
			return math.huge
		end
		return (si - best) / t.srcFps
	end
	local segs = {}
	local start = 0
	while start < count do
		local c = start // keyEvery + per
		local stop = count
		while c * keyEvery < count do
			if lead(c * keyEvery) <= maxLead then
				stop = c * keyEvery
				break
			end
			c += 1
		end
		table.insert(segs, { k0 = start, k1 = stop })
		start = stop
	end
	return segs
end

-- decoder errors without the script location
local function cleanError(err)
	return (string.gsub(tostring(err), "^[%w%._ ]+:%d+: ", ""))
end

function Job.mp4Timing(v, maxFps, maxSeconds)
	local samples = v.samples
	local n = #samples
	local order = table.create(n, 0)
	for i = 1, n do
		order[i] = i
	end
	table.sort(order, function(a, b)
		return samples[a].pts < samples[b].pts
	end)
	local disp, dispPts = table.create(n, 0), table.create(n, 0)
	for k, i in ipairs(order) do
		disp[i] = k
		dispPts[k] = samples[i].pts
	end
	local duration = v.duration
	local last = dispPts[n]
	if n > 1 then
		local frameDur = (last - dispPts[1]) / (n - 1)
		if duration <= 0 or duration < last then
			duration = last + frameDur
		end
	elseif duration <= 0 then
		duration = 1 / 24
	end
	local t = { n = n, disp = disp, dispPts = dispPts, duration = duration }
	t.srcFps = n / duration
	t.fps = math.max(1, math.floor(math.min(maxFps, t.srcFps) + 0.5))
	t.seconds = math.min(duration, maxSeconds)
	t.count = math.max(1, math.floor(t.seconds * t.fps + 1e-6))
	-- the last source frame (display order) whose time has come at output frame k
	function t.sourceIndex(k)
		local time = k / t.fps + 1e-6
		local lo, hi = 1, n
		while lo < hi do
			local mid = (lo + hi + 1) // 2
			if dispPts[mid] <= time then
				lo = mid
			else
				hi = mid - 1
			end
		end
		return lo
	end
	return t
end

function Job.mp4Frames(buf, v, t, k0, k1, sizes, onFrame, yield)
	buf = v.data or buf -- (an MPEG stream's video: its elementary stream)
	local samples, n, disp = v.samples, t.n, t.disp
	local mpgv = v.codec == "mpgv"
	local mp4v = v.codec == "mp4v"
	-- (VP9, VP8, AV1, MPEG-1 / MPEG-2 and MPEG-4 Part 2 are decoded alike here)
	local vp9 = v.codec == "vp09" or v.codec == "vp08" or v.codec == "av01" or mpgv or mp4v
	local hevc = v.codec == "hvc1" or v.codec == "hev1"
	local dec = mpgv and Mpeg2.new() or mp4v and Mpeg4.new(v.config, v.fourcc) or v.codec == "vp08" and Vp8.new()
		or v.codec == "av01" and Av1.new(v.av1C) or hevc and Hevc.new(v.hvcC) or vp9 and Vp9.new() or H264.new(v.avcC)
	local annexB = v.annexB -- (access units with start codes: MPEG-TS)
	local hevcNal = hevc and not annexB and dec.nalLength or nil
	-- (H.265 without temporal sub-layers: a picture no other picture leans on is decoded only when it is shown)
	local hevcFlat = false
	if hevc then
		hevcFlat = next(dec.spsList) ~= nil
		for _, s in pairs(dec.spsList) do
			if s.maxSubLayersMinus1 ~= 0 then
				hevcFlat = false
			end
		end
	end
	local pocType0 = true
	if not vp9 and not hevc then
		for _, s in pairs(dec.spsList) do
			if s.pocType ~= 0 then
				pocType0 = false
			end
		end
	end
	local needed = {}
	local first = t.sourceIndex(k0)
	for k = k0, k1 - 1 do
		needed[t.sourceIndex(k)] = true
	end
	-- start at the last IDR sample (decode order) shown no later than the first frame wanted
	local start = 1
	if k0 > 0 then
		for i = 1, n do
			local s = samples[i]
			local idr
			if hevc then
				idr = isHevcIrap(hevcPictureType(buf, s.pos, s.size, hevcNal))
			elseif annexB then
				idr = isIdrUnit(buf, s.pos, s.size)
			elseif vp9 then
				idr = s.sync
			else
				idr = s.sync and isIdrSample(buf, s.pos, s.size, dec.nalLength)
			end
			if disp[i] <= first and not s.cut and idr then
				start = i
			end
		end
		-- (an IDR inside an HLS segment may come without the stream's parameter sets: they are read from its first unit)
		if annexB and start > 1 then
			pcall(dec.decodeAccessUnit, dec, buf, samples[1].pos, samples[1].size)
			if hevc then
				dec:reset()
			end
		end
		-- (an MPEG key frame may come without the sequence header: it is read from the first frame)
		if (mpgv or (mp4v and not v.config)) and start > 1 then
			pcall(dec.decodeSample, dec, buf, samples[1].pos, samples[1].size)
		end
	end
	local cache = {}
	local nextSample = start
	local lastImages
	local function decodeUntil(si)
		while not cache[si] and nextSample <= n do
			local s = samples[nextSample]
			local idx = nextSample
			local di = disp[idx]
			nextSample += 1
			if s.cut then
				error(("the file is cut off: frame %d of %d is missing (the download stopped early)"):format(idx, n), 0)
			end
			local wanted
			if hevc then
				-- (sub-layer non-reference pictures: even types below 16)
				local pt = hevcFlat and not needed[di] and hevcPictureType(buf, s.pos, s.size, hevcNal)
				wanted = needed[di] or not (pt and pt < 16 and pt % 2 == 0)
			else
				wanted = needed[di] or vp9 or not pocType0 or annexB or isReferenceSample(buf, s.pos, s.size, dec.nalLength)
			end
			if wanted then
				local ok, pic = pcall(annexB and dec.decodeAccessUnit or dec.decodeSample, dec, buf, s.pos, s.size)
				if not ok then
					-- (a frame shown before the part starts may lean on pictures before its sync sample: not needed)
					if di >= first then
						error(("%s (frame %d of %d)"):format(cleanError(pic), idx, n), 0)
					end
				elseif pic and needed[di] then
					cache[di] = Job.yuvToImages(dec, pic, sizes)
				end
			end
			if yield then
				yield()
			end
		end
	end
	for k = k0, k1 - 1 do
		local si = t.sourceIndex(k)
		decodeUntil(si)
		local imgs = cache[si] or lastImages
		if imgs then
			onFrame(k, imgs)
			lastImages = imgs
		end
		for d in pairs(cache) do
			if d < si then
				cache[d] = nil
			end
		end
		if yield then
			yield()
		end
	end
end

function Job.encodeSegment(job, yield, progress)
	local buf = job.bytes
	local m = Job.parse(buf)
	local v = m.video
	local t = Job.mp4Timing(v, job.maxFps, job.maxSeconds)
	local writers = {}
	for i, sz in ipairs(job.sizes) do
		writers[i] = Flv2.writer(sz.w, sz.h, t.fps, { TargetKBps = sz.kbps, Layers = job.layers, KeyEvery = job.keyEvery,
			FirstFrame = job.k0 })
	end
	local done = 0
	Job.mp4Frames(buf, v, t, job.k0, job.k1, job.sizes, function(_, imgs)
		for i, w in ipairs(writers) do
			w:add(imgs[i])
			if yield then
				yield()
			end
		end
		done += 1
		if progress and done % 24 == 0 then
			progress(done)
		end
	end, yield)
	local parts = {}
	for i, w in ipairs(writers) do
		parts[i] = w:finishPart()
	end
	return parts
end

-- frame timing of one HLS segment's access units (decode order, pts in seconds): output frame k (0 = the part's first)
-- shows the last source frame whose time has come at offset + k / fps
local function unitTiming(units, fps, count, offset)
	local n = #units
	local order = table.create(n, 0)
	for i = 1, n do
		order[i] = i
	end
	table.sort(order, function(a, b)
		return units[a].pts < units[b].pts
	end)
	local disp, dispPts = table.create(n, 0), table.create(n, 0)
	local base = n > 0 and units[order[1]].pts or 0
	for k, i in ipairs(order) do
		disp[i] = k
		dispPts[k] = units[i].pts - base
	end
	local t = { n = n, disp = disp, dispPts = dispPts, fps = fps, count = count }
	function t.sourceIndex(k)
		local time = offset + (k - t.k0) / fps + 1e-6
		local lo, hi = 1, math.max(n, 1)
		while lo < hi do
			local mid = (lo + hi + 1) // 2
			if dispPts[mid] <= time then
				lo = mid
			else
				hi = mid - 1
			end
		end
		return lo
	end
	return t
end

function Job.probeTs(bytes)
	local ts = parseSegment(bytes)
	if ts.video.codec == "vp9" or ts.video.codec == "vp8" then
		local dec = (ts.video.codec == "vp8" and Vp8 or Vp9).new()
		for _, u in ipairs(ts.video.units) do
			local ok = pcall(dec.decodeSample, dec, u.data, 0, buffer.len(u.data))
			if ok and dec.width > 0 then
				return dec.width, dec.height, ts.audio.codec ~= nil
			end
		end
		error("the stream's first part has no picture", 0)
	end
	if ts.video.codec ~= "h264" then
		error(("the stream's video is %s: only H.264 can be read"):format(tostring(ts.video.codec or "missing")), 0)
	end
	local dec = H264.new(nil)
	for _, u in ipairs(ts.video.units) do
		local ok = pcall(dec.decodeAccessUnit, dec, u.data, 0, buffer.len(u.data))
		if ok and dec.width then
			return dec.width, dec.height, ts.audio.codec ~= nil
		end
	end
	error("the stream's first part has no picture", 0)
end

-- output frames [k0, k1) of one HLS segment (bytes), decoded: onFrame(k, images) gets one image per size, for every
-- frame (the last picture again where the segment has none; black where it has none at all); returns the segment's
-- audio track (Formats.Ts) or nil. from (default k0): the first frame wanted - decoding starts at the last keyframe
-- (IDR) before it, and the frames before it are left out
function Job.tsFrames(bytes, k0, k1, offset, fps, sizes, onFrame, yield, from)
	local ts = parseSegment(bytes)
	if ts.video.codec ~= "h264" and ts.video.codec ~= "vp9" and ts.video.codec ~= "vp8" then
		error(("the stream's video is %s: only H.264, VP9 and VP8 can be read"):format(tostring(ts.video.codec or "missing")), 0)
	end
	local vp9 = ts.video.codec == "vp9" or ts.video.codec == "vp8" -- (VP9 and VP8 are decoded alike here)
	local units = ts.video.units
	local total = 0
	for _, u in ipairs(units) do
		total += buffer.len(u.data)
	end
	local buf = buffer.create(math.max(total, 1))
	local samples = table.create(#units)
	local pos = 0
	for i, u in ipairs(units) do
		local len = buffer.len(u.data)
		buffer.copy(buf, pos, u.data, 0, len)
		samples[i] = { pos = pos, size = len, pts = u.pts, sync = i == 1 }
		pos += len
	end
	local count = k1 - k0
	local t = unitTiming(samples, fps, count, offset or 0)
	t.k0 = k0
	local first = math.clamp(from or k0, k0, math.max(k0, k1 - 1))
	local nextK, last = first, nil
	Job.mp4Frames(buf, { samples = samples, annexB = not vp9, codec = ts.video.codec == "vp8" and "vp08" or (vp9 and "vp09" or nil) }, t, first, k1, sizes, function(k, imgs)
		while nextK < k and last do
			onFrame(nextK, last)
			nextK += 1
		end
		onFrame(k, imgs)
		nextK, last = k + 1, imgs
	end, yield)
	if nextK < k1 and not last then
		last = {}
		for i, sz in ipairs(sizes) do
			local d = buffer.create(sz.w * sz.h * 4)
			buffer.fill(d, 0, 0)
			last[i] = { width = sz.w, height = sz.h, data = d }
		end
	end
	while nextK < k1 do
		onFrame(nextK, last)
		nextK += 1
	end
	return ts.audio.codec and ts.audio or nil
end

function Job.tsSound(bytes, segStart, yield, Encoder)
	local ts = parseSegment(bytes)
	local a = ts.audio
	local known = a.codec == "aac" or a.codec == "mp3" or a.codec == "opus" or a.codec == "vorbis"
	if not known or not a.frames or #a.frames == 0 then
		return nil
	end
	if not Encoder then
		local AudioLab = game:GetService("ReplicatedStorage"):FindFirstChild("LabHub")
		AudioLab = AudioLab and AudioLab:FindFirstChild("AudioLab")
		if not AudioLab then
			return nil
		end
		Encoder = require(AudioLab.Codec.Encoder)
	end
	-- (the frames one after another: an ADTS / MP3 stream; Opus / Vorbis packets are decoded as a track of them)
	local total = 0
	for _, f in ipairs(a.frames) do
		total += buffer.len(f.data)
	end
	local buf = buffer.create(total)
	local p = 0
	for _, f in ipairs(a.frames) do
		buffer.copy(buf, p, f.data)
		p += buffer.len(f.data)
	end
	local decoded
	if a.codec == "opus" or a.codec == "vorbis" then
		local list, q = table.create(#a.frames), 0
		for i, f in ipairs(a.frames) do
			list[i] = { pos = q, size = buffer.len(f.data) }
			q += buffer.len(f.data)
		end
		decoded = Encoder.decodeMp4Audio(buf, { codec = a.codec == "opus" and "Opus" or "vorbis", dOps = a.dOps, skip = a.skip,
			vorbisHeaders = a.vorbisHeaders, samples = list })
	else
		decoded = Encoder.decodeAudio(buf)
	end
	-- (not compressed here: EncodingService can't be used in parallel; the import worker compresses it after. Every
	-- part is encoded alike, short ones too - AudioLab's short-clip settings would give it fewer voices and other noise
	-- bands - so the parts join into one clip, Video.StreamSound)
	local clip = Encoder.encode(decoded, { Texture = false, Yield = yield, Compress = false, ShortSeconds = 0 })
	-- its start: the part's start plus how far its first sound frame comes after its first picture
	local base = math.huge
	for _, u in ipairs(ts.video.units) do
		base = math.min(base, u.pts)
	end
	if base == math.huge then
		base = a.frames[1].pts
	end
	return clip, segStart + (a.frames[1].pts - base)
end

function Job.encodeTsSegment(job, yield)
	local ts = parseSegment(job.bytes)
	if ts.video.codec ~= "h264" and ts.video.codec ~= "vp9" and ts.video.codec ~= "vp8" then
		error(("the stream's video is %s: only H.264, VP9 and VP8 can be read"):format(tostring(ts.video.codec or "missing")), 0)
	end
	local vp9 = ts.video.codec == "vp9" or ts.video.codec == "vp8" -- (VP9 and VP8 are decoded alike here)
	-- the access units in one buffer, as samples
	local units = ts.video.units
	local total = 0
	for _, u in ipairs(units) do
		total += buffer.len(u.data)
	end
	local buf = buffer.create(math.max(total, 1))
	local samples = table.create(#units)
	local pos = 0
	for i, u in ipairs(units) do
		local len = buffer.len(u.data)
		buffer.copy(buf, pos, u.data, 0, len)
		samples[i] = { pos = pos, size = len, pts = u.pts, sync = i == 1 }
		pos += len
	end
	local count = job.k1 - job.k0
	local t = unitTiming(samples, job.fps, count, job.offset or 0)
	t.k0 = job.k0
	local v = { samples = samples, annexB = not vp9, codec = ts.video.codec == "vp8" and "vp08" or (vp9 and "vp09" or nil) }
	local writers = {}
	for i, sz in ipairs(job.sizes) do
		writers[i] = Flv2.writer(sz.w, sz.h, job.fps, { TargetKBps = sz.kbps, Layers = job.layers, KeyEvery = count + 1,
			FirstFrame = job.k0 })
	end
	local info = { audio = ts.audio.codec and ts.audio or nil }
	local added, last = 0, nil
	local function add(imgs)
		for i, w in ipairs(writers) do
			w:add(imgs[i])
			if yield then
				yield()
			end
		end
		added += 1
		last = imgs
	end
	Job.mp4Frames(buf, v, t, job.k0, job.k1, job.sizes, function(_, imgs)
		add(imgs)
	end, yield)
	-- (the part always fills its frames: the next part starts right after it)
	if added < count and not last then
		last = {}
		for i, sz in ipairs(job.sizes) do
			local d = buffer.create(sz.w * sz.h * 4)
			buffer.fill(d, 0, 0)
			last[i] = { width = sz.w, height = sz.h, data = d }
		end
	end
	while added < count do
		add(last)
	end
	local parts = {}
	for i, w in ipairs(writers) do
		parts[i] = w:finishPart()
	end
	return parts, info
end

return Job
