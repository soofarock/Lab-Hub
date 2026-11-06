-- Atlas manifest: sounds stored as regions of a few uploaded files ("packs"), played with AudioPlayer.LoopRegion. It is
-- the sound source of the Atlas profile (Codec.Manifests: AudioLab attribute Manifest = "Atlas"): a way to play AudioLab
-- from your own uploads, a few files instead of one per sound.
--
-- Making one: tools/audio/make_atlas.py packs the generic sounds of the repo's assets/audio into WAV files and writes
-- their entries (Atlas.packs.<name> = {...}; table.insert(Atlas.order, "<name>")). Upload the WAVs, paste the entries
-- below, put each file's asset id in its pack's `id`. A pack with no id is not used.
--
-- Layout inside a pack, in units (1 unit = 375 samples = 1/128 s at 48 kHz, an exact binary fraction, so every
-- boundary is sample-exact). Each sound is { pre, onset, body, len } (a one-shot: { pre, onset, onset, len, false }),
-- in units from the start of the file:
--   pre    units of silence just before the onset
--   onset  where the sound fades in (1 ms raised-cosine ramp)
--   body   where the loop body starts (one unit after the onset); the body is a whole number of cycles
--   len    loop body length: loop region = [body, body + len] (a one-shot plays once and stops len units after onset)
-- A player started d seconds before `onset` (0 <= d <= lead) begins its sound exactly d seconds late: that is how a
-- note starts inside a 21 ms audio block instead of on its edge.

local Atlas = {
	wired = true, -- the voice pool plays from loop regions (OscillatorPool: applyRegion); false = atlas profiles use their `fallback`
	order = {}, -- packs in the order they are used; a sound in two packs plays from the first
	packs = {},
}

-- your packs (the output of tools/audio/make_atlas.py) go here

-- Atlas.soundsOf(packName) = { name -> { id, pack, lead, onset, loopStart, loopEnd | stopAt } } with times in seconds,
-- or nil when that pack has no id yet (not uploaded). The same sound name can exist in several packs, so a profile asks
-- for its packs one by one.
local cache = {}
function Atlas.soundsOf(packName)
	local pack = Atlas.packs[packName]
	if not (pack and type(pack.id) == "string" and pack.id ~= "") then
		return nil
	end
	local key = packName .. "|" .. pack.id
	if cache[key] then
		return cache[key]
	end
	local out = {}
	local sec = pack.unit / pack.rate
	for name, seg in pairs(pack.segments) do
		local sound = { id = pack.id, pack = packName, lead = seg[1] * sec, onset = seg[2] * sec }
		if seg[5] == false then
			sound.stopAt = (seg[2] + seg[4]) * sec -- one-shot: plays once, the player stops here
		else
			sound.loopStart = seg[3] * sec
			sound.loopEnd = (seg[3] + seg[4]) * sec
		end
		out[name] = sound
	end
	cache[key] = out
	return out
end

-- Atlas.sounds: every uploaded pack of Atlas.order merged, the first pack of the order winning a shared name
Atlas.sounds = {}
for _, packName in ipairs(Atlas.order) do
	for name, sound in pairs(Atlas.soundsOf(packName) or {}) do
		if Atlas.sounds[name] == nil then
			Atlas.sounds[name] = sound
		end
	end
end

return Atlas
