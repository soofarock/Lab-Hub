--!strict
-- Point LabHub at your own audio uploads (Lune: https://lune-org.github.io/docs).
--
--   1. upload the WAVs you want: any of assets/audio, and of assets/audio/extra for the Full profile (Creator Hub > Audio)
--   2. put each new id in the asset_id column of assets/audio/manifest.csv
--   3. lune run tools/set_audio_ids
--
-- Updates AudioLab.Codec.Manifests.Files in both src/LabHub (the Luau sources) and release/LabHub.rbxmx: ids that differ
-- are replaced, and a sound that gets an id for the first time (an extra sound) gets a line of its own. The game builds
-- its preload list from that module when it starts.

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local CSV = "assets/audio/manifest.csv"
local FILES_LUAU = "src/LabHub/AudioLab/Codec/Manifests/Files.luau"
local RELEASE = "release/LabHub.rbxmx"

local ids: { [string]: string } = {}
local count = 0
local first = true
for line in string.gmatch(fs.readFile(CSV), "[^\r\n]+") do
	if first then
		first = false
	else
		local name, id = string.match(line, "^([%w_]+),(%d*),")
		if name and id and id ~= "" then
			ids[name] = id
			count += 1
		end
	end
end
print(("%d ids in %s"):format(count, CSV))

local function patchSource(src: string): (string, number)
	local n = 0
	local seen = {}
	local out = string.gsub(src, '(\n%s*([%w_]+)%s*=%s*"rbxassetid://)(%d+)(")', function(head, name, old, tail)
		seen[name] = true
		local new = ids[name]
		if new and new ~= old then
			n += 1
			return head .. new .. tail
		end
		return nil
	end)
	-- sounds with an id in the csv and no line in the module yet
	local add = {}
	for name, id in ids do
		if not seen[name] then
			table.insert(add, ('\t%s = "rbxassetid://%s",\n'):format(name, id))
		end
	end
	if #add > 0 then
		table.sort(add)
		local close = string.find(out, "\n}%s*$")
		assert(close, "Files: the closing brace of the table wasn't found")
		out = string.sub(out, 1, close) .. "\t-- your own uploads\n" .. table.concat(add) .. string.sub(out, close + 1)
		n += #add
	end
	return out, n
end

-- src
if fs.isFile(FILES_LUAU) then
	local src, n = patchSource(fs.readFile(FILES_LUAU))
	fs.writeFile(FILES_LUAU, src)
	print(("%s: %d changed or added"):format(FILES_LUAU, n))
end

-- release
if fs.isFile(RELEASE) then
	local model = roblox.deserializeModel(fs.readFile(RELEASE))
	local files = model[1].AudioLab.Codec.Manifests.Files
	local src, n = patchSource(files.Source)
	files.Source = src
	fs.writeFile(RELEASE, roblox.serializeModel(model, true))
	print(("%s: %d changed or added"):format(RELEASE, n))
end
