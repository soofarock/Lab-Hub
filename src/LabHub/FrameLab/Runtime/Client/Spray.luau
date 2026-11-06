-- Started by FrameLab:init() on a client: draws picture sprays (workspace.FrameLabSprays, Kind "image" / "url") with
-- FrameLab strips on a SurfaceGui. Only the nearest few within view distance are drawn (Config.SprayMaxRendered /
-- SprayViewDistance); pictures are fetched from the server once and kept.
return function(FrameLab)
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local root = script:FindFirstAncestor("FrameLab")
	local Net = require(root.Tools.Net)
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local folder = workspace:WaitForChild("FrameLabSprays")
	local function newHolder()
		local h = Instance.new("Folder")
		h.Name = "FrameLabSprays"
		h.Parent = playerGui
		return h
	end
	local holder = newHolder()

	local shown = {} -- spray part -> { gui, canvas, level }
	local images = {} -- key -> image table (smaller copy for drawing)

	-- Performance mode (phones by default; Config.SprayPerformanceMode "on" / "off" / "auto"): fewer sprays drawn, and
	-- each with fewer GUI objects. Every device draws a spray cheaply ("far") until you come within
	-- SprayDetailDistance, then in full ("near"): GUI objects cost drawing time every frame, even on a still picture.
	local UIS = game:GetService("UserInputService")
	local function performance()
		local m = Config.SprayPerformanceMode or "auto"
		if m == "on" then
			return true
		elseif m == "off" then
			return false
		end
		return UIS.TouchEnabled and not UIS.KeyboardEnabled
	end
	-- most GUI objects a spray's blocks may take
	local function budgetOf(original, level)
		local perf = performance()
		if level == "far" then
			return perf and 500 or 1500
		end
		if original then
			return perf and (Config.SprayPhonePieces or 3500) or (Config.SprayOriginalPieces or 9000)
		end
		return perf and 1200 or 3000
	end

	local function drop(s)
		if s.canvas then
			s.canvas:destroy()
		end
		s.gui:Destroy()
		if s.old then
			drop(s.old)
			s.old = nil
		end
	end

	local function hide(part)
		local s = shown[part]
		if s then
			shown[part] = nil
			drop(s)
		end
	end

	-- level: "near" | "far"; old: the spray's previous drawing, kept until this one is drawn (no blink when it switches)
	local function show(part, level, old)
		local key = part:GetAttribute("Key")
		local original = part:GetAttribute("Original") == true
		level = level or "near"
		local s = { level = level, old = old }
		shown[part] = s
		local gui = Instance.new("SurfaceGui")
		gui.Adornee = part
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = original and 40 or 30
		gui.LightInfluence = 1
		gui.ClipsDescendants = true
		gui.ResetOnSpawn = false
		gui.Parent = holder
		s.gui = gui
		task.spawn(function()
			-- picture size: O up to SprayOriginalSize (512); the others ~16 pixels a stud (L and XL sharper than S / M)
			local px = original and (Config.SprayOriginalSize or 512)
				or math.clamp(math.floor(math.max(part.Size.X, part.Size.Y) * 16), Config.SprayPictureSize or 96, 192)
			local cacheKey = original and (key .. "#original") or (key .. "#" .. px)
			local img = images[cacheKey]
			if not img then
				local full = Net.image(key)
				if not full then
					return
				end
				img = FrameLab.Resize.fit(full, px)
				images[cacheKey] = img
			end
			if shown[part] ~= s then
				return
			end
			-- block pictures (Image.Blocks, when the pattern library is in place): one ImageLabel per 8x8 / 4x4 block, no
			-- gradients, no streaks. O sprays: the threshold rises a little, then the picture shrinks, until it fits
			-- SprayOriginalPieces objects
			local Blocks = require(root.Image.Blocks)
			if Blocks.ready() then
				local budget = budgetOf(original, level)
				local listKey = cacheKey .. "#blocks" .. budget
				local list = images[listKey]
				if not list then
					local cur = img
					while true do
						for _, T in ipairs({ 6, 9 }) do
							list = Blocks.encode(cur, { Threshold = T, Yield = true })
							if list.count <= budget then
								break
							end
						end
						if list.count <= budget or math.max(cur.width, cur.height) < 80 then
							break
						end
						cur = FrameLab.Resize.fit(img, math.floor(math.max(cur.width, cur.height) * 0.85))
					end
					images[listKey] = list
				end
				if shown[part] ~= s then
					return
				end
				s.canvas = Blocks.draw(list, gui, { KeepAspect = false })
				if s.old and shown[part] == s then
					drop(s.old)
					s.old = nil
				end
				return
			end
			-- a full-resolution picture: as sharp as the strip budget allows (Roblox draws only so many gradients, see
			-- Render/Canvas), so the tolerance rises until it fits
			local tol = 12
			if original then
				-- a full-resolution picture, as sharp as the budget allows. With the ramp image the cost is GUI objects (one per
				-- keypoint pair); without it, strips (each needs a gradient). The tolerance stays low (raising it smears the
				-- picture sideways); past the budget the picture is drawn smaller instead (softer, not smeared)
				local fit = images[cacheKey .. "#fit"]
				if not fit then
					local ramp = FrameLab.Canvas.rampImage() ~= nil
					local limit = ramp and (Config.SprayOriginalPieces or 9000) or (Config.SprayOriginalStrips or 160)
					-- GUI objects: a strip with its own gradient is 1 (the longest ones get those: about 120 of the sprays'
					-- share, Canvas.MaxStaticGradients), a flat one 1, the rest 1 + one ramp piece per segment
					local function cost(strips)
						if not ramp then
							return #strips.list
						end
						local segs = {}
						for _, st in ipairs(strips.list) do
							table.insert(segs, #st.kp - 1)
						end
						table.sort(segs, function(a, b)
							return a > b
						end)
						local n = 0
						for i, k in ipairs(segs) do
							n += (i <= 120 or k <= 1) and 1 or (1 + k)
						end
						return n
					end
					-- (sharp first, then a little softer; past that the picture is drawn smaller. A photo at tolerance 24 came out
					-- streaky (rows smeared sideways); the same budget at a smaller size and tolerance 10 looked far better)
					local tols = ramp and { 10, 14 } or { 12, 24, 40 }
					local cur, side = img, math.max(img.width, img.height)
					while not fit do
						for _, t in ipairs(tols) do
							if cost(FrameLab.encode(cur, { Tolerance = t })) <= limit then
								fit = { img = cur, tol = t }
								break
							end
							task.wait()
						end
						if not fit then
							side = math.floor(side * 0.8)
							if side < 64 then
								fit = { img = cur, tol = tols[#tols] }
							else
								cur = FrameLab.Resize.fit(img, side)
							end
						end
					end
					images[cacheKey .. "#fit"] = fit
				end
				img, tol = fit.img, fit.tol
				if shown[part] ~= s then
					return
				end
			end
			s.canvas = FrameLab.show(img, gui, { Tolerance = tol, KeepAspect = false })
			if s.old and shown[part] == s then
				drop(s.old)
				s.old = nil
			end
		end)
	end

	folder.ChildRemoved:Connect(hide)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.5 then
			return
		end
		acc = 0
		-- respawning clears the PlayerGui, this folder and its sprays too: draw them again in a new one
		if holder.Parent ~= playerGui then
			for p in pairs(shown) do
				hide(p)
			end
			holder = newHolder()
		end
		local cam = workspace.CurrentCamera
		local from = cam and cam.CFrame.Position or Vector3.zero
		local cands = {}
		for _, p in ipairs(folder:GetChildren()) do
			local kind = p:GetAttribute("Kind")
			if (kind == "image" or kind == "url") and p:IsA("BasePart") then
				local d = (p.Position - from).Magnitude
				if d <= (Config.SprayViewDistance or 150) then
					table.insert(cands, { p = p, d = d })
				end
			end
		end
		table.sort(cands, function(a, b)
			return a.d < b.d
		end)
		local want = {}
		local maxShown = Config.SprayMaxRendered or 24
		if performance() then
			maxShown = math.min(maxShown, Config.SprayPhoneMaxRendered or 8)
		end
		-- full detail within SprayDetailDistance (a big spray from further: it looks big from further), cheap beyond
		-- (a little further before going back to cheap: no flipping at the edge)
		local near = Config.SprayDetailDistance or 40
		for i = 1, math.min(#cands, maxShown) do
			local c = cands[i]
			local reach = near * math.max(1, math.max(c.p.Size.X, c.p.Size.Y) / 8)
			local cur = shown[c.p]
			local level
			if cur and cur.level == "near" then
				level = (c.d <= reach * 1.25) and "near" or "far"
			else
				level = (c.d <= reach) and "near" or "far"
			end
			want[c.p] = level
		end
		for p in pairs(shown) do
			if not want[p] then
				hide(p)
			end
		end
		for p, level in pairs(want) do
			local cur = shown[p]
			if not cur then
				show(p, level)
			elseif cur.level ~= level and cur.canvas then
				-- switch detail: the new drawing replaces the old one once it is drawn
				shown[p] = nil
				local old = cur.old
				cur.old = nil
				if old then
					drop(old)
				end
				show(p, level, cur)
			end
		end
	end)
end
