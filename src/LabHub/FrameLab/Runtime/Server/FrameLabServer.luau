-- Started by FrameLab:init() on the server, the same way AudioLabServer works for sound. The
-- server never decodes video: it keeps the playback STATE of synced screens (attributes, see FrameLab.Sync) and every
-- client plays that state itself on the server's playhead.
--
-- 1. Auto-start: an instance tagged "FrameLab" with FrameLabSynced = true and FrameLabAutoPlay = true (set in Studio with
--    FrameLabVideo, FrameLabLoop, FrameLabStartTime, FrameLabSpeed...) starts when the server starts, or when it is
--    added later. Players who join afterwards start in the right place.
-- 2. Client control: ReplicatedStorage.FrameLabSyncRemotes.SyncControl lets a client play / pause / resume / seek / ...
--    a screen it owns (FrameLabOwner = its UserId, e.g. its TV) or one with FrameLabClientControl = true
--    (FrameLab.Sync.request on the client). Requests are validated and rate-limited, and
--    `Sync.authorize(player, target, action, arg)` (set by any server script) can veto them.
-- Other server scripts drive video directly: require(ReplicatedStorage.LabHub.FrameLab.Sync).play(part, { Video = ... }).
return function(FrameLab)
	local CollectionService = game:GetService("CollectionService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Players = game:GetService("Players")
	local root = script:FindFirstAncestor("FrameLab")
	local Sync = require(root.Sync)
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))

	-- 1. auto-start
	local function autoStart(instance)
		if instance:GetAttribute("FrameLabSynced") ~= true or instance:GetAttribute("FrameLabAutoPlay") ~= true then
			return
		end
		if Sync.state(instance) ~= nil then
			return
		end
		Sync.play(instance, {
			StartTime = instance:GetAttribute("FrameLabStartTime") or 0,
			Speed = instance:GetAttribute("FrameLabSpeed") or 1,
			Delay = 0,
		})
	end
	CollectionService:GetInstanceAddedSignal(Sync.Tag):Connect(autoStart)
	for _, instance in ipairs(CollectionService:GetTagged(Sync.Tag)) do
		task.spawn(autoStart, instance)
	end

	-- 2. client requests
	local remotes = ReplicatedStorage:FindFirstChild("FrameLabSyncRemotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "FrameLabSyncRemotes"
		remotes.Parent = ReplicatedStorage
	end
	local control = remotes:FindFirstChild("SyncControl")
	if not control then
		control = Instance.new("RemoteEvent")
		control.Name = "SyncControl"
		control.Parent = remotes
	end

	local recent = {}
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
	Players.PlayerRemoving:Connect(function(player)
		recent[player] = nil
	end)

	local function sanitizePlay(arg)
		if type(arg) ~= "table" then
			return nil
		end
		local v = arg.Video
		if type(v) ~= "string" or #v == 0 or #v > 200 or string.find(v, "..", 1, true) or not Sync.videoEntry(v) then
			return nil
		end
		local o = { Video = v }
		if type(arg.Loop) == "boolean" then
			o.Loop = arg.Loop
		end
		if type(arg.Sound) == "boolean" then
			o.Sound = arg.Sound
		end
		local function num(key, lo, hi)
			local n = arg[key]
			if type(n) == "number" and n == n then
				return math.clamp(n, lo, hi)
			end
			return nil
		end
		o.Speed, o.StartTime = num("Speed", 0.25, 4), num("StartTime", 0, 36000)
		return o
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
	}
	local NEEDS_NUMBER = { seek = true, setSpeed = true }

	control.OnServerEvent:Connect(function(player, target, action, arg)
		if type(action) ~= "string" or not allowed(player, Config.ControlPerSecond or 8) then
			return
		end
		if typeof(target) ~= "Instance" or not target:IsDescendantOf(workspace) then
			return
		end
		local owner = target:GetAttribute("FrameLabOwner")
		local mayControl = (owner ~= nil and owner == player.UserId) or target:GetAttribute("FrameLabClientControl") == true
		if not mayControl then
			return
		end
		if Sync.authorize then
			local ok, verdict = pcall(Sync.authorize, player, target, action, arg)
			if not ok or verdict == false then
				return
			end
		end
		if action == "play" then
			local opts = sanitizePlay(arg)
			if opts then
				Sync.play(target, opts)
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
		handler(target, arg)
	end)
end
