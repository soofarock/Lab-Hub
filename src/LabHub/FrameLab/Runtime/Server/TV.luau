-- Started by FrameLab.init() on the server: placed TVs. Clicking with the TV tool drops the TV (it leaves the hand,
-- lands in front of the player and grows) and makes it that player's synced FrameLab screen (FrameLab.Sync, owner =
-- the player): its owner picks what it plays through FrameLabServer, everyone sees it through FrameLabClient. Picking
-- it up gives the tool back.
return function(FrameLab)
	local Players = game:GetService("Players")
	local root = script:FindFirstAncestor("FrameLab")
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	local Sync = require(root.Sync)
	-- the TV that gets set down: built once from LabHub.Blueprints.tv (Instancer), then cloned
	local template
	local function tvTemplate()
		if not template then
			local hub = root.Parent
			template = require(hub.Instancer).build(require(hub.Blueprints).tv)
		end
		return template
	end
	task.spawn(tvTemplate)
	while not FrameLab.Server do
		task.wait()
	end
	local server = FrameLab.Server
	local remote = server.remotes.TV

	local folder = workspace:FindFirstChild("FrameLabTVs")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "FrameLabTVs"
		folder.Parent = workspace
	end

	local function tvsOf(player)
		local list = {}
		for _, tv in ipairs(folder:GetChildren()) do
			if tv:GetAttribute("FrameLabOwner") == player.UserId then
				table.insert(list, tv)
			end
		end
		return list
	end

	-- the TV tool goes here while its TV stands in the world (picking the TV up gives it back)
	local ServerStorage = game:GetService("ServerStorage")
	local RunService = game:GetService("RunService")
	local TweenService = game:GetService("TweenService")
	local held = ServerStorage:FindFirstChild("FrameLabHeldTools")
	if not held then
		held = Instance.new("Folder")
		held.Name = "FrameLabHeldTools"
		held.Parent = ServerStorage
	end
	local function heldToolOf(player)
		for _, t in ipairs(held:GetChildren()) do
			if t:GetAttribute("HeldBy") == player.UserId then
				return t
			end
		end
	end

	-- the screen takes the shape of what it plays (a 9:16 short gets a tall screen, 21:9 a wide one), as big as fits
	-- inside the TV's own screen, centred; the black backing fills the rest (letterbox / pillarbox bars)
	local function reshape(tv)
		local screen = tv:FindFirstChild("Screen")
		local baseSize = screen and screen:GetAttribute("BaseSize")
		local baseOffset = screen and screen:GetAttribute("BaseOffset")
		if typeof(baseSize) ~= "Vector3" or typeof(baseOffset) ~= "CFrame" then
			return
		end
		local w, h = baseSize.X, baseSize.Y
		local name = tv:GetAttribute("FrameLabVideo")
		local entry = tv:GetAttribute("FrameLabState") ~= "stopped" and name and Sync.videoEntry(name)
		local vw = entry and entry:GetAttribute("Width")
		local vh = entry and entry:GetAttribute("Height")
		if vw and vh and vw > 0 and vh > 0 then
			local aspect = vw / vh
			if aspect >= w / h then
				h = w / aspect
			else
				w = h * aspect
			end
		end
		local key = ("%.3f,%.3f"):format(w, h)
		if screen:GetAttribute("ShapeKey") == key then
			return
		end
		screen:SetAttribute("ShapeKey", key)
		local goal = tv:GetPivot() * baseOffset
		TweenService:Create(screen, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(w, h, baseSize.Z), CFrame = goal }):Play()
	end

	-- like the classic gear that drops itself: the TV leaves the hand where it is, lands in front of the player
	-- facing them, and grows to full size
	local function drop(player)
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local tool = char and char:FindFirstChildOfClass("Tool")
		if not hrp or not hum or hum.Health <= 0 or not tool or not tool:GetAttribute("FrameLabTV") then
			return
		end
		local handle = tool:FindFirstChild("Handle")
		local from = handle and handle.CFrame or hrp.CFrame
		-- the spot: ahead of the player (further for a bigger TV), on whatever is below it
		local scale = Config.TVScale or 3
		local size = tvTemplate().Body.Size * scale
		local ahead = hrp.Position + (hrp.CFrame.LookVector * Vector3.new(1, 0, 1)).Unit * (size.Z / 2 + 2.5 + size.Y / 2) -- far enough back to see the screen
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char, folder }
		local hit = workspace:Raycast(ahead + Vector3.new(0, 4, 0), Vector3.new(0, -40, 0), params)
		local ground = hit and hit.Position or (ahead - Vector3.new(0, hum.HipHeight + hrp.Size.Y / 2, 0))
		local face = (hrp.Position - ground) * Vector3.new(1, 0, 1)
		if face.Magnitude < 0.1 then
			face = -hrp.CFrame.LookVector
		end
		local to = CFrame.lookAt(ground, ground + face.Unit)
		for _, old in ipairs(tvsOf(player)) do
			Sync.stop(old) -- picture and sound
			old:Destroy()
		end
		tool:SetAttribute("HeldBy", player.UserId)
		tool.Parent = held
		local tv = tvTemplate():Clone()
		Sync.setOwner(tv, player) -- the owner controls it through FrameLab.Sync (FrameLabServer checks)
		tv:SetAttribute("OwnerName", player.DisplayName)
		-- its sound is heard at full volume out to the TV's own size (then fades: AudioLab's Range), not Roblox's
		-- default falloff, which made a big TV quiet from where you watch it
		tv:SetAttribute("AudioLabRange", math.max(size.X, size.Y))
		tv.Name = player.Name .. "_TV"
		-- the TV's pivot is its bottom centre; start where the handle was
		tv:PivotTo(from)
		tv.Parent = folder
		local body = tv:FindFirstChild("Body")
		local puff = body and body:FindFirstChild("Puff")
		local t, T = 0, 0.6
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			if not tv.Parent then
				conn:Disconnect()
				return
			end
			t = math.min(T, t + dt)
			local a = t / T
			local e = 1 - (1 - a) * (1 - a) -- ease out
			tv:ScaleTo(1 + (scale - 1) * e)
			tv:PivotTo(from:Lerp(to, e))
			if t >= T then
				conn:Disconnect()
				-- ScaleTo scales the prompt's reach too: set it once the TV is full size, reachable from where you stand
				local prompt = body and body:FindFirstChild("Change")
				if prompt then
					prompt.MaxActivationDistance = math.max(12, size.Z / 2 + size.Y / 2 + 10)
				end
				local screen = tv:FindFirstChild("Screen")
				if screen then
					screen:SetAttribute("BaseSize", screen.Size)
					screen:SetAttribute("BaseOffset", tv:GetPivot():ToObjectSpace(screen.CFrame))
					tv:GetAttributeChangedSignal("FrameLabSeq"):Connect(function()
						reshape(tv)
					end)
					reshape(tv)
				end
				if puff then
					puff:Emit(25)
				end
			end
		end)
	end

	local last = {}
	remote.OnServerEvent:Connect(function(player, action, a)
		local now = os.clock()
		if last[player] and now - last[player] < 0.3 then
			return
		end
		last[player] = now
		if action == "drop" then
			drop(player)
		elseif action == "remove" then
			-- pick the TV up: the tool comes back (unless they got a new one when they respawned)
			if typeof(a) ~= "Instance" or a.Parent ~= folder or a:GetAttribute("FrameLabOwner") ~= player.UserId then
				return
			end
			Sync.stop(a) -- picture and sound
			a:Destroy()
			local tool = heldToolOf(player)
			if tool then
				local backpack = player:FindFirstChildOfClass("Backpack")
				local has = false
				for _, place in ipairs({ backpack, player.Character }) do
					for _, t in ipairs(place and place:GetChildren() or {}) do
						if t:IsA("Tool") and t:GetAttribute("FrameLabTV") then
							has = true
						end
					end
				end
				if has or not backpack then
					tool:Destroy()
				else
					tool:SetAttribute("HeldBy", nil)
					tool.Parent = backpack
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		last[player] = nil
		for _, tv in ipairs(tvsOf(player)) do
			Sync.stop(tv)
			tv:Destroy()
		end
		local tool = heldToolOf(player)
		if tool then
			tool:Destroy()
		end
	end)
end
