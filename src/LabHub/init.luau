-- LabHub: the whole package, modules only. Put this ModuleScript in ReplicatedStorage and start it once on each side:
--
--   ServerScriptService > Script:          require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub")).start()
--   StarterPlayerScripts > LocalScript:    require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub")).start()
--
-- What's inside:
--   LabHub.FrameLab    pictures, video, TVs and sprays (no EditableImage)
--   LabHub.AudioLab    MIDI / SoundFont / WAV / MP3 ... rebuilt from generic uploaded waveforms
--   LabHub.VideoLab    video with sound from one file
--   LabHub.Config      every setting (attributes on the FrameLab module; the in-game Settings panel saves them)
--   LabHub.Instancer   builds instances from Luau descriptions; LabHub.Blueprints: the tools and the TV it builds
--   LabHub.DevKit      Studio command bar: bundled media list, shipping check
--
-- The menu: one "Labs" button at the bottom left (higher up on touch screens, clear of the thumbstick) that opens a list of every Lab panel (AudioLab's music player, FrameLab's
-- data manager and settings, ...). Client only.
--
--   local handle = LabHub.add({
--       id = "music", label = "Music", order = 1,
--       toggle = someGuiObject,            -- shown while the item is selected (or)
--       action = function() ... end,       -- run when picked (one click)
--       available = function() return true end, -- optional, may yield (an admin check): hidden while false
--   })
--   handle.close()   -- deselect a toggle item (its window's own Close button)
--   handle.opened()  -- an action item tells the hub its window opened (the others close)
--   item.closeWindow = function() end  -- action items: how the hub closes their window
--   LabHub.closeAll(exceptId)          -- one Lab window at a time: any other panel can call this too

local LabHub = {}

local Players = game:GetService("Players")

local items = {}
local shown = {} -- id -> true while available
local rebuildQueued = false
local menu

local function visibleItems()
	local list = {}
	for _, it in ipairs(items) do
		if shown[it.id] then
			table.insert(list, it)
		end
	end
	table.sort(list, function(a, b)
		return (a.order or 50) < (b.order or 50)
	end)
	return list
end

-- the "Labs" button (with the HubIcon picture when the setting has one) and its menu of item buttons
local function buildMenu(list)
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	if not menu then
		local sg = Instance.new("ScreenGui")
		sg.Name = "LabHub"
		sg.ResetOnSpawn = false
		sg.DisplayOrder = 40
		sg.IgnoreGuiInset = true
		local okC, Config = pcall(require, script:FindFirstChild("Config"))
		local img = okC and type(Config) == "table" and Config.HubIcon
		local hasImg = type(img) == "string" and img ~= ""
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0, hasImg and 84 or 64, 0, 32)
		-- bottom left; on touch screens above the thumbstick area
		local UIS = game:GetService("UserInputService")
		local touch = UIS.TouchEnabled and not UIS.KeyboardEnabled
		b.AnchorPoint = Vector2.new(0, 1)
		b.Position = touch and UDim2.new(0, 12, 0.55, 0) or UDim2.new(0, 12, 1, -12)
		b.BackgroundColor3 = Color3.fromRGB(20, 23, 30)
		b.BackgroundTransparency = 0.15
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 14
		b.Text = "Labs"
		b.TextXAlignment = hasImg and Enum.TextXAlignment.Right or Enum.TextXAlignment.Center
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = b
		if hasImg then
			local pad = Instance.new("UIPadding")
			pad.PaddingRight = UDim.new(0, 12)
			pad.Parent = b
			local icon = Instance.new("ImageLabel")
			icon.Size = UDim2.new(0, 22, 0, 22)
			icon.Position = UDim2.new(0, 7, 0.5, -11)
			icon.BackgroundTransparency = 1
			icon.Image = img
			icon.Parent = b
		end
		b.Parent = sg
		local list = Instance.new("Frame")
		list.AnchorPoint = Vector2.new(0, 1) -- opens upward, just above the button
		list.Position = b.Position + UDim2.new(0, 0, 0, -38)
		list.Size = UDim2.new(0, 150, 0, 0)
		list.AutomaticSize = Enum.AutomaticSize.Y
		list.BackgroundTransparency = 1
		list.Visible = false
		list.Parent = sg
		local l = Instance.new("UIListLayout")
		l.Padding = UDim.new(0, 4)
		l.SortOrder = Enum.SortOrder.LayoutOrder
		l.Parent = list
		b.Activated:Connect(function()
			list.Visible = not list.Visible
		end)
		sg.Parent = pg
		menu = { gui = sg, list = list }
	end
	for _, c in ipairs(menu.list:GetChildren()) do
		if c:IsA("TextButton") then
			c:Destroy()
		end
	end
	for i, it in ipairs(list) do
		local b = Instance.new("TextButton")
		b.LayoutOrder = i
		b.Size = UDim2.new(1, 0, 0, 30)
		b.BackgroundColor3 = Color3.fromRGB(28, 32, 41)
		b.TextColor3 = Color3.fromRGB(230, 233, 240)
		b.Font = Enum.Font.GothamMedium
		b.TextSize = 13
		b.Text = it.label
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = b
		b.Parent = menu.list
		b.Activated:Connect(function()
			menu.list.Visible = false
			if it.toggle then
				it.toggle.Visible = not it.toggle.Visible
			elseif it.action then
				task.spawn(it.action)
			end
		end)
		it.close = function()
			if it.toggle then
				it.toggle.Visible = false
			elseif it.closeWindow then
				it.closeWindow()
			end
		end
		if it.toggle then
			it.toggle.Visible = false
		end
	end
end

local function queue()
	if not rebuildQueued then
		rebuildQueued = true
		task.delay(0.2, function()
			rebuildQueued = false
			buildMenu(visibleItems())
		end)
	end
end

-- one Lab window at a time
function LabHub.closeAll(exceptId)
	for _, it in ipairs(items) do
		if it.id ~= exceptId then
			local isOpen = (it.toggle and it.toggle.Visible) or (it.isOpen and it.isOpen())
			if isOpen then
				if it.close then
					pcall(it.close)
				elseif it.toggle then
					it.toggle.Visible = false
				elseif it.closeWindow then
					pcall(it.closeWindow)
				end
			end
		end
	end
end

function LabHub.add(item)
	assert(type(item) == "table" and item.id and item.label, "LabHub.add: id and label")
	if item.toggle then
		item.toggle:GetPropertyChangedSignal("Visible"):Connect(function()
			if item.toggle.Visible then
				LabHub.closeAll(item.id)
			end
		end)
	end
	for i, it in ipairs(items) do
		if it.id == item.id then
			table.remove(items, i)
			break
		end
	end
	table.insert(items, item)
	local handle = {}
	function handle.opened()
		LabHub.closeAll(item.id)
	end
	function handle.close()
		if item.close then
			item.close()
		elseif item.toggle then
			item.toggle.Visible = false
		end
	end
	if item.available then
		task.spawn(function()
			local ok, yes = pcall(item.available)
			shown[item.id] = ok and yes == true or nil
			queue()
		end)
	else
		shown[item.id] = true
		queue()
	end
	return handle
end

-- start AudioLab and FrameLab on this side (once): on the server their Runtime/Server modules, on a client their
-- Runtime/Client modules
local started = false
function LabHub.start()
	if started then
		return LabHub
	end
	started = true
	require(script:WaitForChild("AudioLab")).init()
	require(script:WaitForChild("FrameLab")).init()
	return LabHub
end

-- the parts of this package: LabHub.FrameLab, LabHub.AudioLab, LabHub.VideoLab, LabHub.Config, LabHub.Instancer, ...
local PARTS = { FrameLab = true, AudioLab = true, VideoLab = true, Config = true, DevKit = true, Instancer = true, Blueprints = true }
setmetatable(LabHub, {
	__index = function(_, key)
		if PARTS[key] then
			local m = script:FindFirstChild(key)
			return m and require(m)
		end
		return nil
	end,
})

return LabHub
