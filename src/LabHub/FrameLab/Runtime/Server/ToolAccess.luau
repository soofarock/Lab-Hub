-- Started by FrameLab.init() on the server: who gets the Lab tools (the "TV" and "Spray Paint" tools, built from
-- LabHub.Blueprints; a tool of that name in StarterPack is used instead). They are kept in ServerStorage and handed out
-- by the settings:
--   TVToolAccess, SprayToolAccess: "everyone" | "admins" (FrameLab admins: Config.Admins, the owner) | "owner" |
--                                   "list" (ToolAccessList: UserIds or names, comma-separated) | "nobody"
-- A change applies at once (tools given or taken away). The settings panel's "Get tools" gives the owner both tools
-- whatever the settings say (request: toolsGive).
return function(FrameLab)
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local StarterPack = game:GetService("StarterPack")
	local ServerStorage = game:GetService("ServerStorage")
	local root = script:FindFirstAncestor("FrameLab")
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))

	local TOOLS = { { name = "TV", setting = "TVToolAccess" }, { name = "Spray Paint", setting = "SprayToolAccess" } }

	-- the tools, kept out of StarterPack (so nobody gets them unless allowed)
	local store = ServerStorage:FindFirstChild("FrameLabTools") or Instance.new("Folder")
	store.Name = "FrameLabTools"
	store.Parent = ServerStorage
	local hub = root.Parent
	local Blueprints = require(hub.Blueprints)
	local Instancer = require(hub.Instancer)
	local tools = {}
	for _, t in ipairs(TOOLS) do
		local tool = StarterPack:FindFirstChild(t.name) or store:FindFirstChild(t.name)
		if not tool and Blueprints.tools[t.name] then
			tool = Instancer.build(Blueprints.tools[t.name]) -- (its behaviour: FrameLab Runtime/Client/ToolBinder)
		end
		if tool then
			tool.Parent = store
			tools[t.name] = tool
		end
	end

	local t0 = os.clock()
	while not FrameLab.Server and os.clock() - t0 < 30 do
		task.wait(0.1)
	end
	local isAdmin = FrameLab.Server and FrameLab.Server.isAdmin or function()
		return false
	end
	local function isOwner(player)
		if RunService:IsStudio() then
			return true
		end
		if game.CreatorType == Enum.CreatorType.User then
			return player.UserId == game.CreatorId
		end
		local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
		return ok and rank >= 255
	end
	local function onList(player)
		for entry in string.gmatch(tostring(Config.ToolAccessList or ""), "[^,%s]+") do
			if tonumber(entry) == player.UserId or string.lower(entry) == string.lower(player.Name) then
				return true
			end
		end
		return false
	end
	local function allowed(player, setting)
		local mode = Config[setting] or "everyone"
		if mode == "everyone" then
			return true
		elseif mode == "admins" then
			return isAdmin(player) or isOwner(player)
		elseif mode == "owner" then
			return isOwner(player)
		elseif mode == "list" then
			return onList(player) or isOwner(player)
		end
		return false -- "nobody"
	end

	local granted = {} -- player -> { [tool name] = true }: given by "Get tools" whatever the settings
	local function has(player, name)
		local bp = player:FindFirstChildOfClass("Backpack")
		return (bp and bp:FindFirstChild(name)) or (player.Character and player.Character:FindFirstChild(name))
	end
	local function update(player)
		for _, t in ipairs(TOOLS) do
			local tool = tools[t.name]
			if tool then
				local want = allowed(player, t.setting) or (granted[player] and granted[player][t.name])
				local held = has(player, t.name)
				if want and not held then
					local bp = player:FindFirstChildOfClass("Backpack")
					if bp then
						tool:Clone().Parent = bp
					end
				elseif not want and held then
					while has(player, t.name) do
						has(player, t.name):Destroy()
					end
				end
			end
		end
	end
	local function hook(player)
		player.CharacterAdded:Connect(function()
			task.wait() -- (the new Backpack)
			update(player)
		end)
		if player.Character then
			update(player)
		end
	end
	Players.PlayerAdded:Connect(hook)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(hook, p)
	end
	Players.PlayerRemoving:Connect(function(p)
		granted[p] = nil
	end)
	-- a settings change: give / take away now
	for _, key in ipairs({ "TVToolAccess", "SprayToolAccess", "ToolAccessList", "Admins" }) do
		root:GetAttributeChangedSignal(key):Connect(function()
			for _, p in ipairs(Players:GetPlayers()) do
				update(p)
			end
		end)
	end

	if FrameLab.Server then
		FrameLab.Server.handlers.toolsGive = function(player)
			if not isOwner(player) then
				return { error = "only the owner" }
			end
			granted[player] = {}
			for _, t in ipairs(TOOLS) do
				granted[player][t.name] = true
			end
			update(player)
			return { ok = true }
		end
	end
end
