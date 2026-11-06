-- Server-authoritative video playback for FrameLab, the same way AudioLab.Sync does sound. The server never decodes a
-- video: it writes a handful of attributes on the screen's instance (a Part, or a Model with a part named "Screen"),
-- and every client plays the video there itself (Runtime/Client/FrameLabClient), on the server's playhead. Attributes
-- replicate to everyone and stay on the instance, so a player who joins later starts in the right place.
--
-- Server:
--   local Sync = require(game.ReplicatedStorage.LabHub.FrameLab.Sync)
--   Sync.play(screen, { Video = "intro", Loop = true })     -- also StartTime, Speed, Delay, Face, Sound (default true)
--   Sync.pause(screen); Sync.resume(screen); Sync.seek(screen, 12.5); Sync.stop(screen); Sync.setSpeed(screen, 1.5)
--   Sync.getTime(screen, { duration =, loop = })             -- the server's playhead in seconds
--   Sync.setClientControl(screen, true)                      -- clients may pause / seek / ... it (default: only its owner)
--   Sync.setOwner(screen, player)                            -- that player may control it (TVs)
--   Sync.authorize = function(player, target, action, arg) return true end   -- optional: veto client requests
-- Client: Sync.request(screen, "play", { Video = "intro", Loop = true }) or "pause" | "resume" | "toggle" | "stop" |
--   "restart" | "seek" | "setSpeed", n. The server checks it (Runtime/Server/FrameLabServer).
-- In Studio: tag an instance "FrameLab", set FrameLabSynced = true, FrameLabAutoPlay = true, FrameLabVideo = "<name>"
--   (and FrameLabLoop, FrameLabStartTime) and the server starts it.
-- A video imported with its sound (attribute Audio = "clip:<name>") plays that sound through AudioLab.Sync on the same
-- instance, so picture and sound share one playhead.
-- State attributes: FrameLabState ("playing" | "paused" | "stopped"), FrameLabPos, FrameLabAt, FrameLabSpeed, FrameLabSeq.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Sync = {}
Sync.Tag = "FrameLab"
Sync.Delay = 0.5 -- seconds between a server command and the start (time for clients to fetch the first chunk)

local CONFIG = { Video = "FrameLabVideo", Loop = "FrameLabLoop", Face = "FrameLabFace" }

local function serverNow()
	return workspace:GetServerTimeNow()
end

function Sync.state(instance)
	local state = instance:GetAttribute("FrameLabState")
	if state == nil then
		return nil
	end
	return {
		state = state,
		pos = instance:GetAttribute("FrameLabPos") or 0,
		at = instance:GetAttribute("FrameLabAt") or 0,
		speed = instance:GetAttribute("FrameLabSpeed") or 1,
		seq = instance:GetAttribute("FrameLabSeq") or 0,
	}
end

function Sync.rawPosition(st, now)
	if st.state == "playing" then
		return st.pos + (now - st.at) * st.speed
	end
	return st.pos
end

-- where the video should be at server time `now` (seconds, wrapped into the loop), and whether a one-shot finished
function Sync.target(st, now, info)
	local p = Sync.rawPosition(st, now)
	if p < 0 then
		return 0, false
	end
	local d = info.duration or 0
	if info.loop and d > 0 then
		return p % d, false
	end
	if d > 0 and p >= d then
		return d, true
	end
	return p, false
end

function Sync.getTime(instance, info)
	local st = Sync.state(instance)
	if not st then
		return 0
	end
	local now = serverNow()
	if info then
		return (Sync.target(st, now, info))
	end
	return math.max(0, Sync.rawPosition(st, now))
end

local function serverOnly()
	assert(RunService:IsServer(), "FrameLab.Sync commands run on the server")
end

-- AudioLab sound for a video imported with one (best effort: AudioLab may not be there)
local AudioSync
local function audio()
	if AudioSync == nil then
		local rs = game:GetService("ReplicatedStorage")
		local al = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
		local m = al and al:FindFirstChild("Sync")
		local ok, mod = pcall(function()
			return m and require(m)
		end)
		AudioSync = (ok and mod) or false
	end
	return AudioSync or nil
end
local function soundOf(instance)
	if instance:GetAttribute("FrameLabSound") == false then
		return nil
	end
	local a = instance:GetAttribute("FrameLabAudio")
	if type(a) == "string" and string.sub(a, 1, 5) == "clip:" then
		return string.sub(a, 6)
	end
	return nil
end
-- runs fn(AudioLab.Sync) when this screen has (or had) sound: a screen that switched to a silent video still has to
-- stop the old video's sound
local function audioDo(instance, fn)
	local A = audio()
	if A and (instance:GetAttribute("FrameLabAudio") or instance:GetAttribute("AudioLabState") ~= nil) then
		pcall(fn, A)
	end
end

-- The sound follows the picture's playhead exactly: AudioLab's state is written with the same position, start time and
-- speed. (Calling AudioLab.Sync.pause / resume / seek let it pick its own start delay, 0.3 s against the picture's
-- 0.5 s, so every pause / resume or seek moved the sound 0.2 s further from the picture.)
local function mirrorSound(instance)
	if instance:GetAttribute("AudioLabState") == nil or not soundOf(instance) then
		return -- (no sound, or a silent video: its old sound stays stopped)
	end
	instance:SetAttribute("AudioLabPos", instance:GetAttribute("FrameLabPos"))
	instance:SetAttribute("AudioLabAt", instance:GetAttribute("FrameLabAt"))
	instance:SetAttribute("AudioLabSpeed", instance:GetAttribute("FrameLabSpeed"))
	instance:SetAttribute("AudioLabState", instance:GetAttribute("FrameLabState"))
	instance:SetAttribute("AudioLabSeq", (instance:GetAttribute("AudioLabSeq") or 0) + 1) -- last: clients react to it
end

local function write(instance, state, pos, at, speed)
	instance:SetAttribute("FrameLabPos", pos)
	instance:SetAttribute("FrameLabAt", at)
	instance:SetAttribute("FrameLabSpeed", speed)
	instance:SetAttribute("FrameLabState", state)
	instance:SetAttribute("FrameLabSeq", (instance:GetAttribute("FrameLabSeq") or 0) + 1) -- last: clients react to it
end

-- the video library entry (server: both the replicated and the ServerStorage library)
function Sync.videoEntry(name)
	if Sync.extraEntry then -- in-game imports (set by the server's Media runtime)
		local e = Sync.extraEntry(name)
		if e then
			return e
		end
	end
	local root = script.Parent
	local Store = require(root.Tools.Store)
	local roots = { root.Data.Videos }
	if RunService:IsServer() then
		local data = game:GetService("ServerStorage"):FindFirstChild("FrameLabData")
		if data and data:FindFirstChild("Videos") then
			table.insert(roots, data.Videos)
		end
	end
	for _, r in ipairs(roots) do
		local e = Store.entry(r, name)
		if e then
			return e
		end
	end
	return nil
end

function Sync.play(instance, opts)
	serverOnly()
	opts = opts or {}
	for key, attr in pairs(CONFIG) do
		if opts[key] ~= nil then
			instance:SetAttribute(attr, opts[key])
		end
	end
	local name = instance:GetAttribute("FrameLabVideo")
	local entry = name and Sync.videoEntry(name)
	if not entry then
		warn("[FrameLab] Sync.play: no video named " .. tostring(name))
		return
	end
	instance:SetAttribute("FrameLabDuration", entry:GetAttribute("Seconds") or 0)
	instance:SetAttribute("FrameLabAudio", entry:GetAttribute("Audio"))
	instance:SetAttribute("FrameLabSynced", true)
	if opts.Sound ~= nil then
		instance:SetAttribute("FrameLabSound", opts.Sound)
	end
	if not CollectionService:HasTag(instance, Sync.Tag) then
		CollectionService:AddTag(instance, Sync.Tag)
	end
	local delay = opts.Delay or Sync.Delay
	local speed = opts.Speed or instance:GetAttribute("FrameLabSpeed") or 1
	local start = opts.StartTime or 0
	local clip = soundOf(instance)
	-- an imported video's sound downloads to each client when it first plays (FrameLab.Net.clip, a few seconds): the
	-- start waits for it (Sync.soundLoadDelay, set by the server's Media runtime), so picture and sound begin together
	-- (the screen shows its first picture meanwhile)
	if clip and opts.Delay == nil and Sync.soundLoadDelay then
		local ok, d = pcall(Sync.soundLoadDelay, clip)
		if ok and type(d) == "number" then
			delay = math.max(delay, d)
		end
	end
	write(instance, "playing", start, serverNow() + delay, speed)
	-- a video's sound starts on the picture's clock: no start-up lead (AudioLab's default 0.05 s, on top of its own
	-- block-ahead scheduling, put the sound ~0.1 s before the picture), unless the instance sets its own
	if instance:GetAttribute("AudioLabSyncLead") == nil then
		instance:SetAttribute("AudioLabSyncLead", 0)
	end
	audioDo(instance, function(A)
		if clip then
			-- the sound loops on the picture's length (an imported sound is often a few ms shorter or longer than its
			-- video: looping on its own length it crept ~0.05 s further off every loop)
			local len = instance:GetAttribute("FrameLabDuration")
			A.play(instance, { Clip = clip, Loop = instance:GetAttribute("FrameLabLoop") == true, StartTime = start, Speed = speed, Delay = delay, Spatial = true,
				LoopLength = (type(len) == "number" and len > 0) and len or nil })
			mirrorSound(instance) -- the very same start time as the picture
		elseif A.state(instance) then
			A.stop(instance) -- the new video is silent: the old one's sound stops
		end
	end)
end

function Sync.pause(instance)
	serverOnly()
	local st = Sync.state(instance)
	if not st or st.state ~= "playing" then
		return
	end
	local now = serverNow()
	write(instance, "paused", math.max(0, Sync.rawPosition(st, now)), now, st.speed)
	mirrorSound(instance)
end

function Sync.resume(instance)
	serverOnly()
	local st = Sync.state(instance)
	if not st or st.state == "playing" then
		return
	end
	local pos = st.state == "stopped" and 0 or st.pos
	write(instance, "playing", pos, serverNow() + Sync.Delay, st.speed)
	mirrorSound(instance)
end

function Sync.stop(instance)
	serverOnly()
	if not Sync.state(instance) then
		return
	end
	write(instance, "stopped", 0, serverNow(), instance:GetAttribute("FrameLabSpeed") or 1)
	audioDo(instance, function(A)
		A.stop(instance)
	end)
end

function Sync.seek(instance, seconds)
	serverOnly()
	local st = Sync.state(instance)
	if not st then
		return
	end
	local now = serverNow()
	write(instance, st.state == "stopped" and "paused" or st.state, math.max(0, seconds), now, st.speed)
	mirrorSound(instance)
end

function Sync.setSpeed(instance, speed)
	serverOnly()
	local st = Sync.state(instance)
	if not st then
		instance:SetAttribute("FrameLabSpeed", speed)
		return
	end
	local now = serverNow()
	write(instance, st.state, math.max(0, Sync.rawPosition(st, now)), now, speed)
	mirrorSound(instance)
end

function Sync.setClientControl(instance, allowed)
	instance:SetAttribute("FrameLabClientControl", allowed == true)
end

function Sync.setOwner(instance, player)
	instance:SetAttribute("FrameLabOwner", player and player.UserId or nil)
end

-- client: ask the server to change a screen's video
function Sync.request(target, action, arg)
	assert(RunService:IsClient(), "Sync.request is for clients")
	local remotes = game:GetService("ReplicatedStorage"):WaitForChild("FrameLabSyncRemotes", 10)
	if remotes then
		remotes:WaitForChild("SyncControl"):FireServer(target, action, arg)
	end
end

return Sync
