-- Started by FrameLab:init() on the server: the settings panel's server side (the game's owner only; anyone in a
-- Studio test). The settings are the attributes on the FrameLab and AudioLab folders. Changes apply at once (they
-- replicate); Save keeps them in a DataStore, and every server applies the saved ones when it starts, over the place's
-- own values. Clear removes the saved ones (the place's values come back on the next server).
--
-- Requests: settingsGet, settingsSet(folder, key, value), settingsSave, settingsClear, settingsDefault(folder, key)
return function(FrameLab)
	local RunService = game:GetService("RunService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local root = script:FindFirstAncestor("FrameLab")
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))

	local STORE, KEY = "LabSettings_v1", "settings"

	-- the settings: FrameLab's (Config.Defaults) and AudioLab's
	local AUDIO = {
		{ key = "Manifest", default = "Lean", choices = { "Lean", "Full", "Atlas" }, note = "sound set: Lean (the shared uploads), Full (plus your own extra uploads) or Atlas (your own atlas)" },
		{ key = "Debug", default = false, note = "testing aids: logs, the old comparison versions in the music player" },
	}
	local SKIP = {}
	-- FrameLab settings with a fixed set of values (a dropdown in the panel)
	local CHOICES = {
		SprayPerformanceMode = { "auto", "on", "off" },
		ImportVideoQuality = { "144p", "240p", "360p" },
		TVToolAccess = { "everyone", "admins", "owner", "list", "nobody" },
		SprayToolAccess = { "everyone", "admins", "owner", "list", "nobody" },
	}
	-- lists of people (UserIds or names, comma-separated): edited as a list in the panel
	local PEOPLE = { Admins = true, ToolAccessList = true }
	local function folders()
		return { FrameLab = root, AudioLab = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab") }
	end
	local function schema()
		local list = {}
		local keys = {}
		for k in pairs(Config.Defaults) do
			if not SKIP[k] then
				table.insert(keys, k)
			end
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			table.insert(list, { folder = "FrameLab", key = k, default = Config.Defaults[k], choices = CHOICES[k], people = PEOPLE[k] })
		end
		if folders().AudioLab then
			for _, s in ipairs(AUDIO) do
				table.insert(list, { folder = "AudioLab", key = s.key, default = s.default, choices = s.choices, note = s.note })
			end
		end
		return list
	end
	local function find(folder, key)
		for _, s in ipairs(schema()) do
			if s.folder == folder and s.key == key then
				return s
			end
		end
		return nil
	end
	local function valueOf(s)
		local f = folders()[s.folder]
		local v = f and f:GetAttribute(s.key)
		if v == nil then
			v = s.default
		end
		return v
	end

	local store, storeError
	local ok, err = pcall(function()
		store = game:GetService("DataStoreService"):GetDataStore(STORE)
	end)
	if not ok then
		storeError = tostring(err)
	end
	local saved -- the saved table, or nil

	-- the saved settings, over the place's (every server, at start)
	local function apply(t)
		if type(t) ~= "table" then
			return
		end
		for folderName, values in pairs(t) do
			local f = folders()[folderName]
			if f and type(values) == "table" then
				for k, v in pairs(values) do
					local s = find(folderName, k)
					if s and typeof(v) == typeof(s.default) then
						f:SetAttribute(k, v)
					end
				end
			end
		end
	end
	-- read in the background, so requests are answered from the start; a request that needs the saved settings waits
	-- for the read (up to 10 s)
	local loaded = store == nil
	if store then
		task.spawn(function()
			local okG, v = pcall(store.GetAsync, store, KEY)
			if okG then
				saved = v
				apply(v)
			else
				storeError = tostring(v)
			end
			loaded = true
		end)
	end
	local function whenLoaded()
		local t = os.clock()
		while not loaded and os.clock() - t < 10 do
			task.wait(0.1)
		end
	end

	local function isOwner(player)
		if RunService:IsStudio() then
			return true
		end
		if game.CreatorType == Enum.CreatorType.User then
			return player.UserId == game.CreatorId
		end
		local okR, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
		return okR and rank >= 255
	end

	local t0 = os.clock()
	while not FrameLab.Server and os.clock() - t0 < 30 do
		task.wait(0.1)
	end
	if not FrameLab.Server then
		return
	end
	local h = FrameLab.Server.handlers

	h.settingsGet = function(player)
		if not isOwner(player) then
			return { owner = false }
		end
		whenLoaded()
		local items = {}
		for _, s in ipairs(schema()) do
			local sv = nil
			if type(saved) == "table" and type(saved[s.folder]) == "table" then
				sv = saved[s.folder][s.key]
			end
			table.insert(items, {
				folder = s.folder, key = s.key, value = valueOf(s), default = s.default, kind = s.people and "people" or typeof(s.default),
				choices = s.choices, note = s.note, saved = sv ~= nil, changed = sv ~= nil and sv ~= valueOf(s),
			})
		end
		return { owner = true, items = items, store = store ~= nil and storeError == nil, storeError = storeError, hasSaved = saved ~= nil }
	end

	h.settingsSet = function(player, folder, key, value)
		whenLoaded() -- (a change made before the saved settings arrive would be overwritten by them)
		if not isOwner(player) then
			return { error = "only the owner" }
		end
		local s = find(folder, key)
		if not s then
			return { error = "no such setting" }
		end
		if typeof(value) ~= typeof(s.default) then
			return { error = ("%s takes a %s"):format(key, typeof(s.default)) }
		end
		if type(value) == "number" and (value ~= value or math.abs(value) == math.huge) then
			return { error = "not a number" }
		end
		if s.choices and not table.find(s.choices, value) then
			return { error = "pick one of: " .. table.concat(s.choices, ", ") }
		end
		folders()[folder]:SetAttribute(key, value)
		return { ok = true, value = value }
	end

	-- people: a name or a UserId -> { userId, name } (Roblox's lookups, cached)
	local Players = game:GetService("Players")
	local nameCache, idCache = {}, {}
	local function nameOf(id)
		if nameCache[id] == nil then
			local p = Players:GetPlayerByUserId(id)
			if p then
				nameCache[id] = p.Name
			else
				local okN, n = pcall(Players.GetNameFromUserIdAsync, Players, id)
				nameCache[id] = okN and n or false
			end
		end
		return nameCache[id] or nil
	end
	local function idOf(name)
		local key = string.lower(name)
		if idCache[key] == nil then
			for _, p in ipairs(Players:GetPlayers()) do
				if string.lower(p.Name) == key or string.lower(p.DisplayName) == key then
					idCache[key] = p.UserId
					nameCache[p.UserId] = p.Name
				end
			end
			if idCache[key] == nil then
				local okI, id = pcall(Players.GetUserIdFromNameAsync, Players, name)
				idCache[key] = okI and id or false
			end
		end
		return idCache[key] or nil
	end
	h.settingsResolve = function(player, text)
		if not isOwner(player) or type(text) ~= "string" then
			return nil
		end
		text = string.gsub(text, "^%s*@?(.-)%s*$", "%1")
		local id = tonumber(text)
		if id then
			local n = nameOf(id)
			return n and { userId = id, name = n } or { error = "no Roblox user with id " .. text }
		end
		local uid = idOf(text)
		return uid and { userId = uid, name = nameOf(uid) or text } or { error = "no Roblox user named " .. text }
	end
	-- the people in a list setting, with names and ids filled in where Roblox knows them
	h.settingsPeople = function(player, folder, key)
		if not isOwner(player) then
			return nil
		end
		local s = find(folder, key)
		if not s or not s.people then
			return nil
		end
		local out = {}
		for entry in string.gmatch(tostring(valueOf(s)), "[^,%s]+") do
			local id = tonumber(entry)
			if id then
				table.insert(out, { entry = entry, userId = id, name = nameOf(id), byId = true })
			else
				table.insert(out, { entry = entry, name = entry, userId = idOf(entry), byId = false })
			end
		end
		local online = {}
		for _, p in ipairs(Players:GetPlayers()) do
			table.insert(online, { userId = p.UserId, name = p.Name, display = p.DisplayName })
		end
		return { entries = out, online = online }
	end

	h.settingsDefault = function(player, folder, key)
		if not isOwner(player) then
			return { error = "only the owner" }
		end
		local s = find(folder, key)
		if not s then
			return { error = "no such setting" }
		end
		folders()[folder]:SetAttribute(key, s.default)
		return { ok = true, value = s.default }
	end

	-- keep every setting's current value; every server applies them when it starts
	h.settingsSave = function(player)
		whenLoaded()
		if not isOwner(player) then
			return { error = "only the owner" }
		end
		if not store then
			return { error = "no DataStore: " .. tostring(storeError) }
		end
		local t = {}
		for _, s in ipairs(schema()) do
			t[s.folder] = t[s.folder] or {}
			t[s.folder][s.key] = valueOf(s)
		end
		local okS, e = pcall(store.SetAsync, store, KEY, t)
		if not okS then
			return { error = "couldn't save: " .. tostring(e) .. (RunService:IsStudio() and " (Studio: Game Settings > Security > Enable Studio Access to API Services)" or "") }
		end
		saved = t
		return { ok = true }
	end

	h.settingsClear = function(player)
		whenLoaded()
		if not isOwner(player) then
			return { error = "only the owner" }
		end
		if not store then
			return { error = "no DataStore: " .. tostring(storeError) }
		end
		local okR, e = pcall(store.RemoveAsync, store, KEY)
		if not okR then
			return { error = "couldn't clear: " .. tostring(e) }
		end
		saved = nil
		return { ok = true }
	end
end
