-- Shared asset cache: every file is decoded once per Luau VM and the result is shared.
-- Values are shared between callers: treat them as read-only.
--
--   Assets.file(path)        raw bytes (buffer) from Data/Files
--   Assets.midi(path)        decoded MIDI (Midi.decode)
--   Assets.clip(path)        RBAC clip bytes: Data/Clips/<path without extension>, or encoded from the file
--   Assets.bank(path)        baked SoundFont bank (Tools/Baker) or nil
--   Assets.soundFont(path)   decoded SF2 (fallback when there is no baked bank)
--   Assets.instruments(path) { Bank = bank }: the baked bank, or one built in memory (yields)  (pass into MidiSynth.new)
--   Assets.preload({ paths }), Assets.clear(prefix?)
--   Assets.usage() -> { files, clips } bytes held (raw files, encoded clips)
--   Assets.addSource(fn)     fn(clipPath) -> bytes (or a streamed window clip) or nil: where clips that aren't in Data/Clips come from (FrameLab adds
--                            one on clients: in-game video imports keep their sound on the server and send it on demand).
--                            On a client, a clip that isn't there waits a few seconds for a source to be added.
--
-- Concurrent requests for the same path while it is loading wait for the first one instead of
-- decoding twice. Each Actor has its own VM, so each Actor has its own cache: bake SoundFonts so
-- what every Actor loads is small.

local AudioLab = script:FindFirstAncestor("AudioLab")
local Importer = require(AudioLab.Tools.Importer)
local Midi = require(AudioLab.Formats.Midi)
local Sf2 = require(AudioLab.Formats.Sf2)
local Encoder = require(AudioLab.Codec.Encoder)

local Assets = {}
local sources = {}
function Assets.addSource(fn)
	table.insert(sources, fn)
end
local cache = {}
local loading = {}
local NONE = {}

local function get(key, loader)
	local v = cache[key]
	if v ~= nil then
		return (v ~= NONE) and v or nil
	end
	while loading[key] do
		task.wait()
		v = cache[key]
		if v ~= nil then
			return (v ~= NONE) and v or nil
		end
	end
	loading[key] = true
	local ok, result = pcall(loader)
	loading[key] = nil
	if not ok then
		error(("AudioLab.Assets: %s: %s"):format(key, tostring(result)), 0)
	end
	cache[key] = (result == nil) and NONE or result
	return result
end

function Assets.usage()
	local u = { files = 0, clips = 0 }
	for key, v in pairs(cache) do
		local n = (typeof(v) == "buffer" and buffer.len(v)) or (type(v) == "string" and #v) or 0
		if string.sub(key, 1, 5) == "file:" then
			u.files += n
		elseif string.sub(key, 1, 5) == "clip:" then
			u.clips += n
		end
	end
	return u
end

function Assets.file(path)
	return get("file:" .. path, function()
		return Importer.load(path)
	end)
end

function Assets.midi(path)
	return get("midi:" .. path, function()
		return Midi.decode(Assets.file(path))
	end)
end

function Assets.clip(path)
	return get("clip:" .. path, function()
		local clipPath = string.gsub(path, "%.%w+$", "")
		if Importer.hasClip(clipPath) then
			return Importer.loadClip(clipPath)
		end
		if Importer.has(path) then
			return (Encoder.encodeFile(Assets.file(path)))
		end
		if #sources == 0 and game:GetService("RunService"):IsClient() then
			local t0 = os.clock()
			while #sources == 0 and os.clock() - t0 < 10 do -- (a client runtime that adds one may still be starting)
				task.wait(0.1)
			end
		end
		for _, fn in ipairs(sources) do
			local ok, bytes = pcall(fn, clipPath)
			-- (or a clip that fills in as it plays: FrameLab's stream sound, a v3 window clip)
			if ok and (typeof(bytes) == "buffer" or (type(bytes) == "table" and bytes.stream == true)) then
				return bytes
			end
		end
		return (Encoder.encodeFile(Assets.file(path)))
	end)
end

function Assets.bank(path)
	return get("bank:" .. path, function()
		if Importer.hasBank(path) then
			return Importer.loadBank(path)
		end
		return nil
	end)
end

function Assets.soundFont(path)
	return get("sf2:" .. path, function()
		return Sf2.decode(Assets.file(path))
	end)
end

function Assets.instruments(path)
	local bank = Assets.bank(path)
	if bank then
		return { Bank = bank }
	end
	-- not baked: analyse every sample now (yields), so nothing is analysed mid-song
	local built = get("built:" .. path, function()
		local Baker = require(AudioLab.Tools.Baker)
		return (Baker.build(Assets.soundFont(path)))
	end)
	return { Bank = built }
end

function Assets.preload(paths)
	for _, path in ipairs(paths) do
		local ext = string.lower(string.match(path, "%.(%w+)$") or "")
		if ext == "mid" or ext == "midi" then
			Assets.midi(path)
		elseif ext == "sf2" then
			Assets.instruments(path)
		else
			Assets.clip(path)
		end
	end
end

function Assets.clear(prefix)
	for key in pairs(cache) do
		if prefix == nil or string.find(key, prefix, 1, true) then
			cache[key] = nil
		end
	end
end

return Assets
