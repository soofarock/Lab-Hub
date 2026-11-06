--!native
--!optimize 2
-- AVI (RIFF) reader. Video: Motion JPEG ('MJPG' and its aliases) or uncompressed 24 / 32-bit RGB. Audio: PCM
-- (8 / 16 / 24 / 32-bit integer or 32-bit float), handed back as a WAV file for AudioLab.
--
--   local avi = Avi.parse(bytes)
--   avi.width, avi.height, avi.fps, avi.codec ("MJPG" | "RGB"), avi.frameCount, avi.audio (nil when there is none)
--   Avi.frame(avi, i)  -> image { width, height, data = RGBA buffer } for frame i (1-based), or nil for a dropped
--                         frame (show the previous one again)
--   Avi.wav(avi)       -> WAV bytes (buffer) of the audio track, or nil
--   Avi.isAvi(bytes)

local Jpeg
if script then
	Jpeg = require(script.Parent.Jpeg)
else
	Jpeg = require("./Jpeg")
end

local Avi = {}

local MJPEG = { MJPG = true, mjpg = true, AVRn = true, LJPG = true, JPGL = true, dmb1 = true, MJPA = true, jpeg = true, JPEG = true }

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
	if MJPEG[comp] or MJPEG[video.handler or ""] then
		avi.codec = "MJPG"
	elseif comp == "\0\0\0\0" or comp == "DIB " or comp == "RGB " then
		if video.bits ~= 24 and video.bits ~= 32 then
			error(("AVI: uncompressed video with %d bits per pixel isn't supported (24 or 32)"):format(video.bits or 0))
		end
		avi.codec = "RGB"
		avi.bits = video.bits
		avi.bottomUp = (video.height or 0) > 0
	else
		error(("AVI: video codec %q isn't supported; convert it to Motion JPEG (ffmpeg: -c:v mjpeg -q:v 3)"):format(comp))
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
		if audio.format ~= 1 and audio.format ~= 3 then
			avi.audioUnsupported = ("audio format 0x%04X (only PCM is read from AVI)"):format(audio.format or 0)
		else
			avi.audio = audio
		end
	end
	return avi
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
