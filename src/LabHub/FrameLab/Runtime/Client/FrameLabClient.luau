-- Started by FrameLab:init() on a client, the same way AudioLabClient plays synced sound: plays every synced screen
-- (an instance tagged "FrameLab" with FrameLabSynced = true: a Part, or a Model with a part named "Screen") on a
-- SurfaceGui, on the server's playhead (FrameLab.Sync). The video's bytes stream from the server while it plays.
-- Only the nearest screens within view distance play (FrameLab attributes ViewDistance / MaxPlaying). A video kept at
-- several sizes plays at the one this device keeps up with (Video.Stream.deviceLines), one size down when it falls
-- behind.
return function(FrameLab)
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local CollectionService = game:GetService("CollectionService")
	local root = script:FindFirstAncestor("FrameLab")
	local Net = require(root.Tools.Net)
	local Stream = require(root.Video.Stream)
	local Sync = require(root.Sync)
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	local player = Players.LocalPlayer
	if not player then
		return
	end
	-- the sound of an in-game import stays on the server until a TV here plays it (AudioLab asks for clips it hasn't got);
	-- a stream's sound ("stream/<name>") comes part by part as it plays (Video.StreamSound)
	pcall(function()
		local al = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
		if al then
			require(al.Tools.Assets).addSource(function(path)
				if type(path) == "string" and string.sub(path, 1, 7) == "stream/" then
					return require(root.Video.StreamSound).clip(string.sub(path, 8))
				end
				return Net.clip(path)
			end)
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
		local direct = Stream.decodeStreams()
		local stream = Net.openVideo(name, { Direct = direct, Blocks = not direct and Stream.blockStreams() })
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
			-- a stream this client decodes itself (unconverted segments): its reader, on worker threads
			local reader
			if stream.direct then
				local DirectReader = require(root.Video.DirectReader)
				-- (the block player's blocks are worked out on worker threads too)
				local fit
				local okB, Blocks = pcall(require, root.Image.Blocks)
				if okB and Blocks.ready() then
					local UIS = game:GetService("UserInputService")
					fit = { Skip = 5, Split = 6, MaxSplits = (UIS.TouchEnabled and not UIS.KeyboardEnabled) and 300 or 1200 }
				end
				reader = DirectReader.available() and DirectReader.new(stream, { Lines = Stream.directLines(), Fit = fit }) or nil
				if not reader then
					Stream.directOff = true
					stopTV(tv) -- (started again with the server's block picture)
					return
				end
			elseif stream.blocks then
				-- the server's block picture (phones): only the blocks that change are set here
				local okB, Blocks = pcall(require, root.Image.Blocks)
				if not (okB and Blocks.ready()) then
					Stream.blocksOff = true
					stopTV(tv) -- (started again with the server's converted copy)
					return
				end
				reader = require(root.Video.BlockStream).reader(stream)
			end
			local ok, video = pcall(FrameLab.Player.new, stream.bytes, bg, { Clock = clock, Loop = tv:GetAttribute("FrameLabLoop") == true, Ready = stream.ready,
				ChunkData = stream.chunks and stream.chunkData or nil, Reader = reader })
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
			-- same screen), DecodeMs, Behind (rows still to draw), HalfRate, Tolerance, Strips, ShownFps (the rate
			-- the pictures are shown at), Decode (client: this client decodes the stream; DecodeRate: frames a second)
			local Attach
			pcall(function()
				Attach = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab").Synth.Attach)
			end)
			-- waiting on the picture (its bytes, or its decoding after a jump) for more than a moment: a spinner over it, like
			-- YouTube's (the last picture stays under it)
			local spinner = Instance.new("Frame")
			spinner.Name = "Loading"
			spinner.AnchorPoint = Vector2.new(0.5, 0.5)
			spinner.Position = UDim2.fromScale(0.5, 0.5)
			spinner.Size = UDim2.fromScale(0.16, 0.16)
			spinner.SizeConstraint = Enum.SizeConstraint.RelativeYY
			spinner.BackgroundTransparency = 1
			spinner.ZIndex = 20
			spinner.Visible = false
			for i = 0, 7 do
				local a = i / 8 * math.pi * 2
				local dot = Instance.new("Frame")
				dot.AnchorPoint = Vector2.new(0.5, 0.5)
				dot.Position = UDim2.fromScale(0.5 + 0.4 * math.sin(a), 0.5 - 0.4 * math.cos(a))
				dot.Size = UDim2.fromScale(0.18, 0.18)
				dot.BackgroundColor3 = Color3.new(1, 1, 1)
				dot.BackgroundTransparency = 0.15 + ((8 - i) % 8) * 0.1 -- (brightest leading, fading behind)
				dot.BorderSizePixel = 0
				dot.ZIndex = 21
				local corner = Instance.new("UICorner")
				corner.CornerRadius = UDim.new(1, 0)
				corner.Parent = dot
				dot.Parent = spinner
			end
			spinner.Parent = bg
			local waiting = 0
			local readySent, holdSeen
			local lastStall = -math.huge
			local fpsNow = 0
			local fpsConn = RunService.Heartbeat:Connect(function(dt)
				fpsNow = fpsNow * 0.95 + (1 / math.max(dt, 1e-3)) * 0.05
				waiting = video.Stats.buffering and waiting + dt or 0
				local show = waiting > 0.4
				if spinner.Visible ~= show then
					spinner.Visible = show
				end
				if show then
					spinner.Rotation = (spinner.Rotation + dt * 300) % 360
				end
				-- a held seek (Sync.seek): the picture is at the spot, so the playhead may go on (only the screen's
				-- controller is listened to)
				local hold = tv:GetAttribute("FrameLabHold")
				if hold and hold ~= readySent and hold == tv:GetAttribute("FrameLabSeq") and hold ~= holdSeen then
					holdSeen = hold -- (judged from the next frame: the player has seen the jump by then)
				elseif hold and hold ~= readySent and hold == tv:GetAttribute("FrameLabSeq") then
					local st = video.Stats
					local due = math.floor(clock() * video.fps)
					local at = video.reader.frame
					-- (the picture at the spot: not still the one from before a jump back)
					if not st.buffering and (st.behind or 0) == 0
						and at >= due - math.ceil(video.fps / 6) and at <= due + video.fps then
						readySent = hold
						Sync.request(tv, "ready", hold)
					end
				end
				-- the picture stuck loading while it plays (not a held jump): this client, if it controls the screen, asks
				-- the playhead to wait for it, as a video player does while buffering (at most every 10 s)
				if waiting > 1 and tv:GetAttribute("FrameLabHold") == nil and tv:GetAttribute("FrameLabState") == "playing"
					and os.clock() - lastStall > 10 then
					local owner = tv:GetAttribute("FrameLabOwner")
					if (owner ~= nil and owner == game:GetService("Players").LocalPlayer.UserId) or tv:GetAttribute("FrameLabClientControl") == true then
						lastStall = os.clock()
						Sync.request(tv, "stall")
					end
				end
			end)
			-- (only with Config.Debug: checked every half second, so it can be switched on while playing)
			local shown = false
			-- a screen that keeps falling behind (decoding too slow even at half rate, a quarter of the rows left undrawn: the
			-- picture splitting, or the bytes not arriving in time) for 4 s steps down to the video's smaller size, and this
			-- client stays there for the session
			local struggle, slow, heavy = 0, 0, 0
			while playing[tv] == p and gui.Parent do
				local smaller = stream.renditions and stream.rendition and stream.renditions[stream.rendition + 1]
				if video.reader.direct then
					-- decoding the stream here: the picture kept waiting on its decoding (10 s of it, or 3 s while decoding runs
					-- under 80% of the video's rate for 6 s) or failing goes back to the server's converted copy; a picture
					-- above 180 lines steps down to 180 first, and also when drawing it holds the game under 30 frames a second
					local st = video.Stats
					local rate = video.reader.decodeRate()
					slow = (rate and rate < video.fps * 0.8) and slow + 0.5 or 0
					-- (waiting on a jump's picture doesn't count: that is loading, not falling behind; a wait this client
					-- asked for itself, Sync "stall", does)
					local waitingJump = tv:GetAttribute("FrameLabHold") ~= nil and os.clock() - lastStall > 10
					struggle = (st.buffering and not waitingJump) and struggle + 0.5 or math.max(0, struggle - 0.25)
					heavy = (not st.buffering and fpsNow < 30) and heavy + 0.5 or 0
					local lagging = struggle >= 10 or (slow >= 6 and struggle >= 3)
					if video.reader.failed() then
						Stream.directOff = true
						stopTV(tv)
						break
					elseif math.min(video.W or 0, video.H or 0) > 180 and (heavy >= 4 or struggle >= 6 or (slow >= 6 and struggle >= 2)) then
						-- (this client stays at 180 for the session)
						Stream.stepDown = 180
						stopTV(tv)
						break
					elseif lagging then
						Stream.directOff = true
						stopTV(tv)
						break
					end
				elseif video.reader.blocks then
					-- the server's block picture: broken pieces go back to the server's converted copy
					if video.reader.failed() then
						Stream.blocksOff = true
						stopTV(tv)
						break
					end
				elseif smaller and Config.VideoRendition ~= "high" then
					local st = video.Stats
					local slow = (st.halfRate and (st.decodeMs or 0) > video.TargetMs * 1.5) or st.buffering
						or (st.behind or 0) > video.H * 0.25
					struggle = slow and struggle + 0.5 or math.max(0, struggle - 0.25)
					if struggle >= 4 then
						Stream.stepDown = math.min(smaller.width, smaller.height)
						stopTV(tv) -- (started again at the smaller size by the loop below)
						break
					end
				end
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
					gui:SetAttribute("ShownFps", st.fps)
					gui:SetAttribute("Decode", r.direct and "client" or r.blocks and "blocks" or "server")
					gui:SetAttribute("DecodeRate", r.decodeRate and r.decodeRate() or nil)
				end)
				task.wait(0.5)
			end
			fpsConn:Disconnect()
		end)
	end

	CollectionService:GetInstanceRemovedSignal(Sync.Tag):Connect(stopTV)

	-- the video memory this client uses, for the admins' data manager (Labs > Data > Clients), and its Clear
	task.spawn(function()
		local last
		while true do
			local u = Net.cacheUsage()
			local key = table.concat({ u.video, u.limit, u.streams, u.pictures, u.sounds, math.floor(u.memory), math.floor(u.luau) }, "/")
			if key ~= last then
				if pcall(Net.invoke, "cacheReport", u) then
					last = key
				end
			end
			task.wait(3)
		end
	end)
	local cacheEvent = Net.remotes(false):WaitForChild("Cache", 30)
	if cacheEvent then
		cacheEvent.OnClientEvent:Connect(function(what)
			if what == "clear" then
				Net.clearCache()
			end
		end)
	end

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
