-- The Spray Paint tool (FrameLab's ToolBinder calls this with the Tool on each client), modded from Roblox's 2012 Spray Paint
-- gear: pick what to spray, then click / tap a surface within reach.
--   Pictures  FrameLab library pictures (imported in Studio)
--   Decal ID  a Roblox decal or image id, like the original gear
--   Import    admins only: a web address of a PNG / JPG / BMP / TGA / GIF picture; the server imports it into the
--             Pictures list for everyone (kept while the server runs)
return function(tool)
	local Players = game:GetService("Players")
	local UIS = game:GetService("UserInputService")
	local root = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("FrameLab")
	local Net = require(root.Tools.Net)
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	local remote = Net.remotes(false):WaitForChild("Spray")
	local player = Players.LocalPlayer

	local C = {
		bg = Color3.fromRGB(20, 23, 30), panel = Color3.fromRGB(30, 34, 43), text = Color3.fromRGB(230, 233, 240),
		dim = Color3.fromRGB(140, 148, 165), accent = Color3.fromRGB(56, 170, 230), on = Color3.fromRGB(28, 96, 140),
	}
	local choice = nil -- { Kind, Value, Label }
	local size = 5
	local gui, statusLabel, chosenLabel
	local busy = false

	local function make(class, props, parent)
		local i = Instance.new(class)
		for k, v in pairs(props) do
			i[k] = v
		end
		i.Parent = parent
		return i
	end
	local function corner(parent, r)
		make("UICorner", { CornerRadius = UDim.new(0, r or 6) }, parent)
	end
	local function button(parent, text, w, h)
		local b = make("TextButton", {
			Size = UDim2.new(0, w, 0, h or 26), BackgroundColor3 = C.panel, TextColor3 = C.text, Text = text,
			Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = true,
		}, parent)
		corner(b)
		return b
	end
	local function setStatus(t)
		if statusLabel then
			statusLabel.Text = t
		end
	end
	local function choose(c)
		choice = c
		if chosenLabel then
			chosenLabel.Text = c and ("Spraying: " .. c.Label) or "Pick something to spray"
		end
	end

	local function buildGui()
		gui = make("ScreenGui", { Name = "FrameLabSpray", ResetOnSpawn = false, DisplayOrder = 15 })
		local panel = make("Frame", {
			Size = UDim2.new(0, 300, 0, 330), Position = UDim2.new(0, 16, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = C.bg, BackgroundTransparency = 0.05,
		}, gui)
		corner(panel, 10)
		local pad = make("UIPadding", {}, panel)
		pad.PaddingTop, pad.PaddingBottom, pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 10), UDim.new(0, 10), UDim.new(0, 10)
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, Text = "SPRAY PAINT", TextColor3 = C.dim,
			Font = Enum.Font.GothamBold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
		}, panel)
		chosenLabel = make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 0, 0, 20), BackgroundTransparency = 1, TextColor3 = C.text,
			Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		}, panel)
		-- tabs
		local tabs = make("Frame", { Size = UDim2.new(1, 0, 0, 26), Position = UDim2.new(0, 0, 0, 44), BackgroundTransparency = 1 }, panel)
		make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, tabs)
		local body = make("Frame", { Size = UDim2.new(1, 0, 1, -146), Position = UDim2.new(0, 0, 0, 76), BackgroundColor3 = C.panel }, panel)
		corner(body, 8)
		-- size
		local sizeRow = make("Frame", { Size = UDim2.new(1, 0, 0, 26), Position = UDim2.new(0, 0, 1, -62), BackgroundTransparency = 1 }, panel)
		make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, sizeRow)
		make("TextLabel", { Size = UDim2.new(0, 36, 1, 0), BackgroundTransparency = 1, Text = "Size", TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 12, LayoutOrder = 0 }, sizeRow)
		local sizeButtons = {}
		-- XL: the biggest normal spray (10 studs, a sharper picture than the smaller sizes). O (original): the picture at
		-- its own resolution, up to 512 x 512, sized from its pixels (size 0 asks the server for that)
		for i, s in ipairs({ { "S", 3 }, { "M", 5 }, { "L", 8 }, { "XL", 10 }, { "O", 0 } }) do
			local b = button(sizeRow, s[1], 40)
			b.LayoutOrder = i
			sizeButtons[b] = s[2]
			b.MouseButton1Click:Connect(function()
				size = s[2]
				for bb, v in pairs(sizeButtons) do
					bb.BackgroundColor3 = (v == size) and C.on or C.panel
				end
			end)
			b.BackgroundColor3 = (s[2] == size) and C.on or C.panel
		end
		statusLabel = make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 28), Position = UDim2.new(0, 0, 1, -28), BackgroundTransparency = 1, TextColor3 = C.dim,
			Font = Enum.Font.Gotham, TextSize = 11, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
			Text = "Click a surface within reach to spray.",
		}, panel)

		local pages = {}
		local function showPage(name)
			for n, p in pairs(pages) do
				p.page.Visible = (n == name)
				p.tab.BackgroundColor3 = (n == name) and C.on or C.panel
			end
		end
		local function addPage(name)
			local tab = button(tabs, name, 84)
			tab.LayoutOrder = ({ Pictures = 1, ["Decal ID"] = 2, Import = 3 })[name] or 9
			local page = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, body)
			pages[name] = { tab = tab, page = page }
			tab.MouseButton1Click:Connect(function()
				showPage(name)
			end)
			return page
		end

		-- Pictures
		local pics = addPage("Pictures")
		local list = make("ScrollingFrame", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4,
			AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
		}, pics)
		make("UIListLayout", { Padding = UDim.new(0, 4) }, list)
		local lp = make("UIPadding", {}, list)
		lp.PaddingTop, lp.PaddingLeft, lp.PaddingRight = UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 10)
		local function fillPictures()
			for _, c in ipairs(list:GetChildren()) do
				if c:IsA("GuiButton") then
					c:Destroy()
				end
			end
			local images = Net.images()
			if #images == 0 then
				local b = button(list, "No pictures yet (import with FrameLab.import() in Studio)", 10)
				b.Size = UDim2.new(1, 0, 0, 26)
				b.TextWrapped = true
			end
			for _, img in ipairs(images) do
				local b = button(list, ("%s   %dx%d"):format(img.name, img.Width or 0, img.Height or 0), 10)
				b.Size = UDim2.new(1, 0, 0, 26)
				b.TextXAlignment = Enum.TextXAlignment.Left
				make("UIPadding", { PaddingLeft = UDim.new(0, 8) }, b)
				b.MouseButton1Click:Connect(function()
					choose({ Kind = "image", Value = img.name, Label = img.name })
				end)
			end
		end
		task.spawn(fillPictures)

		-- Decal ID
		local decal = addPage("Decal ID")
		local box = make("TextBox", {
			Size = UDim2.new(1, -12, 0, 30), Position = UDim2.new(0, 6, 0, 8), BackgroundColor3 = C.bg, TextColor3 = C.text,
			PlaceholderText = "decal or image id, e.g. 80373024", PlaceholderColor3 = C.dim, Text = "", ClearTextOnFocus = false,
			Font = Enum.Font.Code, TextSize = 13,
		}, decal)
		corner(box)
		local use = button(decal, "Use this decal", 120)
		use.Position = UDim2.new(0, 6, 0, 46)
		local preview = make("ImageLabel", {
			Size = UDim2.new(0, 70, 0, 70), Position = UDim2.new(1, -76, 0, 46), BackgroundColor3 = C.bg, ScaleType = Enum.ScaleType.Fit,
		}, decal)
		corner(preview)
		local function useDecal()
			local id = tonumber(string.match(box.Text, "%d+"))
			if not id then
				setStatus("Type a decal or image id (numbers).")
				return
			end
			box.Text = tostring(id)
			preview.Image = "rbxthumb://type=Asset&id=" .. id .. "&w=150&h=150"
			choose({ Kind = "decal", Value = id, Label = "decal " .. id })
		end
		use.MouseButton1Click:Connect(useDecal)
		box.FocusLost:Connect(function(enter)
			if enter then
				useDecal()
			end
		end)

		-- Import (admins): a picture from a web address joins the Pictures list (for everyone, while the server runs)
		task.spawn(function()
			if not Net.isAdmin() then
				return
			end
			local page = addPage("Import")
			local ubox = make("TextBox", {
				Size = UDim2.new(1, -12, 0, 30), Position = UDim2.new(0, 6, 0, 8), BackgroundColor3 = C.bg, TextColor3 = C.text,
				PlaceholderText = "https://example.com/picture.png", PlaceholderColor3 = C.dim, Text = "", ClearTextOnFocus = false,
				Font = Enum.Font.Code, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd,
			}, page)
			corner(ubox)
			local load = button(page, "Import picture", 120)
			load.Position = UDim2.new(0, 6, 0, 46)
			make("TextLabel", {
				Size = UDim2.new(1, -12, 0, 70), Position = UDim2.new(0, 6, 0, 80), BackgroundTransparency = 1, TextColor3 = C.dim,
				Font = Enum.Font.Gotham, TextSize = 11, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Text = "Admins only. PNG, JPG, WebP, BMP, TGA or GIF. It joins Pictures for everyone until the server closes. Pictures from the web skip Roblox moderation: only import ones you'd be fine with Roblox seeing.",
			}, page)
			local function doImport()
				if busy then
					return
				end
				busy = true
				setStatus("Importing the picture...")
				local ok, res = pcall(Net.invoke, "importUrl", "image", ubox.Text)
				busy = false
				if not ok or type(res) ~= "table" then
					setStatus("That didn't import.")
				elseif res.error then
					setStatus(res.error)
				else
					setStatus(("Imported %s, %dx%d. Click a surface to spray it."):format(res.name, res.width, res.height))
					choose({ Kind = "image", Value = res.name, Label = res.name })
					Net.forget()
					fillPictures()
				end
			end
			load.MouseButton1Click:Connect(doImport)
			ubox.FocusLost:Connect(function(enter)
				if enter then
					doImport()
				end
			end)
		end)

		showPage("Pictures")
		choose(choice)
		gui.Parent = player:WaitForChild("PlayerGui")
	end

	tool.Equipped:Connect(function()
		if not gui then
			buildGui()
		else
			gui.Parent = player:WaitForChild("PlayerGui")
		end
	end)
	tool.Unequipped:Connect(function()
		if gui then
			gui.Parent = nil
		end
	end)

	local lastSpray = 0
	tool.Activated:Connect(function()
		if not choice then
			setStatus("Pick something to spray first.")
			return
		end
		if os.clock() - lastSpray < (Config.SprayCooldown or 1.5) then
			return
		end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local cam = workspace.CurrentCamera
		if not hrp or not cam then
			return
		end
		local m = UIS:GetMouseLocation()
		local ray = cam:ViewportPointToRay(m.X, m.Y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local ignore = { char }
		local sprays = workspace:FindFirstChild("FrameLabSprays")
		if sprays then
			table.insert(ignore, sprays)
		end
		params.FilterDescendantsInstances = ignore
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 300, params)
		if not hit or not hit.Instance:IsA("BasePart") then
			return
		end
		if (hit.Position - hrp.Position).Magnitude > (Config.SprayRange or 14) then
			setStatus("Too far: get closer to the surface.")
			return
		end
		lastSpray = os.clock()
		-- the gear's spray animation (made for R6 bodies)
		local hum = char:FindFirstChildOfClass("Humanoid")
		local anim = tool:FindFirstChild("SprayPaint")
		if hum and anim then
			pcall(function()
				local animator = hum:FindFirstChildOfClass("Animator") or hum
				animator:LoadAnimation(anim):Play()
			end)
		end
		remote:FireServer({ Kind = choice.Kind, Value = choice.Value }, size, hit.Position, hit.Normal, hit.Instance)
		setStatus("Sprayed.")
	end)
end
