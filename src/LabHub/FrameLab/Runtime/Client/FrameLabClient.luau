-- Started by FrameLab:init() on a client, the same way AudioLabClient plays synced sound: plays every synced screen
-- (an instance tagged "FrameLab" with FrameLabSynced = true: a Part, or a Model with a part named "Screen") on a
-- SurfaceGui, on the server's playhead (FrameLab.Sync). The video's bytes stream from the server while it plays.
-- Only the nearest screens within view distance play (FrameLab attributes ViewDistance / MaxPlaying).
return function(FrameLab)
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local CollectionService = game:GetService("CollectionService")
	local root = script:FindFirstAncestor("FrameLab")
	local Net = require(root.Tools.Net)
	local Sync = require(root.Sync)
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	local player = Players.LocalPlayer
	if not player then
		return
	end
	-- the sound of an in-game import stays on the server until a TV here plays it (AudioLab asks for clips it hasn't got)
	pcall(function()
		local al = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
		if al then
			require(al.Tools.Assets).addSource(Net.clip)
		end
	end)
	local playerGui = player:WaitForChild("PlayerGui")

	local function newHolder()
		local h = Instance.new("Folder")
		h.Name = "FrameLabScreens"
		h.Parent = playerGui
		return h
	end
	local holder = newHolder()

	local function screenOf(inst)
		if inst:IsA("BasePart") then
			return inst
		end
		local s = inst:FindFirstChild("Screen", true)
		return s and s:IsA("BasePart") and s or nil
	end

	local playing = {} -- instance -> { gui, video, stream, key }

	local function stopTV(tv)
		local p = playing[tv]
		if not p then
			return
		end
		playing[tv] = nil
		if p.stream then
			p.stream.close()
		end
		if p.video then
			pcall(function()
				p.video:destroy()
			end)
		end
		if p.gui then
			p.gui:Destroy()
		end
	end

	local function startTV(tv)
		local name = tv:GetAttribute("FrameLabVideo")
		local screen = screenOf(tv)
		if not screen or not name or name == "" then
			return
		end
		local key = name
		local p = { key = key }
		playing[tv] = p
		local gui = Instance.new("SurfaceGui")
		gui.Name = tv.Name
		gui.Adornee = screen
		gui.Face = Enum.NormalId[tv:GetAttribute("FrameLabFace") or "Front"] or Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		-- about 1000 pixels across whatever the screen's size (a huge TV stays sharp, a small one stays cheap)
		gui.PixelsPerStud = math.clamp(math.floor(1000 / math.max(screen.Size.X, screen.Size.Y, 0.1)), 4, 200)
		gui.LightInfluence = 0
		gui.ClipsDescendants = true
		gui.ResetOnSpawn = false
		local bg = Instance.new("Frame")
		bg.Size = UDim2.fromScale(1, 1)
		bg.BackgroundColor3 = Color3.new(0, 0, 0)
		bg.BorderSizePixel = 0
		bg.Parent = gui
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.fromRGB(150, 160, 175)
		label.Font = Enum.Font.Code
		label.TextScaled = true
		label.Text = "loading..."
		label.ZIndex = 5
		label.Parent = bg
		local sizer = Instance.new("UITextSizeConstraint")
		sizer.MaxTextSize = 24
		sizer.Parent = label
		gui.Parent = holder
		p.gui = gui
		local stream = Net.openVideo(name)
		p.stream = stream
		task.spawn(function()
			while not stream.info and not stream.failed do
				task.wait(0.05)
			end
			if playing[tv] ~= p then
				return
			end
			if stream.failed then
				label.Text = "can't play " .. name
				return
			end
			local seconds = tv:GetAttribute("FrameLabDuration") or stream.info.Seconds or 1
			if seconds <= 0 then
				seconds = stream.info.Seconds or 1
			end
			local function clock()
				local st = Sync.state(tv)
				if not st then
					return 0
				end
				return (Sync.target(st, workspace:GetServerTimeNow(), { duration = seconds, loop = tv:GetAttribute("FrameLabLoop") == true }))
			end
			stream.follow(clock)
			if not stream.waitFor(clock(), 30) or playing[tv] ~= p then
				if playing[tv] == p then
					label.Text = "can't play " .. name
				end
				return
			end
			local ok, video = pcall(FrameLab.Player.new, stream.bytes, bg, { Clock = clock, Loop = tv:GetAttribute("FrameLabLoop") == true, Ready = stream.ready })
			if not ok then
				label.Text = "can't play " .. name
				warn("[FrameLab TV] " .. tostring(video))
				return
			end
			p.video = video
			label.Visible = false
			video:play()
			-- the player's state on the SurfaceGui (attributes, every half second), to see a screen that looks wrong:
			-- ShownTime (the frame on screen), TargetTime (where it should be), SoundTime (AudioLab's playhead for the
			-- same screen), DecodeMs, Behind (rows still to draw), HalfRate, Tolerance, Strips
			local Attach
			pcall(function()
				Attach = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab").Synth.Attach)
			end)
			local fpsNow = 0
			local fpsConn = RunService.Heartbeat:Connect(function(dt)
				fpsNow = fpsNow * 0.95 + (1 / math.max(dt, 1e-3)) * 0.05
			end)
			-- (only with Config.Debug: checked every half second, so it can be switched on while playing)
			local shown = false
			while playing[tv] == p and gui.Parent do
				if not Config.Debug then
					if shown then
						shown = false
						for k in pairs(gui:GetAttributes()) do
							gui:SetAttribute(k, nil)
						end
					end
					task.wait(0.5)
					continue
				end
				shown = true
				pcall(function()
					local st, r = video.Stats, video.reader
					gui:SetAttribute("ShownTime", r.frame / video.fps)
					gui:SetAttribute("TargetTime", clock())
					local h = Attach and Attach.get(tv)
					gui:SetAttribute("SoundTime", h and h.player and h.player:getTime() or nil)
					gui:SetAttribute("DecodeMs", st.decodeMs)
					gui:SetAttribute("Behind", st.behind)
					gui:SetAttribute("HalfRate", st.halfRate == true)
					gui:SetAttribute("Tolerance", st.tolerance)
					gui:SetAttribute("Strips", st.strips)
					local objects, modes = video.canvas:objects()
					gui:SetAttribute("Objects", objects)
					gui:SetAttribute("Modes", ("own %d, shapes %d+%d, pieces %d, flat %d"):format(modes.grad, modes.shared1, modes.shared, modes.pieces, modes.flat))
					gui:SetAttribute("ShapesInUse", nil)
					-- strip share (follows the gradients replaced per screen frame) and replacements per second
					gui:SetAttribute("Share", video.MaxGradients)
					gui:SetAttribute("ChangesPerSec", video.cps and math.floor(video.cps) or 0)
					gui:SetAttribute("WorkMs", st.ms)
					gui:SetAttribute("Fps", fpsNow)
				end)
				task.wait(0.5)
			end
			fpsConn:Disconnect()
		end)
	end

	CollectionService:GetInstanceRemovedSignal(Sync.Tag):Connect(stopTV)

	-- which screens play: the nearest few with a video, within view distance
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.5 then
			return
		end
		acc = 0
		-- respawning clears the PlayerGui, this folder and its screens too: start them again in a new one
		if holder.Parent ~= playerGui then
			for tv in pairs(playing) do
				stopTV(tv)
			end
			holder = newHolder()
		end
		local cam = workspace.CurrentCamera
		local from = cam and cam.CFrame.Position or Vector3.zero
		local cands = {}
		for _, tv in ipairs(CollectionService:GetTagged(Sync.Tag)) do
			local video = tv:GetAttribute("FrameLabVideo")
			local screen = tv:IsDescendantOf(workspace) and tv:GetAttribute("FrameLabSynced") == true
				and tv:GetAttribute("FrameLabState") ~= "stopped" and screenOf(tv)
			if video and video ~= "" and screen then
				local d = (screen.Position - from).Magnitude - screen.Size.Magnitude / 2 -- from its edge (big screens)
				if d <= (Config.ViewDistance or 120) then
					table.insert(cands, { tv = tv, d = d })
				end
			end
		end
		table.sort(cands, function(a, b)
			return a.d < b.d
		end)
		local want = {}
		for i = 1, math.min(#cands, Config.MaxPlaying or 2) do
			want[cands[i].tv] = true
		end
		for tv, p in pairs(playing) do
			local key = tostring(tv:GetAttribute("FrameLabVideo"))
			if not want[tv] or p.key ~= key then
				stopTV(tv)
			end
		end
		for tv in pairs(want) do
			if not playing[tv] then
				startTV(tv)
			end
		end
	end)
end
