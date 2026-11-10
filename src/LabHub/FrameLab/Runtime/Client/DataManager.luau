-- Started by FrameLab:init() on a client: the data manager panel (admins). Opened from the TV picker's "Data" button
-- (FrameLab.openDataManager()). Lists this server's imports and the kept records (Runtime/Server/Library): thumbnail,
-- name, kind, quality, length, size, who imported it, whether it is in memory; Load (import again from its URL),
-- Delete, and the URL to copy. The header shows how much the server holds. Clients: each player's video memory
-- (FrameLab.Net.cacheUsage) against its limit (VideoCacheMB), with Clear for one player or everyone.
return function(FrameLab)
	local Players = game:GetService("Players")
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local root = script:FindFirstAncestor("FrameLab")
	local Net = require(root.Tools.Net)

	local C = {
		bg = Color3.fromRGB(20, 23, 30), panel = Color3.fromRGB(28, 32, 41), row = Color3.fromRGB(34, 38, 48),
		text = Color3.fromRGB(230, 233, 240), dim = Color3.fromRGB(150, 158, 175), red = Color3.fromRGB(200, 70, 70),
		green = Color3.fromRGB(90, 190, 120), amber = Color3.fromRGB(220, 170, 70),
	}
	local function make(class, props, parent)
		local o = Instance.new(class)
		for k, v in pairs(props) do
			if k ~= "Corner" then -- (ours: rounded corners, not a property)
				o[k] = v
			end
		end
		if class == "TextButton" or class == "TextBox" or (class == "Frame" and props.Corner) then
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
	local function mb(n)
		if not n then
			return "?"
		end
		if n >= 1048576 then
			return ("%.1f MB"):format(n / 1048576)
		end
		return ("%d KB"):format(math.floor(n / 1024 + 0.5))
	end
	local function clock(s)
		if not s then
			return ""
		end
		s = math.floor(s + 0.5)
		return ("%d:%02d"):format(s // 60, s % 60)
	end

	local gui
	local thumbCache = {}
	local function close()
		if gui then
			gui:Destroy()
			gui = nil
		end
	end

	-- a thumbnail (rgb, w x h from the server) into frame
	local function drawThumb(frame, id)
		task.spawn(function()
			local t = thumbCache[id]
			if not t then
				local ok, r = pcall(Net.invoke, "libThumb", id)
				if not ok or type(r) ~= "table" or typeof(r.rgb) ~= "buffer" then
					return
				end
				local data = buffer.create(r.w * r.h * 4)
				for i = 0, r.w * r.h - 1 do
					buffer.writeu8(data, i * 4, buffer.readu8(r.rgb, i * 3))
					buffer.writeu8(data, i * 4 + 1, buffer.readu8(r.rgb, i * 3 + 1))
					buffer.writeu8(data, i * 4 + 2, buffer.readu8(r.rgb, i * 3 + 2))
					buffer.writeu8(data, i * 4 + 3, 255)
				end
				t = { width = r.w, height = r.h, data = data }
				thumbCache[id] = t
			end
			if not frame.Parent then
				return
			end
			local Blocks = require(root.Image.Blocks)
			if Blocks.ready() then
				Blocks.draw(Blocks.encode(t, { Threshold = 5 }), frame, {})
			else
				FrameLab.show(t, frame, { Tolerance = 8, Yield = false })
			end
		end)
	end

	local refresh
	local function open()
		close()
		gui = make("ScreenGui", { Name = "FrameLabDataManager", ResetOnSpawn = false, DisplayOrder = 30 }, playerGui)
		local panel = make("Frame", {
			Size = UDim2.new(0, 600, 0, 480), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = C.bg, Corner = true,
		}, gui)
		local pad = Instance.new("UIPadding")
		for _, k in ipairs({ "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" }) do
			pad[k] = UDim.new(0, 12)
		end
		pad.Parent = panel
		make("TextLabel", {
			Size = UDim2.new(1, -80, 0, 22), BackgroundTransparency = 1, Text = "Data manager", TextColor3 = C.text,
			Font = Enum.Font.GothamBold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left,
		}, panel)
		local closeBtn = btn(panel, "Close", 64)
		closeBtn.Position = UDim2.new(1, -64, 0, 0)
		closeBtn.Activated:Connect(close)
		-- the DataStore switch: keep records (URL + thumbnail) between servers. Off by default.
		local storeBtn = btn(panel, "DataStore: ...", 120)
		storeBtn.Position = UDim2.new(1, -194, 0, 0)
		local storeOn = false
		local function showStore(on)
			storeOn = on
			storeBtn.Text = on and "DataStore: On" or "DataStore: Off"
			storeBtn.BackgroundColor3 = on and Color3.fromRGB(50, 120, 80) or C.row
		end
		storeBtn.Activated:Connect(function()
			storeBtn.Text = "..."
			local ok, r = pcall(Net.invoke, "libSetStore", not storeOn)
			if ok and type(r) == "table" then
				showStore(r.on)
			else
				showStore(storeOn)
			end
			task.spawn(refresh)
		end)
		local view = "items" -- or "clients"
		local clientsBtn = btn(panel, "Clients", 72)
		clientsBtn.Position = UDim2.new(1, -272, 0, 0)
		clientsBtn.Activated:Connect(function()
			view = view == "items" and "clients" or "items"
			clientsBtn.Text = view == "clients" and "Imports" or "Clients"
			task.spawn(refresh)
		end)
		local stats = make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 0, 0, 26), BackgroundTransparency = 1, Text = "loading...",
			TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, panel)
		local urlBox = make("TextBox", {
			Size = UDim2.new(1, 0, 0, 24), Position = UDim2.new(1, 0, 1, 0), AnchorPoint = Vector2.new(1, 1),
			BackgroundColor3 = C.panel, TextColor3 = C.text, Text = "", PlaceholderText = "the URL of the item you click URL on (select it and copy)",
			PlaceholderColor3 = C.dim, Font = Enum.Font.Code, TextSize = 12, ClearTextOnFocus = false, TextEditable = false,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		}, panel)
		local list = make("ScrollingFrame", {
			Size = UDim2.new(1, 0, 1, -82), Position = UDim2.new(0, 0, 0, 50), BackgroundColor3 = C.panel, BorderSizePixel = 0,
			ScrollBarThickness = 4, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
		}, panel)
		make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, list)
		local lp = Instance.new("UIPadding")
		lp.PaddingTop, lp.PaddingLeft, lp.PaddingRight, lp.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 10), UDim.new(0, 6)
		lp.Parent = list

		local busy = false
		local function clearRows()
			for _, c in ipairs(list:GetChildren()) do
				if c:IsA("Frame") then
					c:Destroy()
				end
			end
		end
		local function refreshClients()
			local ok, rows = pcall(Net.invoke, "cacheList")
			if not gui or view ~= "clients" then
				return
			end
			if not ok or type(rows) ~= "table" then
				stats.Text = "only admins can see the clients"
				return
			end
			local total, full = 0, 0
			for _, r in ipairs(rows) do
				total += r.video
				if r.limit > 0 and r.video >= r.limit * 0.95 then
					full += 1
				end
			end
			stats.Text = ("%d players, %s of video in their memory%s"):format(#rows, mb(total), full > 0 and ("  -  %d at the limit"):format(full) or "")
			clearRows()
			local top = make("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = 0 }, list)
			local all = btn(top, "Clear all", 80, C.red)
			all.Activated:Connect(function()
				pcall(Net.invoke, "cacheClear", nil)
				task.delay(1, refresh)
			end)
			make("TextLabel", {
				Size = UDim2.new(1, -90, 1, 0), Position = UDim2.new(0, 90, 0, 0), BackgroundTransparency = 1,
				Text = "video each client keeps (VideoCacheMB); Clear drops its pictures and all video but what its screens show", TextColor3 = C.dim,
				Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
			}, top)
			for i, r in ipairs(rows) do
				local row = make("Frame", { Size = UDim2.new(1, 0, 0, 60), BackgroundColor3 = C.row, LayoutOrder = i, Corner = true }, list)
				make("TextLabel", {
					Size = UDim2.new(1, -90, 0, 18), Position = UDim2.new(0, 8, 0, 4), BackgroundTransparency = 1,
					Text = ("%s (@%s)"):format(r.display, r.name), TextColor3 = C.text, Font = Enum.Font.GothamMedium, TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
				}, row)
				local f = r.limit > 0 and math.clamp(r.video / r.limit, 0, 1) or 0
				local barBg = make("Frame", {
					Size = UDim2.new(0.5, 0, 0, 8), Position = UDim2.new(0, 8, 0, 28), BackgroundColor3 = C.panel, BorderSizePixel = 0,
				}, row)
				make("Frame", {
					Size = UDim2.fromScale(f, 1), BorderSizePixel = 0,
					BackgroundColor3 = f >= 0.95 and C.red or (f >= 0.8 and C.amber or C.green),
				}, barBg)
				make("TextLabel", {
					Size = UDim2.new(0.5, -100, 0, 14), Position = UDim2.new(0.5, 16, 0, 25), BackgroundTransparency = 1,
					Text = r.reported and ("%s of %s  -  %d video%s"):format(mb(r.video), mb(r.limit), r.streams, r.streams == 1 and "" or "s")
						or "nothing played yet",
					TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
				}, row)
				-- what else the client holds, and its whole memory
				make("TextLabel", {
					Size = UDim2.new(1, -90, 0, 14), Position = UDim2.new(0, 8, 0, 40), BackgroundTransparency = 1,
					Text = r.reported and ("pictures %s  -  sounds %s  -  memory %.0f MB (Luau %.0f MB)"):format(mb(r.pictures or 0),
						mb(r.sounds or 0), r.memory or 0, r.luau or 0) or "",
					TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
				}, row)
				local b = btn(row, "Clear", 64, C.red)
				b.AnchorPoint = Vector2.new(1, 0.5)
				b.Position = UDim2.new(1, -8, 0.5, 0)
				b.Activated:Connect(function()
					b.Text = "..."
					pcall(Net.invoke, "cacheClear", r.userId)
					task.delay(1, refresh)
				end)
			end
		end
		-- the client list follows the players while it is shown
		local thisGui = gui
		task.spawn(function()
			while gui == thisGui do
				task.wait(3)
				if gui == thisGui and view == "clients" then
					refreshClients()
				end
			end
		end)
		function refresh()
			if not gui then
				return
			end
			if view == "clients" then
				refreshClients()
				return
			end
			local okS, st = pcall(Net.invoke, "libStats")
			local okL, items = pcall(Net.invoke, "libList")
			if not gui or view ~= "items" then
				return
			end
			if not okL or type(items) ~= "table" then
				stats.Text = "only admins can open the data manager"
				return
			end
			if okS and type(st) == "table" then
				showStore(st.records == true)
				local recs = st.records and (st.storeError and ("DataStore error: " .. st.storeError) or "records kept in the DataStore")
					or (st.storeError and ("DataStore unavailable: " .. st.storeError) or "records in this server only (DataStore off)")
				stats.Text = ("%d items in this server's memory, %s  -  %s"):format(st.entries, mb(st.bytes), recs)
			end
			clearRows()
			if #items == 0 then
				make("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1 }, list)
				make("TextLabel", {
					Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, Text = "nothing imported yet", TextColor3 = C.dim,
					Font = Enum.Font.Gotham, TextSize = 12,
				}, list:FindFirstChildOfClass("Frame"))
			end
			for i, it in ipairs(items) do
				local row = make("Frame", { Size = UDim2.new(1, 0, 0, 64), BackgroundColor3 = C.row, LayoutOrder = i, Corner = true }, list)
				local thumb = make("Frame", {
					Size = UDim2.new(0, 96, 0, 56), Position = UDim2.new(0, 4, 0, 4), BackgroundColor3 = Color3.new(0, 0, 0),
					BorderSizePixel = 0, ClipsDescendants = true,
				}, row)
				local audio = it.kind == "sound" or it.kind == "music"
				if it.thumb then
					drawThumb(thumb, it.id)
				elseif audio then
					thumb.BackgroundColor3 = it.kind == "music" and Color3.fromRGB(60, 40, 90) or Color3.fromRGB(30, 60, 80)
					make("TextLabel", {
						Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = it.kind == "music" and "MUSIC" or "SOUND",
						TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 13,
					}, thumb)
				end
				local name = tostring(it.name or "?"):gsub("^imported/", "")
				make("TextLabel", {
					Size = UDim2.new(1, -330, 0, 20), Position = UDim2.new(0, 108, 0, 6), BackgroundTransparency = 1, Text = name,
					TextColor3 = C.text, Font = Enum.Font.GothamMedium, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
				}, row)
				local info = { it.kind == "image" and "picture" or (audio and (it.kind == "music" and "AudioLab music" or "AudioLab sound")) or (it.stream and "stream" or "video") }
				if it.detail then
					table.insert(info, it.detail)
				end
				if it.quality then
					table.insert(info, it.quality)
				end
				if it.width and it.height then
					table.insert(info, it.width .. "x" .. it.height)
				end
				if it.seconds then
					table.insert(info, clock(it.seconds))
				end
				table.insert(info, mb(it.bytes))
				if it.by then
					table.insert(info, "by " .. it.by)
				end
				make("TextLabel", {
					Size = UDim2.new(1, -330, 0, 16), Position = UDim2.new(0, 108, 0, 26), BackgroundTransparency = 1,
					Text = table.concat(info, "  -  "), TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
				}, row)
				local status = it.loaded and (it.stream and "streaming: the parts being watched are held (this server only)"
					or (it.kept and "in memory, kept" or "in memory (this server only)"))
					or (audio and "kept, not loaded (import it again in the music player, Studio)" or "kept, not loaded")
				make("TextLabel", {
					Size = UDim2.new(1, -330, 0, 16), Position = UDim2.new(0, 108, 0, 42), BackgroundTransparency = 1, Text = status,
					TextColor3 = it.loaded and C.green or C.amber, Font = Enum.Font.Gotham, TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Left,
				}, row)
				local x = -8
				local function action(text, w, color, fn)
					local b = btn(row, text, w, color)
					b.AnchorPoint = Vector2.new(1, 0.5)
					b.Position = UDim2.new(1, x, 0.5, 0)
					x -= w + 6
					b.Activated:Connect(function()
						if busy then
							return
						end
						busy = true
						local old = b.Text
						b.Text = "..."
						local ok, err = pcall(fn)
						if not ok then
							stats.Text = tostring(err)
						end
						if b.Parent then
							b.Text = old
						end
						busy = false
					end)
					return b
				end
				local confirm = false
				local del
				del = action("Delete", 64, C.red, function()
					if not confirm then
						confirm = true
						task.delay(0.05, function()
							if del.Parent then
								del.Text = "Sure?"
							end
						end)
						task.delay(3, function()
							confirm = false
							if del.Parent then
								del.Text = "Delete"
							end
						end)
						return
					end
					local r = Net.invoke("libDelete", it.id)
					if type(r) == "table" and r.error then
						error(r.error, 0)
					end
					pcall(Net.forget)
					task.defer(refresh)
				end)
				if it.url then
					action("URL", 48, nil, function()
						urlBox.Text = it.url
						urlBox:CaptureFocus()
						urlBox.SelectionStart = 1
						urlBox.CursorPosition = #urlBox.Text + 1
					end)
				end
				if not it.loaded and it.kept and not audio then
					action("Load", 56, Color3.fromRGB(50, 90, 160), function()
						stats.Text = "loading " .. name .. " from its URL (the import progress shows in the TV picker)..."
						local r = Net.invoke("libLoad", it.id)
						if type(r) == "table" and r.error then
							error("couldn't load: " .. r.error, 0)
						end
						pcall(Net.forget)
						task.defer(refresh)
					end)
				end
			end
		end
		task.spawn(refresh)
	end

	FrameLab.openDataManager = open
	FrameLab.closeDataManager = close

	-- in the Labs menu (LabHub) for admins
	local hubOk, LabHub = pcall(function()
		return require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub", 5))
	end)
	if hubOk and LabHub then
		local hub
		local baseOpen = open
		-- (one Lab window at a time: opening this closes the others, and the hub can close this one)
		open = function()
			baseOpen()
			if hub then
				hub.opened()
			end
		end
		FrameLab.openDataManager = open
		hub = LabHub.add({
			id = "data", label = "Data", order = 20,
			closeWindow = close,
			isOpen = function()
				return gui ~= nil
			end,
			action = function()
				if gui then
					close()
				else
					open()
				end
			end,
			available = function()
				return Net.isAdmin()
			end,
		})
	end
end
