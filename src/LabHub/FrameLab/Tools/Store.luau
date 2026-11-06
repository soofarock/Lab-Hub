-- FrameLab data storage: binary entries kept in the place as base64 ModuleScripts (Studio, Edit mode / command bar),
-- or as StringValues when written from a running game (game scripts can't write Script.Source). Large entries are
-- split into part modules (Roblox caps a script's Source at 200,000 characters).
--
--   Store.write(root, path, bytes, attributes?) -> the instance       ("a/b/name": nested Folders)
--   Store.read(root, path) -> buffer
--   Store.list(root) -> { path, ... }   Store.has(root, path)   Store.entry(root, path) -> instance

local EncodingService = game:GetService("EncodingService")

local Store = {}

local LINE = 4096
local PART_CHARS = 180000
local VALUE_PART_CHARS = 100000

local function splitPath(path)
	local parts = {}
	for part in string.gmatch(path, "[^/\\]+") do
		table.insert(parts, part)
	end
	return parts
end

local function resolve(root, path, create)
	local parts = splitPath(path)
	assert(#parts > 0, "empty path")
	local node = root
	for i = 1, #parts - 1 do
		local child = node:FindFirstChild(parts[i])
		if not child then
			if not create then
				return nil, parts[#parts]
			end
			child = Instance.new("Folder")
			child.Name = parts[i]
			child.Parent = node
		end
		node = child
	end
	return node, parts[#parts]
end

local canWriteSource = nil
local function sourceWritable()
	if canWriteSource == nil then
		canWriteSource = pcall(function()
			local probe = Instance.new("ModuleScript")
			probe.Source = "return nil"
			probe:Destroy()
		end)
	end
	return canWriteSource
end

local function encode64(buf)
	return buffer.tostring(EncodingService:Base64Encode(buf))
end

local function decode64(text)
	return EncodingService:Base64Decode(buffer.fromstring(text))
end

function Store.write(root, path, bytes, attributes)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local text = encode64(buf)
	local parent, name = resolve(root, path, true)
	local old = parent:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local entry
	if not sourceWritable() then
		entry = Instance.new("StringValue")
		entry.Name = name
		local parts = math.max(1, math.ceil(#text / VALUE_PART_CHARS))
		for p = 1, parts do
			local part = Instance.new("StringValue")
			part.Name = ("part%03d"):format(p)
			part.Value = string.sub(text, (p - 1) * VALUE_PART_CHARS + 1, p * VALUE_PART_CHARS)
			part.Parent = entry
		end
		entry:SetAttribute("Parts", parts)
	else
		local lines = {}
		for i = 1, #text, LINE do
			table.insert(lines, '\t"' .. string.sub(text, i, i + LINE - 1) .. '",')
		end
		entry = Instance.new("ModuleScript")
		entry.Name = name
		if #text <= PART_CHARS then
			entry.Source = "-- FrameLab data: base64, " .. buffer.len(buf) .. " bytes\nreturn table.concat({\n" .. table.concat(lines, "\n") .. "\n})\n"
		else
			local perPart = PART_CHARS // LINE
			local partCount = math.ceil(#lines / perPart)
			for p = 1, partCount do
				local part = Instance.new("ModuleScript")
				part.Name = ("part%03d"):format(p)
				local slice = table.move(lines, (p - 1) * perPart + 1, math.min(#lines, p * perPart), 1, {})
				part.Source = "return table.concat({\n" .. table.concat(slice, "\n") .. "\n})\n"
				part.Parent = entry
			end
			entry.Source = ("-- FrameLab data: base64, %d bytes in %d parts\nlocal parts = {}\nfor i = 1, %d do\n\tparts[i] = require(script[(\"part%%03d\"):format(i)])\nend\nreturn table.concat(parts)\n"):format(buffer.len(buf), partCount, partCount)
		end
	end
	entry:SetAttribute("Bytes", buffer.len(buf))
	for k, v in pairs(attributes or {}) do
		entry:SetAttribute(k, v)
	end
	entry.Parent = parent
	return entry
end

function Store.entry(root, path)
	local parent, name = resolve(root, path, false)
	return parent and parent:FindFirstChild(name)
end

function Store.has(root, path)
	return Store.entry(root, path) ~= nil
end

function Store.read(root, path)
	local entry = Store.entry(root, path)
	if not entry then
		error("FrameLab data not found: " .. path)
	end
	if entry:IsA("StringValue") then
		local parts = {}
		for p = 1, entry:GetAttribute("Parts") or 0 do
			local part = entry:WaitForChild(("part%03d"):format(p), 10)
			if not part then
				error("FrameLab data incomplete (still replicating?): " .. path)
			end
			parts[p] = part.Value
		end
		return decode64(table.concat(parts))
	end
	return decode64(require(entry))
end

function Store.list(root)
	local out = {}
	for _, d in ipairs(root:GetDescendants()) do
		local isEntry = d:IsA("ModuleScript") or (d:IsA("StringValue") and d:GetAttribute("Parts") ~= nil)
		if isEntry and not (d.Parent and (d.Parent:IsA("ModuleScript") or d.Parent:IsA("StringValue"))) then
			local path = d.Name
			local node = d.Parent
			while node and node ~= root do
				path = node.Name .. "/" .. path
				node = node.Parent
			end
			table.insert(out, path)
		end
	end
	table.sort(out)
	return out
end

return Store
