-- VideoLab: video with sound, in one place. The picture is FrameLab's (gradient-strip video, no EditableImage), the
-- sound is AudioLab's (a resynthesised clip, no uploaded audio); VideoLab imports both from one file and plays them
-- together on one clock.
-- (part of LabHub: keep it inside the LabHub module, next to FrameLab and AudioLab)
--
-- Import (picture and sound in one go; MP4 / MOV / M4V with H.264 video and AAC or MP3 sound, AVI, GIF, WebP):
--   VideoLab.import()                                -- Studio command bar: pick files; saved in the place
--   VideoLab.importFile("clip.mp4", bytes, options)  -- Studio: saved in the place; running server: kept until it closes
--   VideoLab.importUrl(url)                          -- server: download and import, kept until the server closes
--                                                       (what the TV's Import box does) -> { name, seconds, ... } or { error }
--   VideoLab.importYouTube(link)                     -- server: a YouTube link, through the VideoLab YouTube helper (yt-dlp
--                                                       on your computer: FrameLab Config YouTubeHelper / YouTubeHelperKey);
--                                                       importUrl takes YouTube links too
--   options: Sound = false (picture only), and the FrameLab importer options (MaxSeconds, MaxVideoWidth, Fps, ...)
--
-- Look up:
--   VideoLab.list() -> { { name, width, height, seconds, fps, sound = "video/<name>" | nil, session = true | nil } }
--   VideoLab.info(name) -> that entry, or nil
--
-- Play for everyone (server): picture and sound follow the server's playhead; players who join later start in step.
--   VideoLab.playOn(screen, name, { Loop, StartTime, Speed, Sound = false })   -- screen: a Part, or a Model with a
--                                                                                -- part named "Screen"
--   VideoLab.pause(screen) / resume(screen) / seek(screen, seconds) / stop(screen) / setSpeed(screen, x)
--   VideoLab.getTime(screen) -> seconds
--
-- Play for one player (client, in a GUI; videos saved in the place):
--   local video = VideoLab.play(name, guiObject, { Loop, Volume, Audio = false })   -- video:pause() / :resume() /
--                                                                                    -- :seek(s) / :destroy()
-- Remove (Studio): VideoLab.remove(name)             -- the picture and its sound clip
--
-- The parts: VideoLab.FrameLab, VideoLab.AudioLab

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local VideoLab = {}

local function frameLab()
	local m = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("FrameLab") or game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("FrameLab", 10)
	if not m then
		error("VideoLab needs FrameLab in ReplicatedStorage", 2)
	end
	return require(m)
end
local function audioLab()
	local m = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab") or game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("AudioLab", 10)
	return m and require(m) or nil
end
local function sync()
	return require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("FrameLab"):WaitForChild("Sync"))
end
local function server()
	local FrameLab = frameLab()
	local t0 = os.clock()
	while not FrameLab.Server and os.clock() - t0 < 10 do
		task.wait(0.1)
	end
	return FrameLab.Server
end
local function soundName(audio)
	if type(audio) == "string" and string.sub(audio, 1, 5) == "clip:" then
		return string.sub(audio, 6)
	end
	return nil
end

------------------------------------------------------------------------------------------------------------------------
-- import

function VideoLab.import(options)
	return frameLab().import(options)
end

function VideoLab.importFile(fileName, bytes, options)
	local FrameLab = frameLab()
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local o = table.clone(options or {})
	if RunService:IsRunning() and RunService:IsServer() then
		-- a running server can't save into the place: keep it for the session, like the TV's imports
		local s = server()
		if not s then
			error("VideoLab: FrameLab's server runtime isn't running (call FrameLab.init() on the server)", 2)
		end
		o.Folder = o.Folder or "imported"
		o.Taken = o.Taken or function(n)
			return s.find("Videos", n) ~= nil or s.find("Images", n) ~= nil
		end
		o.Sink = function(kind, name, data, attrs)
			attrs.Bytes = buffer.len(data)
			s.session[kind][name] = { bytes = data, attrs = attrs }
		end
	end
	return FrameLab.Importer.importFile(fileName, buf, o)
end

function VideoLab.importUrl(url)
	if not RunService:IsServer() then
		error("VideoLab.importUrl runs on the server", 2)
	end
	local s = server()
	if not s then
		error("VideoLab: FrameLab's server runtime isn't running (call FrameLab.init() on the server)", 2)
	end
	return s.importUrl("video", url)
end

function VideoLab.importYouTube(link)
	if type(link) == "string" and string.match(link, "^[%w_%-]+$") and #link == 11 then
		link = "https://www.youtube.com/watch?v=" .. link -- a bare video id
	end
	return VideoLab.importUrl(link)
end

------------------------------------------------------------------------------------------------------------------------
-- look up

local function entryOf(v)
	return { name = v.name, width = v.Width, height = v.Height, seconds = v.Seconds, fps = v.Fps, bytes = v.Bytes,
		sound = soundName(v.Audio), session = v.Imported or nil }
end

function VideoLab.list()
	local FrameLab = frameLab()
	local out = {}
	if RunService:IsServer() then
		local s = RunService:IsRunning() and FrameLab.Server
		if s and s.listOf then
			for _, v in ipairs(s.listOf("Videos")) do
				table.insert(out, entryOf(v))
			end
			return out
		end
		for _, name in ipairs(FrameLab.Store.list(ReplicatedStorage.LabHub.FrameLab.Data.Videos)) do
			local a = FrameLab.info("video", name) or {}
			a.name = name
			table.insert(out, entryOf(a))
		end
		return out
	end
	local Net = require(ReplicatedStorage.LabHub.FrameLab.Tools.Net)
	for _, v in ipairs(Net.videos() or {}) do
		table.insert(out, entryOf(v))
	end
	return out
end

function VideoLab.info(name)
	for _, v in ipairs(VideoLab.list()) do
		if v.name == name then
			return v
		end
	end
	return nil
end

------------------------------------------------------------------------------------------------------------------------
-- play for everyone (server)

function VideoLab.playOn(screen, name, options)
	options = options or {}
	sync().play(screen, { Video = name, Loop = options.Loop == true, StartTime = options.StartTime, Speed = options.Speed,
		Delay = options.Delay, Face = options.Face, Sound = options.Sound })
end
function VideoLab.pause(screen)
	sync().pause(screen)
end
function VideoLab.resume(screen)
	sync().resume(screen)
end
function VideoLab.seek(screen, seconds)
	sync().seek(screen, seconds)
end
function VideoLab.stop(screen)
	sync().stop(screen)
end
function VideoLab.setSpeed(screen, speed)
	sync().setSpeed(screen, speed)
end
function VideoLab.getTime(screen)
	return sync().getTime(screen, { duration = screen:GetAttribute("FrameLabDuration"), loop = screen:GetAttribute("FrameLabLoop") == true })
end

------------------------------------------------------------------------------------------------------------------------
-- play for one player (client GUI)

function VideoLab.play(name, parent, options)
	return frameLab().play(name, parent, options)
end

------------------------------------------------------------------------------------------------------------------------
-- remove (Studio)

function VideoLab.remove(name)
	local FrameLab = frameLab()
	local removed = false
	local roots = { ReplicatedStorage.LabHub.FrameLab.Data.Videos }
	local ss = game:GetService("ServerStorage"):FindFirstChild("FrameLabData")
	if ss and ss:FindFirstChild("Videos") then
		table.insert(roots, ss.Videos)
	end
	local sound
	for _, r in ipairs(roots) do
		local e = FrameLab.Store.entry(r, name)
		if e then
			sound = sound or soundName(e:GetAttribute("Audio"))
			e:Destroy()
			removed = true
		end
	end
	local AudioLab = audioLab()
	if sound and AudioLab then
		local node = AudioLab.Importer.clipsRoot()
		for part in string.gmatch(sound, "[^/]+") do
			node = node and node:FindFirstChild(part)
		end
		if node then
			node:Destroy()
		end
	end
	return removed
end

return setmetatable(VideoLab, {
	__index = function(_, key)
		if key == "FrameLab" then
			return frameLab()
		elseif key == "AudioLab" then
			return audioLab()
		end
		return nil
	end,
})
