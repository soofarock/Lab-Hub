-- FrameLab importer (Studio). Opens the file picker and turns every chosen file into FrameLab data:
--   pictures  PNG, JPG / JPEG / JFIF, BMP, TGA, WebP, GIF (one frame)   -> Data/Images/<name>
--   video     MP4 / MOV / M4V (H.264; up to Config.ImportMaxVideoLines, 480p by default), AVI (Motion JPEG or
--             uncompressed; PCM sound), animated GIF or WebP -> Data/Videos/<name>
--             the sound (MP4: AAC or MP3; AVI: PCM) becomes an AudioLab clip (clip:video/<name>) that the video follows;
--             in-game imports (options.Sink) keep it too, for the server's session
--
--   FrameLab.import(options)            -- run from the command bar (needs plugin access for the picker)
--   Importer.importFile(name, bytes, options) -> result     (also usable from code with bytes you already have)
--
-- options: MaxImage (longest side of a picture, default 512: O sprays draw up to that), Quality ("144p" / "240p" / "360p": the video size and data rate,
--          default Config.ImportVideoQuality; see Importer.Qualities), MaxVideoWidth / MaxVideoHeight (a box instead),
--          Fps (most frames per second kept, default 24, never above 24), MaxSeconds (default 600),
--          TargetKBps (video bytes per second, default 60: about 35 MB for 10 minutes; busy scenes borrow from quiet
--          ones over a few seconds, so motion stays clean), Codec ("FLV2" default, or the
--          older "FLV1" with ChangeTol), Folder (prefix for the stored names), Taken(name) -> true if that name is in use
--          (the name gets a number then)
-- Videos over 5 MB are kept in ServerStorage.FrameLabData and stream to the client that plays them.
-- options.Sink = function(kind ("Images" / "Videos"), name, bytes, attributes): keep the result somewhere else instead
--   (in-game imports keep it in the server's memory); a video's sound is not imported then.
-- Nothing is ever larger than 1024 x 1024.

local FrameLab = script:FindFirstAncestor("FrameLab")
local Store = require(FrameLab.Tools.Store)
local Png = require(FrameLab.Formats.Png)
local Jpeg = require(FrameLab.Formats.Jpeg)
local Bmp = require(FrameLab.Formats.Bmp)
local Tga = require(FrameLab.Formats.Tga)
local Gif = require(FrameLab.Formats.Gif)
local Avi = require(FrameLab.Formats.Avi)
local Webp = require(FrameLab.Formats.Webp)
local Mp4 = require(FrameLab.Formats.Mp4)
local H264 = require(FrameLab.Video.H264)
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
local Resize = require(FrameLab.Image.Resize)
local Stream = require(FrameLab.Video.Stream)
local Flv2 = require(FrameLab.Video.Flv2)

local EncodingService = game:GetService("EncodingService")

local Importer = {}

Importer.Extensions = { "png", "jpg", "jpeg", "jfif", "jpe", "bmp", "dib", "tga", "gif", "webp", "avi", "mp4", "m4v", "mov" }
Importer.Readable = "PNG, JPG, BMP, TGA, GIF, WebP pictures; MP4 (H.264), GIF, WebP, AVI videos"
Importer.Defaults = { MaxImage = 512, MaxVideoWidth = 256, MaxVideoHeight = 256, Fps = 24, MaxSeconds = 600, ChangeTol = 8,
	TargetKBps = 60, Codec = "FLV2" }
local HARD_MAX = 1024

-- video sizes: the short side gets `lines` pixels, the long side at most 16:9 of that (256x144, 426x240; 4:3 -> 192x144)
Importer.Qualities = {
	["144p"] = { lines = 144, kbps = 60 },
	["240p"] = { lines = 240, kbps = 120 },
	["360p"] = { lines = 360, kbps = 200 }, -- 640x360: ~2.3x the drawing and data of 240p (PCs)
}
function Importer.quality(name)
	name = name or Config.ImportVideoQuality or "144p"
	local q = Importer.Qualities[name]
	if q then
		return q, name
	end
	return Importer.Qualities["144p"], "144p"
end

local function opts(options)
	options = options or {}
	local o = {}
	for k, v in pairs(Importer.Defaults) do
		o[k] = v
	end
	for k, v in pairs(options) do
		o[k] = v
	end
	o.Fps = math.min(o.Fps, 24)
	if options.MaxVideoWidth == nil and options.MaxVideoHeight == nil then
		local q, name = Importer.quality(options.Quality)
		o.VideoLines = q.lines
		o.Quality = name
		if options.TargetKBps == nil then
			o.TargetKBps = q.kbps
		end
	end
	return o
end

-- where a video goes: up to 5 MB in ReplicatedStorage (every client has it), larger ones in ServerStorage.FrameLabData
-- (they stream to the one client that plays them, through the FrameLab remotes)
Importer.ServerOnlyBytes = 5 * 1024 * 1024
function Importer.videoRoot(bytes)
	if buffer.len(bytes) <= Importer.ServerOnlyBytes then
		return FrameLab.Data.Videos
	end
	local ss = game:GetService("ServerStorage")
	local root = ss:FindFirstChild("FrameLabData")
	if not root then
		root = Instance.new("Folder")
		root.Name = "FrameLabData"
		root.Parent = ss
	end
	for _, n in ipairs({ "Videos", "Images" }) do
		if not root:FindFirstChild(n) then
			local f = Instance.new("Folder")
			f.Name = n
			f.Parent = root
		end
	end
	return root.Videos
end

local function cleanName(fileName)
	local base = string.gsub(fileName, "%.[^%.]*$", "")
	base = string.gsub(base, "[^%w%-_ ]", "_")
	return string.sub(base, 1, 60)
end

local function zstd(buf)
	return EncodingService:CompressBuffer(buf, Enum.CompressionAlgorithm.Zstd, 9)
end

-- picture entry: "FLI1", width u16, height u16, flags u8 (1 = has transparency), raw size u32, zstd(RGBA)
function Importer.packImage(image)
	local z = zstd(image.data)
	local out = buffer.create(13 + buffer.len(z))
	buffer.writestring(out, 0, "FLI1")
	buffer.writeu16(out, 4, image.width)
	buffer.writeu16(out, 6, image.height)
	buffer.writeu8(out, 8, image.hasAlpha and 1 or 0)
	buffer.writeu32(out, 9, buffer.len(image.data))
	buffer.copy(out, 13, z, 0)
	return out
end

local function kindOf(bytes, fileName)
	if Png.isPng(bytes) then
		return "png"
	elseif Jpeg.isJpeg(bytes) then
		return "jpeg"
	elseif Gif.isGif(bytes) then
		return "gif"
	elseif Avi.isAvi(bytes) then
		return "avi"
	elseif Webp.isWebp(bytes) then
		return "webp"
	elseif Mp4.isMp4(bytes) then
		local brand = buffer.len(bytes) >= 12 and buffer.readstring(bytes, 8, 4) or ""
		if brand ~= "avif" and brand ~= "avis" and brand ~= "heic" and brand ~= "heix" and brand ~= "mif1" and brand ~= "msf1" then
			return "mp4"
		end
	elseif Bmp.isBmp(bytes) then
		return "bmp"
	elseif string.lower(string.match(fileName, "%.(%w+)$") or "") == "tga" and Tga.isTga(bytes) then
		return "tga"
	end
	return nil
end

-- what an unreadable file actually is (so the message can say so), from its first bytes
local function sniff(b)
	local n = buffer.len(b)
	if n == 0 then
		return "an empty file"
	end
	local head = buffer.readstring(b, 0, math.min(n, 64))
	local low = string.lower((string.gsub(head, "^[%s\239\187\191]+", "")))
	if n >= 12 and string.sub(head, 5, 8) == "ftyp" then
		local brand = string.sub(head, 9, 12)
		if brand == "avif" or brand == "avis" then
			return "an AVIF picture (not supported yet: save it as PNG or JPG)"
		elseif brand == "heic" or brand == "heix" or brand == "mif1" or brand == "msf1" then
			return "a HEIC / HEIF picture (iPhone photo format, not supported: save it as JPG or PNG)"
		elseif brand == "qt  " then
			return "a QuickTime MOV video (not supported yet)"
		end
		return ("an MP4 video (brand %q; MP4 import is coming)"):format(brand)
	elseif string.sub(head, 1, 4) == "\26\69\223\163" then
		return string.find(head, "webm", 1, true) and "a WebM video (WebM import is coming)" or "a Matroska (MKV) video (not supported)"
	elseif string.sub(head, 1, 4) == "RIFF" and string.sub(head, 9, 12) == "WAVE" then
		return "a WAV sound (import sounds with AudioLab)"
	elseif string.sub(head, 1, 3) == "ID3" or (n > 1 and buffer.readu8(b, 0) == 0xff and bit32.band(buffer.readu8(b, 1), 0xe0) == 0xe0) then
		return "an MP3 sound (import sounds with AudioLab)"
	elseif string.sub(head, 1, 4) == "OggS" then
		return "an Ogg file (sound or video, not supported here)"
	elseif string.sub(head, 1, 4) == "fLaC" then
		return "a FLAC sound (import sounds with AudioLab)"
	elseif string.sub(head, 1, 4) == "%PDF" then
		return "a PDF document"
	elseif string.sub(head, 1, 2) == "PK" then
		return "a ZIP archive"
	elseif string.sub(head, 1, 4) == "II*\0" or string.sub(head, 1, 4) == "MM\0*" then
		return "a TIFF picture (not supported: save it as PNG)"
	elseif string.sub(head, 1, 4) == "8BPS" then
		return "a Photoshop PSD (not supported: export it as PNG)"
	elseif string.sub(head, 1, 4) == "\0\0\1\0" then
		return "an ICO icon (not supported: save it as PNG)"
	elseif string.find(low, "^<!doctype html") or string.find(low, "^<html") or string.find(low, "^<head") then
		return "a web page, not a picture or video file (copy the file's own link: right-click the picture -> Copy image address)"
	elseif string.find(low, "<svg", 1, true) then
		return "an SVG drawing (not supported: save it as PNG)"
	elseif string.find(low, "^<%?xml") then
		return "an XML document"
	elseif string.find(low, "^[{%[]") then
		return "JSON text, not a picture or video (the site sent data instead of the file)"
	end
	local printable = 0
	for i = 1, #head do
		local c = string.byte(head, i)
		if c == 9 or c == 10 or c == 13 or (c >= 32 and c < 127) then
			printable += 1
		end
	end
	if printable == #head then
		return ("text (%q...), not a picture or video"):format(string.sub(head, 1, 40))
	end
	return "an unknown kind of file"
end
Importer.sniff = sniff

-- decoder errors without the script location ("...Formats.Png:76: PNG: bad filter type 9" -> "PNG: bad filter type 9")
local function cleanError(err)
	local msg = tostring(err)
	msg = string.gsub(msg, "^[%w%._ ]+:%d+: ", "")
	return msg
end
local function decode(fileName, fn, ...)
	local ok, res = pcall(fn, ...)
	if not ok then
		error(("%s couldn't be read: %s"):format(fileName, cleanError(res)), 0)
	end
	return res
end
Importer.cleanError = cleanError

-- a decoded H.264 picture (YUV 4:2:0) -> RGBA at w x h (box filter: each output pixel averages its source area)
local function yuvToImage(dec, pic, w, h)
	local W, Hh = dec.width, dec.height
	local cx, cy = dec.cropX or 0, dec.cropY or 0
	local Yp, Up, Vp, ys, cs, yo, co = pic.Y, pic.U, pic.V, pic.ys, pic.cs, pic.yo, pic.co
	local out = buffer.create(w * h * 4)
	-- colour matrix (BT.709 for HD, BT.601 otherwise, unless the stream says), limited or full range
	local kr, kb = 0.299, 0.114
	if dec.bt709 then
		kr, kb = 0.2126, 0.0722
	end
	local kg = 1 - kr - kb
	local ys0, yscale, cscale = 16, 255 / 219, 255 / 224
	if dec.fullRange then
		ys0, yscale, cscale = 0, 1, 1
	end
	local rv = 2 * (1 - kr) * cscale
	local bu = 2 * (1 - kb) * cscale
	local gu = 2 * (1 - kb) * kb / kg * cscale
	local gv = 2 * (1 - kr) * kr / kg * cscale
	local readu8, writeu8 = buffer.readu8, buffer.writeu8
	local x0s, x1s = table.create(w, 0), table.create(w, 0)
	for ox = 0, w - 1 do
		local x0 = ox * W // w
		x0s[ox + 1] = x0
		x1s[ox + 1] = math.max(x0 + 1, (ox + 1) * W // w)
	end
	for oy = 0, h - 1 do
		local y0 = oy * Hh // h
		local y1 = math.max(y0 + 1, (oy + 1) * Hh // h)
		for ox = 0, w - 1 do
			local x0, x1 = x0s[ox + 1], x1s[ox + 1]
			local sy, n = 0, 0
			for yy = y0, y1 - 1 do
				local row = yo + (yy + cy) * ys + cx
				for xx = x0, x1 - 1 do
					sy += readu8(Yp, row + xx)
				end
				n += x1 - x0
			end
			local su, sv, m = 0, 0, 0
			for yy = (y0 + cy) // 2, (y1 - 1 + cy) // 2 do
				local row = co + yy * cs
				for xx = (x0 + cx) // 2, (x1 - 1 + cx) // 2 do
					su += readu8(Up, row + xx)
					sv += readu8(Vp, row + xx)
					m += 1
				end
			end
			local Y = (sy / n - ys0) * yscale
			local U = su / m - 128
			local V = sv / m - 128
			local r = Y + rv * V
			local g = Y - gu * U - gv * V
			local b = Y + bu * U
			local o = (oy * w + ox) * 4
			writeu8(out, o, math.clamp(math.floor(r + 0.5), 0, 255))
			writeu8(out, o + 1, math.clamp(math.floor(g + 0.5), 0, 255))
			writeu8(out, o + 2, math.clamp(math.floor(b + 0.5), 0, 255))
			writeu8(out, o + 3, 255)
		end
	end
	return { width = w, height = h, data = out, hasAlpha = false }
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

-- a video's sound -> AudioLab clip "video/<name>". decode(AudioLab) -> { signal } | signal. Returns attrs.Audio (or nil)
-- and a note for the message. In-game imports (o.Sink) keep the clip in the server's memory (o.Sink("Sounds", ...)):
-- nothing replicates; a client fetches it from the server when a TV plays it (FrameLab.Net.clip).
local function storeSound(name, seconds, decode, log, o)
	local Rep = game:GetService("ReplicatedStorage")
	local root = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
	if not root then
		return nil, ", sound skipped (AudioLab isn't in this place)"
	end
	local audioName = "video/" .. name
	local progress = (o and o.Progress) or function() end
	local timing = o and o.Timing
	local ok, res = pcall(function()
		local AudioLab = require(root)
		log(("  %s: decoding the sound..."):format(name))
		progress("decoding the sound", 0)
		local t0 = os.clock()
		local decoded = decode(AudioLab)
		local signal = decoded.signal or decoded
		if timing then
			timing["sound decode"] = os.clock() - t0
		end
		log(("  %s: encoding the sound (%.1f s, %d Hz, %d ch)..."):format(name, signal.length / signal.sampleRate, signal.sampleRate, signal.channels))
		progress("encoding the sound", 0.3)
		t0 = os.clock()
		local clip, cs = AudioLab.Encoder.encode(decoded, { Progress = function(_, f)
			progress("encoding the sound", 0.3 + 0.7 * math.clamp(tonumber(f) or 0, 0, 1))
		end })
		if timing then
			timing["sound encode"] = os.clock() - t0
		end
		local attrs = { SourceRate = signal.sampleRate, Seconds = cs.seconds, Video = name }
		if o and o.Sink then
			o.Sink("Sounds", audioName, clip, attrs)
		else
			AudioLab.Importer.storeClip(audioName, clip, attrs)
		end
		return cs
	end)
	if not ok then
		return nil, ", sound not imported: " .. cleanError(res)
	end
	return "clip:" .. audioName, (", sound as AudioLab clip %s (%.0f KB)"):format(audioName, res.bytes / 1024)
end

local function fitSize(w, h, maxW, maxH)
	maxW, maxH = math.min(maxW, HARD_MAX), math.min(maxH, HARD_MAX)
	local s = math.min(1, maxW / w, maxH / h)
	return math.max(1, math.floor(w * s + 0.5)), math.max(1, math.floor(h * s + 0.5))
end

local function storeImage(name, image, o, sourceKind)
	local w, h = fitSize(image.width, image.height, o.MaxImage, o.MaxImage)
	local small = Resize.to(image, w, h, true)
	local bytes = Importer.packImage(small)
	local attrs = { Width = w, Height = h, SourceWidth = image.width, SourceHeight = image.height, Source = sourceKind }
	if o.Sink then
		o.Sink("Images", name, bytes, attrs)
	else
		Store.write(FrameLab.Data.Images, name, bytes, attrs)
	end
	return { kind = "image", name = name, width = w, height = h, bytes = buffer.len(bytes),
		message = ("picture %s: %dx%d (from %dx%d), %.0f KB"):format(name, w, h, image.width, image.height, buffer.len(bytes) / 1024) }
end

-- the stored size of a srcW x srcH video
local function videoSize(srcW, srcH, o)
	if o.VideoLines then
		local long = math.floor(o.VideoLines * 16 / 9)
		if srcW >= srcH then
			return fitSize(srcW, srcH, long, o.VideoLines)
		end
		return fitSize(srcW, srcH, o.VideoLines, long)
	end
	return fitSize(srcW, srcH, o.MaxVideoWidth, o.MaxVideoHeight)
end

-- video from a frame source: getFrame(i) -> image or nil (repeat), times: output frame k -> source index
local function storeVideo(name, srcW, srcH, outFps, frameCount, sourceIndex, getFrame, o, log)
	local w, h = videoSize(srcW, srcH, o)
	local writer
	if o.Codec == "FLV1" then
		writer = Stream.writer(w, h, outFps, { ChangeTol = o.ChangeTol, Compress = zstd })
	else
		writer = Flv2.writer(w, h, outFps, { TargetKBps = o.TargetKBps, Layers = o.Layers })
	end
	local cache, cacheIndex, last = nil, -1, nil
	local t0 = os.clock()
	local lastYield = os.clock()
	local progress = o.Progress
	for k = 0, frameCount - 1 do
		local si = sourceIndex(k)
		if si ~= cacheIndex then
			local img = getFrame(si)
			if img then
				if img.hasAlpha then
					img = Resize.flatten(img, 0, 0, 0)
				end
				cache = Resize.to(img, w, h)
			end
			cacheIndex = si
		end
		cache = cache or last
		if cache then
			writer:add(cache)
			last = cache
		end
		-- (a pause after ~12 ms of work, not after every frame: a wait per frame cost a whole server frame each time,
		-- ~12 s of waiting for a 30 s video)
		if os.clock() - lastYield > 0.012 then
			task.wait()
			lastYield = os.clock()
			if progress then
				progress("video", (k + 1) / frameCount)
			end
		end
		if log and k % 48 == 47 then
			log(("  %s: %d / %d frames (%.0f s)"):format(name, k + 1, frameCount, os.clock() - t0))
		end
	end
	local bytes, stats = writer:finish()
	if o.Timing then
		o.Timing.video = os.clock() - t0
	end
	return bytes, stats, w, h
end

function Importer.importFile(fileName, bytes, options)
	local o = opts(options)
	-- (progress lines only with Config.Debug, or a Log of your own)
	local log = o.Log or (Config.Debug and print or function() end)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local name = (o.Folder and (o.Folder .. "/") or "") .. cleanName(fileName)
	if o.Taken then
		-- a name already in use gets a number ("image0", "image0-2", ...), so an import never replaces another
		local base, n = name, 2
		while o.Taken(name) do
			name = base .. "-" .. n
			n += 1
		end
	end
	local kind = kindOf(buf, fileName)
	if not kind then
		error(("%s is %s. FrameLab reads %s."):format(fileName, sniff(buf), Importer.Readable), 0)
	end
	if kind == "png" then
		return storeImage(name, decode(fileName, Png.decode, buf, { Yield = true }), o, "PNG")
	elseif kind == "jpeg" then
		return storeImage(name, decode(fileName, Jpeg.decode, buf, { MaxSize = o.MaxImage, Yield = true }), o, "JPEG")
	elseif kind == "bmp" then
		return storeImage(name, decode(fileName, Bmp.decode, buf), o, "BMP")
	elseif kind == "tga" then
		return storeImage(name, decode(fileName, Tga.decode, buf), o, "TGA")
	elseif kind == "gif" or kind == "webp" then
		local g
		if kind == "gif" then
			g = decode(fileName, Gif.decode, buf)
		else
			g = decode(fileName, Webp.decode, buf)
			if not g.frames then
				return storeImage(name, g, o, "WebP")
			end
		end
		local label = kind == "gif" and "GIF" or "WebP"
		if #g.frames == 1 then
			return storeImage(name, { width = g.width, height = g.height, data = g.frames[1].data, hasAlpha = g.hasAlpha }, o, label)
		end
		-- animation: frame k shows the GIF frame active at time k / fps
		local starts, total = {}, 0
		for i, f in ipairs(g.frames) do
			starts[i] = total
			total += f.delay
		end
		local fps = o.Fps
		local count = math.max(1, math.floor(math.min(total, o.MaxSeconds) * fps + 0.5))
		local function sourceIndex(k)
			local t = k / fps
			local idx = 1
			for i = 1, #starts do
				if starts[i] <= t + 1e-9 then
					idx = i
				end
			end
			return idx
		end
		local function getFrame(i)
			return { width = g.width, height = g.height, data = g.frames[i].data, hasAlpha = g.hasAlpha }
		end
		local streamBytes, st, w, h = storeVideo(name, g.width, g.height, fps, count, sourceIndex, getFrame, o, log)
		local attrs = { Width = w, Height = h, Fps = fps, Frames = st.frames, Seconds = st.seconds, Loop = true, Source = label }
		if o.Sink then
			o.Sink("Videos", name, streamBytes, attrs)
		else
			Store.write(Importer.videoRoot(streamBytes), name, streamBytes, attrs)
		end
		return { kind = "video", name = name, width = w, height = h, seconds = st.seconds, bytes = st.bytes,
			message = ("video %s: %dx%d, %.1f s at %d fps (animated %s, %d frames), %.0f KB (%.0f KB/s)"):format(name, w, h, st.seconds, fps, label, #g.frames, st.bytes / 1024, st.bytesPerSecond / 1024) }
	elseif kind == "mp4" then
		local m = decode(fileName, Mp4.parse, buf)
		local v = m.video
		if not v then
			error(("%s is a sound file (M4A), not a video: import it with AudioLab"):format(fileName), 0)
		end
		local codec = v.codec or "?"
		if codec ~= "avc1" and codec ~= "avc3" then
			local names = { hvc1 = "H.265 (HEVC)", hev1 = "H.265 (HEVC)", av01 = "AV1", vp09 = "VP9", vp08 = "VP8", mp4v = "MPEG-4 Part 2", s263 = "H.263" }
			error(("%s is an MP4 with %s video, which FrameLab can't read: re-save it as H.264 (\"MP4 / H.264\" in most converters)"):format(fileName, names[codec] or ("%q"):format(codec)), 0)
		end
		if not v.avcC then
			error(fileName .. " couldn't be read: MP4: the H.264 setup (avcC) is missing", 0)
		end
		local dec = decode(fileName, H264.new, v.avcC)
		local sps0
		for _, s in pairs(dec.spsList) do
			sps0 = s
			break
		end
		local srcW, srcH = v.width or 0, v.height or 0
		if sps0 then
			srcW = sps0.mbw * 16 - sps0.cropLeft - sps0.cropRight
			srcH = sps0.mbh * 16 - sps0.cropTop - sps0.cropBottom
		end
		if srcW <= 0 or srcH <= 0 then
			error(fileName .. " couldn't be read: MP4: the video has no size", 0)
		end
		local maxLines = o.MaxVideoLines or Config.ImportMaxVideoLines or 480
		if math.min(srcW, srcH) > maxLines then
			error(("%s is %dx%d (%dp); the limit is %dp (ImportMaxVideoLines). Use a %dp copy, or raise the limit (bigger videos take much longer to import)"):format(
				fileName, srcW, srcH, math.min(srcW, srcH), maxLines, maxLines), 0)
		end
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
		local srcFps = n / duration
		local fps = math.max(1, math.floor(math.min(o.Fps, srcFps) + 0.5))
		local seconds = math.min(duration, o.MaxSeconds)
		local count = math.max(1, math.floor(seconds * fps + 1e-6))
		local j = 1
		local function sourceIndex(k)
			local t = k / fps
			while j < n and dispPts[j + 1] <= t + 1e-6 do
				j += 1
			end
			return j
		end
		local needed = {}
		for k = 0, count - 1 do
			needed[sourceIndex(k)] = true
		end
		j = 1
		local pocType0 = true
		for _, s in pairs(dec.spsList) do
			if s.pocType ~= 0 then
				pocType0 = false
			end
		end
		local w, h = videoSize(srcW, srcH, o)
		local cache = {}
		local nextSample = 1
		local lastNeeded = 0
		for k in pairs(needed) do
			lastNeeded = math.max(lastNeeded, k)
		end
		local function getFrame(si)
			while not cache[si] and nextSample <= n do
				local s = samples[nextSample]
				local di = disp[nextSample]
				local idx = nextSample
				nextSample += 1
				if s.cut then
					error(("%s is cut off: frame %d of %d is missing (the download stopped early)"):format(fileName, idx, n), 0)
				end
				if needed[di] or not pocType0 or isReferenceSample(buf, s.pos, s.size, dec.nalLength) then
					local ok, pic = pcall(dec.decodeSample, dec, buf, s.pos, s.size)
					if not ok then
						error(("%s couldn't be read: %s (frame %d of %d)"):format(fileName, cleanError(pic), idx, n), 0)
					end
					if pic and needed[di] then
						cache[di] = yuvToImage(dec, pic, w, h)
					end
				end
			end
			local img = cache[si]
			for k in pairs(cache) do
				if k < si then
					cache[k] = nil
				end
			end
			return img
		end
		log(("%s: %dx%d H.264 (profile %d) video, %.2f fps, %d frames, %.1f s%s"):format(fileName, srcW, srcH, sps0 and sps0.profile or 0, srcFps, n, duration,
			m.audio and (", sound " .. tostring(m.audio.codec)) or ", no sound"))
		local streamBytes, st, ow, oh = storeVideo(name, srcW, srcH, fps, count, sourceIndex, getFrame, o, log)
		local attrs = { Width = ow, Height = oh, Fps = fps, Frames = st.frames, Seconds = st.seconds, Source = "MP4 H.264", Quality = o.Quality }
		local audioNote = ""
		if m.audio and o.Sound ~= false then
			attrs.Audio, audioNote = storeSound(name, seconds, function(AudioLab)
				return AudioLab.Encoder.decodeMp4Audio(buf, m.audio, { MaxSeconds = seconds + 0.5 })
			end, log, o)
		end
		if o.Sink then
			o.Sink("Videos", name, streamBytes, attrs)
		else
			Store.write(Importer.videoRoot(streamBytes), name, streamBytes, attrs)
		end
		return { kind = "video", name = name, width = ow, height = oh, seconds = st.seconds, bytes = st.bytes,
			message = ("video %s: %dx%d, %.1f s at %d fps (from %dx%d H.264), %.0f KB (%.1f KB/s)%s"):format(name, ow, oh, st.seconds, fps, srcW, srcH,
				st.bytes / 1024, st.bytesPerSecond / 1024, audioNote) }
	else -- avi
		local avi = decode(fileName, Avi.parse, buf)
		local fps = math.min(o.Fps, avi.fps)
		local seconds = math.min(avi.frameCount / avi.fps, o.MaxSeconds)
		local count = math.max(1, math.floor(seconds * fps + 1e-6))
		local function sourceIndex(k)
			return math.min(avi.frameCount, math.floor(k * avi.fps / fps + 1e-6) + 1)
		end
		local function getFrame(i)
			return Avi.frame(avi, i)
		end
		log(("%s: %dx%d %s video, %.2f fps, %d frames%s"):format(fileName, avi.width, avi.height, avi.codec, avi.fps, avi.frameCount,
			avi.audio and (", sound " .. avi.audio.sampleRate .. " Hz") or (avi.audioUnsupported and (", sound skipped: " .. avi.audioUnsupported) or ", no sound")))
		local streamBytes, st, w, h = storeVideo(name, avi.width, avi.height, fps, count, sourceIndex, getFrame, o, log)
		local attrs = { Width = w, Height = h, Fps = fps, Frames = st.frames, Seconds = st.seconds, Source = "AVI " .. avi.codec }
		local audioNote = ""
		if avi.audio and o.Sound ~= false then
			attrs.Audio, audioNote = storeSound(name, seconds, function(AudioLab)
				return AudioLab.Encoder.decodeAudio(Avi.wav(avi), { MaxSeconds = seconds + 1 })
			end, log, o)
		end
		if o.Sink then
			o.Sink("Videos", name, streamBytes, attrs)
		else
			Store.write(Importer.videoRoot(streamBytes), name, streamBytes, attrs)
		end
		return { kind = "video", name = name, width = w, height = h, seconds = st.seconds, bytes = st.bytes,
			message = ("video %s: %dx%d, %.1f s at %d fps, %.0f KB (%.1f KB/s, %s; 10 min would be %.1f MB)%s"):format(name, w, h, st.seconds, fps,
				st.bytes / 1024, st.bytesPerSecond / 1024, st.codec or "FLV1", st.bytesPerSecond * 600 / 1e6, audioNote) }
	end
end

function Importer.prompt(options)
	local StudioService = game:GetService("StudioService")
	local files = StudioService:PromptImportFilesAsync(Importer.Extensions)
	local results = {}
	for _, file in ipairs(files or {}) do
		local t0 = os.clock()
		local ok, res = pcall(Importer.importFile, file.Name, file:GetBinaryContents(), options)
		if ok then
			print(("[FrameLab] imported %s in %.1f s"):format(res.message, os.clock() - t0))
			table.insert(results, res)
		else
			warn("[FrameLab] " .. file.Name .. ": " .. tostring(res))
		end
	end
	return results
end

return Importer
