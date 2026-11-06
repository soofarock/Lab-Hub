-- Started by FrameLab.init() on each client: gives the Lab tools their behaviour. A "TV" tool runs FrameLab.Tools.TVTool
-- and a "Spray Paint" tool runs FrameLab.Tools.SprayTool, once per tool, when it reaches this player's Backpack or
-- character (the tools hold no scripts: the server builds them from LabHub.Blueprints).
return function(FrameLab)
	local Players = game:GetService("Players")
	local player = Players.LocalPlayer
	local root = script:FindFirstAncestor("FrameLab")
	local BEHAVIOUR = { TV = "TVTool", ["Spray Paint"] = "SprayTool" }
	local bound = setmetatable({}, { __mode = "k" })

	local function bind(tool)
		local name = tool:IsA("Tool") and BEHAVIOUR[tool.Name]
		if not name or bound[tool] then
			return
		end
		bound[tool] = true
		task.spawn(function()
			local ok, err = pcall(function()
				require(root.Tools[name])(tool)
			end)
			if not ok then
				warn(("[FrameLab] %s tool: %s"):format(tool.Name, tostring(err)))
			end
		end)
	end
	local function watch(container)
		for _, c in ipairs(container:GetChildren()) do
			bind(c)
		end
		container.ChildAdded:Connect(bind)
	end

	-- the Backpack is replaced on every respawn; the character holds the equipped tool
	player.ChildAdded:Connect(function(c)
		if c:IsA("Backpack") then
			watch(c)
		end
	end)
	local bp = player:FindFirstChildOfClass("Backpack")
	if bp then
		watch(bp)
	end
	player.CharacterAdded:Connect(watch)
	if player.Character then
		watch(player.Character)
	end
end
