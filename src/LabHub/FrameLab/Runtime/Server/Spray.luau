-- Started by FrameLab:init() on the server: Spray Paint. A spray is a thin invisible part on the surface that was
-- sprayed (welded to it when it moves), holding what to show:
--   Kind "decal": a Roblox decal / image id, shown with a normal Decal (Roblox-moderated, like the original gear)
--   Kind "image": a FrameLab library picture ("lib:<name>"), drawn by each client with strips (Runtime/Client/Spray)
--   Kind "url":   a picture an admin loaded from a web address ("url:<n>"), drawn the same way
-- Loading from a URL is for admins only (the FrameLab folder's Admins attribute, and the place owner): those pictures skip Roblox's
-- moderation, so whoever loads them is responsible for them.
return function(FrameLab)
	local Players = game:GetService("Players")
	local HttpService = game:GetService("HttpService")
	local MarketplaceService = game:GetService("MarketplaceService")
	local InsertService = game:GetService("InsertService")
	local root = script:FindFirstAncestor("FrameLab")
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	while not FrameLab.Server do
		task.wait()
	end
	local server = FrameLab.Server
	local remote = server.remotes.Spray

	local folder = workspace:FindFirstChild("FrameLabSprays")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "FrameLabSprays"
		folder.Parent = workspace
	end

	-- decal id -> image texture ("rbxassetid://<image id>"); a decal's own id doesn't work as a texture at runtime
	local textures = {}
	local function textureOf(id)
		if textures[id] ~= nil then
			return textures[id]
		end
		local result = false
		local ok, info = pcall(MarketplaceService.GetProductInfoAsync, MarketplaceService, id, Enum.InfoType.Asset)
		if ok and info then
			if info.AssetTypeId == 1 then -- already an image
				result = "rbxassetid://" .. id
			elseif info.AssetTypeId == 13 then -- a decal: its image
				local ok2, model = pcall(InsertService.LoadAsset, InsertService, id)
				if ok2 and model then
					local d = model:FindFirstChildWhichIsA("Decal", true)
					if d then
						result = d.Texture
					end
					model:Destroy()
				end
				if not result then
					-- the image is usually uploaded just before the decal, by the same creator
					for k = 1, 8 do
						local ok3, i2 = pcall(MarketplaceService.GetProductInfoAsync, MarketplaceService, id - k, Enum.InfoType.Asset)
						if ok3 and i2 and i2.AssetTypeId == 1 and i2.Creator and info.Creator and i2.Creator.Id == info.Creator.Id then
							result = "rbxassetid://" .. (id - k)
							break
						end
					end
				end
			end
		end
		textures[id] = result
		return result
	end

	-- admins: load a picture from a web address
	local urlCount = 0
	local byUrl = {}
	server.handlers.loadUrl = function(player, url)
		if not server.isAdmin(player) then
			return { error = "only admins can load pictures from a URL" }
		end
		if type(url) ~= "string" or #url > 2000 or not string.match(url, "^https?://[%w%.%-]+") then
			return { error = "that isn't a web address (http:// or https://)" }
		end
		local allowed, why = Config.imageUrlAllowed(url)
		if not allowed then
			return { error = why }
		end
		if byUrl[url] then
			local u = server.urlImages[byUrl[url]]
			return { key = byUrl[url], width = u.width, height = u.height }
		end
		local ok, res = pcall(HttpService.RequestAsync, HttpService, { Url = url, Method = "GET" })
		if not ok then
			return { error = "couldn't fetch it: " .. tostring(res) }
		end
		if not res.Success then
			return { error = ("the site answered %d %s"):format(res.StatusCode, tostring(res.StatusMessage)) }
		end
		local body = res.Body
		if #body > (Config.UrlMaxBytes or 4194304) then
			return { error = "that file is too big" }
		end
		local size = Config.UrlPictureSize or 160
		local ok2, image = pcall(FrameLab.decodeImage, buffer.fromstring(body), url, { MaxSize = size, Yield = true })
		if not ok2 then
			return { error = "not a picture FrameLab reads (PNG, JPG, BMP, TGA, GIF)" }
		end
		image = FrameLab.Resize.fit(image, size, size, true)
		local packed = FrameLab.Importer.packImage(image)
		urlCount += 1
		local key = "url:" .. urlCount
		server.urlImages[key] = { bytes = packed, width = image.width, height = image.height, url = url, by = player.UserId }
		byUrl[url] = key
		return { key = key, width = image.width, height = image.height }
	end

	local mine = {} -- player -> { spray parts, oldest first }
	local last = {}

	local function addSpray(player, part)
		local list = mine[player] or {}
		mine[player] = list
		table.insert(list, part)
		while #list > (Config.SprayMaxPerPlayer or 10) do
			local old = table.remove(list, 1)
			old:Destroy()
		end
		local life = Config.SprayLifetime or 300
		if life > 0 then
			task.delay(life, function()
				if part.Parent then
					part:Destroy()
				end
				local l = mine[player]
				if l then
					local i = table.find(l, part)
					if i then
						table.remove(l, i)
					end
				end
			end)
		end
	end

	remote.OnServerEvent:Connect(function(player, choice, size, pos, normal, target)
		local now = os.clock()
		if last[player] and now - last[player] < (Config.SprayCooldown or 1.5) then
			return
		end
		if type(choice) ~= "table" or type(size) ~= "number" or typeof(pos) ~= "Vector3" or typeof(normal) ~= "Vector3" then
			return
		end
		if typeof(target) ~= "Instance" or not target:IsA("BasePart") or not target:IsDescendantOf(workspace) then
			return
		end
		if target:IsDescendantOf(folder) or (workspace:FindFirstChild("FrameLabTVs") and target:IsDescendantOf(workspace.FrameLabTVs)) then
			return
		end
		local model = target:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			return -- not on players or NPCs
		end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hrp or not hum or hum.Health <= 0 or (hrp.Position - pos).Magnitude > (Config.SprayRange or 14) + 4 then
			return
		end
		if normal.Magnitude < 0.5 then
			return
		end
		normal = normal.Unit
		local original = size == 0 -- "O": sized from the picture's own pixels, drawn at full resolution
		size = math.clamp(size, 2, 10)

		-- what to show
		local kind, key, aspect = nil, nil, 1
		if choice.Kind == "decal" then
			local id = tonumber(choice.Value)
			if not id or id <= 0 or id ~= math.floor(id) then
				return
			end
			local tex = textureOf(id)
			if not tex then
				return
			end
			kind, key = "decal", tex
		elseif choice.Kind == "image" and type(choice.Value) == "string" then
			local r, entry = server.find("Images", choice.Value)
			if not r then
				return
			end
			kind, key = "image", "lib:" .. choice.Value
			aspect = (entry:GetAttribute("Height") or 1) / math.max(1, entry:GetAttribute("Width") or 1)
		elseif choice.Kind == "url" and type(choice.Value) == "string" then
			local u = server.urlImages[choice.Value]
			if not u or not server.isAdmin(player) then
				return
			end
			kind, key = "url", choice.Value
			aspect = u.height / math.max(1, u.width)
		else
			return
		end
		last[player] = now

		if original then
			local pw, ph
			if kind == "image" then
				local _, entry = server.find("Images", string.sub(key, 5))
				pw, ph = entry and entry:GetAttribute("Width"), entry and entry:GetAttribute("Height")
			elseif kind == "url" then
				local u = server.urlImages[key]
				pw, ph = u and u.width, u and u.height
			end
			local longest = math.max(pw or 0, ph or 0)
			-- (up to ~21 studs: a 512-pixel picture at 24 pixels a stud)
			size = longest > 0 and math.clamp(longest / (Config.SprayOriginalPixelsPerStud or 24), 3, 22) or 10
		end
		local w, h = size, size
		if aspect > 1 then
			w = size / aspect
		else
			h = size * aspect
		end
		-- facing out of the surface; "up" follows the world, or the player's view on floors and ceilings
		local up = Vector3.yAxis
		if math.abs(normal.Y) > 0.9 then
			up = (hrp.CFrame.LookVector * Vector3.new(1, 0, 1))
			if up.Magnitude < 0.1 then
				up = Vector3.zAxis
			end
			up = up.Unit
			if normal.Y < 0 then
				up = -up
			end
		end
		local p = Instance.new("Part")
		p.Name = "Spray"
		p.Size = Vector3.new(w, h, 0.05)
		p.CFrame = CFrame.lookAt(pos + normal * 0.03, pos + normal * 2, up)
		p.Transparency = 1
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Massless = true
		p:SetAttribute("Kind", kind)
		p:SetAttribute("Key", key)
		p:SetAttribute("Owner", player.UserId)
		if original then
			p:SetAttribute("Original", true)
		end
		if kind == "decal" then
			local d = Instance.new("Decal")
			d.Face = Enum.NormalId.Front
			d.Texture = key
			d.Parent = p
		end
		if target.Anchored then
			p.Anchored = true
		else
			p.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = target
			weld.Part1 = p
			weld.Parent = p
		end
		p.Parent = folder
		addSpray(player, p)
		local tool = char:FindFirstChildOfClass("Tool")
		local sound = tool and tool:FindFirstChild("Handle") and tool.Handle:FindFirstChildOfClass("Sound")
		if sound then
			sound:Play()
			task.delay(1.2, function()
				sound:Stop()
			end)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		last[player] = nil
		for _, p in ipairs(mine[player] or {}) do
			p:Destroy()
		end
		mine[player] = nil
	end)
end
