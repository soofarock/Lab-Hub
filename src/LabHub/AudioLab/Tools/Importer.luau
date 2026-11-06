-- Studio-only: bring files from disk into the place as base64 ModuleScripts, and read them back.
--
--   Importer.prompt({ Folder = "sfx_1" })  -- opens Studio's file picker (plugin/command-bar context)
--   Importer.store("sfx_1/00_twirl.wav", bytes) -> ModuleScript under Data.Files
--   Importer.load("sfx_1/00_twirl.wav") -> buffer       (works at runtime too)
--   Importer.list() -> { "sfx_1/00_twirl.wav", ... }
--   Importer.storeClip(name, rbacBytes) / Importer.loadClip(name)   (Data.Clips)
--   Importer.storeBank(name, table) / Importer.loadBank(name)        (Data.Banks, JSON; baked SoundFonts)
--   Importer.has(path) / hasClip(path) / hasBank(path)
--
-- Paths use "/" separators and become nested Folders, so files with the same name in
-- different source folders don't collide.

local AudioLab = script:FindFirstAncestor("AudioLab")
local Base64 = require(AudioLab.Util.Base64)

local Importer = {}

local LINE = 4096 -- base64 characters per source line (keeps the script editor responsive)
local PART_CHARS = 180000 -- per module, under Roblox's 200,000-character Source limit
local EXTENSIONS = { "wav", "aif", "aiff", "aifc", "mp3", "flac", "ogg", "oga", "mid", "midi", "sf2" }

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

-- Game scripts can't write Script.Source (it needs plugin capability), so the Studio import server
-- running in Play stores entries as StringValues instead: same base64 text, split into parts.
local VALUE_PART_CHARS = 100000
local function storeAsValues(root, path, buf, text, attributes)
	local parent, name = resolve(root, path, true)
	local old = parent:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local holder = Instance.new("StringValue")
	holder.Name = name
	local parts = math.max(1, math.ceil(#text / VALUE_PART_CHARS))
	for p = 1, parts do
		local part = Instance.new("StringValue")
		part.Name = ("part%03d"):format(p)
		part.Value = string.sub(text, (p - 1) * VALUE_PART_CHARS + 1, p * VALUE_PART_CHARS)
		part.Parent = holder
	end
	holder:SetAttribute("Parts", parts)
	holder:SetAttribute("Bytes", buffer.len(buf))
	for k, v in pairs(attributes or {}) do
		holder:SetAttribute(k, v)
	end
	holder.Parent = parent
	return holder
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

local function storeIn(root, path, bytes, attributes)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local text = Base64.encode(buf)
	if not sourceWritable() then
		return storeAsValues(root, path, buf, text, attributes)
	end
	local lines = {}
	for i = 1, #text, LINE do
		table.insert(lines, '\t"' .. string.sub(text, i, i + LINE - 1) .. '",')
	end
	local parent, name = resolve(root, path, true)
	local module = parent:FindFirstChild(name)
	if module and not module:IsA("ModuleScript") then
		module:Destroy()
		module = nil
	end
	if not module then
		module = Instance.new("ModuleScript")
		module.Name = name
	end
	for _, child in ipairs(module:GetChildren()) do
		child:Destroy()
	end
	if #text <= PART_CHARS then
		module.Source = "-- AudioLab data: base64, " .. buffer.len(buf) .. " bytes\nreturn table.concat({\n" .. table.concat(lines, "\n") .. "\n})\n"
	else
		-- Script sources are capped at 200,000 characters: split into child part modules.
		local perPart = PART_CHARS // LINE
		local partCount = math.ceil(#lines / perPart)
		for p = 1, partCount do
			local part = Instance.new("ModuleScript")
			part.Name = ("part%03d"):format(p)
			local slice = table.move(lines, (p - 1) * perPart + 1, math.min(#lines, p * perPart), 1, {})
			part.Source = "return table.concat({\n" .. table.concat(slice, "\n") .. "\n})\n"
			part.Parent = module
		end
		module.Source = ("-- AudioLab data: base64, %d bytes in %d parts\nlocal parts = {}\nfor i = 1, %d do\n\tparts[i] = require(script[(\"part%%03d\"):format(i)])\nend\nreturn table.concat(parts)\n"):format(buffer.len(buf), partCount, partCount)
	end
	module:SetAttribute("Bytes", buffer.len(buf))
	for k, v in pairs(attributes or {}) do
		module:SetAttribute(k, v)
	end
	module.Parent = parent
	return module
end

local function loadFrom(root, path)
	local parent, name = resolve(root, path, false)
	local module = parent and parent:FindFirstChild(name)
	if not module then
		error("AudioLab data not found: " .. path)
	end
	if module:IsA("StringValue") then
		local parts = {}
		for p = 1, module:GetAttribute("Parts") or 0 do
			local part = module:WaitForChild(("part%03d"):format(p), 10)
			if not part then
				error("AudioLab data incomplete (still replicating?): " .. path)
			end
			parts[p] = part.Value
		end
		return Base64.decode(table.concat(parts))
	end
	return Base64.decode(require(module))
end

local function listIn(root)
	local out = {}
	for _, d in ipairs(root:GetDescendants()) do
		-- part### modules of a large entry live inside it: they aren't entries themselves
		local entry = (d:IsA("ModuleScript") or (d:IsA("StringValue") and d:GetAttribute("Parts") ~= nil))
		if entry and not (d.Parent and (d.Parent:IsA("ModuleScript") or d.Parent:IsA("StringValue"))) then
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

function Importer.filesRoot()
	return AudioLab.Data.Files
end

function Importer.clipsRoot()
	return AudioLab.Data.Clips
end

function Importer.store(path, bytes)
	return storeIn(Importer.filesRoot(), path, bytes)
end

function Importer.load(path)
	return loadFrom(Importer.filesRoot(), path)
end

function Importer.list()
	return listIn(Importer.filesRoot())
end

function Importer.storeClip(path, bytes, attributes)
	return storeIn(Importer.clipsRoot(), path, bytes, attributes)
end

function Importer.loadClip(path)
	return loadFrom(Importer.clipsRoot(), path)
end

function Importer.listClips()
	return listIn(Importer.clipsRoot())
end

function Importer.banksRoot()
	return AudioLab.Data.Banks
end

-- Baked data (any JSON-encodable table) under Data/Banks, e.g. an analysed SoundFont.
function Importer.storeBank(path, data, attributes)
	local json = game:GetService("HttpService"):JSONEncode(data)
	return storeIn(Importer.banksRoot(), path, buffer.fromstring(json), attributes)
end

function Importer.loadBank(path)
	return game:GetService("HttpService"):JSONDecode(buffer.tostring(loadFrom(Importer.banksRoot(), path)))
end

function Importer.hasBank(path)
	local parent, name = resolve(Importer.banksRoot(), path, false)
	return parent ~= nil and parent:FindFirstChild(name) ~= nil
end

function Importer.has(path)
	local parent, name = resolve(Importer.filesRoot(), path, false)
	return parent ~= nil and parent:FindFirstChild(name) ~= nil
end

function Importer.hasClip(path)
	local parent, name = resolve(Importer.clipsRoot(), path, false)
	return parent ~= nil and parent:FindFirstChild(name) ~= nil
end

-- Opens Studio's multi-file picker. Needs plugin-level access (command bar / plugin).
-- options.Folder prefixes the stored paths. Returns the stored paths.
function Importer.prompt(options)
	options = options or {}
	local StudioService = game:GetService("StudioService")
	local files = StudioService:PromptImportFilesAsync(options.Extensions or EXTENSIONS)
	local stored = {}
	for _, file in ipairs(files or {}) do
		local path = options.Folder and (options.Folder .. "/" .. file.Name) or file.Name
		Importer.store(path, file:GetBinaryContents())
		table.insert(stored, path)
	end
	return stored
end

return Importer
