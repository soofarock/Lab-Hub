-- Instancer: builds instances from plain Luau descriptions, so LabHub ships as modules only (the tools and the TV model
-- are made at run time instead of being stored as instances).
--
--   local inst = Instancer.build(description, parent?)
--
-- A description:
--   { class = "Part", name = "Handle",
--     props = { Size = Vector3.new(1, 1, 1), Material = Enum.Material.Metal, ... },
--     attributes = { FrameLabTV = true }, tags = { "Tag" },
--     refs = { PrimaryPart = "Body" },               -- properties that point at a descendant, by path from this one
--     children = { <description>, ... } }
--
-- Meshes are Parts with a SpecialMesh child (its MeshId and TextureId can be set by a script, on either side).

local CollectionService = game:GetService("CollectionService")

local Instancer = {}

local function make(desc, built)
	local inst = Instance.new(desc.class)
	inst.Name = desc.name or desc.class
	for k, v in pairs(desc.props or {}) do
		local ok, err = pcall(function()
			inst[k] = v
		end)
		if not ok then
			warn(("[LabHub] %s.%s: %s"):format(inst.Name, k, tostring(err)))
		end
	end
	for k, v in pairs(desc.attributes or {}) do
		inst:SetAttribute(k, v)
	end
	for _, t in ipairs(desc.tags or {}) do
		CollectionService:AddTag(inst, t)
	end
	for _, child in ipairs(desc.children or {}) do
		make(child, built).Parent = inst
	end
	if desc.refs then
		table.insert(built, { inst = inst, refs = desc.refs })
	end
	return inst
end

local function find(root, path)
	local cur = root
	for step in string.gmatch(path, "[^%.]+") do
		cur = cur and cur:FindFirstChild(step)
	end
	return cur
end

-- build a description (and everything under it); parent last, so it arrives whole
function Instancer.build(desc, parent)
	local built = {}
	local inst = make(desc, built)
	for _, b in ipairs(built) do
		for prop, path in pairs(b.refs) do
			local target = find(b.inst, path)
			if target then
				pcall(function()
					b.inst[prop] = target
				end)
			end
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

return Instancer
