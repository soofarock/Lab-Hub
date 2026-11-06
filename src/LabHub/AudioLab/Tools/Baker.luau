-- Studio-time baking: analyse a SoundFont once and store the result in Data/Banks, so games load a
-- few kilobytes of presets instead of decoding and analysing the whole .sf2 at runtime.
--
--   local bank, stats = Baker.bakeSoundFont("MySong/instruments.sf2", { Partials = 6 })
--   -- later, anywhere (any script, any Actor):  Assets.bank("MySong/instruments.sf2")
--
--   Baker.build(sf, options)  -- same analysis, kept in memory (used when a SoundFont has no baked bank)
--
-- Both yield between samples (call from a thread that can yield). options.Progress(done, total) is
-- called after each region. stats.checks lists every analysed sample with its self-check error (dB,
-- rebuilt vs original spectrum), worst first; stats.meanError is the average.

local AudioLab = script:FindFirstAncestor("AudioLab")
local Importer = require(AudioLab.Tools.Importer)
local Sf2 = require(AudioLab.Formats.Sf2)
local Instruments = require(AudioLab.Synth.Instruments)

local Baker = {}
Baker.Version = 1
Baker.FrameBudget = 0.012 -- seconds of analysis per frame before yielding

function Baker.build(sf, options)
	options = options or {}
	local flat = Sf2.flatten(sf)
	local bank = {
		version = Baker.Version,
		partials = options.Partials or Instruments.Defaults.Partials,
		hop = options.Hop or Instruments.Defaults.Hop,
		presets = {}, samples = {},
	}
	local total = 0
	for _, p in ipairs(flat) do
		total += #p.regions
	end
	local regions, samples = 0, 0
	local checks = {}
	local sliceStart = os.clock()
	for _, p in ipairs(flat) do
		local entry = { bank = p.bank, program = p.program, name = p.name, regions = {} }
		for _, r in ipairs(p.regions) do
			if os.clock() - sliceStart > Baker.FrameBudget then
				task.wait()
				sliceStart = os.clock()
			end
			local a, key = Instruments.analyseRegion(sf, r.region, options)
			if bank.samples[key] == nil then
				samples += 1
				table.insert(checks, {
					sample = key, preset = p.name, program = p.program, kind = a.kind,
					err = a.check and a.check.err or -1, steady = a.check and a.check.steady or -1,
					periodicity = a.periodicity, bundleShare = a.bundleShare,
				})
			end
			bank.samples[key] = a
			table.insert(entry.regions, {
				kl = r.keyLo, kh = r.keyHi, vl = r.velLo, vh = r.velHi, sample = key, info = Instruments.regionInfo(r.region),
			})
			regions += 1
			if options.Progress then
				options.Progress(regions, total)
			end
		end
		table.insert(bank.presets, entry)
	end
	table.sort(checks, function(x, y)
		return x.err > y.err
	end)
	local sum = 0
	for _, c in ipairs(checks) do
		sum += math.max(c.err, 0)
	end
	bank.analysisVersion = Instruments.AnalysisVersion
	return bank, { presets = #bank.presets, regions = regions, samples = samples, checks = checks, meanError = sum / math.max(#checks, 1) }
end

function Baker.bakeSoundFont(path, options)
	options = options or {}
	local t0 = os.clock()
	local sf = Sf2.decode(Importer.load(path))
	local bank, stats = Baker.build(sf, options)
	bank.source = path
	local module = Importer.storeBank(options.Name or path, bank, { Presets = stats.presets, Regions = stats.regions, Samples = stats.samples })
	stats.bytes = module:GetAttribute("Bytes")
	stats.seconds = os.clock() - t0
	return bank, stats
end

return Baker
