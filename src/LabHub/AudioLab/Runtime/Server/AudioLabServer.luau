-- Started by AudioLab:init() on the server, run once in its own thread.
return function(AudioLab)
-- AudioLab server. The server never synthesises audio: it keeps the playback STATE of synced audio (a few attributes on
-- each instance, see AudioLab.Sync) and every client plays that state locally and follows the server's playhead.
--
-- 1. Auto-start: an instance tagged "AudioLab" with AudioLabSynced = true and AudioLabAutoPlay = true (set in Studio with
--    AudioLabMidi / AudioLabSoundFont / AudioLabClip, AudioLabLoop, AudioLabVolume...) is started here when the server
--    starts, or when it is added later. Players who join afterwards start in the right place.
-- 2. Client control: ReplicatedStorage.AudioLabSyncRemotes.SyncControl lets a client pause / resume / seek / ... an instance
--    that has AudioLabClientControl = true (AudioLab.Sync.request on the client). Requests are validated and rate-limited.
-- Other server scripts drive audio directly: require(ReplicatedStorage.LabHub.AudioLab.Sync).play(part, { ... }).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sync = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("AudioLab"):WaitForChild("Sync"))

local TAG = Sync.Tag
local MAX_REQUESTS_PER_SECOND = 8

-- 1. auto-start ------------------------------------------------------------------------------------------------------
local function autoStart(instance)
	if instance:GetAttribute("AudioLabSynced") ~= true or instance:GetAttribute("AudioLabAutoPlay") ~= true then
		return
	end
	if Sync.state(instance) ~= nil then
		return -- already has a playback state
	end
	Sync.play(instance, {
		StartTime = instance:GetAttribute("AudioLabStartTime") or 0,
		Speed = instance:GetAttribute("AudioLabSpeed") or 1,
		Delay = 0, -- the server is just starting: nobody is waiting for it
	})
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(autoStart)
for _, instance in ipairs(CollectionService:GetTagged(TAG)) do
	task.spawn(autoStart, instance)
end

-- 2. client requests -------------------------------------------------------------------------------------------------
-- ReplicatedStorage.AudioLabSyncRemotes.SyncControl: a client asks to change audio (AudioLab.Sync.request); the server decides.
-- A player may change their OWN channels (Folders in their PlayerGui made by Sync.channel) unless the server locked them
-- (Sync.setClientControl(channel, false)); world audio only if it has AudioLabClientControl = true. Every request is
-- validated and rate-limited, and `Sync.authorize(player, target, action, arg)` (set by any server script) can veto it.
-- SyncReport: clients say what they are really playing (stored on the channel, Sync.listening(player).reported).
-- (its own folder: ReplicatedStorage.AudioLabRemotes belongs to the Studio-only import server)
local remotes = ReplicatedStorage:FindFirstChild("AudioLabSyncRemotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "AudioLabSyncRemotes"
	remotes.Parent = ReplicatedStorage
end
local function remoteEvent(name)
	local r = remotes:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = remotes
	end
	return r
end
local control = remoteEvent("SyncControl")
local report = remoteEvent("SyncReport")

local recent = {} -- [player] = { windowStart, count }
local function allowed(player, limit)
	local now = os.clock()
	local r = recent[player]
	if not r or now - r[1] >= 1 then
		r = { now, 0 }
		recent[player] = r
	end
	r[2] += 1
	return r[2] <= limit
end
game:GetService("Players").PlayerRemoving:Connect(function(player)
	recent[player] = nil
end)

local AudioLabFolder = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("AudioLab")
local function exists(container, path) -- is there baked / imported data under Data.<container> at path "a/b/c"?
	local node = AudioLabFolder:FindFirstChild("Data")
	node = node and node:FindFirstChild(container)
	for segment in string.gmatch(path, "[^/]+") do
		node = node and node:FindFirstChild(segment)
	end
	return node ~= nil
end

-- A client's "play" request, reduced to what the server accepts: exactly one source that exists, clamped numbers.
local function sanitizePlay(arg)
	if type(arg) ~= "table" then
		return nil
	end
	local o = {}
	local function str(key)
		local v = arg[key]
		if type(v) == "string" and #v > 0 and #v <= 200 and not string.find(v, "..", 1, true) then
			return v
		end
		return nil
	end
	o.Midi, o.SoundFont, o.Clip, o.File = str("Midi"), str("SoundFont"), str("Clip"), str("File")
	local sources = (o.Midi and 1 or 0) + (o.Clip and 1 or 0) + (o.File and 1 or 0)
	if sources ~= 1 then
		return nil
	end
	if o.Midi and not exists("Files", o.Midi) then return nil end
	if o.SoundFont and not (exists("Banks", o.SoundFont) or exists("Files", o.SoundFont)) then return nil end
	if o.Clip and not (exists("Clips", (string.gsub(o.Clip, "%.%w+$", ""))) or exists("Files", o.Clip)) then return nil end
	if o.File and not exists("Files", o.File) then return nil end
	if not o.Midi then
		o.SoundFont = nil
	end
	if type(arg.Loop) == "boolean" then
		o.Loop = arg.Loop
	end
	local function num(key, lo, hi)
		local v = arg[key]
		if type(v) == "number" and v == v then
			return math.clamp(v, lo, hi)
		end
		return nil
	end
	o.Volume, o.Speed, o.StartTime = num("Volume", 0, 1), num("Speed", 0.25, 4), num("StartTime", 0, 36000)
	o.Spatial = false
	return o
end

local function ownChannel(player, instance)
	return typeof(instance) == "Instance" and instance:GetAttribute("AudioLabChannel") ~= nil
		and instance:GetAttribute("AudioLabOwner") == player.UserId and instance:IsDescendantOf(player)
end

local ACTIONS = {
	pause = function(inst) Sync.pause(inst) end,
	resume = function(inst) Sync.resume(inst) end,
	toggle = function(inst)
		local st = Sync.state(inst)
		if st and st.state == "playing" then
			Sync.pause(inst)
		else
			Sync.resume(inst)
		end
	end,
	stop = function(inst) Sync.stop(inst) end,
	restart = function(inst)
		Sync.seek(inst, 0)
		local st = Sync.state(inst)
		if st and st.state ~= "playing" then
			Sync.resume(inst)
		end
	end,
	seek = function(inst, n) Sync.seek(inst, math.max(n, 0)) end,
	setSpeed = function(inst, n) Sync.setSpeed(inst, math.clamp(n, 0.25, 4)) end,
	setVolume = function(inst, n) Sync.setVolume(inst, math.clamp(n, 0, 1)) end,
}
local NEEDS_NUMBER = { seek = true, setSpeed = true, setVolume = true }

control.OnServerEvent:Connect(function(player, target, action, arg)
	if type(action) ~= "string" or not allowed(player, 8) then
		return
	end
	local instance
	if type(target) == "string" then
		if #target > 24 or not string.match(target, "^[%w_]+$") then
			return
		end
		instance = Sync.getChannel(player, target) -- other actions need an existing channel; "play" creates it below
	elseif typeof(target) == "Instance" then
		instance = target
	else
		return
	end
	local own = instance ~= nil and ownChannel(player, instance)
	if instance and own then
		if instance:GetAttribute("AudioLabClientControl") == false then
			return -- the server locked this channel
		end
	elseif instance then
		-- world audio: set up by the server and opted in
		if action == "play" or instance:GetAttribute("AudioLabSynced") ~= true
			or instance:GetAttribute("AudioLabClientControl") ~= true or Sync.state(instance) == nil then
			return
		end
	elseif not (action == "play" and type(target) == "string") then
		return
	end
	if Sync.authorize then
		local ok, verdict = pcall(Sync.authorize, player, instance or target, action, arg)
		if not ok or verdict == false then
			return
		end
	end
	if action == "play" then
		local opts = sanitizePlay(arg)
		if not opts then
			return
		end
		local channel = instance or Sync.channel(player, target)
		if channel then
			Sync.play(channel, opts)
		end
		return
	end
	local handler = ACTIONS[action]
	if not handler then
		return
	end
	if NEEDS_NUMBER[action] and (type(arg) ~= "number" or arg ~= arg or math.abs(arg) == math.huge) then
		return
	end
	handler(instance, arg)
end)

report.OnServerEvent:Connect(function(player, instance, playing, position)
	if not ownChannel(player, instance) or type(playing) ~= "boolean" or type(position) ~= "number" or position ~= position
		or not allowed(player, 16) then
		return
	end
	instance:SetAttribute("AudioLabReportPlaying", playing)
	instance:SetAttribute("AudioLabReportPos", math.clamp(position, 0, 1e6))
	instance:SetAttribute("AudioLabReportAt", workspace:GetServerTimeNow())
end)

end
