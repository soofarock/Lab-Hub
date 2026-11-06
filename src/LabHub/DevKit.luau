-- LabHub DevKit: what media is bundled in the place (FrameLab videos and pictures, AudioLab music, sounds and banks),
-- how big each one is, and a shipping check. Run it from Studio's command bar in Edit mode (changes made while
-- playing are thrown away when you stop):
--
--   local Kit = require(game.ReplicatedStorage.LabHub.DevKit)
--   Kit.list()                                  -- every bundled item with its path and size
--   Kit.remove("FrameLab/Videos/test/my_video") -- delete one item (and its bank/clip copies); Ctrl+Z undoes it
--   Kit.removeTests()                           -- delete everything kept in folders named test/tests
--   Kit.check()                                 -- shipping checklist

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local DevKit = {}

local function bytesOf(inst)
	local n = 0
	local function add(i)
		if i:IsA("LuaSourceContainer") then
			n += #i.Source
		elseif i:IsA("StringValue") or i:IsA("BinaryStringValue") then
			n += #i.Value
		end
	end
	add(inst)
	for _, d in ipairs(inst:GetDescendants()) do
		add(d)
	end
	return n
end

local function kb(n)
	return n >= 1048576 and ("%.1f MB"):format(n / 1048576) or ("%d KB"):format(math.ceil(n / 1024))
end

local function kindOf(lab, store, name)
	if lab == "FrameLab" then
		return store == "Videos" and "video" or "picture"
	end
	local low = string.lower(name)
	if store == "Banks" then
		return "bank"
	elseif store == "Clips" then
		return "sound clip"
	elseif low:match("%.mid$") or low:match("%.midi$") then
		return "music"
	elseif low:match("%.sf2$") or low:match("%.dls$") then
		return "soundfont"
	end
	return "sound"
end

-- the media stores: lab, store name, folder
local function stores()
	local list = {}
	local fl = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("FrameLab")
	local al = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
	local fd = fl and fl:FindFirstChild("Data")
	local ad = al and al:FindFirstChild("Data")
	for _, s in ipairs({ { "FrameLab", fd, "Videos" }, { "FrameLab", fd, "Images" }, { "AudioLab", ad, "Files" }, { "AudioLab", ad, "Clips" }, { "AudioLab", ad, "Banks" } }) do
		local folder = s[2] and s[2]:FindFirstChild(s[3])
		if folder then
			table.insert(list, { lab = s[1], store = s[3], folder = folder })
		end
	end
	return list
end

-- a video's sound track: AudioLab/Clips/video/<group>/<name> (listed and removed with the video)
local function videoClip(group, name)
	local clip = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
	for _, step in ipairs({ "Data", "Clips", "video", group, name }) do
		clip = clip and clip:FindFirstChild(step)
	end
	return clip
end

-- every bundled item: { path, lab, store, group, name, kind, bytes, inst }
function DevKit.items()
	local items = {}
	for _, s in ipairs(stores()) do
		for _, group in ipairs(s.folder:GetChildren()) do
			if not (s.store == "Clips" and group.Name == "video") then
				for _, item in ipairs(group:GetChildren()) do
					local bytes = bytesOf(item)
					if s.store == "Videos" then
						local clip = videoClip(group.Name, item.Name)
						bytes += clip and bytesOf(clip) or 0
					end
					table.insert(items, {
						path = ("%s/%s/%s/%s"):format(s.lab, s.store, group.Name, item.Name),
						lab = s.lab, store = s.store, group = group.Name, name = item.Name,
						kind = kindOf(s.lab, s.store, item.Name), bytes = bytes, inst = item,
					})
				end
			end
		end
	end
	table.sort(items, function(a, b)
		return a.path < b.path
	end)
	return items
end

function DevKit.list()
	local items = DevKit.items()
	local lines, total, per = {}, 0, {}
	for _, it in ipairs(items) do
		total += it.bytes
		per[it.kind] = (per[it.kind] or 0) + it.bytes
		table.insert(lines, ("  %-10s %8s   %s"):format(it.kind, kb(it.bytes), it.path))
	end
	local kinds = {}
	for k, n in pairs(per) do
		table.insert(kinds, k .. " " .. kb(n))
	end
	table.sort(kinds)
	print(("[DevKit] %d bundled items, %s in all (%s)\n%s"):format(#items, kb(total), table.concat(kinds, ", "), table.concat(lines, "\n")))
	return items
end

local function editOnly()
	if RunService:IsRunning() then
		error("[DevKit] stop Play first: changes made while playing are thrown away", 3)
	end
end

-- remove folders left empty, up to (not including) the store folders (Videos, Files, Banks, Clips, ...)
local function dropEmpty(folder)
	while folder and folder:IsA("Folder") and #folder:GetChildren() == 0 do
		local up = folder.Parent
		if not up or up.Name == "Data" then
			return
		end
		folder:Destroy()
		folder = up
	end
end

local function removeItems(match, label, extra)
	editOnly()
	local rec = ChangeHistoryService:TryBeginRecording("DevKit " .. label)
	local gone, bytes = {}, 0
	if extra then
		for _, inst in ipairs(extra) do
			bytes += bytesOf(inst)
			table.insert(gone, inst:GetFullName())
			local up = inst.Parent
			inst:Destroy()
			dropEmpty(up)
		end
	end
	for _, it in ipairs(DevKit.items()) do
		if match(it) then
			bytes += it.bytes
			local group = it.inst.Parent
			it.inst:Destroy()
			dropEmpty(group)
			table.insert(gone, it.path)
		end
	end
	if rec then
		ChangeHistoryService:FinishRecording(rec, Enum.FinishRecordingOperation.Commit)
	end
	print(("[DevKit] removed %d (%s):\n  %s"):format(#gone, kb(bytes), #gone > 0 and table.concat(gone, "\n  ") or "(nothing matched)"))
	return gone
end

-- remove one item by its path from list(). An AudioLab file also takes its bank (same group/name) and clips with
-- it; a FrameLab video also takes its sound clip (AudioLab/Clips/video/<group>/<name>).
function DevKit.remove(path)
	local lab, store, group, name = string.match(tostring(path), "^([^/]+)/([^/]+)/([^/]+)/(.+)$")
	assert(lab, "[DevKit] path looks like FrameLab/Videos/<group>/<name>; see Kit.list()")
	local items = DevKit.items()
	local found = false
	local filesInGroup = 0
	for _, it in ipairs(items) do
		found = found or it.path == path
		if it.lab == "AudioLab" and it.store == "Files" and it.group == group then
			filesInGroup += 1
		end
	end
	if not found then
		print("[DevKit] no item " .. tostring(path) .. "; see Kit.list()")
		return {}
	end
	-- a video's sound track goes with it
	local extra = {}
	local clip = lab == "FrameLab" and store == "Videos" and videoClip(group, name)
	if clip then
		table.insert(extra, clip)
	end
	return removeItems(function(it)
		if it.path == path then
			return true
		end
		if lab == "AudioLab" and store == "Files" and it.lab == "AudioLab" and it.group == group then
			-- the file's bank, and once the group's last file goes, its sound clips too
			return it.store == "Banks" and it.name == name or it.store == "Clips" and filesInGroup == 1
		end
		return false
	end, path, extra)
end

-- everything kept in a group named test or tests (FrameLab test videos/pictures, AudioLab test files and banks)
function DevKit.removeTests()
	local extra = {}
	for _, g in ipairs({ "test", "tests" }) do
		local clips = videoClip(g)
		if clips then
			table.insert(extra, clips)
		end
	end
	return removeItems(function(it)
		local g = string.lower(it.group)
		return g == "test" or g == "tests"
	end, "remove tests", extra)
end

-- shipping checklist: prints what still looks like development
function DevKit.check()
	local notes = {}
	local function note(ok, text)
		table.insert(notes, (ok and "  ok   " or "  TODO ") .. text)
	end
	local fl = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("FrameLab")
	local al = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
	note(not (fl and fl:GetAttribute("Debug")), "FrameLab Debug is off")
	note(not (al and al:GetAttribute("Debug")), "AudioLab Debug is off")
	local tests = 0
	for _, it in ipairs(DevKit.items()) do
		local g = string.lower(it.group)
		if g == "test" or g == "tests" then
			tests += it.bytes
		end
	end
	note(tests == 0, tests == 0 and "no test media bundled" or ("test media still bundled (%s): Kit.removeTests()"):format(kb(tests)))
	local hasTests = al and al:FindFirstChild("Tests")
	note(not hasTests, hasTests and "AudioLab.Tests (test scripts) is still in the place" or "no AudioLab.Tests scripts")
	local old = ReplicatedStorage:FindFirstChild("Old")
	note(not old, old and "ReplicatedStorage.Old (old experiments) is still in the place" or "no ReplicatedStorage.Old")
	note(game.PlaceId ~= 0, game.PlaceId ~= 0 and "place is published" or "place is not published (DataStore saving, records and settings need it)")
	local admins = fl and tostring(fl:GetAttribute("Admins") or "") or ""
	note(true, admins ~= "" and ("Admins: " .. admins) or "Admins: owner only")
	local total = 0
	for _, it in ipairs(DevKit.items()) do
		total += it.bytes
	end
	note(true, "bundled media: " .. kb(total))
	print("[DevKit] shipping check\n" .. table.concat(notes, "\n"))
	return notes
end

return DevKit
