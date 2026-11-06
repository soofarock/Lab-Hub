-- Server-authoritative playback for AudioLab. The server never synthesises anything: it writes a handful of
-- attributes on the audio's instance (a Part, Attachment, Model, or any Instance), and every client plays that audio
-- locally and keeps itself on the server's playhead. Attributes replicate to everyone and stay on the instance, so a
-- player who joins later starts in the right place, and no RemoteEvents are needed.
--
-- Server:
--   local Sync = require(game.ReplicatedStorage.LabHub.AudioLab.Sync)       -- does not load the synth
--   Sync.play(part, { Midi = "MySong/music.mid", SoundFont = "MySong/instruments.sf2", Loop = true, Volume = 0.5 })
--   Sync.play(part, { Clip = "sfx/splash" })              -- or File = "..."
--   Sync.pause(part); Sync.resume(part); Sync.seek(part, 12.5); Sync.stop(part)
--   Sync.setSpeed(part, 1.25); Sync.setVolume(part, 0.3)
--   Sync.getTime(part)  -- the server's playhead in seconds (no audio involved); pass { duration=, loop=, loopStart=, loopEnd= } to wrap it
--   opts: StartTime, Speed, Delay (seconds before the audible start, default Sync.Delay, gives every client time to get ready),
--         Spatial, Mode, Loop, Volume, LoopLength (a clip loops every LoopLength seconds instead of its own length: a
--         video's sound loops with the picture, so a sound a few ms shorter than its video doesn't creep ahead each loop)
-- Clients (AudioLabClient runs this for every instance tagged "AudioLab" that has AudioLabSynced = true):
--   position = AudioLabPos + (serverTime - AudioLabAt) * AudioLabSpeed, wrapped into the loop; re-seeks when a client drifts
--   more than Sync.Tolerance. Instance attribute AudioLabSyncLead (seconds) overrides Sync.Lead for the start-up latency.
--
-- Per-player audio ("channels"): the server owns what each player hears. A channel is a Folder in the player's PlayerGui
-- (replicated to that player only), driven exactly like any synced instance:
--   Sync.playFor(player, "music", { Midi = "MySong/music.mid", SoundFont = "MySong/instruments.sf2", Loop = true })
--   Sync.pause(Sync.getChannel(player, "music"))  -- or Sync.channel(player, "music") to create it
--   Sync.listening(player) -> { { channel, state, midi, soundFont, clip, file, loop, volume, speed, position,
--                                 clientControl, reported = { playing, position, age } | nil }, ... }
--   Sync.setClientControl(channel, false)   -- the client may not change this channel (default: it may)
--   Sync.authorize = function(player, target, action, arg) return true end   -- optional: veto client requests
-- Client: Sync.request("music", "play", { Midi = ..., SoundFont = ..., Loop = true, Volume = 0.5 }) asks the server to start
--   a track on the player's own channel (the server checks the track exists and clamps the numbers);
--   Sync.request("music", "pause" | "resume" | "toggle" | "stop" | "restart" | "seek" | "setSpeed" | "setVolume", n).
--   Clients report what they are really playing every 2 s (listening(...).reported); the server's state stays authoritative.
-- State attributes: AudioLabState ("playing" | "paused" | "stopped"), AudioLabPos, AudioLabAt, AudioLabSpeed, AudioLabSeq.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Sync = {}
Sync.Tag = "AudioLab"
Sync.Delay = 0.3 -- seconds between a server command and the audible start
Sync.Lead = 0.05 -- start-up latency of a client's synth, started this much early
Sync.Tolerance = 0.12 -- seconds of drift tolerated before a client re-seeks

local CONFIG = {
	Midi = "AudioLabMidi", SoundFont = "AudioLabSoundFont", Clip = "AudioLabClip", File = "AudioLabFile",
	Loop = "AudioLabLoop", Spatial = "AudioLabSpatial", Volume = "AudioLabVolume", Mode = "AudioLabMode",
}

local function serverNow()
	return workspace:GetServerTimeNow()
end

-- { state, pos, at, speed, seq } or nil when the instance has no playback state yet
function Sync.state(instance)
	local state = instance:GetAttribute("AudioLabState")
	if state == nil then
		return nil
	end
	return {
		state = state,
		pos = instance:GetAttribute("AudioLabPos") or 0,
		at = instance:GetAttribute("AudioLabAt") or 0,
		speed = instance:GetAttribute("AudioLabSpeed") or 1,
		seq = instance:GetAttribute("AudioLabSeq") or 0,
	}
end

-- Unwrapped playhead (seconds) at server time `now`; negative while a delayed start has not begun.
function Sync.rawPosition(st, now)
	if st.state == "playing" then
		return st.pos + (now - st.at) * st.speed
	end
	return st.pos
end

-- Where the audio should be at server time `now`: position (seconds, wrapped into the loop) and whether a one-shot has
-- finished. info = { duration, loop, loopStart?, loopEnd? }. A negative position means the start is still ahead.
function Sync.target(st, now, info)
	local p = Sync.rawPosition(st, now)
	if p < 0 then
		return p, false
	end
	local loopStart, loopEnd = info.loopStart or 0, info.loopEnd or info.duration
	if info.loop and loopEnd > loopStart then
		if p >= loopEnd then
			p = loopStart + (p - loopStart) % (loopEnd - loopStart)
		end
		return p, false
	end
	if p >= info.duration then
		return info.duration, true
	end
	return p, false
end

local function write(instance, state, pos, at, speed)
	instance:SetAttribute("AudioLabPos", pos)
	instance:SetAttribute("AudioLabAt", at)
	instance:SetAttribute("AudioLabSpeed", speed)
	instance:SetAttribute("AudioLabState", state)
	instance:SetAttribute("AudioLabSeq", (instance:GetAttribute("AudioLabSeq") or 0) + 1) -- last: clients react to it
end

local function serverOnly()
	assert(RunService:IsServer(), "AudioLab.Sync commands run on the server")
end

function Sync.play(instance, opts)
	serverOnly()
	opts = opts or {}
	for key, attr in pairs(CONFIG) do
		if opts[key] ~= nil then
			instance:SetAttribute(attr, opts[key])
		end
	end
	if opts.Midi ~= nil or opts.Clip ~= nil or opts.File ~= nil then
		for _, key in ipairs({ "Midi", "SoundFont", "Clip", "File" }) do -- a new track replaces the old one
			if opts[key] == nil then
				instance:SetAttribute(CONFIG[key], nil)
			end
		end
	end
	instance:SetAttribute("AudioLabLoopLength", (type(opts.LoopLength) == "number" and opts.LoopLength > 0) and opts.LoopLength or nil)
	instance:SetAttribute("AudioLabSynced", true)
	instance:SetAttribute("AudioLabAutoPlay", false)
	if not CollectionService:HasTag(instance, Sync.Tag) then
		CollectionService:AddTag(instance, Sync.Tag)
	end
	local delay = opts.Delay
	if delay == nil then
		delay = Sync.Delay
	end
	write(instance, "playing", opts.StartTime or 0, serverNow() + delay, opts.Speed or 1)
end

function Sync.pause(instance)
	serverOnly()
	local st = Sync.state(instance)
	if st and st.state == "playing" then
		write(instance, "paused", math.max(Sync.rawPosition(st, serverNow()), st.pos), 0, st.speed)
	end
end

function Sync.resume(instance, delay)
	serverOnly()
	local st = Sync.state(instance)
	if st and st.state == "paused" then
		write(instance, "playing", st.pos, serverNow() + (delay or Sync.Delay), st.speed)
	end
end

function Sync.seek(instance, t, delay)
	serverOnly()
	local st = Sync.state(instance) or { state = "paused", pos = 0, at = 0, speed = 1 }
	if st.state == "playing" then
		write(instance, "playing", t, serverNow() + (delay or Sync.Delay), st.speed)
	else
		write(instance, "paused", t, 0, st.speed)
	end
end

function Sync.stop(instance)
	serverOnly()
	local st = Sync.state(instance)
	if st then
		write(instance, "stopped", 0, 0, st.speed)
	end
end

function Sync.setSpeed(instance, speed)
	serverOnly()
	local st = Sync.state(instance)
	if not st then
		return
	end
	if st.state == "playing" then
		local now = serverNow()
		write(instance, "playing", math.max(Sync.rawPosition(st, now), 0), now, speed)
	else
		write(instance, st.state, st.pos, st.at, speed)
	end
end

function Sync.setVolume(instance, volume)
	serverOnly()
	instance:SetAttribute("AudioLabVolume", volume)
end

-- The server's playhead in seconds (works on the client too); wrapped when `info` is given.
function Sync.getTime(instance, info)
	local st = Sync.state(instance)
	if not st then
		return 0
	end
	local now = serverNow()
	if info then
		local p = Sync.target(st, now, info)
		return p
	end
	return math.max(Sync.rawPosition(st, now), 0)
end

-- Per-player channels (server) ------------------------------------------------------------------------------------------
local MAX_CHANNELS = 4
local function channelFolderName(name)
	return "AudioLabChannel_" .. name
end

function Sync.channels(player)
	local list = {}
	local gui = player:FindFirstChild("PlayerGui")
	if gui then
		for _, child in ipairs(gui:GetChildren()) do
			if child:GetAttribute("AudioLabChannel") ~= nil then
				table.insert(list, child)
			end
		end
	end
	return list
end

function Sync.getChannel(player, name)
	local gui = player:FindFirstChild("PlayerGui")
	return gui and gui:FindFirstChild(channelFolderName(name)) or nil
end

-- The player's channel `name` (created on first use; nil when the player has no PlayerGui or too many channels).
function Sync.channel(player, name)
	serverOnly()
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Sync.channel expects a Player")
	assert(type(name) == "string" and string.match(name, "^[%w_]+$") and #name <= 24, "channel names are 1-24 letters, digits or _")
	local gui = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not gui then
		return nil
	end
	local channel = gui:FindFirstChild(channelFolderName(name))
	if channel then
		return channel
	end
	if #Sync.channels(player) >= MAX_CHANNELS then
		return nil
	end
	channel = Instance.new("Folder")
	channel.Name = channelFolderName(name)
	channel:SetAttribute("AudioLabChannel", name)
	channel:SetAttribute("AudioLabOwner", player.UserId)
	channel:SetAttribute("AudioLabClientControl", true)
	channel.Parent = gui
	return channel
end

function Sync.playFor(player, name, opts)
	local channel = Sync.channel(player, name)
	if channel then
		Sync.play(channel, opts)
	end
	return channel
end

-- May the player change this channel (or world audio instance) through Sync.request?
function Sync.setClientControl(instance, allowed)
	serverOnly()
	instance:SetAttribute("AudioLabClientControl", allowed == true)
end

-- What this player is listening to, as far as the server knows (its own state) plus what the client last reported.
function Sync.listening(player)
	local list = {}
	local now = serverNow()
	for _, channel in ipairs(Sync.channels(player)) do
		local st = Sync.state(channel)
		local reportAt = channel:GetAttribute("AudioLabReportAt")
		table.insert(list, {
			channel = channel:GetAttribute("AudioLabChannel"),
			instance = channel,
			state = st and st.state or "stopped",
			midi = channel:GetAttribute("AudioLabMidi"),
			soundFont = channel:GetAttribute("AudioLabSoundFont"),
			clip = channel:GetAttribute("AudioLabClip"),
			file = channel:GetAttribute("AudioLabFile"),
			loop = channel:GetAttribute("AudioLabLoop") == true,
			volume = channel:GetAttribute("AudioLabVolume"),
			speed = st and st.speed or 1,
			position = st and Sync.getTime(channel) or 0, -- unwrapped seconds (the server does not know the loop region)
			clientControl = channel:GetAttribute("AudioLabClientControl") == true,
			reported = reportAt and {
				playing = channel:GetAttribute("AudioLabReportPlaying") == true,
				position = channel:GetAttribute("AudioLabReportPos"),
				age = now - reportAt,
			} or nil,
		})
	end
	return list
end

-- Client: ask the server to control audio. `target` is an instance with AudioLabClientControl = true, or the NAME of the
-- player's own channel. The server only obeys instances it set up (and checks everything the request contains).
-- action: "play" (own channel; arg = { Midi?, SoundFont?, Clip?, File?, Loop?, Volume?, Speed?, StartTime? }) |
-- "pause" | "resume" | "toggle" | "seek" | "stop" | "setSpeed" | "setVolume" | "restart"; arg: a number for seek / setSpeed / setVolume.
local remoteCache = {}
local function remote(name)
	local r = remoteCache[name]
	if r and r.Parent then
		return r
	end
	local folder = game:GetService("ReplicatedStorage"):WaitForChild("AudioLabSyncRemotes", 5)
	r = folder and folder:WaitForChild(name, 5)
	remoteCache[name] = r
	return r
end

function Sync.request(target, action, arg)
	assert(RunService:IsClient(), "AudioLab.Sync.request runs on the client")
	local r = remote("SyncControl")
	if r then
		r:FireServer(target, action, arg)
	end
end

-- Client (called by the player code every 2 s for channels): tell the server what is really playing.
function Sync.report(instance, playing, position)
	assert(RunService:IsClient(), "AudioLab.Sync.report runs on the client")
	local r = remote("SyncReport")
	if r then
		r:FireServer(instance, playing == true, position or 0)
	end
end

return Sync
