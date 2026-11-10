-- FrameLab importer (Studio). Opens the file picker and turns every chosen file into FrameLab data:
--   pictures  PNG, JPG / JPEG / JFIF, BMP, TGA, WebP, GIF (one frame), HEIC / HEIF (iPhone photos), AVIF
--             -> Data/Images/<name>
--   video     MP4 / MOV / M4V (H.264, H.265, AV1 or MPEG-4 Part 2), WebM (VP9, VP8 or AV1), MKV (VP9, VP8, AV1, H.264,
--             H.265 or MPEG-4 Part 2), AVI / DivX
--             (MPEG-4 Part 2: Xvid, DivX; Motion JPEG or uncompressed), MPEG-1 / MPEG-2 (.mpg / .mpeg / .vob, .m1v / .m2v) and
--             transport streams (.ts / .m2ts / .mts: MPEG-2, H.264 or H.265); sources up to Config.ImportMaxVideoLines, 1080p by
--             default, shrunk to the import quality; animated GIF, WebP or PNG (APNG) -> Data/Videos/<name>
--             360p and 240p imports keep a smaller copy too (180p / 144p, one entry: Flv2.packSet), so a device that
--             can't keep up with the big one plays the small one (Video.Stream.deviceLines). In a running game an MP4 /
--             MOV is encoded in parts on Config.ImportWorkers parallel workers (Tools.ImportPool), and its sound is
--             encoded meanwhile
--             the sound (MP4 / MOV: AAC, MP3, Opus, FLAC or AC-3; WebM / MKV: Opus, Vorbis, AAC, MP3, FLAC or AC-3; MPEG: MP2 /
--             MP3, AC-3, AAC or 16-bit PCM; AVI: PCM, MP3, MP2 or AC-3) becomes an AudioLab clip (clip:video/<name>) that the video follows;
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
local Heif = require(FrameLab.Formats.Heif)
local Mp4 = require(FrameLab.Formats.Mp4)
local Webm = require(FrameLab.Formats.Webm)
local Mpg = require(FrameLab.Formats.Mpg)
local Mpeg4 = require(FrameLab.Video.Mpeg4)
local Vp9 = require(FrameLab.Video.Vp9)
local Vp8 = require(FrameLab.Video.Vp8)
local H264 = require(FrameLab.Video.H264)
local Hevc = require(FrameLab.Video.Hevc)
local Av1 = require(FrameLab.Video.Av1)
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
local Resize = require(FrameLab.Image.Resize)
local Stream = require(FrameLab.Video.Stream)
local Flv2 = require(FrameLab.Video.Flv2)
local ImportJob = require(FrameLab.Tools.ImportJob)
local ImportPool = require(FrameLab.Tools.ImportPool)

local EncodingService = game:GetService("EncodingService")

local Importer = {}

Importer.Extensions = { "png", "jpg", "jpeg", "jfif", "jpe", "bmp", "dib", "tga", "gif", "webp", "heic", "heif", "avif", "avi", "divx", "mp4", "m4v", "mov", "webm", "mkv", "mpg", "mpeg", "m1v", "m2v", "vob", "ts", "m2ts", "mts" }
Importer.Readable = "PNG, JPG, BMP, TGA, GIF, WebP, HEIC, AVIF pictures; MP4 / MOV (H.264, H.265, AV1, MPEG-4), WebM (VP9 / VP8 / AV1), MKV (VP9 / VP8 / AV1 / H.264 / H.265 / MPEG-4), AVI (Xvid / DivX, Motion JPEG), MPEG-1 / MPEG-2 (.mpg, .vob, .ts), GIF, WebP, APNG videos"
Importer.Defaults = { MaxImage = 512, MaxVideoWidth = 256, MaxVideoHeight = 256, Fps = 24, MaxSeconds = 600, ChangeTol = 8,
	TargetKBps = 60, Codec = "FLV2" }
local HARD_MAX = 1024

-- video sizes: the short side gets `lines` pixels, the long side at most 16:9 of that (256x144, 426x240; 4:3 -> 192x144);
-- low: the smaller copy kept alongside for slower devices
Importer.Qualities = {
	["144p"] = { lines = 144, kbps = 60 },
	["240p"] = { lines = 240, kbps = 120, low = { lines = 144, kbps = 40 } },
	["360p"] = { lines = 360, kbps = 200, low = { lines = 180, kbps = 48 } }, -- 640x360: ~2.3x the drawing and data of 240p
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
	elseif Webm.isWebm(bytes) then
		return "webm"
	elseif Heif.isHeif(bytes) then
		return "heif"
	elseif Mp4.isMp4(bytes) then
		local brand = buffer.len(bytes) >= 12 and buffer.readstring(bytes, 8, 4) or ""
		if brand ~= "avif" and brand ~= "avis" and brand ~= "heic" and brand ~= "heix" and brand ~= "mif1" and brand ~= "msf1" then
			return "mp4"
		end
	elseif Mpg.isMpg(bytes) then
		return "mpg"
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
			return "an AVIF picture of a kind FrameLab can't read (save it as PNG or JPG)"
		elseif brand == "heic" or brand == "heix" or brand == "mif1" or brand == "msf1" then
			return "a HEIC / HEIF picture of a kind FrameLab can't read (save it as JPG or PNG)"
		end
		return ("an MP4-family file (brand %q)"):format(brand)
	elseif string.sub(head, 1, 4) == "\26\69\223\163" then
		return string.find(head, "webm", 1, true) and "a WebM video" or "a Matroska (MKV) video"
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
	-- (a picture decoded at a reduced size names the size it came from)
	local srcW, srcH = image.sourceWidth or image.width, image.sourceHeight or image.height
	local attrs = { Width = w, Height = h, SourceWidth = srcW, SourceHeight = srcH, Source = sourceKind }
	if o.Sink then
		o.Sink("Images", name, bytes, attrs)
	else
		Store.write(FrameLab.Data.Images, name, bytes, attrs)
	end
	return { kind = "image", name = name, width = w, height = h, bytes = buffer.len(bytes),
		message = ("picture %s: %dx%d (from %dx%d), %.0f KB"):format(name, w, h, srcW, srcH, buffer.len(bytes) / 1024) }
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

-- the sizes a video is kept at: the import quality, and the quality's smaller copy (FLV2 only)
local function videoSizes(srcW, srcH, o)
	local w, h = videoSize(srcW, srcH, o)
	local list = { { w = w, h = h, kbps = o.TargetKBps } }
	local q = o.VideoLines and Importer.Qualities[o.Quality]
	local low = q and q.low
	if low and o.Renditions ~= false and o.Codec ~= "FLV1" then
		local lw, lh = videoSize(srcW, srcH, { VideoLines = low.lines })
		if lw < w or lh < h then
			table.insert(list, { w = lw, h = lh, kbps = low.kbps })
		end
	end
	return list
end

-- the sizes kept for a srcW x srcH source at import quality `quality` (also for streams: Tools.Live)
function Importer.videoSizes(srcW, srcH, quality)
	return videoSizes(srcW, srcH, opts({ Quality = quality }))
end

-- one writer per size, fed by produce(add): add(images) with one image per size, in frame order
local function encodeSizes(sizes, fps, produce, o)
	local writers = {}
	for i, sz in ipairs(sizes) do
		if o.Codec == "FLV1" then
			writers[i] = Stream.writer(sz.w, sz.h, fps, { ChangeTol = o.ChangeTol, Compress = zstd })
		else
			writers[i] = Flv2.writer(sz.w, sz.h, fps, { TargetKBps = sz.kbps, Layers = o.Layers })
		end
	end
	produce(function(imgs)
		for i, w in ipairs(writers) do
			w:add(imgs[i])
		end
	end)
	local results = {}
	for i, w in ipairs(writers) do
		local bytes, st = w:finish()
		results[i] = { bytes = bytes, stats = st }
	end
	return results
end

-- the entry's bytes (several sizes: one FLVS set) and the main size's stats (bytes: the whole entry)
local function finishVideo(results, sizes)
	local bytes = results[1].bytes
	if #sizes > 1 then
		local list = {}
		for i, sz in ipairs(sizes) do
			list[i] = { bytes = results[i].bytes, width = sz.w, height = sz.h, bytesPerSecond = results[i].stats.bytesPerSecond }
		end
		bytes = Flv2.packSet(list)
	end
	local st = results[1].stats
	st.bytes = buffer.len(bytes)
	return bytes, st
end

local function sizesNote(sizes)
	if #sizes < 2 then
		return ""
	end
	return (", with a %dx%d copy for slower devices"):format(sizes[2].w, sizes[2].h)
end

-- video from a frame source: getFrame(i) -> image or nil (repeat), times: output frame k -> source index
local function storeVideo(name, srcW, srcH, outFps, frameCount, sourceIndex, getFrame, o, log)
	local sizes = videoSizes(srcW, srcH, o)
	local t0 = os.clock()
	local results = encodeSizes(sizes, outFps, function(add)
		local cache, cacheIndex, last = nil, -1, nil
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
					cache = {}
					for i, sz in ipairs(sizes) do
						cache[i] = Resize.to(img, sz.w, sz.h)
					end
				end
				cacheIndex = si
			end
			cache = cache or last
			if cache then
				add(cache)
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
	end, o)
	local bytes, stats = finishVideo(results, sizes)
	if o.Timing then
		o.Timing.video = os.clock() - t0
	end
	return bytes, stats, sizes[1].w, sizes[1].h, sizes
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
	local avi
	if kind == "avi" then
		avi = decode(fileName, Avi.parse, buf)
		if avi.video then
			kind = "avi4" -- (MPEG-4 video: read like an MP4's track)
		end
	end
	if kind == "png" and not Png.isAnimated(buf) then
		return storeImage(name, decode(fileName, Png.decode, buf, { Yield = true }), o, "PNG")
	elseif kind == "jpeg" then
		return storeImage(name, decode(fileName, Jpeg.decode, buf, { MaxSize = o.MaxImage, Yield = true }), o, "JPEG")
	elseif kind == "bmp" then
		return storeImage(name, decode(fileName, Bmp.decode, buf), o, "BMP")
	elseif kind == "tga" then
		return storeImage(name, decode(fileName, Tga.decode, buf), o, "TGA")
	elseif kind == "heif" then
		local label = ({ heic = "HEIC", avif = "AVIF" })[Heif.brand(buf)] or "HEIF"
		return storeImage(name, decode(fileName, Heif.decode, buf, { MaxSize = math.min(o.MaxImage, HARD_MAX), Yield = true }), o, label)
	elseif kind == "gif" or kind == "webp" or kind == "png" then
		local g
		if kind == "gif" then
			g = decode(fileName, Gif.decode, buf)
		elseif kind == "png" then
			g = decode(fileName, Png.decodeAnimation, buf, { Yield = true })
		else
			g = decode(fileName, Webp.decode, buf)
			if not g.frames then
				return storeImage(name, g, o, "WebP")
			end
		end
		local label = kind == "gif" and "GIF" or (kind == "png" and "APNG" or "WebP")
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
	elseif kind == "mp4" or kind == "webm" or kind == "mpg" or kind == "avi4" then
		local webm = kind == "webm"
		local mpg = kind == "mpg"
		local m
		if avi then
			-- (PCM sound: as the WAV file it is)
			m = { container = "AVI", video = avi.video, audio = avi.track or (avi.audio and { codec = "PCM", wav = true }) }
		else
			m = decode(fileName, mpg and Mpg.parse or (webm and Webm.parse or Mp4.parse), buf)
		end
		local container = (mpg or avi) and m.container or (webm and "WebM" or "MP4")
		local v = m.video
		if not v and mpg then
			if m.otherVideo then
				error(("%s is an MPEG stream with %s video, which FrameLab can't read: re-save it as H.264 (\"MP4 / H.264\" in most converters)"):format(
					fileName, m.otherVideo), 0)
			end
			error(("%s has no video FrameLab can read (MPEG-1 / MPEG-2, H.264 or H.265)"):format(fileName), 0)
		elseif not v then
			error(("%s is a sound file (%s), not a video: import it with AudioLab"):format(fileName, webm and "WebM / MKV" or "M4A"), 0)
		end
		local codec = v.codec or "?"
		local isVp8 = codec == "vp08"
		local isVp9 = codec == "vp09" or isVp8 -- (VP9 and VP8 are read alike here)
		local isMpeg = codec == "mpgv"
		local isMp4v = codec == "mp4v"
		local isHevc = codec == "hvc1" or codec == "hev1"
		local isAv1 = codec == "av01"
		if codec ~= "avc1" and codec ~= "avc3" and not isVp9 and not isMpeg and not isMp4v and not isHevc and not isAv1 then
			local names = { m2v1 = "MPEG-2", s263 = "H.263", theora = "Theora" }
			error(("%s is %s with %s video, which FrameLab can't read: re-save it as H.264 (\"MP4 / H.264\" in most converters) or as VP9 / VP8 WebM"):format(
				fileName, webm and "a WebM / MKV" or "an MP4", names[codec] or ("%q"):format(codec)), 0)
		end
		local codecName = isMpeg and (v.mpeg2 and "MPEG-2" or "MPEG-1") or isMp4v and "MPEG-4" or isHevc and "H.265" or isAv1 and "AV1" or isVp8 and "VP8" or isVp9 and "VP9" or "H.264"
		local srcW, srcH = v.width or 0, v.height or 0 -- (MPEG: from the sequence header, in the picture's shape)
		local sps0
		if v.annexB then
			-- (H.264 / H.265 from a transport stream: the size from its first pictures)
			local probe = isHevc and Hevc.new(nil) or H264.new(nil)
			for i = 1, math.min(#v.samples, 30) do
				local s = v.samples[i]
				if pcall(probe.decodeAccessUnit, probe, v.data, s.pos, s.size) and probe.width then
					srcW, srcH = probe.width, probe.height
					break
				end
			end
		elseif isVp9 then
			-- (the picture size from the first frame: the track may give a display size)
			local first = v.samples[1]
			local probe = isVp8 and Vp8.new() or Vp9.new()
			local okProbe, err = pcall(probe.decodeSample, probe, buf, first.pos, first.size)
			if not okProbe then
				error(("%s couldn't be read: %s"):format(fileName, cleanError(err)), 0)
			end
			if probe.width > 0 then
				srcW, srcH = probe.width, probe.height
			end
		elseif isMp4v then
			-- (the picture size and pixel shape from the VOL headers: the setup, or the first frame)
			local probe = Mpeg4.parser(v.config)
			local st = probe.st
			if (st.width or 0) == 0 and v.samples[1] then
				pcall(probe.vops, probe, v.data or buf, v.samples[1].pos, v.samples[1].size)
			end
			if (st.width or 0) > 0 then
				srcW, srcH = st.width, st.height
				if st.parW > 0 and st.parH > 0 and st.parW ~= st.parH then
					srcW = math.max(1, math.floor(st.width * st.parW / st.parH + 0.5))
				end
			end
		elseif isAv1 then
			-- (the picture size from the sequence header: the setup's, or the first frame's)
			local probe
			if v.av1C then
				probe = decode(fileName, Av1.new, v.av1C)
			end
			if not probe or (probe.width or 0) <= 0 then
				local first = v.samples[1]
				probe = Av1.new(nil)
				local okProbe, err = pcall(probe.decodeSample, probe, v.data or buf, first.pos, first.size)
				if not okProbe then
					error(("%s couldn't be read: %s"):format(fileName, cleanError(err)), 0)
				end
			end
			if (probe.width or 0) > 0 then
				srcW, srcH = probe.width, probe.height
			end
		elseif isHevc then
			-- (the picture size and pixel shape from the setup's sequence parameters)
			if not v.hvcC then
				error(("%s couldn't be read: %s: the H.265 setup (hvcC) is missing"):format(fileName, container), 0)
			end
			local probe = decode(fileName, Hevc.new, v.hvcC)
			if probe.width then
				srcW, srcH = probe.width, probe.height
				if probe.sarW > 0 and probe.sarH > 0 and probe.sarW ~= probe.sarH then
					srcW = math.max(1, math.floor(probe.width * probe.sarW / probe.sarH + 0.5))
				end
			end
		elseif not isMpeg then
			if not v.avcC then
				error(("%s couldn't be read: %s: the H.264 setup (avcC) is missing"):format(fileName, container), 0)
			end
			local dec = decode(fileName, H264.new, v.avcC)
			for _, s in pairs(dec.spsList) do
				sps0 = s
				break
			end
			if sps0 then
				srcW = sps0.mbw * 16 - sps0.cropLeft - sps0.cropRight
				srcH = sps0.mbh * 16 - sps0.cropTop - sps0.cropBottom
			end
		end
		if srcW <= 0 or srcH <= 0 then
			error(("%s couldn't be read: %s: the video has no size"):format(fileName, container), 0)
		end
		local maxLines = o.MaxVideoLines or Config.ImportMaxVideoLines or 1080
		if math.min(srcW, srcH) > maxLines then
			error(("%s is %dx%d (%dp); the limit is %dp (ImportMaxVideoLines). Use a %dp copy, or raise the limit (bigger videos take much longer to import)"):format(
				fileName, srcW, srcH, math.min(srcW, srcH), maxLines, maxLines), 0)
		end
		local t = ImportJob.mp4Timing(v, o.Fps, o.MaxSeconds)
		local fps, seconds, count = t.fps, t.seconds, t.count
		local sizes = videoSizes(srcW, srcH, o)
		local ow, oh = sizes[1].w, sizes[1].h
		log(("%s: %dx%d %s video, %.2f fps, %d frames, %.1f s%s"):format(fileName, srcW, srcH,
			codecName .. (sps0 and (" (profile " .. sps0.profile .. ")") or ""), t.srcFps, t.n, t.duration,
			m.audio and (", sound " .. tostring(m.audio.codec)) or ", no sound"))
		local attrs = { Width = ow, Height = oh, Fps = fps, Source = container .. " " .. codecName, Quality = o.Quality }
		local audioNote = ""
		local soundDone = not (m.audio and o.Sound ~= false)
		local function sound(so)
			if not soundDone then
				soundDone = true
				attrs.Audio, audioNote = storeSound(name, seconds, function(AudioLab)
					if m.audio.wav then
						return AudioLab.Encoder.decodeAudio(Avi.wav(avi), { MaxSeconds = seconds + 0.5 })
					end
					return AudioLab.Encoder.decodeMp4Audio(buf, m.audio, { MaxSeconds = seconds + 0.5 })
				end, log, so)
			end
		end
		local t0 = os.clock()
		local results
		local keyEvery = fps * 4
		local layers = o.Layers or 2
		local workers = math.floor(tonumber(o.Workers or Config.ImportWorkers) or 1)
		local ok, err = pcall(function()
			if o.Codec ~= "FLV1" and workers > 1 and count > keyEvery * 3 and ImportPool.available() then
				local segs = ImportJob.planSegments(t, ImportJob.idrDisplay(buf, v, t), keyEvery, workers * 2)
				if #segs > 1 then
					local jobs = {}
					for i, sg in ipairs(segs) do
						jobs[i] = { k0 = sg.k0, k1 = sg.k1, sizes = sizes, maxFps = o.Fps, maxSeconds = o.MaxSeconds, layers = layers,
							keyEvery = keyEvery }
					end
					log(("  %s: %d parts on %d workers"):format(name, #jobs, math.min(workers, #jobs)))
					-- the sound is decoded and encoded here while the workers encode the picture (its progress isn't shown)
					local quiet = table.clone(o)
					quiet.Progress = nil
					local soundRunning = true
					task.spawn(function()
						pcall(sound, quiet)
						soundRunning = false
					end)
					local parts = ImportPool.run(buf, jobs, workers, function(done)
						if o.Progress then
							o.Progress("video", math.min(1, done / count))
						end
					end)
					while soundRunning do
						task.wait(0.1)
					end
					if parts then
						results = {}
						for si, sz in ipairs(sizes) do
							local list = table.create(#jobs)
							for i = 1, #jobs do
								list[i] = parts[i][si]
							end
							local bytes, st = Flv2.assemble(list, sz.w, sz.h, fps, keyEvery, layers)
							results[si] = { bytes = bytes, stats = st }
						end
					end
				end
			end
			if not results then
				results = encodeSizes(sizes, fps, function(add)
					local lastYield = os.clock()
					local function yield()
						if os.clock() - lastYield > 0.012 then
							task.wait()
							lastYield = os.clock()
						end
					end
					ImportJob.mp4Frames(buf, v, t, 0, count, sizes, function(k, imgs)
						add(imgs)
						if o.Progress and k % 6 == 0 then
							o.Progress("video", (k + 1) / count)
						end
						if k % 48 == 47 then
							log(("  %s: %d / %d frames (%.0f s)"):format(name, k + 1, count, os.clock() - t0))
						end
						yield()
					end, yield)
				end, o)
			end
		end)
		if not ok then
			error(("%s couldn't be read: %s"):format(fileName, cleanError(err)), 0)
		end
		if o.Timing then
			o.Timing.video = os.clock() - t0
		end
		sound(o)
		local streamBytes, st = finishVideo(results, sizes)
		attrs.Frames, attrs.Seconds = st.frames, st.seconds
		if o.Sink then
			o.Sink("Videos", name, streamBytes, attrs)
		else
			Store.write(Importer.videoRoot(streamBytes), name, streamBytes, attrs)
		end
		return { kind = "video", name = name, width = ow, height = oh, seconds = st.seconds, bytes = st.bytes,
			message = ("video %s: %dx%d, %.1f s at %d fps (from %dx%d %s), %.0f KB (%.1f KB/s)%s%s"):format(name, ow, oh, st.seconds, fps, srcW, srcH, codecName,
				st.bytes / 1024, st.bytesPerSecond / 1024, sizesNote(sizes), audioNote) }
	else -- avi
		avi = avi or decode(fileName, Avi.parse, buf)
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
