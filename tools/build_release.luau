--!strict
-- LabHub release builder (Lune: https://lune-org.github.io/docs).
--
--   lune run tools/build_release <place.rbxl> [--private <words.txt>] [--keep-media]
--
-- Reads a saved Studio place, takes ReplicatedStorage.LabHub out of it, cleans it for release and writes:
--   release/LabHub.rbxmx    the one-file release (drop it into ReplicatedStorage)
--   src/LabHub/...          every module as a .luau file (Rojo layout; `rojo build -o LabHub.rbxmx` rebuilds the model);
--                           the README.md files already in src/LabHub are kept
--   assets/audio/manifest.csv   name, asset id, profiles, file and length of every generic audio upload
-- LabHub is ModuleScripts and Folders, plus childless Scripts and LocalScripts kept switched off (templates the code
-- clones, such as FrameLab's import and decode workers); anything else in it stops the build.
--
-- Cleaning (your working place is not changed):
--   * settings (attributes on FrameLab) go back to their defaults from LabHub.Config: no Admins, no ToolAccessList,
--     Debug off; AudioLab's runtime attributes are removed, Manifest = Lean, Debug off
--   * bundled media is removed (FrameLab Data.Videos / Data.Images, AudioLab Data.Files / Banks / Clips): the
--     release ships empty libraries (--keep-media keeps them)
--   * debug/test code is removed: AudioLab.Tests, FrameLab's debug viewer panel (FrameLabViewer)
--   * every text in the package (scripts, attributes, values, names) is checked against your private words file
--     (one word per line: your user name, UserId, e-mail, local paths ...). Default: ../private.txt next to the repo
--     folder, so it never gets committed. Any hit stops the build.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local luau = require("@lune/luau")

type Instance = any

local args = process.args
local placePath: string? = nil
local privatePath = "../private.txt"
local keepMedia = false
local i = 1
while i <= #args do
	local a = args[i]
	if a == "--private" then
		privatePath = args[i + 1]
		i += 1
	elseif a == "--keep-media" then
		keepMedia = true
	elseif placePath == nil then
		placePath = a
	end
	i += 1
end
if not placePath then
	print("usage: lune run tools/build_release <place.rbxl> [--private <words.txt>] [--keep-media]")
	process.exit(1)
end
assert(placePath)

local function fail(msg: string)
	print("BUILD STOPPED: " .. msg)
	process.exit(1)
end

---------------------------------------------------------------------------------------------------------------------
-- 1. read the place. Newer Studio files store Tags in a format rbx-dom can't read yet; tags aren't part of the
--    release, so those property chunks are dropped before decoding.
local function dropTagChunks(data: string): string
	if string.sub(data, 1, 8) ~= "<roblox!" then
		return data -- XML place: rbx-dom reads it as is
	end
	local out = { string.sub(data, 1, 32) }
	local pos = 33
	while pos <= #data do
		local name = string.sub(data, pos, pos + 3)
		local comp, ulen = string.unpack("<I4I4", data, pos + 4)
		local size = comp > 0 and comp or ulen
		local keep = true
		if name == "PROP" then
			local raw = string.sub(data, pos + 16, pos + 15 + size)
			local p = raw
			if comp > 0 then
				p = serde.decompress(string.sub(raw, 1, 4) == "\x28\xb5\x2f\xfd" and "zstd" or "lz4", raw)
			end
			local _, n = string.unpack("<I4I4", p)
			if string.sub(p, 9, 8 + n) == "Tags" then
				keep = false
			end
		end
		if keep then
			table.insert(out, string.sub(data, pos, pos + 15 + size))
		end
		pos += 16 + size
		if name == "END\0" then
			break
		end
	end
	return table.concat(out)
end

local raw = fs.readFile(placePath)
local game
if string.sub(raw, 1, 8) == "<roblox!" then
	game = roblox.deserializePlace(dropTagChunks(raw))
else
	game = roblox.deserializePlace(raw)
end
local hub = game:GetService("ReplicatedStorage"):FindFirstChild("LabHub")
if not hub then
	fail("no ReplicatedStorage.LabHub in " .. placePath)
end
local FrameLab = hub:FindFirstChild("FrameLab")
local AudioLab = hub:FindFirstChild("AudioLab")
if not FrameLab or not AudioLab or not hub:FindFirstChild("Config") then
	fail("LabHub needs FrameLab, AudioLab and Config inside it")
end

---------------------------------------------------------------------------------------------------------------------
-- 2. clean
local removed = {}
local function remove(inst: Instance?)
	if inst then
		table.insert(removed, inst:GetFullName())
		inst.Parent = nil
	end
end
local function at(root: Instance, path: { string }): Instance?
	local cur = root
	for _, step in path do
		cur = cur and cur:FindFirstChild(step)
	end
	return cur
end

-- debug / test code
remove(at(AudioLab, { "Tests" }))
remove(at(FrameLab, { "Runtime", "Client", "FrameLabViewer" }))

-- bundled media: the stores stay, empty
if not keepMedia then
	for _, store in { at(FrameLab, { "Data", "Videos" }), at(FrameLab, { "Data", "Images" }), at(AudioLab, { "Data", "Files" }),
		at(AudioLab, { "Data", "Banks" }), at(AudioLab, { "Data", "Clips" }) } do
		if store then
			for _, c in store:GetChildren() do
				if c.Name == "imports" or c.Name == "video" then
					for _, g in c:GetChildren() do
						remove(g)
					end
				else
					remove(c)
				end
			end
		end
	end
end

-- settings back to the defaults written in LabHub.Config (the DEFAULTS table)
local cfgSrc: string = hub.Config.Source
local a = string.find(cfgSrc, "local DEFAULTS = {", 1, true)
local b = a and string.find(cfgSrc, "\n}\n", a, true)
if not a or not b then
	fail("couldn't find the DEFAULTS table in LabHub.Config")
end
assert(a and b)
local tableSrc = "return " .. string.sub(cfgSrc, a + #"local DEFAULTS = ", b + 1)
local okLoad, DEFAULTS = pcall(function()
	return luau.load(luau.compile(tableSrc), { debugName = "Config.DEFAULTS" })()
end)
if not okLoad or type(DEFAULTS) ~= "table" then
	fail("couldn't read LabHub.Config DEFAULTS: " .. tostring(DEFAULTS))
end
local changed = {}
for k, v in FrameLab:GetAttributes() do
	local d = DEFAULTS[k]
	if d == nil then
		FrameLab:SetAttribute(k, nil)
		table.insert(changed, k .. " (removed)")
	elseif d ~= v then
		FrameLab:SetAttribute(k, d)
		table.insert(changed, k)
	end
end
for k, v in DEFAULTS do
	if FrameLab:GetAttribute(k) == nil then
		FrameLab:SetAttribute(k, v)
	end
end
FrameLab:SetAttribute("Admins", "")
FrameLab:SetAttribute("ToolAccessList", "")
FrameLab:SetAttribute("Debug", false)

for _, k in { "ManifestActive", "ManifestEntries" } do
	if AudioLab:GetAttribute(k) ~= nil then
		AudioLab:SetAttribute(k, nil)
		table.insert(changed, "AudioLab." .. k .. " (removed)")
	end
end
AudioLab:SetAttribute("Debug", false)
AudioLab:SetAttribute("Manifest", "Lean")

---------------------------------------------------------------------------------------------------------------------
-- 3. private words check
local words = {}
if fs.isFile(privatePath) then
	for line in string.gmatch(fs.readFile(privatePath), "[^\r\n]+") do
		local w = string.match(line, "^%s*(.-)%s*$")
		if w and w ~= "" and string.sub(w, 1, 1) ~= "#" then
			table.insert(words, string.lower(w))
		end
	end
else
	print("note: no private words file at " .. privatePath .. " (make one to have the build check for your name, UserId ...)")
end
local hits = {}
local function check(where: string, text: string)
	local low = string.lower(text)
	for _, w in words do
		if string.find(low, w, 1, true) then
			table.insert(hits, where)
			return
		end
	end
end
for _, d in { hub, table.unpack(hub:GetDescendants()) } do
	local where = d:GetFullName()
	check(where .. " (name)", d.Name)
	if d:IsA("LuaSourceContainer") then
		check(where, d.Source)
	end
	if d:IsA("StringValue") then
		check(where .. ".Value", d.Value)
	end
	for k, v in d:GetAttributes() do
		check(where .. "@" .. k, tostring(v))
	end
end
if #hits > 0 then
	fail("private words found in:\n  " .. table.concat(hits, "\n  "))
end

---------------------------------------------------------------------------------------------------------------------
-- 4. release/LabHub.rbxmx
fs.writeDir("release")
fs.writeFile("release/LabHub.rbxmx", roblox.serializeModel({ hub }, true))

---------------------------------------------------------------------------------------------------------------------
-- 5. src/: Rojo layout
--   a ModuleScript is <name>.luau, or a folder with init.luau when it has children; a Folder is a folder. Attributes
--   go in <name>.meta.json / init.meta.json.
for _, d in { hub, table.unpack(hub:GetDescendants()) } do
	if d.ClassName == "Script" or d.ClassName == "LocalScript" then
		local okE, on = pcall(function()
			return d.Enabled
		end)
		if not okE then
			okE, on = pcall(function()
				return not d.Disabled
			end)
		end
		if #d:GetChildren() > 0 or on == true then
			fail(d:GetFullName() .. " is a " .. d.ClassName .. " with children or switched on (a script in LabHub is a switched-off template)")
		end
	elseif d.ClassName ~= "ModuleScript" and d.ClassName ~= "Folder" then
		fail(d:GetFullName() .. " is a " .. d.ClassName .. " (LabHub is ModuleScripts, Folders and switched-off scripts)")
	end
end
local function attrsJson(inst: Instance): { [string]: any }?
	local t = {}
	local any = false
	for k, v in inst:GetAttributes() do
		local tv = typeof(v)
		if tv == "string" then
			t[k] = { String = v }
		elseif tv == "number" then
			t[k] = { Float64 = v }
		elseif tv == "boolean" then
			t[k] = { Bool = v }
		else
			fail("attribute " .. k .. " on " .. inst:GetFullName() .. " is a " .. tv .. " (only strings, numbers, booleans)")
		end
		any = true
	end
	return any and t or nil
end

-- file names ignore case on Windows / macOS: siblings may not differ only by case
for _, d in { hub, table.unpack(hub:GetDescendants()) } do
	local seen = {}
	for _, c in d:GetChildren() do
		local k = string.lower(c.Name)
		if seen[k] then
			fail(("%s has two children named %q and %q (same file name on Windows)"):format(d:GetFullName(), seen[k], c.Name))
		end
		seen[k] = c.Name
	end
end

local fileCount = 0
local function emit(inst: Instance, dir: string)
	local name = inst.Name
	if string.find(name, '[<>:"/\\|%?%*%.]') or name == "init" then
		fail("can't write a file for " .. inst:GetFullName() .. " (characters not allowed in a file name)")
	end
	local kids = inst:GetChildren()
	local attrs = attrsJson(inst)
	if inst.ClassName == "Script" then
		-- (a switched-off template: <name>.server.luau)
		fs.writeFile(dir .. "/" .. name .. ".server.luau", inst.Source)
		fs.writeFile(dir .. "/" .. name .. ".meta.json", serde.encode("json", { properties = { Disabled = true }, attributes = attrs }, true))
		fileCount += 1
	elseif inst.ClassName == "LocalScript" then
		-- (a switched-off template: <name>.client.luau)
		fs.writeFile(dir .. "/" .. name .. ".client.luau", inst.Source)
		fs.writeFile(dir .. "/" .. name .. ".meta.json", serde.encode("json", { properties = { Disabled = true }, attributes = attrs }, true))
		fileCount += 1
	elseif inst.ClassName == "ModuleScript" then
		if #kids == 0 then
			fs.writeFile(dir .. "/" .. name .. ".luau", inst.Source)
			if attrs then
				fs.writeFile(dir .. "/" .. name .. ".meta.json", serde.encode("json", { attributes = attrs }, true))
			end
		else
			local sub = dir .. "/" .. name
			fs.writeDir(sub)
			fs.writeFile(sub .. "/init.luau", inst.Source)
			if attrs then
				fs.writeFile(sub .. "/init.meta.json", serde.encode("json", { attributes = attrs }, true))
			end
			for _, c in kids do
				emit(c, sub)
			end
		end
		fileCount += 1
	else -- Folder
		local sub = dir .. "/" .. name
		fs.writeDir(sub)
		-- a meta file only when it says something, or to keep an empty folder in git (a needless init.meta.json would
		-- clash with a child module's Init.meta.json on Windows / macOS, where file names ignore case)
		if attrs or #kids == 0 then
			fs.writeFile(sub .. "/init.meta.json", serde.encode("json", { className = "Folder", attributes = attrs }, true))
		end
		for _, c in kids do
			emit(c, sub)
		end
	end
end

-- the folder READMEs in src/LabHub are kept: read before src/LabHub is rewritten, put back after
local readmes: { [string]: string } = {}
local function collectReadmes(dir: string)
	for _, name in fs.readDir(dir) do
		local p = dir .. "/" .. name
		if fs.isDir(p) then
			collectReadmes(p)
		elseif name == "README.md" then
			readmes[p] = fs.readFile(p)
		end
	end
end
if fs.isDir("src/LabHub") then
	collectReadmes("src/LabHub")
	fs.removeDir("src/LabHub")
end
fs.writeDir("src")
emit(hub, "src")
for p, text in readmes do
	local dir = string.match(p, "^(.*)/README.md$")
	if dir and fs.isDir(dir) then
		fs.writeFile(p, text)
	else
		print("note: " .. p .. " dropped (its folder is no longer in LabHub)")
	end
end

---------------------------------------------------------------------------------------------------------------------
-- 6. assets/audio/manifest.csv: every WAV in assets/audio and assets/audio/extra, with its asset id from
--    AudioLab.Codec.Manifests.Files (empty when the sound has no upload there). A core sound (assets/audio) is used by
--    both profiles; an extra one by Full once it has an id (the texture grains by neither: they are the beds' fallback).
local function wavSeconds(path: string): number?
	if not fs.isFile(path) then
		return nil
	end
	local d = fs.readFile(path)
	local pos = 13
	local rate, block, dataLen
	while pos + 8 <= #d do
		local id = string.sub(d, pos, pos + 3)
		local len = string.unpack("<I4", d, pos + 4)
		if id == "fmt " then
			rate = string.unpack("<I4", d, pos + 12)
			block = string.unpack("<I2", d, pos + 20)
		elseif id == "data" then
			dataLen = len
			break
		end
		pos += 8 + len + (len % 2)
	end
	return (rate and block and dataLen) and dataLen / block / rate or nil
end
local files = at(AudioLab, { "Codec", "Manifests", "Files" })
if files then
	local rows = { "name,asset_id,profiles,set,file,seconds" }
	local names = {}
	local ids = {}
	for n, id in string.gmatch(files.Source, '\n%s*([%w_]+)%s*=%s*"rbxassetid://(%d+)"') do
		table.insert(names, n)
		ids[n] = id
	end
	for _, dir in { "assets/audio", "assets/audio/extra" } do
		if fs.isDir(dir) then
			for _, f in fs.readDir(dir) do
				local n = string.match(f, "^([%w_]+)%.wav$")
				if n and ids[n] == nil then
					table.insert(names, n)
					ids[n] = ""
				end
			end
		end
	end
	table.sort(names)
	for _, n in names do
		local core = "assets/audio/" .. n .. ".wav"
		local set = fs.isFile(core) and "core" or "extra"
		local file = set == "core" and core or ("assets/audio/extra/" .. n .. ".wav")
		local prof = set == "core" and "Full,Lean" or (string.sub(n, 1, 4) == "tex_" and "" or "Full")
		local secs = wavSeconds(file)
		table.insert(rows, ('%s,%s,"%s",%s,%s,%s'):format(n, ids[n], prof, set, fs.isFile(file) and file or "", secs and ("%.4f"):format(secs) or ""))
	end
	fs.writeDir("assets/audio")
	fs.writeFile("assets/audio/manifest.csv", table.concat(rows, "\n") .. "\n")
	print(("audio manifest: %d sounds"):format(#names))
end

print(("release/LabHub.rbxmx written (%d instances)"):format(#hub:GetDescendants() + 1))
print(("src/LabHub: %d modules"):format(fileCount))
print(("cleaned: %d removed, settings reset: %s"):format(#removed, #changed > 0 and table.concat(changed, ", ") or "none"))
