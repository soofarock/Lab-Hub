-- Asset manifests: which audio the engine uses, chosen by name.
--
--   AudioLab folder attribute  Manifest = "Lean" | "Full" | "Atlas"   (default: Manifests.Default)
--
-- Two sources of sounds (child modules):
--   Manifests.Files   per-sound manifest: every sound as its own uploaded file (name -> id), hundreds if necessary
--   Manifests.Atlas   single-file manifest: a few "packs" (uploaded files), each with the loop region of every sound
--                     inside it; a core pack plus optional ones (decays, bursts...) that a profile adds when it wants them
-- A profile picks the source and which of its sounds are in use (WaveBank.refresh applies it when a song, clip or pool
-- starts, so reselect a song after changing the attribute; a file used for the first time loads in the background, so
-- the first notes may be late):
--   source       "files" (default) or "atlas"
--   packs        atlas only: which packs of Manifests.Atlas the profile uses (default: Atlas.order)
--   include      function(name) -> bool: the sound is preloaded, warmed and used (atlas: default every sound in its packs)
--   SineRange    one sine sound (this base index) plays every pitch, or nil: the four sine bases play their own ranges
--   SharedNoise  two noise sounds play all 16 bands by playback speed, or false: every band has its own sound
-- A new profile is one more entry in Manifests.Profiles.

local Manifests = {}

Manifests.Default = "Lean"
Manifests.Files = require(script.Files)
Manifests.Atlas = require(script.Atlas)
-- individual files every profile uses, whatever its source (WaveBank.refresh adds them to any profile)
-- (tex_*: Codec.Texture; its tone / click / grain / loop files come from Texture.LAYOUT.allFiles, which follows how
-- each kind is split into upload files)
Manifests.Core = { "rough_880", "pink_noise",
	"tex_beds_01", "tex_beds_02", "tex_beds_03", "tex_beds_04", "tex_beds_05", "tex_beds_06", "tex_beds_07", "tex_beds_08",
	"tex_beds_09", "tex_beds_10", "tex_beds_11", "tex_beds_12", "tex_beds_13" }
do
	local ok, Texture = pcall(require, script.Parent:FindFirstChild("Texture"))
	local files = ok and type(Texture) == "table" and Texture.LAYOUT and Texture.LAYOUT.allFiles
		or { "tex_tones", "tex_clicks", "tex_grains2", "tex_loop" }
	for i, name in ipairs(files) do
		table.insert(Manifests.Core, 2 + i, name)
	end
end

local function startsWith(name, prefix)
	return name:sub(1, #prefix) == prefix
end

-- what typical SoundFont songs use: one sine, the waveforms
-- (General MIDI tracks without a SoundFont play from them), the harmonic bundles that exist for them and two noise sounds
local function leanSet(name)
	if startsWith(name, "wave_") then
		return not (name == "wave_sine_55" or name == "wave_sine_220" or name == "wave_sine_3520")
	elseif startsWith(name, "bundle_") then
		return name ~= "bundle_g4_110" and name ~= "bundle_g4_220"
	elseif startsWith(name, "noise_") then
		return name == "noise_4_1000" or name == "noise_6_4000"
	end
	return false
end

-- every one of the 16 noise bands as its own sound? (`has(name)`: whether a sound exists)
local NOISE = { 125, 250, 500, 1000, 2000, 4000, 8000, 16000, 88, 177, 354, 707, 1414, 2828, 5657, 11314 }
local function allNoise(has)
	for i, c in ipairs(NOISE) do
		if not has(("noise_%d_%d"):format(i, c)) then
			return false
		end
	end
	return true
end

Manifests.Profiles = {
	-- the fewest uploads: one sine plays every pitch, two noise files play all 16 bands by speed, the rough sine
	Lean = {
		description = "Fewest files: one sine for every pitch, two speed-shifted noise files, the rough sine",
		source = "files",
		SineRange = 3,
		SharedNoise = true,
		include = leanSet,
	},
	-- every file in Manifests.Files: the Lean files plus any extra sounds you upload and list there (other sine bases,
	-- the other noise bands, onset bursts, pulse bundles, decaying sines)
	Full = {
		description = "Every file in Manifests.Files",
		source = "files",
		-- plain sines from the one 880 Hz file like Lean (any idle sine player can take any note: with four sine bases
		-- hundreds of idle players piled up per base and the audio engine fell behind); the other bases are still
		-- used by the decaying / tracked sines
		SineRange = 3,
		SharedNoise = not allNoise(function(name)
			return Manifests.Files[name] ~= nil
		end), -- (all 16 bands as files: each plays its own)
		include = function(name)
			return not startsWith(name, "tex_") -- (the texture files in use come from Core: Texture.LAYOUT.allFiles)
		end,
	},
	-- your own atlas: the sounds of the packs in Manifests.Atlas (tools/audio/make_atlas.py makes the files and their
	-- entries). With no uploaded pack it plays as Lean.
	Atlas = {
		description = "Your own atlas packs (Codec/Manifests/Atlas)",
		source = "atlas",
		fallback = "Lean",
		SineRange = 3,
		SharedNoise = not allNoise(function(name)
			return Manifests.Atlas.sounds[name] ~= nil
		end),
	},
}

-- The sounds of the atlas packs a profile uses: name -> { id, pack, lead, onset, loopStart, loopEnd }
function Manifests.atlasSounds(profile)
	local out = {}
	for _, packName in ipairs(profile.packs or Manifests.Atlas.order) do
		for name, sound in pairs(Manifests.Atlas.soundsOf(packName) or {}) do
			if out[name] == nil and (not profile.include or profile.include(name)) then
				out[name] = sound
			end
		end
	end
	return out
end

-- How many sounds ("entries") profile `name` uses, and from how many distinct uploaded files. The entry count says which
-- level is in use: more entries = closer to the original (Lean < Full).
function Manifests.count(name)
	local profile = Manifests.Profiles[name]
	if not profile then
		return nil
	end
	local entries, files, seen = 0, 0, {}
	local function add(id)
		entries += 1
		if not seen[id] then
			seen[id] = true
			files += 1
		end
	end
	if profile.source == "atlas" then
		for _, sound in pairs(Manifests.atlasSounds(profile)) do
			add(sound.id)
		end
		for _, sound in ipairs(profile.extraFiles or {}) do
			if Manifests.Files[sound] then
				add(Manifests.Files[sound])
			end
		end
	else
		for sound, id in pairs(Manifests.Files) do
			if profile.include(sound) and not table.find(Manifests.Core, sound) then
				add(id)
			end
		end
	end
	for _, sound in ipairs(Manifests.Core) do
		if Manifests.Files[sound] then
			add(Manifests.Files[sound])
		end
	end
	return entries, files
end

-- The uploaded files profile `name` plays from: sound name -> asset id (the same set WaveBank.refresh loads)
function Manifests.assetsOf(name)
	local profile = Manifests.Profiles[name]
	local out = {}
	if not profile then
		return out
	end
	if profile.source == "atlas" then
		for sound, region in pairs(Manifests.atlasSounds(profile)) do
			out[sound] = region.id
		end
		for _, sound in ipairs(profile.extraFiles or {}) do
			out[sound] = out[sound] or Manifests.Files[sound]
		end
	else
		for sound, id in pairs(Manifests.Files) do
			if profile.include(sound) then
				out[sound] = id
			end
		end
	end
	for _, sound in ipairs(Manifests.Core) do
		out[sound] = Manifests.Files[sound]
	end
	return out
end

-- `folder` (AudioLabPreload.Files): one AudioPlayer per uploaded file of any profile (Name = its sound, Asset = its id, attribute
-- Profiles = "Full,Lean": the profiles that use it). The server keeps it in ReplicatedFirst.AudioLabPreload so every
-- client starts loading these files the moment it joins. This brings `folder` in line with the
-- manifests and returns how many players it added, changed or removed (0 = it was already up to date).
function Manifests.syncPreload(folder)
	local want = {} -- id -> { name, profiles }
	local names = {}
	for pname in pairs(Manifests.Profiles) do
		table.insert(names, pname)
	end
	table.sort(names)
	for _, pname in ipairs(names) do
		for sound, id in pairs(Manifests.assetsOf(pname)) do
			if id and id ~= "" then
				local w = want[id]
				if not w then
					w = { name = sound, profiles = {} }
					want[id] = w
				elseif sound < w.name then
					w.name = sound
				end
				if not table.find(w.profiles, pname) then
					table.insert(w.profiles, pname)
				end
			end
		end
	end
	local changes, have = 0, {}
	for _, child in ipairs(folder:GetChildren()) do
		local w = child:IsA("AudioPlayer") and want[child.Asset]
		if not w or have[child.Asset] then
			child:Destroy()
			changes += 1
		else
			have[child.Asset] = child
		end
	end
	for id, w in pairs(want) do
		local p = have[id]
		local profiles = table.concat(w.profiles, ",")
		if not p then
			p = Instance.new("AudioPlayer")
			p.Asset = id
			p.Name = w.name
			p:SetAttribute("Profiles", profiles)
			p.Parent = folder
			changes += 1
		elseif p.Name ~= w.name or p:GetAttribute("Profiles") ~= profiles then
			p.Name = w.name
			p:SetAttribute("Profiles", profiles)
			changes += 1
		end
	end
	return changes
end

-- every profile as { name, entries, files, source }, fewest entries first
function Manifests.levels()
	local list = {}
	for name, profile in pairs(Manifests.Profiles) do
		local entries, files = Manifests.count(name)
		table.insert(list, { name = name, entries = entries, files = files, source = profile.source or "files" })
	end
	table.sort(list, function(a, b)
		if a.entries ~= b.entries then
			return a.entries < b.entries
		end
		return a.name < b.name
	end)
	return list
end

return Manifests
