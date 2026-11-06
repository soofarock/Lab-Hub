--!native
--!optimize 2
-- SoundFont 2 (RIFF sfbk) parser with preset -> instrument -> zone resolution.
--
-- local sf = Sf2.decode(bytes)
--   sf.info     INFO strings (INAM, isng, ...), sf.version
--   sf.presets  { {name, preset, bank, zones = {{gens, mods}}, globalZone} }
--   sf.instruments, sf.samples (shdr records)
--   Sf2.findPreset(sf, bank, program)
--   Sf2.regions(sf, bank, program, key, velocity) -> resolved playable regions:
--       { sample, sampleIndex, rootKey, tuneCents, scaleTuning, loopMode, start, finish,
--         loopStart, loopEnd, attenuation (dB), pan (-0.5..0.5), filterHz,
--         env = {delay, attack, hold, decay, sustain (0..1 level), release} (seconds),
--         exclusiveClass, gens }
--   Sf2.pitchRatio(region, key, outputRate?) -> playback-rate multiplier
--   Sf2.samplePcm(sf, sampleOrRegion) -> Signal (mono, normalized)

local AudioLab = script:FindFirstAncestor("AudioLab")
local Iff = require(AudioLab.Formats.Iff)
local Signal = require(AudioLab.DSP.Signal)

local Sf2 = {}

-- Generator operators (SoundFont 2.04, section 8.1.2)
local G = {
	startAddrsOffset = 0, endAddrsOffset = 1, startloopAddrsOffset = 2, endloopAddrsOffset = 3,
	startAddrsCoarseOffset = 4, modLfoToPitch = 5, vibLfoToPitch = 6, modEnvToPitch = 7,
	initialFilterFc = 8, initialFilterQ = 9, modLfoToFilterFc = 10, modEnvToFilterFc = 11,
	endAddrsCoarseOffset = 12, modLfoToVolume = 13, chorusEffectsSend = 15, reverbEffectsSend = 16,
	pan = 17, delayModLFO = 21, freqModLFO = 22, delayVibLFO = 23, freqVibLFO = 24,
	delayModEnv = 25, attackModEnv = 26, holdModEnv = 27, decayModEnv = 28, sustainModEnv = 29,
	releaseModEnv = 30, keynumToModEnvHold = 31, keynumToModEnvDecay = 32,
	delayVolEnv = 33, attackVolEnv = 34, holdVolEnv = 35, decayVolEnv = 36, sustainVolEnv = 37,
	releaseVolEnv = 38, keynumToVolEnvHold = 39, keynumToVolEnvDecay = 40,
	instrument = 41, keyRange = 43, velRange = 44, startloopAddrsCoarseOffset = 45,
	keynum = 46, velocity = 47, initialAttenuation = 48, endloopAddrsCoarseOffset = 50,
	coarseTune = 51, fineTune = 52, sampleID = 53, sampleModes = 54, scaleTuning = 56,
	exclusiveClass = 57, overridingRootKey = 58,
}
Sf2.Generators = G

local DEFAULTS = {
	[G.initialFilterFc] = 13500, [G.delayModLFO] = -12000, [G.delayVibLFO] = -12000,
	[G.delayModEnv] = -12000, [G.attackModEnv] = -12000, [G.holdModEnv] = -12000,
	[G.decayModEnv] = -12000, [G.releaseModEnv] = -12000,
	[G.delayVolEnv] = -12000, [G.attackVolEnv] = -12000, [G.holdVolEnv] = -12000,
	[G.decayVolEnv] = -12000, [G.releaseVolEnv] = -12000,
	[G.keynum] = -1, [G.velocity] = -1, [G.scaleTuning] = 100, [G.overridingRootKey] = -1,
}

-- Generators that are not additive at preset level (SF2 spec 8.5) or are ranges/links.
local NOT_ADDITIVE = {
	[G.startAddrsOffset] = true, [G.endAddrsOffset] = true, [G.startloopAddrsOffset] = true,
	[G.endloopAddrsOffset] = true, [G.startAddrsCoarseOffset] = true, [G.endAddrsCoarseOffset] = true,
	[G.startloopAddrsCoarseOffset] = true, [G.endloopAddrsCoarseOffset] = true,
	[G.keynum] = true, [G.velocity] = true, [G.sampleModes] = true, [G.exclusiveClass] = true,
	[G.overridingRootKey] = true, [G.instrument] = true, [G.sampleID] = true,
	[G.keyRange] = true, [G.velRange] = true,
}

local function records(chunk, size)
	if not chunk then
		error("SF2 pdta is missing a required sub-chunk")
	end
	if chunk.size % size ~= 0 then
		error(("SF2 %s size %d is not a multiple of %d"):format(chunk.id, chunk.size, size))
	end
	return Iff.reader(chunk), chunk.size // size
end

-- Generator amount: ranges are two bytes (lo, hi); everything else a signed 16-bit word.
local function readGens(r, count)
	local list = table.create(count)
	for i = 1, count do
		local oper = r:u16()
		local lo = r:u8()
		local hi = r:u8()
		local amount
		if oper == G.keyRange or oper == G.velRange then
			amount = { lo, hi }
		else
			amount = lo + hi * 256
			if oper == G.sampleID or oper == G.instrument or oper == G.sampleModes then
				-- unsigned
			elseif amount >= 32768 then
				amount -= 65536
			end
		end
		list[i] = { oper = oper, amount = amount }
	end
	return list
end

local function readBags(r, count)
	local list = table.create(count)
	for i = 1, count do
		list[i] = { gen = r:u16(), mod = r:u16() }
	end
	return list
end

-- Split a header list (phdr/inst) into zones using the bag/gen tables.
-- terminalGen: G.instrument for presets, G.sampleID for instruments.
local function buildZones(headers, bagField, bags, gens, terminalGen)
	for h = 1, #headers - 1 do -- last header is the terminal EOP/EOI record
		local header = headers[h]
		local first = header[bagField] + 1
		local last = headers[h + 1][bagField] -- exclusive in 0-based terms
		header.zones = {}
		for b = first, last do
			local bag, nextBag = bags[b], bags[b + 1]
			if not (bag and nextBag) then
				error("SF2 bag index out of range")
			end
			local zone = { gens = {}, ordered = {} }
			for gi = bag.gen + 1, nextBag.gen do
				local g = gens[gi]
				if not g then
					error("SF2 generator index out of range")
				end
				zone.gens[g.oper] = g.amount
				table.insert(zone.ordered, g)
			end
			zone.keyRange = zone.gens[G.keyRange] or { 0, 127 }
			zone.velRange = zone.gens[G.velRange] or { 0, 127 }
			if zone.gens[terminalGen] == nil then
				if #header.zones == 0 and not header.globalZone then
					header.globalZone = zone -- first zone without a terminal generator is global
				end
				-- other zones without a terminal generator are ignored per spec
			else
				table.insert(header.zones, zone)
			end
		end
	end
	headers[#headers] = nil
end

function Sf2.decode(bytes)
	local form, chunks = Iff.open(bytes)
	if form ~= "sfbk" then
		error("RIFF form is " .. form .. ", expected sfbk")
	end
	local sf = { info = {} }

	local info = Iff.findList(chunks, "INFO")
	if info then
		for _, c in ipairs(info.children) do
			local r = Iff.reader(c)
			if c.id == "ifil" and c.size >= 4 then
				sf.version = { major = r:u16(), minor = r:u16() }
			else
				sf.info[c.id] = r:cstr(c.size)
			end
		end
	end

	local sdta = Iff.findList(chunks, "sdta")
	local smpl = sdta and Iff.find(sdta.children, "smpl")
	if not smpl then
		error("SF2 has no sample data (sdta/smpl)")
	end
	sf.sampleData = smpl.body -- ByteReader window over 16-bit little-endian samples
	sf.sampleCount = smpl.size // 2

	local pdta = Iff.findList(chunks, "pdta")
	if not pdta then
		error("SF2 has no pdta list")
	end
	local p = {}
	for _, c in ipairs(pdta.children) do
		p[c.id] = c
	end

	local r, n = records(p.phdr, 38)
	local presets = table.create(n)
	for i = 1, n do
		presets[i] = {
			name = r:cstr(20), preset = r:u16(), bank = r:u16(), bagIndex = r:u16(),
			library = r:u32(), genre = r:u32(), morphology = r:u32(),
		}
	end
	r, n = records(p.pbag, 4)
	local pbags = readBags(r, n)
	r, n = records(p.pgen, 4)
	local pgens = readGens(r, n)

	r, n = records(p.inst, 22)
	local instruments = table.create(n)
	for i = 1, n do
		instruments[i] = { name = r:cstr(20), bagIndex = r:u16() }
	end
	r, n = records(p.ibag, 4)
	local ibags = readBags(r, n)
	r, n = records(p.igen, 4)
	local igens = readGens(r, n)

	r, n = records(p.shdr, 46)
	local samples = table.create(n)
	for i = 1, n do
		samples[i] = {
			name = r:cstr(20), start = r:u32(), finish = r:u32(), loopStart = r:u32(), loopEnd = r:u32(),
			sampleRate = r:u32(), originalPitch = r:u8(), pitchCorrection = r:i8(),
			sampleLink = r:u16(), sampleType = r:u16(), index = i - 1,
		}
	end
	samples[#samples] = nil -- EOS terminal record

	buildZones(presets, "bagIndex", pbags, pgens, G.instrument)
	buildZones(instruments, "bagIndex", ibags, igens, G.sampleID)

	sf.presets, sf.instruments, sf.samples = presets, instruments, samples
	sf.presetIndex = {}
	for _, pr in ipairs(presets) do
		sf.presetIndex[pr.bank * 128 + pr.preset] = pr
	end
	return sf
end

-- Percussion uses bank 128 (MIDI channel 10 is the caller's job to map).
-- Melodic banks fall back to bank 0 when the requested bank is missing (GM behaviour).
function Sf2.findPreset(sf, bank, program)
	local found = sf.presetIndex[bank * 128 + program]
	if found then
		return found
	end
	if bank ~= 128 then
		return sf.presetIndex[program]
	end
	return nil
end

local function inRange(range, v)
	return v >= range[1] and v <= range[2]
end

local function timecents(tc)
	if tc <= -12000 then
		return 0
	end
	return 2 ^ (tc / 1200)
end

local function resolve(sf, presetZone, presetGlobal, instZone, instGlobal)
	local gens = {}
	for k, v in pairs(DEFAULTS) do
		gens[k] = v
	end
	-- instrument level: absolute, local zone overrides global zone
	if instGlobal then
		for k, v in pairs(instGlobal.gens) do
			gens[k] = v
		end
	end
	for k, v in pairs(instZone.gens) do
		gens[k] = v
	end
	-- preset level: relative offsets added on top; local preset zone overrides preset global
	local presetGens = {}
	if presetGlobal then
		for k, v in pairs(presetGlobal.gens) do
			presetGens[k] = v
		end
	end
	for k, v in pairs(presetZone.gens) do
		presetGens[k] = v
	end
	for k, v in pairs(presetGens) do
		if not NOT_ADDITIVE[k] then
			gens[k] = (gens[k] or 0) + v
		end
	end

	local sampleIndex = gens[G.sampleID]
	local sample = sf.samples[sampleIndex + 1]
	if not sample then
		return nil
	end
	local function g(op)
		return gens[op] or 0
	end
	local region = { gens = gens, sample = sample, sampleIndex = sampleIndex }
	region.start = sample.start + g(G.startAddrsOffset) + g(G.startAddrsCoarseOffset) * 32768
	region.finish = sample.finish + g(G.endAddrsOffset) + g(G.endAddrsCoarseOffset) * 32768
	region.loopStart = sample.loopStart + g(G.startloopAddrsOffset) + g(G.startloopAddrsCoarseOffset) * 32768
	region.loopEnd = sample.loopEnd + g(G.endloopAddrsOffset) + g(G.endloopAddrsCoarseOffset) * 32768
	region.loopMode = bit32.band(g(G.sampleModes), 3) -- 0 none, 1 continuous, 3 until release
	region.rootKey = (g(G.overridingRootKey) >= 0) and g(G.overridingRootKey) or sample.originalPitch
	region.tuneCents = g(G.coarseTune) * 100 + g(G.fineTune) + sample.pitchCorrection
	region.scaleTuning = g(G.scaleTuning)
	region.attenuation = math.max(0, g(G.initialAttenuation)) / 10 -- centibels -> dB
	region.pan = math.clamp(g(G.pan), -500, 500) / 1000
	region.filterHz = 8.176 * 2 ^ (g(G.initialFilterFc) / 1200)
	region.exclusiveClass = g(G.exclusiveClass)
	region.env = {
		delay = timecents(g(G.delayVolEnv)), attack = timecents(g(G.attackVolEnv)),
		hold = timecents(g(G.holdVolEnv)), decay = timecents(g(G.decayVolEnv)),
		sustain = 10 ^ (-math.clamp(g(G.sustainVolEnv), 0, 1440) / 200), -- cB attenuation -> level
		release = timecents(g(G.releaseVolEnv)),
	}
	return region
end

function Sf2.regions(sf, bank, program, key, velocity)
	local preset = Sf2.findPreset(sf, bank, program)
	local out = {}
	if not preset then
		return out
	end
	for _, pz in ipairs(preset.zones) do
		local pKey = pz.gens[G.keyRange] or (preset.globalZone and preset.globalZone.keyRange) or { 0, 127 }
		local pVel = pz.gens[G.velRange] or (preset.globalZone and preset.globalZone.velRange) or { 0, 127 }
		if inRange(pKey, key) and inRange(pVel, velocity) then
			local inst = sf.instruments[pz.gens[G.instrument] + 1]
			if inst and inst.zones then
				for _, iz in ipairs(inst.zones) do
					local iKey = iz.gens[G.keyRange] or (inst.globalZone and inst.globalZone.keyRange) or { 0, 127 }
					local iVel = iz.gens[G.velRange] or (inst.globalZone and inst.globalZone.velRange) or { 0, 127 }
					if inRange(iKey, key) and inRange(iVel, velocity) then
						local region = resolve(sf, pz, preset.globalZone, iz, inst.globalZone)
						if region then
							region.instrument = inst.name
							table.insert(out, region)
						end
					end
				end
			end
		end
	end
	return out
end

-- Every playable region of every preset, with preset/instrument key and velocity ranges
-- intersected. Returns { { bank, program, name, regions = { { keyLo, keyHi, velLo, velHi, region } } } }.
function Sf2.flatten(sf)
	local out = {}
	for _, preset in ipairs(sf.presets) do
		local entry = { bank = preset.bank, program = preset.preset, name = preset.name, regions = {} }
		local pg = preset.globalZone
		for _, pz in ipairs(preset.zones) do
			local pKey = pz.gens[G.keyRange] or (pg and pg.keyRange) or { 0, 127 }
			local pVel = pz.gens[G.velRange] or (pg and pg.velRange) or { 0, 127 }
			local inst = sf.instruments[pz.gens[G.instrument] + 1]
			if inst and inst.zones then
				local ig = inst.globalZone
				for _, iz in ipairs(inst.zones) do
					local iKey = iz.gens[G.keyRange] or (ig and ig.keyRange) or { 0, 127 }
					local iVel = iz.gens[G.velRange] or (ig and ig.velRange) or { 0, 127 }
					local kl, kh = math.max(pKey[1], iKey[1]), math.min(pKey[2], iKey[2])
					local vl, vh = math.max(pVel[1], iVel[1]), math.min(pVel[2], iVel[2])
					if kl <= kh and vl <= vh then
						local region = resolve(sf, pz, pg, iz, ig)
						if region then
							region.instrument = inst.name
							table.insert(entry.regions, { keyLo = kl, keyHi = kh, velLo = vl, velHi = vh, region = region })
						end
					end
				end
			end
		end
		table.insert(out, entry)
	end
	return out
end

-- Playback-rate multiplier for a key. With outputRate, also folds in the sample-rate ratio.
function Sf2.pitchRatio(region, key, outputRate)
	local semis = (key - region.rootKey) * region.scaleTuning / 100 + region.tuneCents / 100
	local ratio = 2 ^ (semis / 12)
	if outputRate then
		ratio *= region.sample.sampleRate / outputRate
	end
	return ratio
end

-- Decode a sample (shdr record or region) to a normalized mono Signal.
-- For a region, uses its offset-adjusted start/finish. Loop points are returned relative.
function Sf2.samplePcm(sf, item)
	local sample = item.sample or item
	local start = item.start or sample.start
	local finish = item.finish or sample.finish
	start = math.clamp(start, 0, sf.sampleCount)
	finish = math.clamp(finish, start, sf.sampleCount)
	local n = finish - start
	local signal = Signal.new(sample.sampleRate > 0 and sample.sampleRate or 44100, 1, n)
	local src = sf.sampleData.buf
	local base = sf.sampleData.base + start * 2
	local dst = signal.data[1]
	for i = 0, n - 1 do
		buffer.writef32(dst, i * 4, buffer.readi16(src, base + i * 2) / 32768)
	end
	signal.loopStart = (item.loopStart or sample.loopStart) - start
	signal.loopEnd = (item.loopEnd or sample.loopEnd) - start
	signal.rootKey = item.rootKey or sample.originalPitch
	return signal
end

return Sf2
