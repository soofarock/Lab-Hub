-- Started by FrameLab:init() on a client: the settings panel (the game's owner; anyone in a Studio test), in the Labs
-- menu (LabHub). Every FrameLab and AudioLab setting: switches, choices, numbers and text. A change applies at once;
-- Save keeps them all (a DataStore) and every server starts with them, over the place's own values.
return function(FrameLab)
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local root = script:FindFirstAncestor("FrameLab")
	local Net = require(root.Tools.Net)

	local C = {
		bg = Color3.fromRGB(20, 23, 30), panel = Color3.fromRGB(28, 32, 41), row = Color3.fromRGB(34, 38, 48),
		text = Color3.fromRGB(230, 233, 240), dim = Color3.fromRGB(150, 158, 175), on = Color3.fromRGB(50, 120, 80),
		blue = Color3.fromRGB(50, 90, 160), red = Color3.fromRGB(160, 60, 60),
	}
	local openChoices -- (below)
	local openPeople -- (below)
	local function make(class, props, parent)
		local o = Instance.new(class)
		for k, v in pairs(props) do
			o[k] = v
		end
		if class == "TextButton" or class == "TextBox" then
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, 6)
			c.Parent = o
		end
		o.Parent = parent
		return o
	end
	local function btn(parent, text, w, color)
		return make("TextButton", {
			Size = UDim2.new(0, w, 0, 24), BackgroundColor3 = color or C.row, TextColor3 = C.text, Text = text,
			Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = true,
		}, parent)
	end

	-- the window (hidden until picked in the Labs menu)
	local gui = make("ScreenGui", { Name = "LabSettings", ResetOnSpawn = false, DisplayOrder = 30 }, playerGui)
	local win = make("Frame", {
		Size = UDim2.new(0, 560, 0, 500), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = C.bg, Visible = false,
	}, gui)
	local wc = Instance.new("UICorner")
	wc.CornerRadius = UDim.new(0, 12)
	wc.Parent = win
	local pad = Instance.new("UIPadding")
	for _, k in ipairs({ "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" }) do
		pad[k] = UDim.new(0, 12)
	end
	pad.Parent = win
	make("TextLabel", {
		Size = UDim2.new(1, -320, 0, 24), BackgroundTransparency = 1, Text = "Settings", TextColor3 = C.text,
		Font = Enum.Font.GothamBold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left,
	}, win)
	local closeB = btn(win, "Close", 60)
	closeB.Position = UDim2.new(1, -60, 0, 0)
	local saveB = btn(win, "Save", 60, C.blue)
	saveB.Position = UDim2.new(1, -126, 0, 0)
	local clearB = btn(win, "Clear saved", 90, C.red)
	clearB.Position = UDim2.new(1, -222, 0, 0)
	-- the TV and Spray Paint tools for you, whatever the access settings say
	local toolsB = btn(win, "Get tools", 76, C.on)
	toolsB.Position = UDim2.new(1, -304, 0, 0)
	local status = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 30), Position = UDim2.new(0, 0, 0, 28), BackgroundTransparency = 1, Text = "",
		TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 11, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
	}, win)
	local list = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, -64), Position = UDim2.new(0, 0, 0, 64), BackgroundColor3 = C.panel, BorderSizePixel = 0,
		ScrollBarThickness = 4, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
	}, win)
	make("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	local lp = Instance.new("UIPadding")
	lp.PaddingTop, lp.PaddingLeft, lp.PaddingRight, lp.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 10), UDim.new(0, 6)
	lp.Parent = list

	local function say(text)
		status.Text = text
	end

	-- the open dropdown list (one at a time; closes on a pick or a click elsewhere in the window)
	local choiceList
	local function closeChoices()
		if choiceList then
			choiceList:Destroy()
			choiceList = nil
		end
	end
	local set -- (below)
	function openChoices(anchor, it)
		local wasFor = choiceList and choiceList:GetAttribute("For")
		closeChoices()
		if wasFor == it.folder .. "." .. it.key then
			return -- (a second click closes it)
		end
		local a, s = anchor.AbsolutePosition - win.AbsolutePosition, anchor.AbsoluteSize
		choiceList = make("Frame", {
			Position = UDim2.fromOffset(a.X - 12, a.Y + s.Y + 2 - 12), Size = UDim2.fromOffset(s.X, #it.choices * 26 + 6),
			BackgroundColor3 = C.bg, BorderSizePixel = 0, ZIndex = 20,
		}, win)
		choiceList:SetAttribute("For", it.folder .. "." .. it.key)
		local st = Instance.new("UIStroke")
		st.Color = Color3.fromRGB(70, 78, 96)
		st.Parent = choiceList
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, 6)
		cc.Parent = choiceList
		for i, v in ipairs(it.choices) do
			local b = btn(choiceList, tostring(v), s.X - 6, v == it.value and C.on or C.row)
			b.Position = UDim2.fromOffset(3, 3 + (i - 1) * 26)
			b.ZIndex = 21
			b.Activated:Connect(function()
				closeChoices()
				if v ~= it.value then
					set(it, v)
				end
			end)
		end
	end
	list:GetPropertyChangedSignal("CanvasPosition"):Connect(closeChoices)

	-- a list of people (Admins, ToolAccessList): who is on it (name and UserId), remove with x, add with + by name or
	-- UserId or from the players in this server; each kept as a UserId (survives name changes) or a username
	local peopleView
	local saveAsId = true
	function openPeople(it)
		closeChoices()
		if peopleView then
			peopleView:Destroy()
		end
		local v = make("Frame", {
			Size = UDim2.new(1, 0, 1, -64), Position = UDim2.new(0, 0, 0, 64), BackgroundColor3 = C.panel, ZIndex = 10,
			BorderSizePixel = 0,
		}, win)
		peopleView = v
		local title = make("TextLabel", {
			Size = UDim2.new(1, -90, 0, 26), Position = UDim2.new(0, 8, 0, 4), BackgroundTransparency = 1,
			Text = it.key == "Admins" and "Admins (import, Data, URL pictures)" or (it.key .. " (who gets tools set to \"list\")"),
			TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 11,
		}, v)
		local done = btn(v, "Done", 70, C.blue)
		done.Position = UDim2.new(1, -78, 0, 4)
		done.ZIndex = 11
		done.Activated:Connect(function()
			v:Destroy()
			peopleView = nil
			task.spawn(refresh)
		end)
		-- add row: name / UserId box, players here, save as, add
		local box = make("TextBox", {
			Size = UDim2.new(0, 170, 0, 26), Position = UDim2.new(0, 8, 0, 36), BackgroundColor3 = C.row, TextColor3 = C.text,
			PlaceholderText = "username or UserId", PlaceholderColor3 = C.dim, Text = "", Font = Enum.Font.Gotham, TextSize = 12,
			ClearTextOnFocus = false, ZIndex = 11,
		}, v)
		local here = btn(v, "Players here  v", 110, C.row)
		here.Position = UDim2.new(0, 184, 0, 37)
		here.ZIndex = 11
		local asB = btn(v, "", 120, C.row)
		asB.Position = UDim2.new(0, 300, 0, 37)
		asB.ZIndex = 11
		local function showAs()
			asB.Text = saveAsId and "Save as: UserId" or "Save as: Username"
		end
		showAs()
		asB.Activated:Connect(function()
			saveAsId = not saveAsId
			showAs()
		end)
		local add = btn(v, "+ Add", 64, C.on)
		add.Position = UDim2.new(0, 426, 0, 37)
		add.ZIndex = 11
		local note = make("TextLabel", {
			Size = UDim2.new(1, -16, 0, 16), Position = UDim2.new(0, 8, 0, 66), BackgroundTransparency = 1,
			Text = "A UserId keeps working when someone changes their name.", TextColor3 = C.dim, Font = Enum.Font.Gotham,
			TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 11,
		}, v)
		local rows = make("ScrollingFrame", {
			Size = UDim2.new(1, -16, 1, -94), Position = UDim2.new(0, 8, 0, 88), BackgroundTransparency = 1, BorderSizePixel = 0,
			ScrollBarThickness = 4, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ZIndex = 11,
		}, v)
		make("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, rows)

		local current = tostring(it.value)
		local function entries()
			local list = {}
			for e in string.gmatch(current, "[^,%s]+") do
				table.insert(list, e)
			end
			return list
		end
		local function store(list)
			current = table.concat(list, ", ")
			local ok, r = pcall(Net.invoke, "settingsSet", it.folder, it.key, current)
			if ok and type(r) == "table" and r.ok then
				it.value = current
				say(it.key .. " changed (applied; Save to keep it)")
			else
				say("couldn't change " .. it.key)
			end
		end
		local draw
		function draw()
			for _, c in ipairs(rows:GetChildren()) do
				if c:IsA("Frame") then
					c:Destroy()
				end
			end
			local okP, data = pcall(Net.invoke, "settingsPeople", it.folder, it.key)
			if not okP or type(data) ~= "table" then
				return
			end
			if #data.entries == 0 then
				local r = make("Frame", { Size = UDim2.new(1, -6, 0, 28), BackgroundTransparency = 1, ZIndex = 11 }, rows)
				make("TextLabel", {
					Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "nobody yet", TextColor3 = C.dim,
					Font = Enum.Font.Gotham, TextSize = 12, ZIndex = 12,
				}, r)
			end
			for i, e in ipairs(data.entries) do
				local r = make("Frame", { Size = UDim2.new(1, -6, 0, 30), BackgroundColor3 = C.row, LayoutOrder = i, ZIndex = 11 }, rows)
				local rc = Instance.new("UICorner")
				rc.CornerRadius = UDim.new(0, 6)
				rc.Parent = r
				local label = e.name and (e.userId and ("%s  (%d)"):format(e.name, e.userId) or e.name) or ("UserId " .. e.entry .. " (not found)")
				if not e.byId and not e.userId then
					label = e.entry .. "  (no such user)"
				end
				make("TextLabel", {
					Size = UDim2.new(1, -150, 1, 0), Position = UDim2.new(0, 8, 0, 0), BackgroundTransparency = 1, Text = label,
					TextColor3 = C.text, Font = Enum.Font.GothamMedium, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 12,
				}, r)
				make("TextLabel", {
					Size = UDim2.new(0, 100, 1, 0), Position = UDim2.new(1, -140, 0, 0), BackgroundTransparency = 1,
					Text = e.byId and "saved as UserId" or "saved as name", TextColor3 = C.dim, Font = Enum.Font.Gotham,
					TextSize = 11, ZIndex = 12,
				}, r)
				local x = btn(r, "x", 26, C.red)
				x.AnchorPoint = Vector2.new(1, 0.5)
				x.Position = UDim2.new(1, -4, 0.5, 0)
				x.ZIndex = 12
				x.Activated:Connect(function()
					local list = entries()
					local idx = table.find(list, e.entry)
					if idx then
						table.remove(list, idx)
						store(list)
						draw()
					end
				end)
			end
		end
		local function addPerson(text)
			if text == "" then
				return
			end
			note.Text = "looking up " .. text .. "..."
			local okR, who = pcall(Net.invoke, "settingsResolve", text)
			if not okR or type(who) ~= "table" or who.error then
				note.Text = type(who) == "table" and who.error or "couldn't look that up"
				return
			end
			local token = saveAsId and tostring(who.userId) or who.name
			local list = entries()
			for _, e in ipairs(list) do
				if e == token or e == tostring(who.userId) or string.lower(e) == string.lower(who.name) then
					note.Text = who.name .. " is already on the list"
					return
				end
			end
			table.insert(list, token)
			store(list)
			box.Text = ""
			note.Text = ("added %s (%d)"):format(who.name, who.userId)
			draw()
		end
		add.Activated:Connect(function()
			addPerson(box.Text)
		end)
		box.FocusLost:Connect(function(enter)
			if enter then
				addPerson(box.Text)
			end
		end)
		-- players in this server, to pick from
		local pick
		here.Activated:Connect(function()
			if pick then
				pick:Destroy()
				pick = nil
				return
			end
			local okP, data = pcall(Net.invoke, "settingsPeople", it.folder, it.key)
			local online = okP and type(data) == "table" and data.online or {}
			pick = make("ScrollingFrame", {
				Size = UDim2.fromOffset(200, math.min(#online, 8) * 28 + 8), Position = UDim2.new(0, 184, 0, 66),
				BackgroundColor3 = C.bg, BorderSizePixel = 0, ScrollBarThickness = 4, ZIndex = 30,
				AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
			}, v)
			make("UIListLayout", { Padding = UDim.new(0, 2) }, pick)
			for _, p in ipairs(online) do
				local b = btn(pick, (p.display ~= p.name) and ("%s (@%s)"):format(p.display, p.name) or p.name, 194, C.row)
				b.ZIndex = 31
				b.Activated:Connect(function()
					pick:Destroy()
					pick = nil
					addPerson(tostring(p.userId))
				end)
			end
		end)
		task.spawn(draw)
	end

	local refresh
	function set(it, value)
		local ok, r = pcall(Net.invoke, "settingsSet", it.folder, it.key, value)
		if not ok or type(r) ~= "table" then
			say("couldn't change " .. it.key)
		elseif r.error then
			say(it.key .. ": " .. r.error)
		else
			say(("%s is now %s (applied; Save to keep it)"):format(it.key, tostring(r.value)))
		end
		task.spawn(refresh)
	end

	function refresh()
		local ok, data = pcall(Net.invoke, "settingsGet")
		if not ok or type(data) ~= "table" then
			say("only the game's owner can change settings")
			return
		end
		local head = data.store and (data.hasSaved and "Saved settings are applied on every server." or "Nothing saved yet: the place's own values are used.")
			or ("No DataStore (" .. tostring(data.storeError) .. "): changes last for this server only.")
		say(head .. " Changes apply at once; Save keeps them.")
		local canvasY = list.CanvasPosition.Y
		for _, c in ipairs(list:GetChildren()) do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		local lastFolder
		local order = 0
		for _, it in ipairs(data.items) do
			if it.folder ~= lastFolder then
				lastFolder = it.folder
				order += 1
				local hdr = make("Frame", { Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, LayoutOrder = order }, list)
				make("TextLabel", {
					Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = string.upper(it.folder), TextColor3 = C.dim,
					Font = Enum.Font.GothamBold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
				}, hdr)
			end
			order += 1
			local row = make("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = C.row, LayoutOrder = order }, list)
			local rc = Instance.new("UICorner")
			rc.CornerRadius = UDim.new(0, 6)
			rc.Parent = row
			local isDefault = it.value == it.default
			make("TextLabel", {
				Size = UDim2.new(0.5, -8, 1, 0), Position = UDim2.new(0, 8, 0, 0), BackgroundTransparency = 1,
				Text = it.key .. (isDefault and "" or "  *"), TextColor3 = C.text, Font = Enum.Font.GothamMedium, TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
			}, row)
			local ctl
			if it.kind == "people" then
				local n = 0
				for _ in string.gmatch(tostring(it.value), "[^,%s]+") do
					n += 1
				end
				ctl = btn(row, (n == 1 and "1 person" or (n .. " people")) .. "  -  Edit", 140, C.panel)
				ctl.Activated:Connect(function()
					openPeople(it)
				end)
			elseif it.kind == "boolean" then
				ctl = btn(row, it.value and "On" or "Off", 70, it.value and C.on or C.panel)
				ctl.Activated:Connect(function()
					set(it, not it.value)
				end)
			elseif it.choices then
				-- a dropdown: the value and an arrow; the choices open in a list under it
				ctl = btn(row, tostring(it.value) .. "  v", 120, C.panel)
				ctl.Activated:Connect(function()
					openChoices(ctl, it)
				end)
			else
				ctl = make("TextBox", {
					Size = UDim2.new(0, it.kind == "number" and 90 or 220, 0, 24), BackgroundColor3 = C.panel, TextColor3 = C.text,
					Text = tostring(it.value), Font = Enum.Font.Code, TextSize = 12, ClearTextOnFocus = false,
					TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
				}, row)
				ctl.FocusLost:Connect(function(enter)
					local v = ctl.Text
					if it.kind == "number" then
						v = tonumber(v)
						if not v then
							say(it.key .. " takes a number")
							ctl.Text = tostring(it.value)
							return
						end
					end
					if v ~= it.value then
						set(it, v)
					end
				end)
			end
			ctl.AnchorPoint = Vector2.new(1, 0.5)
			ctl.Position = UDim2.new(1, -60, 0.5, 0)
			local def = btn(row, "Default", 52, C.panel)
			def.TextSize = 10
			def.AnchorPoint = Vector2.new(1, 0.5)
			def.Position = UDim2.new(1, -4, 0.5, 0)
			def.Visible = not isDefault
			def.Activated:Connect(function()
				pcall(Net.invoke, "settingsDefault", it.folder, it.key)
				say(it.key .. " is back to its default (Save to keep it)")
				task.spawn(refresh)
			end)
		end
		list.CanvasPosition = Vector2.new(0, canvasY)
	end

	toolsB.Activated:Connect(function()
		local ok, r = pcall(Net.invoke, "toolsGive")
		if ok and type(r) == "table" and r.ok then
			say("The TV and Spray Paint tools are in your backpack.")
		else
			say(type(r) == "table" and r.error or "couldn't give the tools")
		end
	end)
	saveB.Activated:Connect(function()
		say("saving...")
		local ok, r = pcall(Net.invoke, "settingsSave")
		if ok and type(r) == "table" and r.ok then
			say("Saved: every server starts with these settings.")
		else
			say(type(r) == "table" and r.error or "couldn't save")
		end
	end)
	local clearArmed = false
	clearB.Activated:Connect(function()
		if not clearArmed then
			clearArmed = true
			clearB.Text = "Sure?"
			task.delay(3, function()
				clearArmed = false
				clearB.Text = "Clear saved"
			end)
			return
		end
		local ok, r = pcall(Net.invoke, "settingsClear")
		if ok and type(r) == "table" and r.ok then
			say("Saved settings cleared: the next server uses the place's own values.")
		else
			say(type(r) == "table" and r.error or "couldn't clear")
		end
	end)

	win:GetPropertyChangedSignal("Visible"):Connect(function()
		closeChoices()
		if peopleView then
			peopleView:Destroy()
			peopleView = nil
		end
		if win.Visible then
			task.spawn(refresh)
		end
	end)

	local hubOk, LabHub = pcall(function()
		return require(ReplicatedStorage:WaitForChild("LabHub", 5))
	end)
	if hubOk and LabHub then
		local hub = LabHub.add({
			id = "settings", label = "Settings", order = 90, toggle = win,
			-- asks again (a few times) while the server gives no answer: a request can go unanswered while the
			-- server is still starting, or be dropped when a player sends many at once
			available = function()
				for attempt = 1, 6 do
					local ok, d = pcall(Net.invoke, "settingsGet")
					if ok and type(d) == "table" then
						return d.owner == true
					end
					task.wait(attempt)
				end
				return false
			end,
		})
		closeB.Activated:Connect(function()
			hub.close()
		end)
	else
		closeB.Activated:Connect(function()
			win.Visible = false
		end)
	end
	FrameLab.openSettings = function()
		win.Visible = true
	end
end
