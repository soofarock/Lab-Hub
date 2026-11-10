--!native
--!optimize 2
-- AVI (RIFF) reader. Video: MPEG-4 Part 2 (Xvid, DivX 4/5/6 and the other MPEG-4 FourCCs), Motion JPEG ('MJPG' and its
-- aliases) or uncompressed 24 / 32-bit RGB. Audio: PCM (8 / 16 / 24 / 32-bit integer or 32-bit float), handed back as a
-- WAV file for AudioLab, or MP3 / MP2 / AC-3, handed back as their stream.
--
--   local avi = Avi.parse(bytes)
--   avi.width, avi.height, avi.fps, avi.codec ("MP4V" | "MJPG" | "RGB"), avi.frameCount, avi.audio (PCM: nil when there
--       is none)
--   avi.video (MPEG-4 only): a track in Formats.Mp4's shape for the import path: { codec = "mp4v", fourcc, config (the
--       VOL headers), data (the file), samples = { { pos, size, pts, sync } } (one per coded VOP, decode order: packed
--       frames are split, "not coded" ones left out), duration = 0, width, height }
--   avi.track: MP3 / MP2 ("mpga") or AC-3 ("ac-3") sound as { codec, data (the stream), sampleRate, channels, start = 0 }
--   Avi.frame(avi, i)  -> image { width, height, data = RGBA buffer } for frame i (1-based), or nil for a dropped
--                         frame (show the previous one again) (Motion JPEG / RGB)
--   Avi.wav(avi)       -> WAV bytes (buffer) of the PCM audio track, or nil
--   Avi.isAvi(bytes)

local Jpeg, Mpeg4
if script then
	Jpeg = require(script.Parent.Jpeg)
	Mpeg4 = require(script.Parent.Parent.Video.Mpeg4)
else
	Jpeg = require("./Jpeg")
	Mpeg4 = require("./Mpeg4")
end

local Avi = {}

local MJPEG = { MJPG = true, mjpg = true, AVRn = true, LJPG = true, JPGL = true, dmb1 = true, MJPA = true, jpeg = true, JPEG = true }
-- MPEG-4 Part 2 FourCCs (upper case)
local MPEG4 = { XVID = true, XVIX = true, DIVX = true, DX50 = true, DX40 = true, FMP4 = true, MP4V = true, MP4S = true,
	M4S2 = true, ["3IV2"] = true, RMP4 = true, ZMP4 = true, SIPP = true, UMP4 = true, WV1F = true, BLZ0 = true, DXGM = true,
	EM4A = true, GEOV = true, SMP4 = true, LMP4 = true, DIGI = true, PVMM = true, SEDG = true, M4CC = true, ["3IVD"] = true,
	FFDS = true, FVFW = true, DM4V = true, DMK2 = true, HDX4 = true, MVXM = true, NDIG = true, QMP4 = true }
-- other codecs worth naming in the message
local OTHER = { DIV3 = "DivX 3 (MS MPEG-4 v3)", DIV4 = "DivX 3 (MS MPEG-4 v3)", MP43 = "MS MPEG-4 v3", MP42 = "MS MPEG-4 v2",
	H264 = "H.264", X264 = "H.264", AVC1 = "H.264", HEVC = "H.265", H265 = "H.265", HVC1 = "H.265", WMV3 = "WMV 9",
	WMV2 = "WMV 8", WMV1 = "WMV 7", CVID = "Cinepak", IV50 = "Indeo 5", IV41 = "Indeo 4", IV32 = "Indeo 3",
	MPG2 = "MPEG-2", VP80 = "VP8", VP90 = "VP9", AV01 = "AV1", DVSD = "DV", HFYU = "HuffYUV", FFV1 = "FFV1" }

function Avi.isAvi(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return buffer.len(b) >= 12 and buffer.readstring(b, 0, 4) == "RIFF" and buffer.readstring(b, 8, 4) == "AVI "
end

function Avi.parse(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not Avi.isAvi(b) then
		error("AVI: not an AVI file")
	end
	local len = buffer.len(b)
	local avi = { buf = b, streams = {}, frames = {}, audioChunks = {}, usPerFrame = 0 }
	local current -- stream being described (strl)

	local function walk(pos, stop)
		while pos + 8 <= stop do
			local id = buffer.readstring(b, pos, 4)
			local size = buffer.readu32(b, pos + 4)
			local data = pos + 8
			if data + size > len then
				size = len - data -- truncated file: take what is there
			end
			if id == "LIST" or id == "RIFF" then
				local kind = buffer.readstring(b, data, 4)
				if kind == "strl" then
					current = { index = #avi.streams }
					table.insert(avi.streams, current)
				end
				walk(data + 4, data + size)
			elseif id == "avih" then
				avi.usPerFrame = buffer.readu32(b, data)
				avi.width, avi.height = buffer.readu32(b, data + 32), buffer.readu32(b, data + 36)
			elseif id == "strh" and current then
				current.type = buffer.readstring(b, data, 4)
				current.handler = buffer.readstring(b, data + 4, 4)
				current.scale, current.rate = buffer.readu32(b, data + 20), buffer.readu32(b, data + 24)
			elseif id == "strf" and current then
				if current.type == "vids" then
					current.width = buffer.readi32(b, data + 4)
					current.height = buffer.readi32(b, data + 8)
					current.bits = buffer.readu16(b, data + 14)
					current.compression = buffer.readstring(b, data + 16, 4)
				elseif current.type == "auds" then
					current.format = buffer.readu16(b, data)
					current.channels = buffer.readu16(b, data + 2)
					current.sampleRate = buffer.readu32(b, data + 4)
					current.byteRate = buffer.readu32(b, data + 8)
					current.blockAlign = buffer.readu16(b, data + 12)
					current.bitsPerSample = buffer.readu16(b, data + 14)
					if current.format == 0xFFFE and size >= 40 then -- WAVE_FORMAT_EXTENSIBLE: the real tag is in the GUID
						current.format = buffer.readu16(b, data + 24)
					end
				end
			elseif string.match(id, "^%d%d[%a][%a]$") then
				-- stream data chunk: NNdc / NNdb (video), NNwb (audio)
				local n = tonumber(string.sub(id, 1, 2))
				local tag = string.sub(id, 3, 4)
				local s = avi.streams[n + 1]
				if s and s.type == "vids" and (tag == "dc" or tag == "db") then
					table.insert(avi.frames, { data, size })
				elseif s and s.type == "auds" and tag == "wb" then
					table.insert(avi.audioChunks, { data, size })
				end
			end
			pos = data + size + (size % 2) -- chunks are padded to an even length
		end
	end
	walk(12, len)

	local video, audio
	for _, s in ipairs(avi.streams) do
		if s.type == "vids" and not video then
			video = s
		elseif s.type == "auds" and not audio then
			audio = s
		end
	end
	if not video then
		error("AVI: no video stream")
	end
	local comp = video.compression or ""
	local up = string.upper(comp)
	if MPEG4[up] then
		avi.codec = "MP4V"
	elseif MJPEG[comp] or MJPEG[video.handler or ""] then
		avi.codec = "MJPG"
	elseif comp == "\0\0\0\0" or comp == "DIB " or comp == "RGB " then
		if video.bits ~= 24 and video.bits ~= 32 then
			error(("AVI: uncompressed video with %d bits per pixel isn't supported (24 or 32)"):format(video.bits or 0))
		end
		avi.codec = "RGB"
		avi.bits = video.bits
		avi.bottomUp = (video.height or 0) > 0
	else
		error(("AVI: the video is %s, which isn't supported; re-save it as MP4 (H.264), or as Xvid / Motion JPEG AVI"):format(
			OTHER[up] or ("%q"):format(comp)), 0)
	end
	avi.width = math.abs(video.width or avi.width)
	avi.height = math.abs(video.height or avi.height)
	if video.scale and video.scale > 0 and video.rate > 0 then
		avi.fps = video.rate / video.scale
	elseif avi.usPerFrame > 0 then
		avi.fps = 1e6 / avi.usPerFrame
	else
		avi.fps = 24
	end
	avi.frameCount = #avi.frames
	if audio and #avi.audioChunks > 0 then
		local f = audio.format
		if f == 1 or f == 3 then
			avi.audio = audio
		elseif f == 0x55 or f == 0x50 or f == 0x2000 then
			local total = 0
			for _, c in ipairs(avi.audioChunks) do
				total += c[2]
			end
			local data = buffer.create(total)
			local o = 0
			for _, c in ipairs(avi.audioChunks) do
				buffer.copy(data, o, b, c[1], c[2])
				o += c[2]
			end
			avi.track = { codec = f == 0x2000 and "ac-3" or "mpga", data = data, sampleRate = audio.sampleRate,
				channels = audio.channels, start = 0 }
		else
			local names = { [0x2] = "MS ADPCM", [0x11] = "IMA ADPCM", [0xFF] = "AAC", [0x1610] = "AAC", [0x2001] = "DTS",
				[0x161] = "WMA", [0x162] = "WMA Pro", [0x674F] = "Vorbis" }
			avi.audioUnsupported = ("%s sound (AVI sound is read as PCM, MP3, MP2 or AC-3)"):format(
				names[f or 0] or ("format 0x%04X"):format(f or 0))
		end
	end
	if avi.codec == "MP4V" then
		avi.video = Avi.mpeg4Track(avi, comp)
	end
	return avi
end

-- the MPEG-4 frames as one sample per coded VOP: their times from the VOP headers (packed frames hold two VOPs; the
-- stand-in frame after one is "not coded")
function Avi.mpeg4Track(avi, fourcc)
	local b = avi.buf
	local parser = Mpeg4.parser()
	local samples = {}
	local config
	for _, f in ipairs(avi.frames) do
		if f[2] > 0 then
			local ok, vops = pcall(parser.vops, parser, b, f[1], f[2])
			if ok then
				if not config and #vops > 0 then
					-- (the VOL headers: the first frame's bytes before its first VOP start code)
					local p, stop = f[1], f[1] + f[2] - 3
					while p < stop do
						if buffer.readu8(b, p) == 0 and buffer.readu8(b, p + 1) == 0 and buffer.readu8(b, p + 2) == 1
							and buffer.readu8(b, p + 3) == 0xB6 then
							break
						end
						p += 1
					end
					if p > f[1] then
						config = buffer.create(p - f[1])
						buffer.copy(config, 0, b, f[1], p - f[1])
					end
				end
				for _, v in ipairs(vops) do
					if v.coded then
						table.insert(samples, { pos = v.pos, size = v.size, pts = v.time, sync = v.type == 1 })
					end
				end
			end
		end
	end
	if #samples == 0 then
		error("AVI: the MPEG-4 video has no pictures", 0)
	end
	local minPts = math.huge
	for _, s in ipairs(samples) do
		minPts = math.min(minPts, s.pts)
	end
	for _, s in ipairs(samples) do
		s.pts -= minPts
	end
	return { codec = "mp4v", fourcc = fourcc, config = config, data = b, samples = samples, duration = 0,
		width = avi.width, height = avi.height }
end

function Avi.frame(avi, i)
	local f = avi.frames[i]
	if not f or f[2] == 0 then
		return nil
	end
	local b = avi.buf
	if avi.codec == "MJPG" then
		local slice = buffer.create(f[2])
		buffer.copy(slice, 0, b, f[1], f[2])
		return Jpeg.decode(slice)
	end
	-- uncompressed: BGR(A), rows padded to 4 bytes, bottom-up unless the height was negative
	local W, H = avi.width, avi.height
	local bpp = avi.bits // 8
	local stride = (W * bpp + 3) // 4 * 4
	local out = buffer.create(W * H * 4)
	for y = 0, H - 1 do
		local sy = avi.bottomUp and (H - 1 - y) or y
		local row = f[1] + sy * stride
		for x = 0, W - 1 do
			local p = row + x * bpp
			local o = (y * W + x) * 4
			buffer.writeu8(out, o, buffer.readu8(b, p + 2))
			buffer.writeu8(out, o + 1, buffer.readu8(b, p + 1))
			buffer.writeu8(out, o + 2, buffer.readu8(b, p))
			buffer.writeu8(out, o + 3, 255)
		end
	end
	return { width = W, height = H, data = out, hasAlpha = false }
end

function Avi.wav(avi)
	local a = avi.audio
	if not a then
		return nil
	end
	local total = 0
	for _, c in ipairs(avi.audioChunks) do
		total += c[2]
	end
	local out = buffer.create(44 + total)
	buffer.writestring(out, 0, "RIFF")
	buffer.writeu32(out, 4, 36 + total)
	buffer.writestring(out, 8, "WAVEfmt ")
	buffer.writeu32(out, 16, 16)
	buffer.writeu16(out, 20, a.format)
	buffer.writeu16(out, 22, a.channels)
	buffer.writeu32(out, 24, a.sampleRate)
	local block = a.blockAlign > 0 and a.blockAlign or (a.channels * a.bitsPerSample // 8)
	buffer.writeu32(out, 28, a.sampleRate * block)
	buffer.writeu16(out, 32, block)
	buffer.writeu16(out, 34, a.bitsPerSample)
	buffer.writestring(out, 36, "data")
	buffer.writeu32(out, 40, total)
	local o = 44
	for _, c in ipairs(avi.audioChunks) do
		buffer.copy(out, o, avi.buf, c[1], c[2])
		o += c[2]
	end
	return out
end

return Avi
