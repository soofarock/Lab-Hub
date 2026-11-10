-- Started by FrameLab:init() on a client: the TV owner's controls. A TV is a synced FrameLab screen (FrameLabClient
-- plays it for everyone); its owner gets a prompt on it to pick a video, pause / resume, stop, or pick the TV up.
-- Anyone can click a TV to watch it: the camera sits in front of its screen until they move or press Leave (clicking
-- the picture again plays / pauses). While
-- watching, a YouTube-style bar shows the time and a seek bar; the TV's owner (or anyone, on a screen with
-- FrameLabClientControl) can play / pause, seek, skip 10 s and change the speed, and everyone sets their own volume.
-- Music the player is playing in the AudioLab player pauses while they watch and resumes when they leave.
-- Keys while watching: Space / K play-pause, J / L 10 s back / ahead, Left / Right 5 s, Up / Down volume, M mute.
return function(FrameLab)
	local Players = game:GetService("Players")
	local root = script:FindFirstAncestor("FrameLab")
	local Net = require(root.Tools.Net)
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local remote = Net.remotes(false):WaitForChild("TV")
	local Sync = require(root.Sync)
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	local folder = workspace:WaitForChild("FrameLabTVs")

	-- picker for the owner
	local picker
	local function closePicker()
		if picker then
			picker:Destroy()
			picker = nil
		end
	end
	local order = 0
	local function button(parent, text, w)
		local b = Instance.new("TextButton")
		order += 1
		b.LayoutOrder = order
		b.Size = UDim2.new(0, w, 0, 30)
		b.BackgroundColor3 = Color3.fromRGB(34, 38, 48)
		b.TextColor3 = Color3.fromRGB(230, 233, 240)
		b.Font = Enum.Font.GothamMedium
		b.TextSize = 13
		b.Text = text
		b.AutoButtonColor = true
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = b
		b.Parent = parent
		return b
	end
	local function openPicker(tv)
		closePicker()
		-- (one window at a time: the Labs panels close)
		pcall(function()
			require(game:GetService("ReplicatedStorage"):FindFirstChild("LabHub")).closeAll()
		end)
		local sg = Instance.new("ScreenGui")
		sg.Name = "FrameLabTVPicker"
		sg.ResetOnSpawn = false
		sg.DisplayOrder = 20
		local panel = Instance.new("Frame")
		panel.Size = UDim2.new(0, 380, 0, 420)
		panel.Position = UDim2.fromScale(0.5, 0.5)
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.BackgroundColor3 = Color3.fromRGB(20, 23, 30)
		panel.Parent = sg
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 12)
		c.Parent = panel
		local pad = Instance.new("UIPadding")
		for _, k in ipairs({ "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" }) do
			pad[k] = UDim.new(0, 12)
		end
		pad.Parent = panel
		local title = Instance.new("TextLabel")
		title.Size = UDim2.new(1, 0, 0, 22)
		title.BackgroundTransparency = 1
		title.Text = "TV: pick a video"
		title.TextColor3 = Color3.fromRGB(230, 233, 240)
		title.Font = Enum.Font.GothamBold
		title.TextSize = 15
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = panel
		-- admins: the data manager (every import, its size, delete / load again: Runtime/Client/DataManager)
		local dataBtn = button(panel, "Data", 56)
		dataBtn.Size = UDim2.new(0, 56, 0, 24)
		dataBtn.Position = UDim2.new(1, -56, 0, -2)
		dataBtn.Visible = false
		task.spawn(function()
			dataBtn.Visible = Net.isAdmin()
		end)
		dataBtn.MouseButton1Click:Connect(function()
			closePicker()
			if FrameLab.openDataManager then
				FrameLab.openDataManager()
			end
		end)
		local list = Instance.new("ScrollingFrame")
		list.Size = UDim2.new(1, 0, 1, -112)
		list.Position = UDim2.new(0, 0, 0, 68)
		-- admins: import a video from a web address (kept while the server runs)
		local importRow = Instance.new("Frame")
		importRow.Size = UDim2.new(1, 0, 0, 30)
		importRow.Position = UDim2.new(0, 0, 0, 30)
		importRow.BackgroundTransparency = 1
		importRow.Visible = false
		importRow.Parent = panel
		local urlBox = Instance.new("TextBox")
		urlBox.Size = UDim2.new(1, -228, 1, 0)
		urlBox.BackgroundColor3 = Color3.fromRGB(28, 32, 41)
		urlBox.TextColor3 = Color3.fromRGB(230, 233, 240)
		urlBox.PlaceholderText = "video URL: MP4, GIF, WebP, AVI, or a YouTube link"
		urlBox.PlaceholderColor3 = Color3.fromRGB(140, 148, 165)
		urlBox.Text = ""
		urlBox.ClearTextOnFocus = false
		urlBox.Font = Enum.Font.Code
		urlBox.TextSize = 12
		urlBox.TextTruncate = Enum.TextTruncate.AtEnd
		local uc = Instance.new("UICorner")
		uc.CornerRadius = UDim.new(0, 6)
		uc.Parent = urlBox
		urlBox.Parent = importRow
		local importBtn = button(importRow, "Import", 88)
		importBtn.Position = UDim2.new(1, -88, 0, 0)
		-- the size the video is imported at (FrameLab Config ImportVideoQuality is the default; this client remembers the pick)
		local QUALITIES = { "144p", "240p", "360p" }
		local quality = playerGui:GetAttribute("FrameLabImportQuality") or Config.ImportVideoQuality or "144p"
		if not table.find(QUALITIES, quality) then
			quality = "144p"
		end
		local qualityBtn = button(importRow, quality, 50)
		qualityBtn.Position = UDim2.new(1, -144, 0, 0)
		qualityBtn.MouseButton1Click:Connect(function()
			quality = QUALITIES[(table.find(QUALITIES, quality) or 1) % #QUALITIES + 1]
			qualityBtn.Text = quality
			playerGui:SetAttribute("FrameLabImportQuality", quality)
		end)
		-- Stream: an address plays in parts as it is watched (an MP4 / MOV up to 360p, or HLS), started on this TV at once,
		-- instead of being imported whole first (this client remembers the switch)
		local streamMode = playerGui:GetAttribute("FrameLabStreamMode") == true
		local streamBtn = button(importRow, "", 70)
		streamBtn.Position = UDim2.new(1, -220, 0, 0)
		local function showStream()
			streamBtn.Text = streamMode and "Stream: on" or "Stream: off"
			streamBtn.BackgroundColor3 = streamMode and Color3.fromRGB(190, 30, 55) or Color3.fromRGB(34, 38, 48)
			urlBox.PlaceholderText = streamMode and "stream URL: MP4 / MOV (up to 360p) or .m3u8 - plays right away"
				or "video URL: MP4, GIF, WebP, AVI, or a YouTube link"
		end
		showStream()
		streamBtn.MouseButton1Click:Connect(function()
			streamMode = not streamMode
			playerGui:SetAttribute("FrameLabStreamMode", streamMode)
			showStream()
		end)
		task.spawn(function()
			importRow.Visible = Net.isAdmin()
		end)
		list.BackgroundColor3 = Color3.fromRGB(28, 32, 41)
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 4
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.CanvasSize = UDim2.new()
		list.Parent = panel
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 4)
		layout.Parent = list
		local lp = Instance.new("UIPadding")
		lp.PaddingTop, lp.PaddingLeft, lp.PaddingRight = UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 10)
		lp.Parent = list
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 30)
		row.Position = UDim2.new(0, 0, 1, -30)
		row.BackgroundTransparency = 1
		row.Parent = panel
		local rl = Instance.new("UIListLayout")
		rl.SortOrder = Enum.SortOrder.LayoutOrder
		rl.FillDirection = Enum.FillDirection.Horizontal
		rl.Padding = UDim.new(0, 6)
		rl.Parent = row
		button(row, "Pause / play", 96).MouseButton1Click:Connect(function()
			Sync.request(tv, "toggle")
		end)
		button(row, "Stop", 60).MouseButton1Click:Connect(function()
			Sync.request(tv, "stop")
			closePicker()
		end)
		button(row, "Pick up", 70).MouseButton1Click:Connect(function()
			remote:FireServer("remove", tv)
			closePicker()
		end)
		button(row, "Close", 60).MouseButton1Click:Connect(closePicker)
		sg:SetAttribute("TV", tv.Name)
		sg.Parent = playerGui
		picker = sg
		local importing = false
		local fill
		local function doImport()
			if importing or urlBox.Text == "" then
				return
			end
			importing = true
			importBtn.Text = "Importing..."
			title.Text = "Importing... (a long video takes a while)"
			-- how far it is (the server's ImportStatus: "42% - video - 31 s")
			task.spawn(function()
				local folder = Net.remotes(false)
				while importing and picker == sg do
					local st = folder:GetAttribute("ImportStatus")
					if type(st) == "string" and st ~= "" then
						title.Text = "Importing: " .. st
						importBtn.Text = string.match(st, "^%d+%%") or "Importing..."
					end
					task.wait(0.25)
				end
			end)
			local ok, res = pcall(Net.invoke, "importUrl", "video", urlBox.Text, quality, streamMode)
			importing = false
			importBtn.Text = "Import"
			if picker ~= sg then
				return
			end
			if not ok or type(res) ~= "table" then
				title.Text = "That didn't import"
			elseif res.error then
				title.Text = res.error
			elseif streamMode and res.stream then
				-- stream mode: it plays on this TV straight away
				urlBox.Text = ""
				Net.forget()
				Sync.request(tv, "play", { Video = res.name, Loop = true })
				closePicker()
			else
				-- the new video joins the list (the panel stays as it is)
				title.Text = ("Imported %s (%.1f s): pick it below"):format(res.name, res.seconds or 0)
				urlBox.Text = ""
				Net.forget()
				fill()
			end
		end
		importBtn.MouseButton1Click:Connect(doImport)
		urlBox.FocusLost:Connect(function(enter)
			if enter then
				doImport()
			end
		end)
		function fill()
			for _, ch in ipairs(list:GetChildren()) do
				if ch:IsA("GuiButton") then
					ch:Destroy()
				end
			end
		local videos = Net.videos()
		if #videos == 0 then
			local b = button(list, "No videos yet: import some with FrameLab.import() in Studio", 10)
			b.Size = UDim2.new(1, 0, 0, 30)
			b.TextWrapped = true
		end
		for _, v in ipairs(videos) do
			local b = button(list, ("%s   %dx%d, %.1f s%s"):format(v.name, v.Width or 0, v.Height or 0, v.Seconds or 0, v.Imported and ", imported" or (v.Server and ", streamed" or "")), 10)
			b.Size = UDim2.new(1, 0, 0, 30)
			b.TextXAlignment = Enum.TextXAlignment.Left
			local bp = Instance.new("UIPadding")
			bp.PaddingLeft = UDim.new(0, 8)
			bp.Parent = b
			b.MouseButton1Click:Connect(function()
				Sync.request(tv, "play", { Video = v.name, Loop = true })
				closePicker()
			end)
		end
		end
		fill()
	end

	-- watching: the camera in front of a TV's screen, framing it
	local RunService = game:GetService("RunService")
	local PromptService = game:GetService("ProximityPromptService")
	local watching, watchConn, watchGui, promptsWere, pendingWas
	local watchConns = {} -- input connections of the control bar
	local buildControls -- (below)
	local watchToggle -- play / pause of the TV being watched (clicking its picture while watching)
	local UIS = game:GetService("UserInputService")
	local CAS = game:GetService("ContextActionService")
	local KEYS_ACTION = "FrameLabTVKeys"
	-- this player's own volume per TV (0..1, times the TV's AudioLab volume); AudioLab's handle for the TV's sound
	local tvVolume, tvMuted = {}, {}
	local Attach, Library
	pcall(function()
		local al = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("AudioLab", 2)
		Attach = require(al.Synth.Attach)
		Library = require(al.Tools.Library)
	end)
	local pausedMusic -- this player's own music, paused while watching (resumed when they leave)
	-- while watching, the backpack and the other GUI step aside (chat stays)
	local StarterGui = game:GetService("StarterGui")
	local CORE = { Enum.CoreGuiType.Backpack, Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Health, Enum.CoreGuiType.EmotesMenu }
	local coreWas, hiddenGuis = {}, {}
	local function hideGui()
		for _, t in ipairs(CORE) do
			coreWas[t] = StarterGui:GetCoreGuiEnabled(t)
			pcall(StarterGui.SetCoreGuiEnabled, StarterGui, t, false)
		end
		for _, g in ipairs(playerGui:GetChildren()) do
			-- (not the ones holding SurfaceGuis / BillboardGuis: those draw the TVs and other things in the world)
			if g:IsA("ScreenGui") and g.Enabled and g ~= watchGui and not g:FindFirstChildWhichIsA("SurfaceGui", true)
				and not g:FindFirstChildWhichIsA("BillboardGui", true) then
				g.Enabled = false
				table.insert(hiddenGuis, g)
			end
		end
	end
	local function showGui()
		for t, was in pairs(coreWas) do
			pcall(StarterGui.SetCoreGuiEnabled, StarterGui, t, was)
		end
		table.clear(coreWas)
		for _, g in ipairs(hiddenGuis) do
			if g.Parent then
				g.Enabled = true
			end
		end
		table.clear(hiddenGuis)
	end
	local function stopWatching()
		if not watching then
			return
		end
		watching = nil
		if watchConn then
			watchConn:Disconnect()
			watchConn = nil
		end
		if watchGui then
			watchGui:Destroy()
			watchGui = nil
		end
		for _, c in ipairs(watchConns) do
			c:Disconnect()
		end
		table.clear(watchConns)
		CAS:UnbindAction(KEYS_ACTION)
		watchToggle = nil
		if pausedMusic and Library then
			Library.resumeAll(pausedMusic)
		end
		pausedMusic = nil
		if promptsWere ~= nil then
			-- a moment later: the click that ended watching mustn't also trigger the prompt it reveals
			pendingWas = promptsWere
			promptsWere = nil
			task.delay(0.3, function()
				if not watching and pendingWas ~= nil then
					PromptService.Enabled = pendingWas
					pendingWas = nil
				end
			end)
		end
		showGui()
		local cam = workspace.CurrentCamera
		cam.CameraType = Enum.CameraType.Custom
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			cam.CameraSubject = hum
		end
	end
	-- the control bar (YouTube-like) shown while watching
	local RED = Color3.fromRGB(255, 0, 51)
	local WHITE = Color3.new(1, 1, 1)
	local function clock(t)
		t = math.max(0, math.floor(t + 0.0001))
		if t >= 3600 then
			return ("%d:%02d:%02d"):format(t // 3600, (t // 60) % 60, t % 60)
		end
		return ("%d:%02d"):format(t // 60, t % 60)
	end
	local function iconButton(parent, text, w, order_)
		local b = Instance.new("TextButton")
		b.LayoutOrder = order_
		b.Size = UDim2.new(0, w, 0, 36)
		b.BackgroundColor3 = Color3.fromRGB(28, 28, 28)
		b.BackgroundTransparency = 0.35
		b.TextColor3 = WHITE
		b.Font = Enum.Font.GothamBold
		b.TextSize = 15
		b.Text = text
		b.AutoButtonColor = true
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = b
		b.Parent = parent
		return b
	end
	function buildControls(tv, gui)
		local function canControl()
			local owner = tv:GetAttribute("FrameLabOwner")
			return (owner ~= nil and owner == player.UserId) or tv:GetAttribute("FrameLabClientControl") == true
		end
		local function duration()
			return tv:GetAttribute("FrameLabDuration") or 0
		end
		local function now()
			return Sync.getTime(tv, { duration = duration(), loop = tv:GetAttribute("FrameLabLoop") == true })
		end
		local function playing()
			return tv:GetAttribute("FrameLabState") == "playing"
		end
		local function seekTo(t)
			local d = duration()
			if d > 0 then
				t = math.clamp(t, 0, math.max(0, d - 0.05))
			end
			Sync.request(tv, "seek", math.max(0, t))
		end

		-- bottom panel: a dark fade, the seek bar, then the buttons. A CanvasGroup, so the whole bar fades out together
		-- (GroupTransparency) when the mouse rests, and snaps back in when it moves (see update)
		local panel = Instance.new("CanvasGroup")
		panel.Name = "Controls"
		panel.AnchorPoint = Vector2.new(0.5, 1)
		panel.Position = UDim2.new(0.5, 0, 1, 0)
		panel.Size = UDim2.new(1, 0, 0, 116) -- (12 px of headroom: a CanvasGroup clips, and the seek time tip sits above the bar)
		panel.BackgroundTransparency = 1
		panel.BorderSizePixel = 0
		panel.Active = true -- clicks on the bar don't reach the TV behind it
		local shade = Instance.new("Frame") -- (its own frame: a gradient on the group would fade the buttons too)
		shade.Name = "Shade"
		shade.Size = UDim2.fromScale(1, 1)
		shade.BackgroundColor3 = Color3.new(0, 0, 0)
		shade.BorderSizePixel = 0
		shade.ZIndex = 0
		local fade = Instance.new("UIGradient")
		fade.Rotation = 90
		fade.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.35) })
		fade.Parent = shade
		shade.Parent = panel
		panel.Parent = gui

		-- seek bar (a wide invisible hit area around a thin bar)
		local hit = Instance.new("TextButton")
		hit.Name = "Seek"
		hit.Text = ""
		hit.AutoButtonColor = false
		hit.BackgroundTransparency = 1
		hit.AnchorPoint = Vector2.new(0.5, 0)
		hit.Position = UDim2.new(0.5, 0, 0, 30)
		hit.Size = UDim2.new(1, -48, 0, 18)
		hit.Parent = panel
		local track = Instance.new("Frame")
		track.AnchorPoint = Vector2.new(0, 0.5)
		track.Position = UDim2.new(0, 0, 0.5, 0)
		track.Size = UDim2.new(1, 0, 0, 4)
		track.BackgroundColor3 = WHITE
		track.BackgroundTransparency = 0.65
		track.BorderSizePixel = 0
		track.Parent = hit
		-- the parts of the video this player already holds (YouTube's lighter line): jumping there starts at once
		local held = Instance.new("Frame")
		held.Name = "Held"
		held.Size = UDim2.fromScale(1, 1)
		held.BackgroundTransparency = 1
		held.Parent = track
		local heldBars, heldAt = {}, 0
		local hover = Instance.new("Frame") -- where a click would land
		hover.Size = UDim2.new(0, 0, 1, 0)
		hover.BackgroundColor3 = WHITE
		hover.BackgroundTransparency = 0.6
		hover.BorderSizePixel = 0
		hover.Visible = false
		hover.Parent = track
		local fill = Instance.new("Frame")
		fill.Size = UDim2.new(0, 0, 1, 0)
		fill.BackgroundColor3 = RED
		fill.BorderSizePixel = 0
		fill.ZIndex = 2
		fill.Parent = track
		local knob = Instance.new("Frame")
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.Size = UDim2.new(0, 13, 0, 13)
		knob.BackgroundColor3 = RED
		knob.BorderSizePixel = 0
		knob.ZIndex = 3
		local kc = Instance.new("UICorner")
		kc.CornerRadius = UDim.new(1, 0)
		kc.Parent = knob
		knob.Parent = track
		local tip = Instance.new("TextLabel") -- the time under the mouse
		tip.AnchorPoint = Vector2.new(0.5, 1)
		tip.Size = UDim2.new(0, 56, 0, 20)
		tip.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
		tip.BackgroundTransparency = 0.2
		tip.TextColor3 = WHITE
		tip.Font = Enum.Font.GothamMedium
		tip.TextSize = 12
		tip.Visible = false
		tip.ZIndex = 4
		local tc = Instance.new("UICorner")
		tc.CornerRadius = UDim.new(0, 4)
		tc.Parent = tip
		tip.Parent = hit

		-- button row
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Position = UDim2.new(0, 24, 0, 58)
		row.Size = UDim2.new(1, -48, 0, 40)
		row.Parent = panel
		local left = Instance.new("Frame")
		left.BackgroundTransparency = 1
		left.Size = UDim2.new(0.6, 0, 1, 0)
		left.Parent = row
		local ll = Instance.new("UIListLayout")
		ll.FillDirection = Enum.FillDirection.Horizontal
		ll.VerticalAlignment = Enum.VerticalAlignment.Center
		ll.SortOrder = Enum.SortOrder.LayoutOrder
		ll.Padding = UDim.new(0, 8)
		ll.Parent = left
		local right = Instance.new("Frame")
		right.BackgroundTransparency = 1
		right.AnchorPoint = Vector2.new(1, 0)
		right.Position = UDim2.new(1, 0, 0, 0)
		right.Size = UDim2.new(0.4, 0, 1, 0)
		right.Parent = row
		local rl = ll:Clone()
		rl.HorizontalAlignment = Enum.HorizontalAlignment.Right
		rl.Parent = right

		local playBtn = iconButton(left, "II", 40, 1)
		local backBtn = iconButton(left, "-10", 46, 2)
		local fwdBtn = iconButton(left, "+10", 46, 3)
		local volBtn = iconButton(left, "Vol", 48, 4)
		volBtn.TextSize = 12
		local volTrack = Instance.new("TextButton")
		volTrack.LayoutOrder = 5
		volTrack.Text = ""
		volTrack.AutoButtonColor = false
		volTrack.Size = UDim2.new(0, 80, 0, 4)
		volTrack.BackgroundColor3 = WHITE
		volTrack.BackgroundTransparency = 0.65
		volTrack.BorderSizePixel = 0
		volTrack.Parent = left
		local volFill = Instance.new("Frame")
		volFill.Size = UDim2.new(1, 0, 1, 0)
		volFill.BackgroundColor3 = WHITE
		volFill.BorderSizePixel = 0
		volFill.Parent = volTrack
		local timeLabel = Instance.new("TextLabel")
		timeLabel.LayoutOrder = 6
		timeLabel.BackgroundTransparency = 1
		timeLabel.Size = UDim2.new(0, 120, 0, 36)
		timeLabel.TextColor3 = WHITE
		timeLabel.Font = Enum.Font.GothamMedium
		timeLabel.TextSize = 14
		timeLabel.TextXAlignment = Enum.TextXAlignment.Left
		timeLabel.Text = "0:00 / 0:00"
		timeLabel.Parent = left

		local speeds = { 0.5, 1, 1.5, 2 }
		local speedBtns = {}
		for i, sp in ipairs(speeds) do
			local b = iconButton(right, (sp == math.floor(sp) and tostring(math.floor(sp)) or tostring(sp)) .. "x", 46, i)
			b.TextSize = 13
			speedBtns[sp] = b
			b.Activated:Connect(function()
				if canControl() then
					Sync.request(tv, "setSpeed", sp)
				end
			end)
		end
		local leaveBtn = iconButton(right, "Leave", 64, 10)
		leaveBtn.TextSize = 13
		leaveBtn.Activated:Connect(stopWatching)

		local note = Instance.new("TextLabel") -- why the buttons do nothing
		note.AnchorPoint = Vector2.new(0.5, 1)
		note.Position = UDim2.new(0.5, 0, 0, 26)
		note.Size = UDim2.new(1, 0, 0, 16)
		note.BackgroundTransparency = 1
		note.TextColor3 = Color3.fromRGB(200, 200, 200)
		note.Font = Enum.Font.Gotham
		note.TextSize = 12
		note.Text = ""
		note.Parent = panel

		-- actions
		local function toggle()
			if canControl() then
				Sync.request(tv, "toggle")
			end
		end
		local function skip(dt)
			if canControl() then
				seekTo(now() + dt)
			end
		end
		local function volume()
			return tvVolume[tv] or 1
		end
		local function setVolume(v)
			tvVolume[tv] = math.clamp(v, 0, 1)
			tvMuted[tv] = tvVolume[tv] <= 0 or nil
		end
		playBtn.Activated:Connect(toggle)
		watchToggle = toggle
		backBtn.Activated:Connect(function()
			skip(-10)
		end)
		fwdBtn.Activated:Connect(function()
			skip(10)
		end)
		volBtn.Activated:Connect(function()
			tvMuted[tv] = not tvMuted[tv] or nil
			if not tvMuted[tv] and volume() <= 0 then
				tvVolume[tv] = 1
			end
		end)

		-- dragging (seek bar and volume)
		local dragging -- "seek" | "volume"
		local lastMove = os.clock()
		local function fracOf(guiObj, x)
			local p, w = guiObj.AbsolutePosition.X, math.max(guiObj.AbsoluteSize.X, 1)
			return math.clamp((x - p) / w, 0, 1)
		end
		local previewT
		local function isPress(input)
			return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
		end
		table.insert(watchConns, hit.InputBegan:Connect(function(input)
			if isPress(input) and canControl() then
				dragging = "seek"
				previewT = fracOf(track, input.Position.X) * duration()
			end
		end))
		table.insert(watchConns, volTrack.InputBegan:Connect(function(input)
			if isPress(input) then
				dragging = "volume"
				setVolume(fracOf(volTrack, input.Position.X))
			end
		end))
		table.insert(watchConns, UIS.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				lastMove = os.clock()
				if dragging == "seek" then
					previewT = fracOf(track, input.Position.X) * duration()
				elseif dragging == "volume" then
					setVolume(fracOf(volTrack, input.Position.X))
				end
			end
		end))
		table.insert(watchConns, UIS.InputEnded:Connect(function(input)
			if isPress(input) and dragging then
				if dragging == "seek" and previewT then
					seekTo(previewT)
				end
				dragging, previewT = nil, nil
			end
		end))

		-- keys (sunk, so Space doesn't jump and the arrows don't walk away from the TV)
		CAS:BindActionAtPriority(KEYS_ACTION, function(_, state, input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Sink
			end
			lastMove = os.clock()
			local k = input.KeyCode
			if k == Enum.KeyCode.Space or k == Enum.KeyCode.K then
				toggle()
			elseif k == Enum.KeyCode.J then
				skip(-10)
			elseif k == Enum.KeyCode.L then
				skip(10)
			elseif k == Enum.KeyCode.Left then
				skip(-5)
			elseif k == Enum.KeyCode.Right then
				skip(5)
			elseif k == Enum.KeyCode.Up then
				setVolume(volume() + 0.1)
			elseif k == Enum.KeyCode.Down then
				setVolume(volume() - 0.1)
			elseif k == Enum.KeyCode.M then
				tvMuted[tv] = not tvMuted[tv] or nil
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 100, Enum.KeyCode.Space, Enum.KeyCode.K, Enum.KeyCode.J,
			Enum.KeyCode.L, Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.M)

		-- every frame: time, bar, buttons, this player's volume on the TV's sound; the bar hides after 3 s without the
		-- mouse moving (while playing)
		local lastHandle, lastGain
		local shownAmount, lastUpdate = 1, os.clock() -- 1 = bar fully shown
		local FADE_IN, FADE_OUT, IDLE = 0.08, 0.6, 2.5 -- seconds
		local function update()
			local d = duration()
			local t = now()
			local shown = previewT or t
			local f = d > 0 and math.clamp(shown / d, 0, 1) or 0
			fill.Size = UDim2.new(f, 0, 1, 0)
			knob.Position = UDim2.new(f, 0, 0.5, 0)
			if os.clock() - heldAt > 0.25 then
				heldAt = os.clock()
				local ranges = Net.buffered(tv:GetAttribute("FrameLabVideo"))
				for i, rg in ipairs(ranges) do
					local b = heldBars[i]
					if not b then
						b = Instance.new("Frame")
						b.BackgroundColor3 = WHITE
						b.BackgroundTransparency = 0.45
						b.BorderSizePixel = 0
						b.Parent = held
						heldBars[i] = b
					end
					b.Visible = true
					b.Position = UDim2.fromScale(rg[1], 0)
					b.Size = UDim2.fromScale(rg[2] - rg[1], 1)
				end
				for i = #ranges + 1, #heldBars do
					heldBars[i].Visible = false
				end
			end
			timeLabel.Text = clock(shown) .. " / " .. clock(d)
			local isPlaying = playing()
			playBtn.Text = isPlaying and "II" or ">"
			local sp = tv:GetAttribute("FrameLabSpeed") or 1
			for v, b in pairs(speedBtns) do
				local on = math.abs(v - sp) < 0.01
				b.BackgroundColor3 = on and RED or Color3.fromRGB(28, 28, 28)
			end
			local ctl = canControl()
			for _, b in ipairs({ playBtn, backBtn, fwdBtn }) do
				b.TextTransparency = ctl and 0 or 0.55
			end
			for _, b in pairs(speedBtns) do
				b.TextTransparency = ctl and 0 or 0.55
			end
			if not ctl then
				note.Text = ("Only %s can pause, seek or change the speed of this TV"):format(tv:GetAttribute("OwnerName") or "its owner")
			else
				note.Text = ""
			end
			-- the mouse over the seek bar: a preview of where a click goes
			local m = UIS:GetMouseLocation() -- screen pixels, like this ScreenGui's (IgnoreGuiInset)
			local mx, my = m.X, m.Y
			local hp, hs = hit.AbsolutePosition, hit.AbsoluteSize
			local over = ctl and mx >= hp.X and mx <= hp.X + hs.X and my >= hp.Y - 6 and my <= hp.Y + hs.Y + 6
			track.Size = UDim2.new(1, 0, 0, (over or dragging == "seek") and 6 or 4)
			if (over or dragging == "seek") and d > 0 then
				local hf = dragging == "seek" and f or fracOf(track, mx)
				hover.Visible = true
				hover.Size = UDim2.new(hf, 0, 1, 0)
				tip.Visible = true
				tip.Position = UDim2.new(hf, 0, 0, -8)
				tip.Text = clock(hf * d)
			else
				hover.Visible = false
				tip.Visible = false
			end
			-- volume
			local vol = tvMuted[tv] and 0 or volume()
			volFill.Size = UDim2.new(vol, 0, 1, 0)
			volBtn.Text = (vol <= 0) and "Muted" or "Vol"
			if Attach then
				local h = Attach.get(tv)
				if h then
					local base = tv:GetAttribute("AudioLabVolume") or 1
					local gain = base * vol
					if h ~= lastHandle or gain ~= lastGain then
						pcall(h.setVolume, h, gain)
						lastHandle, lastGain = h, gain
					end
				end
			end
			-- auto-hide
			local show = not isPlaying or dragging ~= nil or over or os.clock() - lastMove < IDLE
			-- a quick fade in when the mouse moves, a slow fade out when it rests
			local tNow = os.clock()
			local dt = math.min(tNow - lastUpdate, 0.1)
			lastUpdate = tNow
			if show then
				shownAmount = math.min(1, shownAmount + dt / FADE_IN)
			else
				shownAmount = math.max(0, shownAmount - dt / FADE_OUT)
			end
			local eased = shownAmount * shownAmount * (3 - 2 * shownAmount)
			panel.GroupTransparency = 1 - eased
			panel.Visible = shownAmount > 0
		end
		return { update = update }
	end

	local function watch(tv)
		if watching == tv then
			-- clicking the picture while watching: play / pause, like a video site (Leave or moving ends watching)
			if watchToggle then
				watchToggle()
			end
			return
		end
		stopWatching()
		local screen = tv:FindFirstChild("Screen")
		if not screen then
			return
		end
		watching = tv
		closePicker()
		-- the player's own music pauses while they watch (and picks up again when they leave)
		if Library then
			pausedMusic = Library.pauseAll()
		end
		-- no prompts ("Change video") over the picture while watching
		if pendingWas ~= nil then
			promptsWere, pendingWas = pendingWas, nil
		else
			promptsWere = PromptService.Enabled
		end
		PromptService.Enabled = false
		local cam = workspace.CurrentCamera
		local from = cam.CFrame
		cam.CameraType = Enum.CameraType.Scriptable
		local t0 = os.clock()
		watchConn = RunService.RenderStepped:Connect(function()
			local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if not tv:IsDescendantOf(folder) or not screen.Parent or not hum or hum.Health <= 0 or hum.MoveDirection.Magnitude > 0.1
				or hum.Jump then
				stopWatching()
				return
			end
			-- frame the TV's own screen (the picture fits inside it), as big as the view allows
			local size = screen:GetAttribute("BaseSize")
			local offset = screen:GetAttribute("BaseOffset")
			local base = (typeof(offset) == "CFrame") and (tv:GetPivot() * offset) or screen.CFrame
			size = typeof(size) == "Vector3" and size or screen.Size
			local vp = cam.ViewportSize
			local tanV = math.tan(math.rad(cam.FieldOfView) / 2)
			local d = math.max(size.Y / 2 / tanV, size.X / 2 / (tanV * vp.X / math.max(vp.Y, 1))) * 1.06 + size.Z / 2
			local goal = CFrame.lookAt((base * CFrame.new(0, 0, -d)).Position, base.Position, base.UpVector)
			local a = math.min(1, (os.clock() - t0) / 0.5)
			cam.CFrame = from:Lerp(goal, 1 - (1 - a) ^ 3)
		end)
		watchGui = Instance.new("ScreenGui")
		watchGui.Name = "FrameLabTVWatch"
		watchGui.ResetOnSpawn = false
		watchGui.DisplayOrder = 15
		watchGui.IgnoreGuiInset = true
		local controls = buildControls(tv, watchGui)
		watchGui.Parent = playerGui
		hideGui()
		local update = controls.update
		local inner = watchConn
		watchConn = RunService.RenderStepped:Connect(function(dt)
			update(dt)
		end)
		table.insert(watchConns, inner)
	end
	player.CharacterAdded:Connect(stopWatching)

	-- the TV tool's hint goes once no TV tool is in hand (the tool's own script can be gone before it clears it)
	task.spawn(function()
		while true do
			task.wait(0.5)
			local hint = playerGui:FindFirstChild("FrameLabTVHint")
			if hint then
				local tool = player.Character and player.Character:FindFirstChildOfClass("Tool")
				if not (tool and tool:GetAttribute("FrameLabTV")) then
					hint:Destroy()
				end
			end
		end
	end)

	local function hook(tv)
		local detector = tv:FindFirstChild("Watch", true)
		if detector and detector:IsA("ClickDetector") then
			detector.MouseClick:Connect(function(who)
				if who == player then
					watch(tv)
				end
			end)
		end
		local prompt = tv:FindFirstChild("Change", true)
		if prompt and prompt:IsA("ProximityPrompt") then
			-- only the owner sees the prompt (a client-side change)
			prompt.Enabled = tv:GetAttribute("FrameLabOwner") == player.UserId
			prompt.Triggered:Connect(function(who)
				if picker and picker:GetAttribute("TV") == tv.Name then
					return -- already open: keep what's typed in it
				end
				if who == player and tv:GetAttribute("FrameLabOwner") == player.UserId then
					openPicker(tv)
				end
			end)
		end
		tv.AncestryChanged:Connect(function()
			if not tv:IsDescendantOf(folder) and picker and picker:GetAttribute("TV") == tv.Name then
				closePicker()
			end
		end)
	end
	for _, tv in ipairs(folder:GetChildren()) do
		hook(tv)
	end
	folder.ChildAdded:Connect(hook)

end
