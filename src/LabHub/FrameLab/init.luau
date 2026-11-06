-- FrameLab: pictures and video in Roblox GUI without uploading them and without EditableImage. A picture is drawn
-- with gradient strips: Frames whose UIGradient holds up to 20 colour keypoints along a row, blended by Roblox, so a
-- 256 x 144 picture takes about 700 - 1,000 Frames instead of 37,000. Video only redraws the strips a frame changed,
-- with quality settings a player can change while it plays.
-- (part of LabHub: keep it inside the LabHub module in ReplicatedStorage)
--   Formats/  Inflate, Png, Jpeg, Bmp, Tga, Gif, Avi
--   Image/    Resize, Strips (the strip fitter)
--   Render/   Canvas (strips as GUI, pooled)
--   Video/    Stream (FrameLab video data), Player (runtime strip video player)
--   Tools/    Store (data in the place), Importer (Studio file import)
--   Data/     Images, Videos (imported data)
--   Runtime/  Server and Client modules (TVs, sprays, panels), started by FrameLab:init() (LabHub.start calls it)
--
-- Usage:
--   FrameLab.import()                                   -- command bar: pick pictures / videos to import
--   local canvas = FrameLab.show("cat", someGuiObject)  -- a stored picture (or an image table)
--   local video = FrameLab.play("intro", someGuiObject, { Loop = true })   -- plays its sound too, if it has one
--   FrameLab.list()                                     -- { images = {...}, videos = {...} }

local FrameLab = {}
local cache = {}
local paths = {
	Inflate = { "Formats", "Inflate" }, Png = { "Formats", "Png" }, Jpeg = { "Formats", "Jpeg" }, Bmp = { "Formats", "Bmp" },
	Tga = { "Formats", "Tga" }, Gif = { "Formats", "Gif" }, Avi = { "Formats", "Avi" },
	Resize = { "Image", "Resize" }, Strips = { "Image", "Strips" }, Canvas = { "Render", "Canvas" },
	Stream = { "Video", "Stream" }, Player = { "Video", "Player" }, Store = { "Tools", "Store" }, Importer = { "Tools", "Importer" },
}

local EncodingService = game:GetService("EncodingService")

local started = {}
function FrameLab.init()
	local side = game:GetService("RunService"):IsServer() and "Server" or "Client"
	if started[side] then
		return FrameLab
	end
	started[side] = true
	local folder = script:FindFirstChild("Runtime") and script.Runtime:FindFirstChild(side)
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("ModuleScript") then
				local ok, fn = pcall(require, m)
				if not ok then
					warn(("[FrameLab] %s failed to load: %s"):format(m:GetFullName(), tostring(fn)))
				elseif type(fn) == "function" then
					task.spawn(fn, FrameLab)
				end
			end
		end
	end
	return FrameLab
end

-- any supported picture file -> image { width, height, data (RGBA buffer), hasAlpha } (a GIF gives its first frame)
-- options: MaxSize (only this big is needed: big JPEGs decode at a fraction of their size), Yield (pause every few
-- milliseconds: call it where yielding is allowed)
function FrameLab.decodeImage(bytes, fileName, options)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if FrameLab.Png.isPng(b) then
		return FrameLab.Png.decode(b, options)
	elseif FrameLab.Jpeg.isJpeg(b) then
		return FrameLab.Jpeg.decode(b, options)
	elseif FrameLab.Gif.isGif(b) then
		local g = FrameLab.Gif.decode(b)
		return { width = g.width, height = g.height, data = g.frames[1].data, hasAlpha = g.hasAlpha }
	elseif FrameLab.Bmp.isBmp(b) then
		return FrameLab.Bmp.decode(b)
	elseif FrameLab.Tga.isTga(b) then
		return FrameLab.Tga.decode(b)
	end
	error("FrameLab: " .. tostring(fileName or "data") .. " is not a picture FrameLab reads")
end

function FrameLab.unpackImage(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	assert(buffer.readstring(b, 0, 4) == "FLI1", "not a FrameLab picture")
	local w, h = buffer.readu16(b, 4), buffer.readu16(b, 6)
	local z = buffer.create(buffer.len(b) - 13)
	buffer.copy(z, 0, b, 13)
	local data = EncodingService:DecompressBuffer(z, Enum.CompressionAlgorithm.Zstd)
	return { width = w, height = h, data = data, hasAlpha = buffer.readu8(b, 8) == 1 }
end

function FrameLab.loadImage(name)
	return FrameLab.unpackImage(FrameLab.Store.read(script.Data.Images, name))
end

function FrameLab.list()
	return { images = FrameLab.Store.list(script.Data.Images), videos = FrameLab.Store.list(script.Data.Videos) }
end

function FrameLab.info(kind, name)
	local root = (kind == "video") and script.Data.Videos or script.Data.Images
	local e = FrameLab.Store.entry(root, name)
	return e and e:GetAttributes() or nil
end

-- strips for a picture; transparent pixels (alpha < 128) are left out
function FrameLab.encode(image, options)
	options = options or {}
	-- rows when the ramp image is there (Render/Canvas draws row strips with it, column strips only with gradients)
	return FrameLab.Strips.encode(image, { Tol = options.Tolerance or 8, Merge = options.Merge,
		Orientation = options.Orientation or (FrameLab.Canvas.rampImage() and "rows" or nil) })
end

-- show a picture: source = a stored picture name, an image table, or file bytes
--   options: Tolerance (0..255, default 8: lower = sharper, more Frames), MaxSize (shrink first), Yield (build a few
--            hundred Frames per frame, default true), and the Canvas options (Size, Position, AnchorPoint, Background)
function FrameLab.show(source, parent, options)
	options = options or {}
	local image
	if type(source) == "string" and FrameLab.Store.has(script.Data.Images, source) then
		image = FrameLab.loadImage(source)
	elseif type(source) == "table" then
		image = source
	else
		image = FrameLab.decodeImage(source)
	end
	if options.MaxSize then
		image = FrameLab.Resize.fit(image, options.MaxSize)
	end
	local strips = FrameLab.encode(image, options)
	local canvas = FrameLab.Canvas.new(parent, image.width, image.height, options)
	canvas.strips = strips
	canvas:draw(strips, options.Yield ~= false and 400 or nil, image.hasAlpha)
	return canvas
end

-- play a stored video; when it has a sound clip (imported from the same file) the sound plays too and the picture
-- follows the sound's clock. options: Loop, Volume, Audio (false = picture only), and the Player / Canvas options.
function FrameLab.play(name, parent, options)
	options = options or {}
	local root = script.Data.Videos
	local entry = FrameLab.Store.entry(root, name)
	if not entry then
		error("FrameLab: no video named " .. tostring(name))
	end
	local bytes = FrameLab.Store.read(root, name)
	local audioId = entry:GetAttribute("Audio")
	local playerOptions = table.clone(options)
	local track
	local player = FrameLab.Player.new(bytes, parent, playerOptions)
	player:prepare()
	if audioId and options.Audio ~= false then
		local ok, AudioLab = pcall(require, game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("AudioLab", 5))
		if ok and AudioLab then
			local ok2, t = pcall(AudioLab.play, audioId, { Loop = options.Loop == true, Volume = options.Volume or 1 })
			if ok2 and t then
				track = t
				player.Clock = function()
					return track:getTime()
				end
				player.track = track
			else
				warn("[FrameLab] the video's sound didn't start: " .. tostring(t))
			end
		end
	end
	player:play()
	-- a video with sound ends when the sound ends (non-looping)
	if track and track.Ended and not options.Loop then
		track.Ended:Connect(function()
			player.Clock = nil
			player:stop()
			player.endedEvent:Fire()
		end)
	end
	local destroy = player.destroy
	function player.destroy(p)
		if track then
			pcall(function()
				track:stop()
			end)
		end
		destroy(p)
	end
	return player
end

-- Studio: open the file picker and import pictures / videos (run from the command bar)
function FrameLab.import(options)
	return FrameLab.Importer.prompt(options)
end

return setmetatable(FrameLab, {
	__index = function(_, name)
		local c = cache[name]
		if c ~= nil then
			return c
		end
		local path = paths[name]
		if not path then
			return nil
		end
		local mod = require(script:WaitForChild(path[1]):WaitForChild(path[2]))
		cache[name] = mod
		return mod
	end,
})