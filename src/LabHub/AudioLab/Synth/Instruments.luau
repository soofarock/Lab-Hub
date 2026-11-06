--!optimize 2
-- Instrument presets for MidiSynth.
--
--   Instruments.gm(program)    General MIDI family defaults (single waveform + envelope)
--   Instruments.drum(key)      synthesized GM drum (MIDI channel 10 when no SoundFont)
--   Instruments.fromSoundFont(sf, bank, program, key, velocity, options)
--   Instruments.fromBank(bankData, bank, program, key, velocity, options)   -- baked (Tools/Baker)
--   Instruments.analyse(pcm, info, options)  -> analysis table (JSON-safe, used by the baker)
--
-- SoundFont samples are analysed over time, in the sample's own clock:
--   * partials: the strongest harmonics (k * f0) and their amplitude every `hop` seconds through the
--     attack/one-shot body, plus the steady spectrum of the loop. Played back as one sine voice per
--     partial (additive synthesis), so the tone follows the real sample instead of one fixed shape.
--   * noise: for non-periodic samples (percussion, breath), 16-band noise chain levels over time.
--   * wave/volume: the single closest WaveBank waveform (cheap fallback, options.Mode = "wave").
-- The SoundFont volume envelope is applied on top, as an SF2 player would.
--
--   preset = { name, delay, attack, hold, decay, sustain (0..1), release, transpose (semitones),
--              speed (sample-time per second), gain, wave,             -- single-wave fields
--              additive = analysis?, noise = { frames, loop?, hop }? }
--   Decay and release are SoundFont times: the level falls 96/time dB per second.

local AudioLab = script:FindFirstAncestor("AudioLab")
local WaveBank = require(AudioLab.Codec.WaveBank)
local Analyzer = require(AudioLab.Codec.Analyzer)
local Sf2 = require(AudioLab.Formats.Sf2)
local FFT = require(AudioLab.DSP.FFT)

local Instruments = {}

local W = {}
for i, w in ipairs(WaveBank.Waves) do
	W[w.name] = i
end
Instruments.WaveIndex = W

Instruments.Defaults = {
	Partials = 10, -- most sine voices per note in additive mode
	-- Cycle = "exact": a sample that reaches a loop of whole waveform periods within CycleMaxAttack seconds is one
	-- fixed waveform; it is played as its own harmonics (every one above CycleFloor dB), exact level and phase.
	-- Chosen automatically for every sample that qualifies; false turns it off.
	Cycle = "exact",
	-- Harmonic = "auto": see harmonicChoice (steered pairs / exact fixed-phase harmonics / the normal analysis)
	Peaks = "auto", -- bell-like samples (bundles misfit by >= PeaksMinError dB): a sine at each real overtone
	PeaksMinError = 12,
	Smooth = false, -- sines as phase-steered pairs: smooth fades, no block-stepped echo
	-- Modes = "auto": the strong harmonics of a one-shot are fitted as 1-ModesOrder damped sinusoids each (see modesFit);
	-- a harmonic is replaced by its modes when they match it within ModesMinSNR dB
	Modes = "auto",
	ModesMinSNR = 15,
	ModesOrder = 4,
	ModesMax = 10,
	ModesStrong = -24,
	Images = true, -- the original's resampling character: in-band softening + mirror images (see playbackImages)
	Hold = false, -- held loops whose bundles misfit by >= HoldMinError dB: exact sines once the loop starts
	HoldMinError = 5,
	Harmonic = false, -- "auto" picks exact harmonics / steered pairs per sample
	HarmonicFloor = -50,
	HarmonicMax = 64,
	HarmonicMinShare = 0.75,
	HarmonicSteerGain = 3,
	HarmonicMinError = 5,
	CycleFloor = -50,
	CycleMax = 64,
	CycleMaxAttack = 0.04,
	MinPartials = 3,
	EnergyTarget = 0.98, -- add partials (strongest first) until they carry this share of the harmonic energy
	MaxHarmonic = 20, -- highest harmonic considered when choosing partials
	Hop = 0.01, -- analysis step in sample time (seconds)
	FramePeriods = 4, -- frame analysis window: this many periods of the sample's pitch (sharper attacks)
	MaxAnalysis = 1.5, -- seconds of attack / one-shot body analysed
	MaxTrack = 3, -- seconds of pitched sample (attack + one loop pass) analysed frame by frame
	-- Harmonics 9-16 become sines too (instead of one bundle) when the bundle's fixed 1/k tilt misplaces more than
	-- ExtraSineMismatch of the sample's energy (basses, mellow leads: their upper harmonics fall much faster than 1/k,
	-- so the bundle made them buzzy). ExtraSines = 0: always 8 sines.
	ExtraSines = 16,
	ExtraSineMismatch = 0.05,
	-- Voice mode: breathy samples (choirs, vocals) are tonal only in their lowest harmonics; the rest is noise-like
	-- with a little pitch wobble. Played as a periodic comb (sines + bundles) that buzzes. In voice mode only the first
	-- VoiceHarmonics harmonics become sines and everything above is noise (the valley level between harmonics,
	-- through the noise chain). Voice = "auto": a tonal sample whose normal fit error is >= VoiceMinErr is analysed
	-- again in voice mode and kept if that fits at most VoiceGain times as badly; false: never; "force": always.
	Voice = "auto",
	VoiceShare = 0.85, -- a harmonic counts as tonal while its (neighbour-smoothed) peak share is at least this
	VoiceMinErr = 0.3,
	VoiceGain = 0.6,
}

-- General MIDI --------------------------------------------------------------------------

local FAMILIES = {
	[0] = { name = "piano", wave = W.triangle, gain = 0.55, attack = 0.004, decay = 3.5, sustain = 0.15, release = 0.8 },
	[1] = { name = "chromatic percussion", wave = W.sine, gain = 0.6, attack = 0.002, decay = 1.5, sustain = 0.0, release = 0.9 },
	[2] = { name = "organ", wave = W.square, gain = 0.3, attack = 0.012, decay = 0.1, sustain = 1.0, release = 0.15 },
	[3] = { name = "guitar", wave = W.pulse25, gain = 0.35, attack = 0.004, decay = 2.0, sustain = 0.1, release = 0.55 },
	[4] = { name = "bass", wave = W.triangle, gain = 0.65, attack = 0.006, decay = 0.9, sustain = 0.6, release = 0.25 },
	[5] = { name = "strings", wave = W.saw, gain = 0.3, attack = 0.18, decay = 0.7, sustain = 0.85, release = 1.0 },
	[6] = { name = "ensemble", wave = W.saw, gain = 0.28, attack = 0.25, decay = 0.7, sustain = 0.85, release = 1.3 },
	[7] = { name = "brass", wave = W.saw, gain = 0.32, attack = 0.05, decay = 0.55, sustain = 0.75, release = 0.45 },
	[8] = { name = "reed", wave = W.square, gain = 0.3, attack = 0.03, decay = 0.45, sustain = 0.85, release = 0.35 },
	[9] = { name = "pipe", wave = W.triangle, gain = 0.5, attack = 0.05, decay = 0.45, sustain = 0.9, release = 0.45 },
	[10] = { name = "synth lead", wave = W.saw, gain = 0.3, attack = 0.008, decay = 0.45, sustain = 0.9, release = 0.25 },
	[11] = { name = "synth pad", wave = W.triangle, gain = 0.45, attack = 0.45, decay = 1.1, sustain = 0.85, release = 2.0 },
	[12] = { name = "synth effects", wave = W.pulse12, gain = 0.3, attack = 0.1, decay = 1.3, sustain = 0.6, release = 1.5 },
	[13] = { name = "ethnic", wave = W.pulse25, gain = 0.35, attack = 0.006, decay = 1.3, sustain = 0.25, release = 0.65 },
	[14] = { name = "percussive", wave = W.sine, gain = 0.6, attack = 0.001, decay = 0.8, sustain = 0.0, release = 0.45 },
	[15] = { name = "sound effects", wave = W.pulse12, gain = 0.3, attack = 0.05, decay = 1.1, sustain = 0.5, release = 1.1 },
}
local OVERRIDES = {
	[16] = { wave = W.pulse12 },
	[73] = { wave = W.sine, gain = 0.6 },
	[80] = { wave = W.square, gain = 0.3 },
	[81] = { wave = W.saw },
}

local gmCache = {}
function Instruments.gm(program)
	program = math.clamp(program or 0, 0, 127)
	local cached = gmCache[program]
	if cached then
		return cached
	end
	local p = table.clone(FAMILIES[program // 8])
	for k, v in pairs(OVERRIDES[program] or {}) do
		p[k] = v
	end
	p.program = program
	gmCache[program] = p
	return p
end

-- Synthesized drum kit (no SoundFont) ---------------------------------------------------

local function kit(tone, noise)
	return { tone = tone, noise = noise }
end
local DRUMS = {
	kick = kit({ wave = W.sine, from = 160, to = 48, sweep = 0.06, decay = 0.35, gain = 1.0 }, { bands = { 1, 2 }, levels = { 0.4, 0.2 }, decay = 0.03 }),
	snare = kit({ wave = W.triangle, from = 240, to = 180, sweep = 0.02, decay = 0.08, gain = 0.5 }, { bands = { 4, 5, 6, 7 }, levels = { 0.5, 0.8, 0.8, 0.5 }, decay = 0.14 }),
	clap = kit(nil, { bands = { 4, 5, 6 }, levels = { 0.6, 0.9, 0.6 }, decay = 0.11 }),
	hatClosed = kit(nil, { bands = { 7, 8 }, levels = { 0.5, 0.6 }, decay = 0.045 }),
	hatPedal = kit(nil, { bands = { 7, 8 }, levels = { 0.35, 0.4 }, decay = 0.07 }),
	hatOpen = kit(nil, { bands = { 6, 7, 8 }, levels = { 0.25, 0.5, 0.6 }, decay = 0.35 }),
	crash = kit(nil, { bands = { 5, 6, 7, 8 }, levels = { 0.3, 0.55, 0.6, 0.5 }, decay = 1.2 }),
	ride = kit({ wave = W.sine, from = 3200, to = 3200, sweep = 0, decay = 0.4, gain = 0.08 }, { bands = { 6, 7, 8 }, levels = { 0.2, 0.35, 0.3 }, decay = 0.6 }),
	tomLow = kit({ wave = W.sine, from = 140, to = 80, sweep = 0.12, decay = 0.35, gain = 0.8 }, { bands = { 2, 3 }, levels = { 0.15, 0.1 }, decay = 0.04 }),
	tomMid = kit({ wave = W.sine, from = 200, to = 120, sweep = 0.1, decay = 0.3, gain = 0.8 }, { bands = { 3, 4 }, levels = { 0.15, 0.1 }, decay = 0.04 }),
	tomHigh = kit({ wave = W.sine, from = 280, to = 170, sweep = 0.08, decay = 0.25, gain = 0.8 }, { bands = { 3, 4 }, levels = { 0.15, 0.1 }, decay = 0.04 }),
	rim = kit({ wave = W.triangle, from = 800, to = 700, sweep = 0.01, decay = 0.03, gain = 0.4 }, { bands = { 5, 6 }, levels = { 0.4, 0.3 }, decay = 0.02 }),
	shaker = kit(nil, { bands = { 6, 7 }, levels = { 0.3, 0.3 }, decay = 0.06 }),
	cowbell = kit({ wave = W.square, from = 560, to = 560, sweep = 0, decay = 0.25, gain = 0.25 }, nil),
	default = kit(nil, { bands = { 5, 6 }, levels = { 0.4, 0.4 }, decay = 0.1 }),
}
local DRUM_KEYS = {
	[35] = "kick", [36] = "kick", [37] = "rim", [38] = "snare", [39] = "clap", [40] = "snare",
	[41] = "tomLow", [42] = "hatClosed", [43] = "tomLow", [44] = "hatPedal", [45] = "tomMid",
	[46] = "hatOpen", [47] = "tomMid", [48] = "tomHigh", [49] = "crash", [50] = "tomHigh",
	[51] = "ride", [52] = "crash", [53] = "ride", [54] = "shaker", [55] = "crash", [56] = "cowbell",
	[57] = "crash", [59] = "ride", [69] = "shaker", [70] = "shaker", [82] = "shaker",
}
Instruments.DrumKit = DRUMS
function Instruments.drum(key)
	return DRUMS[DRUM_KEYS[key] or "default"]
end

-- Sample analysis -----------------------------------------------------------------------
--
-- Version 2. Every sample is first tested for periodicity at its root-key period (normalised
-- autocorrelation, best lag within +-3%): >= PeriodicThreshold is tonal, below is noise.
--   tonal: per frame, the amplitudes of harmonics 1..8 (one sine each) and the energy of each higher
--          octave of harmonics (9-16, 17-32, 33-64, 65-128), carried at runtime by the WaveBank
--          harmonic bundles. Every harmonic region is measured, so nothing is dropped.
--   noise: per frame, the levels of the 16-band noise chain (overlapping bands every half octave),
--          fitted to the sample's half-octave spectrum.
-- check: the rebuilt spectrum is compared with the sample's own (half-octave bins, loudness-weighted
-- mean |dB| error over bins within 40 dB of the loudest), so every baked instrument carries a score.

local ANALYSIS_VERSION = 2
Instruments.AnalysisVersion = ANALYSIS_VERSION
local SINES = WaveBank.Sines
local GROUPS = WaveBank.BundleGroups
local CHAIN = WaveBank.NoiseChain
local CHAIN_N = #CHAIN
local BINS = WaveBank.ChainBins
local LOW = WaveBank.ChainLowShare

local function round(x)
	if x == 0 then
		return 0
	end
	local mag = 10 ^ (math.floor(math.log10(math.abs(x))) - 3)
	return math.floor(x / mag + 0.5) * mag -- 4 significant digits keeps baked banks small
end

local function roundRow(row)
	for i = 1, #row do
		row[i] = round(row[i])
	end
	return row
end

-- main-lobe amplitude of harmonics k = 1..K from a transformed frame
local function harmonicAmps(re, im, n, rate, f0, K, powScale, out, offset)
	offset = offset or 0
	local half = n // 2
	for k = 1, K do
		local center = k * f0 * n / rate + 1
		local spread = math.max(1, center * 0.03)
		local lo = math.max(2, math.floor(center - spread))
		local hi = math.min(half, math.ceil(center + spread))
		local best, bi = -1, nil
		for j = lo, hi do
			local e = re[j] * re[j] + im[j] * im[j]
			if e > best then
				best, bi = e, j
			end
		end
		local amp = 0
		if bi then
			local e = 0
			for j = math.max(2, bi - 2), math.min(half, bi + 2) do
				e += re[j] * re[j] + im[j] * im[j]
			end
			amp = math.sqrt(2 * powScale * e)
		end
		out[offset + k] = amp
	end
	return out
end

local function binOf(hz)
	if hz < 20 then
		return nil
	end
	local i = math.floor(2 * math.log(hz / WaveBank.ChainEdge, 2)) + 1
	return math.clamp(i, 1, BINS)
end

-- mean-square energy of the frame between loHz (inclusive) and hiHz (exclusive)
local function rangeEnergy(re, im, n, rate, loHz, hiHz, powScale)
	local hz = rate / n
	local lo = math.max(2, math.ceil(loHz / hz) + 1)
	local hi = math.min(n // 2, math.ceil(hiHz / hz))
	local e = 0
	for j = lo, hi do
		e += re[j] * re[j] + im[j] * im[j]
	end
	return e * powScale
end

-- sine-equivalent amplitude of harmonics 1..K: all energy within f0/2 of k*f0 (vibrato smear included)
local function regionAmps(re, im, n, rate, f0, K, powScale, out, offset)
	for k = 1, K do
		out[offset + k] = math.sqrt(2 * rangeEnergy(re, im, n, rate, (k - 0.5) * f0, (k + 0.5) * f0, powScale))
	end
	return out
end

-- Share of a steady harmonic's energy that a Hann frame of `periods` periods keeps within f0/4 of k*f0 (averaged over
-- where the harmonic falls between FFT bins). The rest leaks into the gaps between harmonics, where it would
-- be counted as noise: a short frame (4 periods) leaks ~7%, a hiss ~11 dB under every harmonic.
local LEAK_P = { 2, 3, 4, 5, 6, 8, 10 }
local LEAK_L = { 0.641, 0.822, 0.928, 0.977, 0.996, 0.999, 1 }
local function peakShare(periods)
	if periods <= LEAK_P[1] then
		return LEAK_L[1]
	end
	for i = 2, #LEAK_P do
		if periods <= LEAK_P[i] then
			local t = (periods - LEAK_P[i - 1]) / (LEAK_P[i] - LEAK_P[i - 1])
			return LEAK_L[i - 1] + (LEAK_L[i] - LEAK_L[i - 1]) * t
		end
	end
	return 1
end

-- sine amplitude of harmonics 1..K without the noise between them: the peak (within f0/4, leakage restored) or
-- the whole cell, whichever is smaller. The cell's noise is carried by the residual instead (not twice).
local function peakAmps(re, im, n, rate, f0, K, powScale, out, offset, share)
	for k = 1, K do
		local cell = rangeEnergy(re, im, n, rate, (k - 0.5) * f0, (k + 0.5) * f0, powScale)
		local peak = rangeEnergy(re, im, n, rate, (k - 0.25) * f0, (k + 0.25) * f0, powScale) / share
		out[offset + k] = math.sqrt(2 * math.min(cell, peak))
	end
	return out
end

-- harmonic-aligned bins for the self-check: each harmonic region's energy goes to the bin of k*f0, so a
-- harmonic sitting on a bin edge isn't counted as an error
local function alignedBins(re, im, n, rate, f0, powScale, out)
	out = out or table.create(BINS, 0)
	for i = 1, BINS do
		out[i] = 0
	end
	local top = math.min(rate / 2, WaveBank.BundleTop)
	local b0 = binOf(math.max(20, f0 * 0.25))
	if b0 then
		out[b0] += rangeEnergy(re, im, n, rate, 20, f0 * 0.5, powScale)
	end
	local k = 1
	while (k - 0.5) * f0 < top do
		local b = binOf(k * f0)
		if b then
			out[b] += rangeEnergy(re, im, n, rate, (k - 0.5) * f0, math.min((k + 0.5) * f0, top), powScale)
		end
		k += 1
	end
	return out
end

-- energy near the harmonics (within f0/4 of k*f0), per chain bin: what the sines and bundles can carry
local function harmonicBins(re, im, n, rate, f0, powScale, out)
	for i = 1, BINS do
		out[i] = 0
	end
	local top = math.min(rate / 2, WaveBank.BundleTop)
	local k = 1
	while (k + 0.25) * f0 < top do
		local b = binOf(k * f0)
		if b then
			out[b] += rangeEnergy(re, im, n, rate, (k - 0.25) * f0, (k + 0.25) * f0, powScale)
		end
		k += 1
	end
	return out
end

-- sine-equivalent amplitude of each present harmonic octave (sqrt(2 * energy))
local function groupAmps(re, im, n, rate, f0, groups, powScale, out, offset)
	local top = math.min(rate / 2, WaveBank.BundleTop)
	for j, g in ipairs(groups) do
		local grp = GROUPS[g]
		local lo, hi = (grp[1] - 0.5) * f0, math.min((grp[2] + 0.5) * f0, top)
		if hi <= lo then
			out[offset + j] = 0
		else
			local e = rangeEnergy(re, im, n, rate, lo, hi, powScale)
			-- harmonicShare: energy within f0/4 of each harmonic vs the whole range. Calibrated: a harmonic
			-- comb scores ~0.95-1.0, noise ~0.45-0.56; the bundle (a perfect harmonic comb) only carries the
			-- harmonic part, so breath noise up there doesn't turn into buzz.
			local peak = 0
			local kTop = math.min(grp[2], math.floor(top / f0 - 0.25))
			for k = grp[1], kTop do
				peak += rangeEnergy(re, im, n, rate, (k - 0.25) * f0, (k + 0.25) * f0, powScale)
			end
			local harmonicShare = (e > 0) and math.clamp((peak / e - 0.5) / 0.47, 0, 1) or 0
			out[offset + j] = math.sqrt(2 * e * harmonicShare)
		end
	end
	return out
end

-- energy in the 17 half-octave bins of the noise chain (bin 1 also takes everything down to 20 Hz)
local function chainBins(re, im, n, rate, powScale, out)
	out = out or table.create(BINS, 0)
	for i = 1, BINS do
		local lo = WaveBank.ChainEdge * 2 ^ ((i - 1) / 2)
		local hi = WaveBank.ChainEdge * 2 ^ (i / 2)
		if i == 1 then
			lo = 20
		end
		out[i] = (lo < rate / 2) and rangeEnergy(re, im, n, rate, lo, math.min(hi, rate / 2), powScale) or 0
	end
	return out
end

-- non-negative fit of chain band energies u (bin i ~ LOW*u[i] + (1-LOW)*u[i-1]), relative error
local function fitChain(bins, u)
	local peak = 0
	for i = 1, BINS do
		peak = math.max(peak, bins[i])
	end
	if peak <= 0 then
		for i = 1, CHAIN_N do
			u[i] = 0
		end
		return u
	end
	local eps = peak * 1e-7
	local w = table.create(BINS)
	for i = 1, BINS do
		w[i] = 1 / (bins[i] + eps) ^ 2
	end
	for i = 1, CHAIN_N do
		u[i] = (bins[i] + bins[i + 1]) / 2
	end
	local hiShare = 1 - LOW
	for _ = 1, 40 do
		for i = 1, CHAIN_N do
			local r1 = bins[i] - ((i > 1) and hiShare * u[i - 1] or 0)
			local r2 = bins[i + 1] - ((i < CHAIN_N) and LOW * u[i + 1] or 0)
			local num = w[i] * LOW * r1 + w[i + 1] * hiShare * r2
			local den = w[i] * LOW * LOW + w[i + 1] * hiShare * hiShare
			u[i] = math.max(0, num / den)
		end
	end
	return u
end

local function chainModel(u, out)
	out = out or table.create(BINS, 0)
	for i = 1, BINS do
		out[i] = ((i <= CHAIN_N) and LOW * u[i] or 0) + ((i > 1) and (1 - LOW) * u[i - 1] or 0)
	end
	return out
end


-- loudness-weighted mean |dB| difference over bins within 40 dB of the loudest source bin
local function spectralError(src, model)
	local top = -math.huge
	for i = 1, BINS do
		if src[i] > 0 then
			top = math.max(top, 10 * math.log10(src[i]))
		end
	end
	if top == -math.huge then
		return 0
	end
	local sum, wsum = 0, 0
	for i = 1, BINS do
		local sd = (src[i] > 0) and 10 * math.log10(src[i]) or -200
		if sd > top - 40 then
			local md = (model[i] > 0) and 10 * math.log10(model[i]) or -200
			local w = 10 ^ ((sd - top) / 20)
			sum += math.min(math.abs(sd - md), 40) * w
			wsum += w
		end
	end
	return sum / math.max(wsum, 1e-12)
end

-- best normalised autocorrelation at lags within +-3% of the period; read(i) gives sample i
local function periodicity(read, available, rate, f0, start, count)
	local P = rate / f0
	local best = 0
	for lag = math.floor(P * 0.97), math.ceil(P * 1.03) do
		if lag >= 2 and start + count + lag <= available then
			local sxy, sxx, syy = 0, 0, 0
			for i = start, start + count - 1 do
				local x, y = read(i), read(i + lag)
				sxy += x * y
				sxx += x * x
				syy += y * y
			end
			best = math.max(best, 2 * sxy / math.max(sxx + syy, 1e-20))
		end
	end
	return best
end

Instruments.PeriodicThreshold = 0.9 -- melodic samples measure >= 0.97; drums with ringing tones 0.7-0.9
Instruments.PeakCount = 8 -- sines for the resonant peaks of percussion

-- A clap is a flam: 4-6 noise hits within ~35 ms (a snare is one hit). The rises of the 1 ms RMS envelope give the hit
-- times and sizes; the synth plays them as short bursts at exact offsets, because a 21 ms audio block smears them into one.
-- Returns { {t = seconds, amp = rms in the sample's own units, hz = spectral centroid estimate}, ... } or nil (under 3 hits).
function Instruments.detectHits(pcm)
	local rate, src, length = pcm.sampleRate, pcm.data[1], pcm.length
	local win = math.max(8, math.floor(rate * 0.001))
	local nb = math.min(length, math.floor(rate * 0.05)) // win
	if nb < 12 then
		return nil
	end
	local env, dif, maxEnv = table.create(nb, 0), table.create(nb, 0), 0
	for k = 0, nb - 1 do
		local s, d = 0, 0
		local prev = (k > 0) and buffer.readf32(src, (k * win - 1) * 4) or 0
		for i = k * win, (k + 1) * win - 1 do
			local x = buffer.readf32(src, i * 4)
			s += x * x
			d += (x - prev) * (x - prev)
			prev = x
		end
		env[k + 1], dif[k + 1] = math.sqrt(s / win), math.sqrt(d / win)
		maxEnv = math.max(maxEnv, env[k + 1])
	end
	local hits, last = {}, -10
	for k = 1, nb - 1 do
		local before = 0
		for j = math.max(1, k - 3), k - 1 do
			before = math.max(before, env[j])
		end
		local e = env[k]
		if e > maxEnv * 0.15 and e >= before * 1.5 and k - last >= 3 then
			local amp = math.max(e, env[k + 1] or 0, env[k + 2] or 0)
			local r = dif[k] / math.max(e, 1e-9)
			local hz = rate / math.pi * math.asin(math.min(r / 2, 1))
			table.insert(hits, {
				t = math.floor((k - 1) * win / rate * 1000 + 0.5) / 1000,
				amp = math.floor(amp * 1000 + 0.5) / 1000,
				hz = math.floor(hz + 0.5),
			})
			last = k
		end
	end
	return #hits >= 3 and hits or nil
end

-- pcm: Signal from Sf2.samplePcm (loopStart/loopEnd relative to its start).
-- info: { root, pitchCorrection, loopMode }. Returns a JSON-safe analysis table.
local function analyseOnce(pcm, info, options)
	local o = table.clone(Instruments.Defaults)
	for k, v in pairs(options or {}) do
		o[k] = v
	end
	local rate = pcm.sampleRate
	local src = pcm.data[1]
	local length = pcm.length
	local f0 = 440 * 2 ^ ((info.root - 69) / 12) * 2 ^ (-(info.pitchCorrection or 0) / 1200)
	local looped = (info.loopMode or 0) ~= 0 and pcm.loopEnd > pcm.loopStart + 16 and pcm.loopEnd <= length
	local loopLen = looped and (pcm.loopEnd - pcm.loopStart) or 0
	local yieldable = coroutine.isyieldable()

	local function readLinear(i)
		return (i >= 0 and i < length) and buffer.readf32(src, i * 4) or 0
	end
	local function readLoop(i)
		return buffer.readf32(src, (pcm.loopStart + i % loopLen) * 4)
	end

	-- 1. tonal or noise
	local count = math.max(64, math.floor(rate * 0.03))
	local r = 0
	if looped then
		r = periodicity(readLoop, math.huge, rate, f0, 0, count)
	else
		for _, t in ipairs({ 0.03, 0.08, 0.15 }) do
			r = math.max(r, periodicity(readLinear, length, rate, f0, math.floor(t * rate), count))
		end
		if length < count * 2 then
			r = math.max(r, periodicity(readLinear, length, rate, f0, 0, math.max(16, length // 3)))
		end
	end
	-- a waveform that repeats every two root periods (but not every one) sounds an octave lower
	local fundamental = 1
	if r < 0.95 then
		local r2 = 0
		if looped then
			r2 = periodicity(readLoop, math.huge, rate, f0 / 2, 0, count)
		else
			for _, t in ipairs({ 0.03, 0.08, 0.15 }) do
				r2 = math.max(r2, periodicity(readLinear, length, rate, f0 / 2, math.floor(t * rate), count))
			end
		end
		if r2 >= Instruments.PeriodicThreshold and r2 > r + 0.1 then
			fundamental = 0.5
			f0 = f0 / 2
			r = r2
		end
	end
	local isNoise = r < Instruments.PeriodicThreshold

	-- 2. steady spectrum: the loop repeated, or a segment from 25% of a one-shot
	local n = math.clamp(FFT.nextPow2(rate * 0.04), 512, 4096)
	local w = FFT.window("hann", n)
	local powScale = 2 / (n * FFT.windowStats("hann", n).sumSq)
	local re, im = table.create(n, 0), table.create(n, 0)
	local steadyStart = math.floor(length * 0.25)
	for i = 0, n - 1 do
		re[i + 1] = (looped and readLoop(i) or readLinear(steadyStart + i)) * w[i + 1]
		im[i + 1] = 0
	end
	FFT.transform(re, im)
	local steadyBins = chainBins(re, im, n, rate, powScale)

	-- single closest waveform (Mode = "wave" fallback)
	local Kw = math.max(1, math.min(20, math.floor(rate * 0.45 / f0)))
	local steadyH = harmonicAmps(re, im, n, rate, f0, Kw, powScale, table.create(Kw, 0))
	local wave, volume, fitError = Analyzer.fitWave(steadyH, Kw, true)

	local hop = o.Hop
	local bodyEnd = looped and (pcm.loopStart / rate) or (length / rate)
	bodyEnd = math.min(bodyEnd, isNoise and 2 or o.MaxAnalysis)
	local frameCount = math.floor(bodyEnd / hop + 1e-9) + 1
	if looped and pcm.loopStart / rate < hop then
		frameCount = 0 -- the loop starts right away; the steady spectrum covers it
	end

	local a = {
		version = ANALYSIS_VERSION, f0 = round(f0), rate = rate, looped = looped, hop = hop,
		loopStart = looped and round(pcm.loopStart / rate) or nil,
		length = round(length / rate), periodicity = round(r), fundamental = fundamental,
		wave = wave, volume = round(volume), fitError = round(fitError),
	}

	if isNoise then
		-- 3a. peaks + noise. Percussion often rings at a few fixed (inharmonic) frequencies: toms, blocks,
		-- cowbells, the thump of a kick. The strongest spectral peaks of the attack become sines (frequency
		-- refined per frame, so a kick's downward sweep is followed); what's left goes to the noise chain.
		local nf = math.clamp(FFT.nextPow2(rate * 0.064), 1024, 4096) -- ~15 Hz bins: close tom resonances separate
		local wf = FFT.window("hann", nf)
		local ps = 2 / (nf * FFT.windowStats("hann", nf).sumSq)
		local rf, imf = table.create(nf, 0), table.create(nf, 0)
		local half = nf // 2
		local hzb = rate / nf
		local bins, u = table.create(BINS, 0), table.create(CHAIN_N, 0)
		local function fill(centerSample)
			local start = centerSample - nf // 2
			for i = 1, nf do
				rf[i] = readLinear(start + i - 1) * wf[i]
				imf[i] = 0
			end
			FFT.transform(rf, imf)
		end
		local function pw(q)
			return rf[q] * rf[q] + imf[q] * imf[q]
		end
		-- nominal peaks: local maxima of the attack spectrum (first ~120 ms, summed), strongest first
		local acc = table.create(half + 1, 0)
		local attackFrames = math.max(1, math.min(frameCount, math.floor(0.12 / hop) + 1))
		for j = 0, attackFrames - 1 do
			fill(math.floor(j * hop * rate + 0.5))
			for q = 2, half do
				acc[q] += pw(q)
			end
		end
		local accMax, accTotal = 0, 0
		for q = 2, half do
			accMax = math.max(accMax, acc[q])
			accTotal += acc[q]
		end
		local cands = {}
		local lowQ = math.max(3, math.ceil(25 / hzb) + 1)
		for q = lowQ, half - 2 do
			local v = acc[q]
			if v > accMax * 1e-4 and v >= acc[q - 1] and v > acc[q + 1] and v >= acc[q - 2] and v > acc[q + 2] then
				table.insert(cands, q)
			end
		end
		table.sort(cands, function(x, y)
			return acc[x] > acc[y]
		end)
		local peakBins = {}
		for _, q in ipairs(cands) do
			if #peakBins >= Instruments.PeakCount then
				break
			end
			local ok = true
			for _, p in ipairs(peakBins) do
				if math.abs(p - q) < 3 then
					ok = false
					break
				end
			end
			-- keep a peak only if it stands out: >= 0.5% of the attack energy
			local e = 0
			for d = -2, 2 do
				e += acc[q + d] or 0
			end
			if ok and e >= accTotal * 0.005 then
				table.insert(peakBins, q)
			end
		end
		table.sort(peakBins)
		local npk = #peakBins
		local peakFreqs = table.create(npk)
		local peakAmpFrames, peakFreqFrames = {}, {}

		local frames = {}
		local errSum, errW = 0, 0
		for j = 0, frameCount - 1 do
			fill(math.floor(j * hop * rate + 0.5) )
			local ampsRow, freqRow = table.create(npk, 0), table.create(npk, 0)
			local srcBins = chainBins(rf, imf, nf, rate, ps, table.create(BINS, 0))
			for pi, q0 in ipairs(peakBins) do
				-- refine: strongest bin within +-15% of the nominal peak
				local lo = math.max(2, math.floor(q0 * 0.85))
				local hi = math.min(half - 1, math.ceil(q0 * 1.15))
				local bq, best = q0, -1
				for q = lo, hi do
					if pw(q) > best then
						bq, best = q, pw(q)
					end
				end
				local e = 0
				for q = math.max(2, bq - 2), math.min(half, bq + 2) do
					e += pw(q)
				end
				e *= ps
				local d = 0
				if bq > 2 and bq < half then
					local y0, y1, y2 = math.log(math.max(pw(bq - 1), 1e-30)), math.log(math.max(best, 1e-30)), math.log(math.max(pw(bq + 1), 1e-30))
					local den = y0 - 2 * y1 + y2
					if den < 0 then
						d = math.clamp(0.5 * (y0 - y2) / den, -0.5, 0.5)
					end
				end
				ampsRow[pi] = math.sqrt(2 * e)
				freqRow[pi] = (bq - 1 + d) * hzb
				if j == 0 or not peakFreqs[pi] then
					peakFreqs[pi] = (q0 - 1) * hzb
				end
				-- remove the peak from the spectrum before fitting the noise
				for q = math.max(2, bq - 2), math.min(half, bq + 2) do
					rf[q], imf[q] = 0, 0
				end
			end
			chainBins(rf, imf, nf, rate, ps, bins)
			frames[j + 1] = roundRow(table.clone((function()
				fitChain(bins, u)
				local row = table.create(CHAIN_N, 0)
				for i = 1, CHAIN_N do
					row[i] = math.sqrt(u[i]) / WaveBank.NoiseRms
				end
				return row
			end)()))
			peakAmpFrames[j + 1] = roundRow(ampsRow)
			peakFreqFrames[j + 1] = roundRow(freqRow)
			-- self-check: chain model + the peaks vs the whole frame spectrum
			local e = 0
			for i = 1, BINS do
				e += srcBins[i]
			end
			if e > 0 then
				local model = chainModel(u)
				for pi = 1, npk do
					local b = binOf(freqRow[pi])
					if b then
						model[b] += ampsRow[pi] ^ 2 / 2
					end
				end
				errSum += spectralError(srcBins, model) * math.sqrt(e)
				errW += math.sqrt(e)
			end
			if yieldable and j % 8 == 7 then
				task.wait()
			end
		end
		-- looped noise (rare): steady chain levels, peaks dropped
		local loopRow = nil
		if looped then
			fitChain(steadyBins, u)
			loopRow = table.create(CHAIN_N, 0)
			for i = 1, CHAIN_N do
				loopRow[i] = round(math.sqrt(u[i]) / WaveBank.NoiseRms)
			end
		end
		a.kind = "noise"
		a.noise = {
			frames = frames, loop = loopRow, hop = hop,
			peakFreqs = npk > 0 and roundRow(peakFreqs) or nil,
			peakAmps = npk > 0 and peakAmpFrames or nil,
			peakFreqFrames = npk > 0 and peakFreqFrames or nil,
			hits = (not looped) and Instruments.detectHits(pcm) or nil,
		}
		a.check = { err = round((errW > 0) and errSum / errW or 0), steady = 0 }
		return a
	end

	-- 3b. tonal: sines for harmonics 1..8 and one bundle per higher harmonic octave below Nyquist
	local nyq = math.min(rate / 2, WaveBank.BundleTop)
	local P = 0
	for k = 1, SINES do
		if k * f0 < nyq * 0.98 then
			P = k
		end
	end
	P = math.max(P, 1)
	-- Extra sines. The bundle for harmonics 9-16 spreads the group's energy with a fixed 1/k amplitude tilt. A sample
	-- whose harmonics 9-16 fall much faster (typical for basses) would get its energy moved to the top of the group:
	-- up to +12 dB at 800-1600 Hz and a buzzy edge. Measure the misplaced share over the attack/body and the steady
	-- loop; above the threshold, harmonics 9-16 are played as sines.
	local extraTop = tonumber(o.ExtraSines) or 0
	if P == SINES and extraTop > SINES and extraTop * f0 < nyq * 0.98 and GROUPS[1][2] == extraTop then
		local nf0 = math.clamp(FFT.nextPow2(o.FramePeriods * rate / f0), 256, 2048)
		local w0 = FFT.window("hann", nf0)
		local ps0 = 2 / (nf0 * FFT.windowStats("hann", nf0).sumSq)
		local r0, i0 = table.create(nf0, 0), table.create(nf0, 0)
		local tEnd0 = math.min((looped and (pcm.loopEnd / rate) or (length / rate)), o.MaxAnalysis)
		local num, den = 0, 0
		local act = table.create(extraTop, 0)
		local function frameMismatch()
			FFT.transform(r0, i0)
			local eg, ws = 0, 0
			for k = 1, extraTop do
				act[k] = rangeEnergy(r0, i0, nf0, rate, (k - 0.5) * f0, (k + 0.5) * f0, ps0)
				den += act[k]
				if k > SINES then
					eg += act[k]
					ws += k ^ (-2 * WaveBank.BundleTilt)
				end
			end
			if ws > 0 then
				for k = SINES + 1, extraTop do
					num += math.abs(eg * k ^ (-2 * WaveBank.BundleTilt) / ws - act[k])
				end
			end
		end
		local t = 0
		while t <= tEnd0 + 1e-9 do
			local c = math.floor(t * rate + 0.5)
			for i = 1, nf0 do
				local idx = c + i - 1 - nf0 // 2
				local x = 0
				if idx >= 0 then
					if looped and idx >= pcm.loopEnd then
						x = buffer.readf32(src, (pcm.loopStart + (idx - pcm.loopStart) % loopLen) * 4)
					elseif idx < length then
						x = buffer.readf32(src, idx * 4)
					end
				end
				r0[i], i0[i] = x * w0[i], 0
			end
			frameMismatch()
			t += 0.03
		end
		if looped then
			for i = 1, nf0 do
				r0[i], i0[i] = buffer.readf32(src, (pcm.loopStart + (i - 1) % loopLen) * 4) * w0[i], 0
			end
			frameMismatch()
		end
		if den > 0 and num / den > o.ExtraSineMismatch then
			P = extraTop
		end
		a.extraMismatch = round(den > 0 and num / den or 0)
	end
	local voice, voiceK, coherent = false, 0, false
	local VPK = 0.3 -- voice mode: the sine of harmonic k owns +-VPK*f0; the rest of the cell is noise
	do
		-- tonal harmonics: the lowest harmonics whose energy sits in a peak (within f0/4 of k*f0) rather than spread over
		-- the whole cell (comb ~0.95-1, noise ~0.5), smoothed over neighbours; the first one below VoiceShare ends it
		local maxK = math.min(tonumber(o.VoiceMaxHarmonics) or 16, math.floor(nyq * 0.98 / f0))
		if maxK >= 4 then
			local share = table.create(maxK, 0)
			for k = 1, maxK do
				local ce = rangeEnergy(re, im, n, rate, (k - 0.5) * f0, (k + 0.5) * f0, powScale)
				local pk = rangeEnergy(re, im, n, rate, (k - 0.25) * f0, (k + 0.25) * f0, powScale)
				share[k] = (ce > 0) and pk / ce or 0
			end
			local thr = tonumber(o.VoiceShare) or 0.85
			local kt = 0
			for k = 1, maxK do
				local s = (share[math.max(1, k - 1)] + share[k] + share[math.min(maxK, k + 1)]) / 3
				if s >= thr then
					kt = k
				else
					break
				end
			end
			voiceK = math.max(kt, 1)
			voice = (o.Voice == "force") and voiceK < maxK
			if voice then
				P = voiceK
			end
		end
		-- coherent voice: every harmonic up to CoherentHz is a sine started at the phase it has in the sample (a sung voice is
		-- one pulse per period: its harmonics line up); everything above them is noise (breath, consonants), no bundles
		if o.Voice == "coherent" then
			local top = math.floor(math.min(tonumber(o.CoherentHz) or 2600, nyq * 0.98) / f0)
			if top >= 4 then
				voice, coherent, P, voiceK = true, true, top, top
			end
		end
	end
	local partials = table.create(P)
	for k = 1, P do
		partials[k] = k
	end
	local groups = {}
	if P >= SINES and not voice then
		for g, grp in ipairs(GROUPS) do
			if grp[1] > P and (grp[1] - 0.5) * f0 < nyq then
				table.insert(groups, g)
			end
		end
	end
	local width = P + #groups
	local function measure(rr, ii, nn, ps, f)
		f = f or f0
		local row = table.create(width, 0)
		if voice then
			for k = 1, P do
				row[k] = math.sqrt(2 * rangeEnergy(rr, ii, nn, rate, (k - VPK) * f, (k + VPK) * f, ps))
			end
			if coherent then
				groupAmps(rr, ii, nn, rate, f, groups, ps, row, P)
			end
			return row
		end
		if o.ResidualLeak ~= false then
			peakAmps(rr, ii, nn, rate, f, P, ps, row, 0, peakShare(nn * f / rate))
		else
			regionAmps(rr, ii, nn, rate, f, P, ps, row, 0)
		end
		groupAmps(rr, ii, nn, rate, f, groups, ps, row, P)
		return row
	end
	-- voice mode noise: per harmonic cell above the sines, the energy outside the +-VPK*f0 peak (the valley level)
	-- spread over the whole cell, into the chain bin of the harmonic; returns the bins and their total energy
	local function voiceNoise(rr, ii, nn, ps, f, out, nm)
		for i = 1, BINS do
			out[i] = 0
		end
		local top = math.min(rate / 2, WaveBank.BundleTop)
		local total = 0
		local k = P + 1
		if coherent then
			-- noise = everything that is not a sine's peak: the valley of each harmonic cell below the top sine (spread over the
			-- cell, like a breathy onset or consonant) and the whole cell above it
			k = 1
			while (k - 0.5) * f < top do
				local cLo, cHi = (k - 0.5) * f, math.min((k + 0.5) * f, top)
				local e = rangeEnergy(rr, ii, nn, rate, cLo, cHi, ps)
				if k <= P then
					local pLo, pHi = (k - VPK) * f, math.min((k + VPK) * f, cHi)
					local outerW = (cHi - cLo) - math.max(0, pHi - pLo)
					if outerW > 0.1 * f then
						e = math.max(0, e - rangeEnergy(rr, ii, nn, rate, pLo, pHi, ps)) / outerW * (cHi - cLo)
					else
						e = 0
					end
				end
				e *= (tonumber(o.CoherentNoise) or 0.4) * (nm or 1) -- the noise chain plays about 4 dB hotter than the measured cell energy
				local b = binOf(k * f)
				if b then
					out[b] += e
					total += e
				end
				k += 1
			end
			return out, total
		end
		while (k - 0.5) * f < top do
			local cLo, cHi = (k - 0.5) * f, math.min((k + 0.5) * f, top)
			local pLo, pHi = (k - VPK) * f, math.min((k + VPK) * f, top)
			local pkW = math.max(0, pHi - pLo)
			local outerW = (cHi - cLo) - pkW
			if outerW > 0.1 * f then
				local eOut = rangeEnergy(rr, ii, nn, rate, cLo, cHi, ps)
				if pkW > 0 then
					eOut -= rangeEnergy(rr, ii, nn, rate, pLo, pHi, ps)
				end
				local e = math.max(0, eOut) / outerW * (cHi - cLo)
				local b = binOf(k * f)
				if b then
					out[b] += e
					total += e
				end
			end
			k += 1
		end
		return out, total
	end
	local steadyRow = measure(re, im, n, powScale)

	-- self-check on the steady spectrum: sines at their harmonics, each octave spread over its
	-- harmonics with the bundles' 1/k profile
	local function modelBins(row, f)
		local f0 = f or f0
		local out = table.create(BINS, 0)
		for k = 1, P do
			local b = binOf(k * f0)
			if b then
				out[b] += row[k] * row[k] / 2
			end
		end
		for j, g in ipairs(groups) do
			local grp = GROUPS[g]
			local e = row[P + j] * row[P + j] / 2
			local kmax = math.min(grp[2], math.floor(nyq / f0))
			local wsum = 0
			for k = grp[1], kmax do
				wsum += k ^ (-2 * WaveBank.BundleTilt)
			end
			for k = grp[1], kmax do
				local b = binOf(k * f0)
				if b and wsum > 0 then
					out[b] += e * k ^ (-2 * WaveBank.BundleTilt) / wsum
				end
			end
		end
		return out
	end
	local steadyModel = modelBins(steadyRow)
	if voice then
		local nb = voiceNoise(re, im, n, powScale, f0, table.create(BINS, 0))
		for i = 1, BINS do
			steadyModel[i] += nb[i]
		end
	end
	local steadyErr = spectralError(alignedBins(re, im, n, rate, f0, powScale), steadyModel)

	local nf = math.clamp(FFT.nextPow2((coherent and (tonumber(o.CoherentFramePeriods) or 2) or o.FramePeriods) * rate / f0), 256, 2048)
	local wf = FFT.window("hann", nf)
	local ps = 2 / (nf * FFT.windowStats("hann", nf).sumSq)
	local rf, imf = table.create(nf, 0), table.create(nf, 0)
	-- Frames cover the attack and, for looped samples, one full pass of the loop (played back cyclically
	-- by the synth, so the loop's own movement survives). The sample is read as a player would: past the
	-- loop end the loop repeats.
	local function readPlay(i)
		if i < 0 then
			return 0
		end
		if looped and i >= pcm.loopEnd then
			return buffer.readf32(src, (pcm.loopStart + (i - pcm.loopStart) % loopLen) * 4)
		end
		return (i < length) and buffer.readf32(src, i * 4) or 0
	end
	local tEnd = math.min(looped and (pcm.loopEnd / rate) or (length / rate), o.MaxTrack)
	local tFrames = math.floor(tEnd / hop + 1e-9) + 1
	-- pitch track: the best normalised autocorrelation lag within +-6% of the period, every frame
	local P0 = rate / f0
	local span = math.max(math.floor(P0 * 2), 256)
	local lagLo, lagHi = math.max(2, math.floor(P0 * 0.94)), math.ceil(P0 * 1.06)
	local rs = {}
	local function trackLag(center)
		local start = center - span // 2
		local best, bestLag = -1, nil
		for lag = lagLo, lagHi do
			local sxy, sxx, syy = 0, 0, 0
			for i = start, start + span - 1 do
				local x, y = readPlay(i), readPlay(i + lag)
				sxy += x * y
				sxx += x * x
				syy += y * y
			end
			local r = 2 * sxy / math.max(sxx + syy, 1e-20)
			rs[lag] = r
			if r > best then
				best, bestLag = r, lag
			end
		end
		if not bestLag or best < 0.5 then
			return nil
		end
		local d = 0
		local y0, y2 = rs[bestLag - 1], rs[bestLag + 1]
		if y0 and y2 and bestLag > lagLo and bestLag < lagHi then
			local den = y0 - 2 * best + y2
			if den < 0 then
				d = math.clamp(0.5 * (y0 - y2) / den, -0.5, 0.5)
			end
		end
		return bestLag + d
	end
	local cents = table.create(tFrames, 0)
	local prevC = 0
	local slice = os.clock()
	for j = 0, tFrames - 1 do
		local lag = trackLag(math.floor(j * hop * rate + 0.5))
		if lag then
			prevC = 1200 * math.log(P0 / lag, 2)
		end
		cents[j + 1] = prevC
		if yieldable and os.clock() - slice > 0.01 then
			task.wait()
			slice = os.clock()
		end
	end
	-- median of three (drops single-frame glitches)
	local track = table.create(tFrames, 0)
	local moving = false
	for j = 1, tFrames do
		local x, y, z = cents[math.max(1, j - 1)], cents[j], cents[math.min(tFrames, j + 1)]
		track[j] = math.max(math.min(x, y), math.min(math.max(x, y), z))
		if math.abs(track[j]) > 3 then
			moving = true
		end
	end

	-- coherent voice: follow the pitch cycle by cycle. The autocorrelation track averages over ~2 periods and flattens
	-- the quick fall that opens a sung vowel (about 100 cents in 25 ms), which is the "intonation" of the original.
	-- Band-pass the fundamental, time each rising zero crossing, one pitch value per cycle; cycles that disagree
	-- with their neighbours (consonant noise) are replaced from the good ones.
	if coherent then
		local nS = math.floor(tEnd * rate) + 1
		local NN = FFT.nextPow2(nS + 256)
		local re, im = table.create(NN, 0), table.create(NN, 0)
		for i = 1, nS do
			re[i] = readPlay(i - 1)
		end
		FFT.transform(re, im)
		local lo, hi = 0.6 * f0, 1.7 * f0
		for i = 0, NN // 2 do
			local fr = i * rate / NN
			local g = 0
			if fr >= lo and fr <= hi then
				g = 1
			elseif fr > lo * 0.7 and fr < lo then
				g = (fr - lo * 0.7) / (lo * 0.3)
			elseif fr > hi and fr < hi * 1.3 then
				g = (hi * 1.3 - fr) / (hi * 0.3)
			end
			re[i + 1] *= g
			im[i + 1] *= g
			if i > 0 and i < NN // 2 then
				re[NN - i + 1] *= g
				im[NN - i + 1] *= g
			end
		end
		for i = 1, NN do
			im[i] = -im[i]
		end
		FFT.transform(re, im) -- inverse by conjugation: real part / NN
		local zc = {}
		for i = 2, nS do
			local y0, y1 = re[i - 1], re[i]
			if y0 < 0 and y1 >= 0 then
				table.insert(zc, ((i - 2) + (-y0) / (y1 - y0)) / rate)
			end
		end
		local cyT, cyC = {}, {}
		for q = 1, #zc - 1 do
			local per = zc[q + 1] - zc[q]
			if per > 0 then
				table.insert(cyT, (zc[q] + zc[q + 1]) / 2)
				table.insert(cyC, 1200 * math.log(1 / (per * f0), 2))
			end
		end
		-- keep cycles within 200 cents of the median of their neighbours (+-2)
		local goodT, goodC = {}, {}
		for q = 1, #cyC do
			local w = {}
			for r = math.max(1, q - 2), math.min(#cyC, q + 2) do
				table.insert(w, cyC[r])
			end
			table.sort(w)
			local med = w[(#w + 1) // 2]
			if math.abs(cyC[q] - med) <= (tonumber(o.CoherentPitchDev) or 200) and math.abs(cyC[q]) < 400 then
				table.insert(goodT, cyT[q])
				table.insert(goodC, cyC[q])
			end
		end
		if #goodT >= 3 then
			moving = false
			local gi = 1
			for j = 1, tFrames do
				local tf = (j - 1) * hop
				while gi < #goodT and goodT[gi + 1] <= tf do
					gi += 1
				end
				local v
				if tf <= goodT[1] then
					v = goodC[1]
				elseif gi >= #goodT then
					v = goodC[#goodT]
				else
					local u = (tf - goodT[gi]) / (goodT[gi + 1] - goodT[gi])
					v = goodC[gi] + (goodC[gi + 1] - goodC[gi]) * u
				end
				track[j] = v
				if math.abs(v) > 3 then
					moving = true
				end
			end
		end
	end

	if coherent and moving then
		-- after the opening glide the pitch moves slowly; the cycle timing jitters a few tens of cents, which is heard
		-- as a buzz when the note closes, so smooth it there
		local raw = table.clone(track)
		local from = math.floor((tonumber(o.CoherentGlideTime) or 0.075) / hop) + 1
		for j = from, tFrames do
			local acc, cnt = 0, 0
			for q = math.max(1, j - 3), math.min(tFrames, j + 3) do
				acc += raw[q]
				cnt += 1
			end
			track[j] = acc / cnt
		end
	end

	local shortN = math.floor(rate * 0.005)
	local gains = table.create(tFrames, 0)
	-- residual: everything that isn't near a harmonic (attack clicks, breath, bow noise), as noise-chain
	-- levels per frame; played through the shared noise bands, so it costs no extra players
	local residualRows = table.create(tFrames)
	local totalBins, harmBins, residBins = table.create(BINS, 0), table.create(BINS, 0), table.create(BINS, 0)
	local ru = table.create(CHAIN_N, 0)
	local residualPeakShare = 0
	local frameNoiseE = 0
	local frames = {}
	local errSum, errW = 0, 0
	local fbins = table.create(BINS, 0)
	-- coherent voice: loudness-weighted mean phase of each harmonic relative to the fundamental
	local phZr, phZi, xw = table.create(P, 0), table.create(P, 0), table.create(nf, 0)
	local atan2 = function(y, x)
		return math.atan2 and math.atan2(y, x) or (x == 0 and (y >= 0 and math.pi / 2 or -math.pi / 2)) or math.atan(y / x) + ((x < 0) and (y >= 0 and math.pi or -math.pi) or 0)
	end
	for j = 0, tFrames - 1 do
		local f = f0 * 2 ^ (track[j + 1] / 1200)
		local start = math.floor(j * hop * rate + 0.5) - nf // 2
		for i = 1, nf do
			rf[i] = readPlay(start + i - 1) * wf[i]
			imf[i] = 0
		end
		FFT.transform(rf, imf)
		local row = measure(rf, imf, nf, ps, f)
		if coherent and j % 3 == 0 then
			for i = 1, nf do
				xw[i] = readPlay(start + i - 1) * wf[i]
			end
			local a1, m1 = 0, 0
			for k = 1, P do
				local w = 2 * math.pi * k * f / rate
				local cr, ci = math.cos(w), -math.sin(w)
				local zr, zi, sr, si = 1, 0, 0, 0
				for i = 1, nf do
					local x = xw[i]
					sr += x * zr
					si += x * zi
					zr, zi = zr * cr - zi * ci, zr * ci + zi * cr
				end
				local mag = math.sqrt(sr * sr + si * si)
				if k == 1 then
					a1, m1 = atan2(si, sr), mag
				end
				local ang = atan2(si, sr) - k * a1
				local wt = mag * m1
				phZr[k] += wt * math.cos(ang)
				phZi[k] += wt * math.sin(ang)
			end
		end
		frameNoiseE = 0
		do
			if voice then
				local nm = 1
				if coherent then
					-- the consonant burst at the start and the breathy tail are real noise and carry the "t" and the
					-- soft close; in the sustained vowel the cells between harmonics are mostly leakage, so keep that quiet
					local tf = j * hop
					local on = tonumber(o.CoherentNoiseOnset) or 1
					local tl = tonumber(o.CoherentNoiseTail) or 1
					local onsetEnd = tonumber(o.CoherentOnsetTime) or 0.02
					if tf <= onsetEnd then
						nm = on
					elseif tf < onsetEnd + (tonumber(o.CoherentOnsetFade) or 0.02) then
						nm = on + (1 - on) * (tf - onsetEnd) / (tonumber(o.CoherentOnsetFade) or 0.02)
					end
					local tailStart = tEnd - (tonumber(o.CoherentTailTime) or 0.1)
					if tf > tailStart then
						nm = math.max(nm, 1 + (tl - 1) * math.min(1, (tf - tailStart) / 0.04))
					end
				end
				local _, tn = voiceNoise(rf, imf, nf, ps, f, residBins, nm)
				frameNoiseE = tn
				residualPeakShare = 1
			else
				chainBins(rf, imf, nf, rate, ps, totalBins)
				harmonicBins(rf, imf, nf, rate, f, ps, harmBins)
				local tot, res = 0, 0
				local leak = o.ResidualLeak ~= false
				local share = leak and peakShare(nf * f / rate) or 1
				for i = 1, BINS do
					residBins[i] = math.max(0, totalBins[i] - harmBins[i] / share)
					tot += totalBins[i]
					res += residBins[i]
				end
				if tot > 0 then
					residualPeakShare = math.max(residualPeakShare, res / tot)
				end
				if leak then
					frameNoiseE = res -- the residual is part of the model: the frame's loudness isn't put on the sines twice
				end
			end
			fitChain(residBins, ru)
			local lv = table.create(CHAIN_N, 0)
			for i = 1, CHAIN_N do
				lv[i] = math.sqrt(ru[i]) / WaveBank.NoiseRms
			end
			residualRows[j + 1] = lv
		end
		-- temporal envelope: the long analysis window (several periods) smears attacks and fast vowel
		-- changes; scale the frame to the energy of a short window (one period, >= 5 ms) at the same instant
		do
			-- energy over two periods of the tracked pitch (>= 5 ms) at this instant; applied after the loop,
			-- averaged over neighbouring frames so it sharpens attacks without adding a frame-rate wobble
			local c = math.floor(j * hop * rate + 0.5)
			local nShort = math.max(shortN, math.floor(2 * rate / f + 0.5))
			local e = 0
			for i = c - nShort // 2, c - nShort // 2 + nShort - 1 do
				local x = readPlay(i)
				e += x * x
			end
			e /= nShort
			local mEnergy = 0
			for k = 1, width do
				mEnergy += row[k] * row[k] / 2
			end
			mEnergy += frameNoiseE -- voice mode: the noise is part of the model
			gains[j + 1] = (mEnergy > 1e-12) and math.log(math.clamp(math.sqrt(e / mEnergy), 0.1, coherent and (tonumber(o.CoherentGainMax) or 1.5) or 3)) or 0
		end
		if j % 4 == 0 then
			alignedBins(rf, imf, nf, rate, f, ps, fbins)
			local e = 0
			for i = 1, BINS do
				e += fbins[i]
			end
			if e > 0 then
				local mb = modelBins(row, f)
				if voice then
					for i = 1, BINS do
						mb[i] += residBins[i]
					end
				end
				errSum += spectralError(fbins, mb) * math.sqrt(e)
				errW += math.sqrt(e)
			end
		end
		frames[j + 1] = row
		if yieldable and os.clock() - slice > 0.01 then
			task.wait()
			slice = os.clock()
		end
	end
	for j = 1, tFrames do
		local g = (gains[math.max(1, j - 1)] + gains[j] + gains[math.min(tFrames, j + 1)]) / 3
		local scale = math.exp(g)
		local row = frames[j]
		for k = 1, #row do
			row[k] *= scale
		end
		frames[j] = roundRow(row)
		local rr = residualRows[j]
		if rr then
			for k = 1, #rr do
				rr[k] *= scale
			end
			residualRows[j] = roundRow(rr)
		end
	end
	-- keep the residual only where it matters (>= 2% of a frame's energy somewhere in the sample)
	if residualPeakShare >= 0.02 then
		a.residual = { frames = residualRows, hop = hop }
	end
	if moving then
		local pc = table.create(tFrames, 0)
		for j = 1, tFrames do
			pc[j] = math.floor(track[j] * 10 + 0.5) / 10
		end
		a.pitch = pc -- cents from the root pitch, per frame (sample time)
	end
	if looped then
		a.cycle = true -- frames past loopStart repeat with the loop
		a.loopLength = (pcm.loopEnd - pcm.loopStart) / rate
	end
	a.kind = "tonal"
	if voice then
		a.voice = true
	end
	if coherent then
		-- sine-phase of harmonic k at note start (cycles) when the fundamental starts at sine phase 0
		local ph = table.create(P, 0)
		for k = 1, P do
			local theta = (phZr[k] ~= 0 or phZi[k] ~= 0) and atan2(phZi[k], phZr[k]) or 0
			local p = theta - (k - 1) * math.pi / 2
			ph[k] = math.floor((p / (2 * math.pi)) % 1 * 1000 + 0.5) / 1000
		end
		a.phases = ph
	end
	a.voiceK = voiceK
	a.partials = partials
	a.groups = groups
	a.frames = frames
	if looped then
		a.loopAmps = roundRow(steadyRow)
	end
	-- steady-part energy carried by the sines vs the bundles (reported by the baker)
	local se, ge = 0, 0
	for k = 1, P do
		se += steadyRow[k] ^ 2
	end
	for j = 1, #groups do
		ge += steadyRow[P + j] ^ 2
	end
	a.bundleShare = round(ge / math.max(se + ge, 1e-20))
	a.check = { err = round((errW > 0) and (errSum / errW + steadyErr) / 2 or steadyErr), steady = round(steadyErr) }
	return a
end

-- Phase-locked voice (Voice = "phase"): every harmonic up to PhaseHz gets its own amplitude AND phase per frame
-- (Hann-windowed projection at k x the tracked pitch, one frame every Hop). Phases are stored unwrapped (cycles of
-- the sine since the sample start), so the synth can steer each sine's speed to land on the sample's own phase at
-- every update: the shape of each vocal pulse survives, where one fixed phase per harmonic blurs it and noise
-- (or a bundle) above the sines turns it into a buzz.
local function phaseVoice(a, pcm, info, o)
	local rate = pcm.sampleRate
	local src = pcm.data[1]
	local length = pcm.length
	local f0 = 440 * 2 ^ ((info.root - 69) / 12) * 2 ^ (-(info.pitchCorrection or 0) / 1200) * (a.fundamental or 1)
	local hop = a.hop
	local pitch = a.pitch
	local nFr = math.floor((length / rate) / hop + 1e-9) + 2
	local function cents(j)
		if not pitch or #pitch == 0 then
			return 0
		end
		return pitch[math.clamp(j + 1, 1, #pitch)]
	end
	local maxC = 0
	if pitch then
		for _, c in ipairs(pitch) do
			maxC = math.max(maxC, c)
		end
	end
	local K = math.max(1, math.floor(math.min(tonumber(o.PhaseHz) or 8000, rate * 0.47 / 2 ^ (maxC / 1200)) / f0))
	local L = math.floor((tonumber(o.PhaseWindow) or 0.02) * rate + 0.5)
	local w = table.create(L, 0)
	local wsum = 0
	for i = 1, L do
		w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * (i - 1) / (L - 1))
		wsum += w[i]
	end
	-- fundamental phase (cycles) at each frame, integrated from the pitch track
	local Phi = table.create(nFr, 0)
	local acc = 0
	for j = 1, nFr - 1 do
		local c0, c1 = cents(j - 1), cents(j)
		for q = 0, 15 do
			acc += f0 * 2 ^ ((c0 + (c1 - c0) * (q + 0.5) / 16) / 1200) * hop / 16
		end
		Phi[j + 1] = acc
	end
	local xs = table.create(L, 0)
	local amps, unw = table.create(nFr), table.create(nFr)
	local LEAK_M = 6
	local Xr, Xi, Cr, Ci, Nr, Ni = table.create(K, 0), table.create(K, 0), table.create(K, 0), table.create(K, 0), table.create(K, 0), table.create(K, 0)
	local Wr, Wi = table.create(LEAK_M, 0), table.create(LEAK_M, 0)
	local yieldable = coroutine.isyieldable()
	local slice = os.clock()
	local half = L // 2
	for j = 0, nFr - 1 do
		local c = math.floor(j * hop * rate + 0.5)
		for i = 1, L do
			local idx = c - half + i - 1
			xs[i] = ((idx >= 0 and idx < length) and buffer.readf32(src, idx * 4) or 0) * w[i]
		end
		local f = f0 * 2 ^ (cents(j) / 1200)
		local row, urow = table.create(K, 0), table.create(K, 0)
		local prev = unw[j]
		-- projections X_k = (2/sum w) sum w x e^{-i k om tau}
		for k = 1, K do
			local om = 2 * math.pi * k * f / rate
			local cr, ci = math.cos(om), -math.sin(om)
			local zr, zi = math.cos(om * half), math.sin(om * half) -- e^{-i om tau} at tau = -half
			local sr, si = 0, 0
			for i = 1, L do
				local x = xs[i]
				sr += x * zr
				si += x * zi
				zr, zi = zr * cr - zi * ci, zr * ci + zi * cr
			end
			Xr[k], Xi[k] = 2 * sr / wsum, 2 * si / wsum
		end
		-- the window leaks every harmonic into its neighbours (a loud fundamental shows up as a wobble in the
		-- phase of the 2nd and 3rd); undo it: X_j = c_j + sum_k c_k W((j-k) om) + conj(c_k) W((j+k) om), solved by
		-- a few Jacobi steps (the leakage is small, so this converges at once). Same as a joint least-squares fit.
		do
			local om1 = 2 * math.pi * f / rate
			for m = 1, LEAK_M do
				local cr, ci = math.cos(m * om1), -math.sin(m * om1)
				local zr, zi = math.cos(m * om1 * half), math.sin(m * om1 * half)
				local sr, si = 0, 0
				for i = 1, L do
					local ww = w[i]
					sr += ww * zr
					si += ww * zi
					zr, zi = zr * cr - zi * ci, zr * ci + zi * cr
				end
				Wr[m], Wi[m] = sr / wsum, si / wsum -- W(m om) normalised; W(-m om) = conj
			end
			for k = 1, K do
				Cr[k], Ci[k] = Xr[k], Xi[k]
			end
			for _ = 1, 4 do
				for jj = 1, K do
					local ar, ai = Xr[jj], Xi[jj]
					for k = math.max(1, jj - LEAK_M), math.min(K, jj + LEAK_M) do
						if k ~= jj then
							local m = jj - k
							local wr, wi = Wr[math.abs(m)], Wi[math.abs(m)]
							if m < 0 then
								wi = -wi
							end
							-- c_k * W(m om)
							ar -= Cr[k] * wr - Ci[k] * wi
							ai -= Cr[k] * wi + Ci[k] * wr
						end
					end
					for k = 1, LEAK_M - jj do
						local wr, wi = Wr[jj + k], Wi[jj + k]
						-- conj(c_k) * W((j+k) om)
						ar -= Cr[k] * wr + Ci[k] * wi
						ai -= Cr[k] * wi - Ci[k] * wr
					end
					Nr[jj], Ni[jj] = ar, ai
				end
				for k = 1, K do
					Cr[k], Ci[k] = Nr[k], Ni[k]
				end
			end
		end
		for k = 1, K do
			local sr, si = Cr[k], Ci[k]
			local amp = math.sqrt(sr * sr + si * si)
			if k * f >= rate * 0.47 then
				amp = 0
			end
			row[k] = math.floor(amp * 1e6 + 0.5) / 1e6
			local cyc = (math.atan2(si, sr) + math.pi / 2) / (2 * math.pi) -- sine phase at the frame centre
			local u
			if not prev then
				u = cyc % 1
			else
				local pred = prev[k] + k * (Phi[j + 1] - Phi[j])
				local d = cyc - pred
				d -= math.floor(d + 0.5)
				u = pred + d
			end
			urow[k] = math.floor(u * 1e4 + 0.5) / 1e4
		end
		amps[j + 1] = row
		unw[j + 1] = urow
		if yieldable and os.clock() - slice > 0.01 then
			task.wait()
			slice = os.clock()
		end
	end
	-- PhaseSmooth: [1 2 1] passes over each harmonic's phase deviation from the pitch track. The synth can only
	-- change a sine's speed once per game frame, so frame-to-frame phase jitter (largely measurement noise on weak
	-- harmonics) turns into speed jumps
	local passes = tonumber(o.PhaseSmooth) or 0
	if passes > 0 and nFr > 2 then
		local dev = table.create(nFr, 0)
		local tmp = table.create(nFr, 0)
		for k = 1, K do
			local base = unw[1][k]
			for j = 1, nFr do
				dev[j] = unw[j][k] - base - k * Phi[j]
			end
			for _ = 1, passes do
				for j = 1, nFr do
					tmp[j] = (dev[math.max(1, j - 1)] + 2 * dev[j] + dev[math.min(nFr, j + 1)]) / 4
				end
				dev, tmp = tmp, dev
			end
			for j = 1, nFr do
				unw[j][k] = math.floor((base + k * Phi[j] + dev[j]) * 1e4 + 0.5) / 1e4
			end
		end
	end
	-- PhaseBursts: the consonant at the start ("t", a click, breath) is noise the harmonics can't make. Measure
	-- what the harmonic model leaves over in the first 30 ms, per octave band, and match it with the onset-burst
	-- assets (sharp 0.7 ms attack, 6 or 25 ms decay): their energies in 0-8 ms and 8-30 ms give the two gains.
	if o.PhaseBursts and WaveBank.Bursts then
		local n = math.min(length, math.floor(0.030 * rate))
		local res = table.create(n, 0)
		for i = 0, n - 1 do
			local fpos = (i / rate) / hop
			local j = math.floor(fpos)
			local u = fpos - j
			local r0, r1 = amps[j + 1], amps[j + 2] or amps[j + 1]
			local p0, p1 = unw[j + 1], unw[j + 2] or unw[j + 1]
			local y = 0
			for k = 1, K do
				local am = r0[k] + (r1[k] - r0[k]) * u
				if am > 0 then
					y += am * math.sin(2 * math.pi * (p0[k] + (p1[k] - p0[k]) * u))
				end
			end
			res[i + 1] = buffer.readf32(src, i * 4) - y
		end
		local function bandEnergies(i0, i1)
			local N = FFT.nextPow2(math.max(64, i1 - i0))
			local re, im2 = table.create(N, 0), table.create(N, 0)
			for i = i0, i1 - 1 do
				re[i - i0 + 1] = res[i + 1] or 0
			end
			FFT.transform(re, im2)
			return function(lo, hi)
				local e = 0
				for q = 1, N // 2 - 1 do
					local fq = q * rate / N
					if fq >= lo and fq < hi then
						e += re[q + 1] * re[q + 1] + im2[q + 1] * im2[q + 1]
					end
				end
				return 2 * e / N / rate -- sum of x^2 / rate in this band
			end
		end
		local i8 = math.min(n, math.floor(0.008 * rate))
		local w1, w2 = bandEnergies(0, i8), bandEnergies(i8, n)
		local list = {}
		for _, band in ipairs({ "1000", "2000", "4000", "8000", "16000" }) do
			local b6, b25 = WaveBank.Bursts["burst_" .. band .. "_t6"], WaveBank.Bursts["burst_" .. band .. "_t25"]
			if b6 and b25 and b6.lo < rate / 2 then
				local R1, R2 = w1(b6.lo, b6.hi), w2(b6.lo, b6.hi)
				local det = b6.e1 * b25.e2 - b25.e1 * b6.e2
				local x = (R1 * b25.e2 - b25.e1 * R2) / det
				local y = (b6.e1 * R2 - R1 * b6.e2) / det
				if x < 0 then
					x, y = 0, (R1 + R2) / (b25.e1 + b25.e2)
				elseif y < 0 then
					x, y = (R1 + R2) / (b6.e1 + b6.e2), 0
				end
				local g6, g25 = math.sqrt(math.max(x, 0)) * (tonumber(o.PhaseBurstGain) or 1), math.sqrt(math.max(y, 0)) * (tonumber(o.PhaseBurstGain) or 1)
				if g6 > 1e-4 then
					table.insert(list, { name = "burst_" .. band .. "_t6", gain = math.floor(g6 * 1e5 + 0.5) / 1e5 })
				end
				if g25 > 1e-4 then
					table.insert(list, { name = "burst_" .. band .. "_t25", gain = math.floor(g25 * 1e5 + 0.5) / 1e5 })
				end
			end
		end
		a.bursts = (#list > 0) and list or nil
	end
	-- PhasePairs: every harmonic is played by two sines at one fixed volume; its loudness comes from how far
	-- apart their phases are steered (the engine ramps every volume change over ~10 ms and then holds it, which at
	-- 60 updates a second is heard as a faint echo; speed changes are not)
	local pairs = o.PhasePairs == true
	local partials = table.create(pairs and 2 * K or K, 0)
	for k = 1, K do
		partials[k] = k
		if pairs then
			partials[K + k] = k
		end
	end
	a.partials = partials
	a.pairs = pairs or nil
	a.frames = amps
	a.phaseFrames = unw
	a.groups = nil
	a.residual = nil
	a.phases = nil
	a.loopAmps = nil
	a.voice = true
	a.phaseVoice = true
	return a
end

-- Presets -------------------------------------------------------------------------------

-- Exact cycle (Cycle = "exact"): a sample that settles into a short loop of a few periods (the DS-style single-cycle
-- instruments) is one fixed waveform. Its harmonics are read straight off the loop (a DFT over the loop is exact
-- when the loop holds a whole number of periods), and every harmonic above CycleFloor dB of the loudest becomes
-- its own sine at the loop's own phase. The bundles' smooth 1/k spread can't do this: a mostly-odd waveform (brass,
-- clarinet, square-ish chips) gets its weak even harmonics raised ~15 dB, which is heard as a buzz.
local function exactCycle(a, pcm, info, o)
	local rate = pcm.sampleRate
	local src = pcm.data[1]
	local ls, le = pcm.loopStart, pcm.loopEnd
	local n = le - ls
	local f0 = 440 * 2 ^ ((info.root - 69) / 12) * 2 ^ (-(info.pitchCorrection or 0) / 1200) * (a.fundamental or 1)
	-- only for samples that reach their loop quickly: the loop replaces the whole note here, so a longer attack
	-- (a pluck or a piano strike before the loop) would be lost
	if ls / rate > (tonumber(o.CycleMaxAttack) or 0.04) then
		return a
	end
	local periods = n * f0 / rate
	local m = math.floor(periods + 0.5)
	if m < 1 or m > (tonumber(o.CycleMaxPeriods) or 16) or math.abs(periods - m) > 0.08 * m then
		return a -- not a whole number of periods: not a single fixed waveform
	end
	local kTop = math.floor((n / 2 - 1) / m)
	kTop = math.min(kTop, math.floor(rate * 0.47 / f0))
	local re, im2 = table.create(kTop, 0), table.create(kTop, 0)
	local top = 0
	for k = 1, kTop do
		local w = 2 * math.pi * k * m / n
		local sr, si = 0, 0
		for i = 0, n - 1 do
			local x = buffer.readf32(src, (ls + i) * 4)
			sr += x * math.cos(w * i)
			si -= x * math.sin(w * i)
		end
		re[k], im2[k] = 2 * sr / n, 2 * si / n
		top = math.max(top, math.sqrt(re[k] ^ 2 + im2[k] ^ 2))
	end
	local floor = top * 10 ^ ((tonumber(o.CycleFloor) or -50) / 20)
	local partials, amps, phases = {}, {}, {}
	for k = 1, kTop do
		local amp = math.sqrt(re[k] ^ 2 + im2[k] ^ 2)
		if amp > floor and #partials < (tonumber(o.CycleMax) or 64) then
			table.insert(partials, k)
			table.insert(amps, math.floor(amp * 1e6 + 0.5) / 1e6)
			-- x = amp cos(k phi + arg) = amp sin(k phi + arg + pi/2): sine phase in cycles at the loop start
			local cyc = ((math.atan2(im2[k], re[k]) + math.pi / 2) / (2 * math.pi)) % 1
			table.insert(phases, math.floor(cyc * 1000 + 0.5) / 1000)
		end
	end
	if #partials == 0 then
		return a
	end
	a.partials = partials
	a.loopAmps = amps
	a.frames = {}
	a.phases = phases
	a.groups = nil
	a.residual = nil
	a.cycle = nil
	a.pitch = nil
	a.exactCycle = true
	return a
end

-- Automatic harmonic choice (Harmonic = "auto"). Every tonal sample is also measured harmonic by harmonic (leak-free,
-- frame by frame). Then:
--   * if the harmonics don't hold most of its energy (inharmonic bells, noisy sounds), keep the normal analysis;
--   * if following each harmonic's own phase frame by frame fits the waveform clearly better than fixed phases
--     (a sung vowel, a moving pitch), play it as steered pairs of sines (the channel-4 voice method);
--   * else if the normal analysis' bundles misplace its upper harmonics (smooth 1/k spread over harmonics that are
--     really uneven, e.g. odd-only), play every harmonic above HarmonicFloor dB as its own sine, exact level, with
--     a fixed phase each (cheap: no steering);
--   * else keep the normal analysis (it is already close and uses fewer players).
local function bundleError(a, rows, K)
	-- loudness-weighted dB error of the bundles' 1/k spread against the measured harmonics (above the sines)
	local isSine = {}
	if a.partials and not a.voice then
		for _, k in ipairs(a.partials) do
			isSine[k] = true
		end
	else
		for k = 1, 8 do
			isSine[k] = true
		end
	end
	local num, den = 0, 0
	for _, row in ipairs(rows) do
		local fe, strongest = 0, 0
		for k = 1, K do
			fe += row[k] ^ 2
			strongest = math.max(strongest, row[k])
		end
		if fe > 0 then
			local floor = strongest * 10 ^ (-50 / 20)
			local ferr, fw = 0, 0
			for _, g in ipairs(WaveBank.BundleGroups) do
				local E, W = 0, 0
				for k = g[1], math.min(g[2], K) do
					if not isSine[k] then
						E += row[k] ^ 2
						W += k ^ -2
					end
				end
				if W > 0 and E > 0 then
					for k = g[1], math.min(g[2], K) do
						if not isSine[k] then
							local pred, meas = math.sqrt(E * k ^ -2 / W), row[k]
							local big = math.max(pred, meas)
							if big > floor then
								local e = math.abs(20 * math.log10(math.max(pred, floor * 0.3) / math.max(meas, floor * 0.3)))
								ferr += math.min(e, 30) * big * big
								fw += big * big
							end
						end
					end
				end
			end
			if fw > 0 then
				num += ferr / fw * fe
				den += fe
			end
		end
	end
	return den > 0 and num / den or 0
end

local function harmonicChoice(a, pcm, info, o, isVoice)
	local rate = pcm.sampleRate
	local src = pcm.data[1]
	local length = pcm.length
	local forced = table.clone(o)
	forced.Voice = "coherent"
	forced.PhaseHz = tonumber(o.HarmonicHz) or 16000
	forced.PhasePairs = nil
	forced.PhaseBursts = nil
	local ok, ph = pcall(function()
		return phaseVoice(analyseOnce(pcm, info, forced), pcm, info, forced)
	end)
	if not ok or not ph or not ph.phaseFrames or #ph.frames < 2 then
		return nil
	end
	local hop = ph.hop
	local lastS = a.looped and math.min(length, pcm.loopEnd) or length
	local nf = math.min(#ph.frames, math.floor((lastS / rate) / hop) + 1)
	local K = #ph.partials
	local rows, U = table.move(ph.frames, 1, nf, 1, {}), ph.phaseFrames
	-- 1. harmonic share of the energy (20 ms around each frame)
	local hE, tE = 0, 0
	local half = math.floor(0.01 * rate)
	for j = 1, nf do
		local c = math.floor((j - 1) * hop * rate + 0.5)
		local p, cnt = 0, 0
		for i = math.max(0, c - half), math.min(lastS - 1, c + half) do
			local x = buffer.readf32(src, i * 4)
			p += x * x
			cnt += 1
		end
		if cnt > 0 then
			tE += p / cnt
			for k = 1, K do
				hE += rows[j][k] ^ 2 / 2
			end
		end
	end
	local share = tE > 0 and hE / tE or 0
	if share < (tonumber(o.HarmonicMinShare) or 0.75) then
		Instruments.lastHarmonicStats = { share = share, choice = "inharmonic" }
		return nil
	end
	-- 2. how much following each harmonic's own phase helps, against what a fixed-pitch player can do: one
	-- constant pitch for the whole note (fitted jointly over all harmonics) and one fixed phase per harmonic
	local n = math.min(lastS, math.floor(1.0 * rate))
	local function u(j, k)
		return U[math.min(j, #U)][k]
	end
	local tb, ub = table.create(K, 0), table.create(K, 0)
	local wk = table.create(K, 0)
	for k = 1, K do
		local sw, st, su = 0, 0, 0
		for j = 1, nf do
			local w = rows[j][k] ^ 2
			sw += w
			st += w * (j - 1) * hop
			su += w * u(j, k)
		end
		wk[k] = sw
		if sw > 0 then
			tb[k], ub[k] = st / sw, su / sw
		end
	end
	local bn, bd = 0, 0
	for k = 1, K do
		if wk[k] > 0 then
			for j = 1, nf do
				local w = rows[j][k] ^ 2
				local dt = (j - 1) * hop - tb[k]
				bn += w * k * dt * (u(j, k) - ub[k])
				bd += w * k * k * dt * dt
			end
		end
	end
	local beta = bd > 0 and bn / bd or 0 -- fundamental, cycles per second
	local psi = table.create(K, 0)
	for k = 1, K do
		psi[k] = (ub[k] - k * beta * tb[k]) % 1
	end
	local eFrame, eFixed, eSig = 0, 0, 0
	for i = 0, n - 1 do
		local tt = i / rate
		local fpos = tt / hop
		local j = math.floor(fpos)
		local t = fpos - j
		local r0, r1 = rows[math.min(j + 1, nf)], rows[math.min(j + 2, nf)]
		local yA, yB = 0, 0
		for k = 1, K do
			local amp = r0[k] + (r1[k] - r0[k]) * t
			if amp > 0 then
				yA += amp * math.sin(2 * math.pi * (u(j + 1, k) + (u(j + 2, k) - u(j + 1, k)) * t))
				yB += amp * math.sin(2 * math.pi * (k * beta * tt + psi[k]))
			end
		end
		local x = buffer.readf32(src, i * 4)
		eSig += x * x
		eFrame += (x - yA) ^ 2
		eFixed += (x - yB) ^ 2
	end
	local snrFixed = (eFixed > 0) and 10 * math.log10(eSig / eFixed) or 99
	local snrSteer = (eFrame > 0) and 10 * math.log10(eSig / eFrame) or 99
	local gain = (eFrame > 0 and eFixed > 0) and 10 * math.log10(eFixed / eFrame) or 0
	local pitchDev = 0
	local berr = bundleError(a, rows, K)
	local choice
	if isVoice then
		choice = "steered"
	elseif berr >= (tonumber(o.HarmonicMinError) or 5) then
		choice = "fixed"
	else
		Instruments.lastHarmonicStats = { share = share, gain = gain, berr = berr, snrFixed = snrFixed, snrSteer = snrSteer, beta = beta, choice = "normal" }
		return nil, { share = share, gain = gain, berr = berr }
	end
	local stats = { share = share, gain = gain, berr = berr, snrFixed = snrFixed, snrSteer = snrSteer, beta = beta, choice = choice }
	Instruments.lastHarmonicStats = stats
	if choice == "steered" then
		local f2 = table.clone(o)
		f2.Voice = "coherent"
		f2.PhaseHz = tonumber(o.SteerHz) or 8000
		f2.PhasePairs = true
		local ok2, pv = pcall(function()
			return phaseVoice(analyseOnce(pcm, info, f2), pcm, info, f2)
		end)
		if ok2 and pv and pv.phaseFrames then
			-- only the harmonics that matter: up to the highest one above HarmonicFloor dB, at most HarmonicMax
			local Kp = #pv.frames[1]
			local mx, topA = table.create(Kp, 0), 0
			for _, row in ipairs(pv.frames) do
				for k = 1, Kp do
					mx[k] = math.max(mx[k], row[k] or 0)
					topA = math.max(topA, row[k] or 0)
				end
			end
			local fl = topA * 10 ^ ((tonumber(o.HarmonicFloor) or -50) / 20)
			local Kn = 1
			for k = 1, Kp do
				if mx[k] > fl then
					Kn = k
				end
			end
			Kn = math.min(Kn, tonumber(o.HarmonicSteerMax) or 24)
			if Kn < Kp then
				for j, row in ipairs(pv.frames) do
					pv.frames[j] = table.move(row, 1, Kn, 1, table.create(Kn, 0))
				end
				for j, row in ipairs(pv.phaseFrames) do
					pv.phaseFrames[j] = table.move(row, 1, Kn, 1, table.create(Kn, 0))
				end
				local parts = table.create(2 * Kn, 0)
				for k = 1, Kn do
					parts[k] = k
					parts[Kn + k] = k
				end
				pv.partials = parts
			end
			pv.choice = "steered"
			return pv, stats
		end
		return nil, stats
	end
	-- fixed phases: every harmonic above the floor, its own amplitude frame by frame, then the loop's level
	local top, maxA = 0, table.create(K, 0)
	for j = 1, nf do
		for k = 1, K do
			maxA[k] = math.max(maxA[k], rows[j][k])
			top = math.max(top, rows[j][k])
		end
	end
	local floor = top * 10 ^ ((tonumber(o.HarmonicFloor) or -50) / 20)
	local sel = {}
	for k = 1, K do
		if maxA[k] > floor then
			table.insert(sel, k)
		end
	end
	local cap = tonumber(o.HarmonicMax) or 64
	if #sel > cap then
		table.sort(sel, function(x, y)
			return maxA[x] > maxA[y]
		end)
		sel = table.move(sel, 1, cap, 1, {})
		table.sort(sel)
	end
	local frames = table.create(nf)
	for j = 1, nf do
		local row = table.create(#sel, 0)
		for i, k in ipairs(sel) do
			row[i] = rows[j][k]
		end
		frames[j] = row
	end
	local phases = table.create(#sel, 0)
	for i, k in ipairs(sel) do
		phases[i] = math.floor((psi[k] % 1) * 1000 + 0.5) / 1000
	end
	a.partials = sel
	a.frames = frames
	a.phases = phases
	a.groups = nil
	a.cycle = nil
	a.residual = nil -- it belongs to the grouped model: on top of exact harmonics it would sound like static
	if a.looped then
		-- the loop's level. A loop that holds a whole number of periods is read exactly (a DFT over the loop is
		-- the spectrum of the loop as it repeats); otherwise the frames inside the loop are averaged
		local ls, le = pcm.loopStart, pcm.loopEnd
		local nL = le - ls
		local f0 = 440 * 2 ^ ((info.root - 69) / 12) * 2 ^ (-(info.pitchCorrection or 0) / 1200) * (a.fundamental or 1)
		local periods = nL * f0 / rate
		local m = math.floor(periods + 0.5)
		local exact = m >= 1 and math.abs(periods - m) <= 0.08 * m and nL > 8
		local la = table.create(#sel, 0)
		if exact then
			local keep, kph = {}, {}
			local top2 = 0
			local re, imv = {}, {}
			for _, k in ipairs(sel) do
				local w = 2 * math.pi * k * m / nL
				local sr, si = 0, 0
				if k * m < nL / 2 then
					for i = 0, nL - 1 do
						local x = buffer.readf32(src, (ls + i) * 4)
						sr += x * math.cos(w * i)
						si -= x * math.sin(w * i)
					end
				end
				re[k], imv[k] = 2 * sr / nL, 2 * si / nL
				top2 = math.max(top2, math.sqrt(re[k] ^ 2 + imv[k] ^ 2))
			end
			for i, k in ipairs(sel) do
				local amp = math.sqrt(re[k] ^ 2 + imv[k] ^ 2)
				la[i] = math.floor(amp * 1e6 + 0.5) / 1e6
				-- sine phase at the loop start, carried back to the note start at the loop's own pitch
				local cyc = (math.atan2(imv[k], re[k]) + math.pi / 2) / (2 * math.pi)
				local back = k * m * ls / nL
				phases[i] = math.floor(((cyc - back) % 1) * 1000 + 0.5) / 1000
			end
			-- drop harmonics that are both below the floor in the loop and only briefly above it in the attack
			-- (they stay as attack-only parts: the player releases them once they fall below the floor)
		else
			local j0 = math.floor((ls / rate) / hop) + 1
			local cnt = 0
			for j = math.min(j0, nf), nf do
				for i = 1, #sel do
					la[i] += frames[j][i]
				end
				cnt += 1
			end
			for i = 1, #sel do
				la[i] = math.floor(la[i] / math.max(cnt, 1) * 1e6 + 0.5) / 1e6
			end
		end
		a.loopAmps = la
		a.loopExact = exact or nil
	end
	a.phases = phases
	-- Cost: during the attack only harmonics within HarmonicAttackFloor dB of that frame's strongest are kept (an attack
	-- is short and its own transient covers the faint ones); the held loop keeps everything above HarmonicFloor. A
	-- harmonic that is needed in neither is dropped from the sample.
	do
		local afl = 10 ^ ((tonumber(o.HarmonicAttackFloor) or -40) / 20)
		local need = table.create(#sel, false)
		for _, row in ipairs(frames) do
			local mx = 0
			for i = 1, #sel do
				mx = math.max(mx, row[i])
			end
			for i = 1, #sel do
				if row[i] > mx * afl then
					need[i] = true
				end
			end
		end
		local la = a.loopAmps
		if la then
			local mx = 0
			for i = 1, #sel do
				mx = math.max(mx, la[i])
			end
			local lfl = mx * 10 ^ ((tonumber(o.HarmonicFloor) or -50) / 20)
			for i = 1, #sel do
				if la[i] > lfl then
					need[i] = true
				else
					la[i] = 0
				end
			end
		end
		local keepIdx = {}
		for i = 1, #sel do
			if need[i] then
				table.insert(keepIdx, i)
			end
		end
		if #keepIdx < #sel then
			local function pick(t)
				local r = table.create(#keepIdx, 0)
				for q, i in ipairs(keepIdx) do
					r[q] = t[i]
				end
				return r
			end
			for j, row in ipairs(frames) do
				frames[j] = pick(row)
			end
			a.partials = pick(sel)
			a.phases = pick(phases)
			if la then
				a.loopAmps = pick(la)
			end
		end
	end
	a.exactCycle = true -- phase-locked sines (speed always sent)
	a.choice = "fixed"
	return a, stats
end

-- Peaks (Peaks = "auto"): a bell-like sample whose overtones aren't evenly spread over the harmonics (a tubular bell:
-- 1, 2, 3, 4, 5, 6 as close pairs that beat, then nothing until a cluster at 13 and 15). The bundles spread an octave's
-- energy smoothly over every harmonic in it, which blurs those clusters away. Here each real overtone gets its own
-- sine at its own (non-integer) frequency ratio:
--   * frequencies: the strongest peaks of a long, finely zero-padded spectrum of the sample before its loop;
--   * the attack: every frame, all the sines' levels at once (a least-squares fit, so a close pair is split right);
--   * the loop: the loop's own line spectrum, its energy shared out to the nearest sine.
local function complexSolve(M, b, K)
	-- Gauss-Jordan on a K x K complex system (M[i][j] = {re, im}), b = { {re, im} }
	local A = {}
	for i = 1, K do
		local row = {}
		for j = 1, K do
			row[j] = { M[i][j][1], M[i][j][2] }
		end
		row[K + 1] = { b[i][1], b[i][2] }
		A[i] = row
	end
	for c = 1, K do
		local p, best = c, -1
		for r = c, K do
			local m = A[r][c][1] ^ 2 + A[r][c][2] ^ 2
			if m > best then
				p, best = r, m
			end
		end
		A[c], A[p] = A[p], A[c]
		local pr, pi = A[c][c][1], A[c][c][2]
		local d = pr * pr + pi * pi
		if d < 1e-30 then
			return nil
		end
		local ir, ii = pr / d, -pi / d
		for j = c, K + 1 do
			local x = A[c][j]
			x[1], x[2] = x[1] * ir - x[2] * ii, x[1] * ii + x[2] * ir
		end
		for r = 1, K do
			if r ~= c then
				local fr, fi = A[r][c][1], A[r][c][2]
				if fr ~= 0 or fi ~= 0 then
					for j = c, K + 1 do
						local y = A[c][j]
						local x = A[r][j]
						x[1] -= fr * y[1] - fi * y[2]
						x[2] -= fr * y[2] + fi * y[1]
					end
				end
			end
		end
	end
	local out = {}
	for i = 1, K do
		out[i] = A[i][K + 1]
	end
	return out
end

local function peaksVoice(a, pcm, info, o)
	local rate = pcm.sampleRate
	local src = pcm.data[1]
	local length = pcm.length
	local f0 = 440 * 2 ^ ((info.root - 69) / 12) * 2 ^ (-(info.pitchCorrection or 0) / 1200)
	local looped = a.looped
	local ls = looped and pcm.loopStart or length
	local le = looped and pcm.loopEnd or length
	local s0 = math.floor(0.02 * rate)
	local s1 = math.max(s0 + math.floor(0.1 * rate), ls) -- the sample before its loop (at least 100 ms)
	s1 = math.min(s1, length)
	local n = s1 - s0
	if n < 256 then
		return nil
	end
	-- 1. frequencies
	local N = math.min(FFT.nextPow2(n * 4), 131072)
	local re, im = table.create(N, 0), table.create(N, 0)
	local w = FFT.window("hann", math.min(n, N))
	for i = 1, math.min(n, N) do
		re[i] = buffer.readf32(src, (s0 + i - 1) * 4) * w[i]
	end
	FFT.transform(re, im)
	local half = N // 2
	local L = table.create(half, -300)
	local top = -300
	for i = 1, half do
		local m = re[i] * re[i] + im[i] * im[i]
		L[i] = 10 * math.log10(m + 1e-30)
		top = math.max(top, L[i])
	end
	local hz = rate / N
	local dist = math.max(1, math.floor(5 / hz)) -- local maximum within +-5 Hz
	local reach = math.max(dist, math.floor(40 / hz)) -- prominence looked for within +-40 Hz
	local floorDb = top + (tonumber(o.PeaksFloor) or -45)
	local cands = {}
	local loBin, hiBin = math.max(2, math.ceil(0.4 * f0 / hz)), math.min(half - 1, math.floor(0.45 * rate / hz))
	for i = loBin, hiBin do
		local v = L[i]
		if v > floorDb and v >= L[i - 1] and v > L[i + 1] then
			local isMax = true
			for d = 1, dist do
				if L[math.max(1, i - d)] > v or L[math.min(half, i + d)] > v then
					isMax = false
					break
				end
			end
			-- prominence: the dip on each side before the spectrum climbs above this peak again
			local minL, minR = v, v
			for d = 1, reach do
				local l = L[math.max(1, i - d)]
				if l > v then
					break
				end
				minL = math.min(minL, l)
			end
			for d = 1, reach do
				local r = L[math.min(half, i + d)]
				if r > v then
					break
				end
				minR = math.min(minR, r)
			end
			if isMax and v - math.max(minL, minR) >= 3 then
				local y0, y1, y2 = L[i - 1], v, L[i + 1]
				local den = y0 - 2 * y1 + y2
				local dd = (den < 0) and 0.5 * (y0 - y2) / den or 0
				table.insert(cands, { f = (i - 1 + dd) * hz, db = v })
			end
		end
	end
	table.sort(cands, function(x, y)
		return x.db > y.db
	end)
	local K = math.min(#cands, tonumber(o.PeaksMax) or 20)
	if K < 2 then
		return nil
	end
	local freqs = {}
	for i = 1, K do
		freqs[i] = cands[i].f
	end
	table.sort(freqs)
	-- 2. attack frames: joint least squares of all the sines in each Hann frame
	local hop = a.hop or 0.01
	local nw = math.floor((tonumber(o.PeaksWindow) or 0.06) * rate)
	local win = FFT.window("hann", nw)
	local M = {}
	for i = 1, K do
		M[i] = {}
		for j = 1, K do
			local sr, si = 0, 0
			local dw = 2 * math.pi * (freqs[j] - freqs[i]) / rate
			for t = 0, nw - 1 do
				local ww = win[t + 1] ^ 2
				sr += ww * math.cos(dw * t)
				si += ww * math.sin(dw * t)
			end
			M[i][j] = { sr, si }
		end
	end
	local ridge = 0
	for i = 1, K do
		ridge += M[i][i][1]
	end
	ridge = 1e-3 * ridge / K
	for i = 1, K do
		M[i][i][1] += ridge
	end
	local function readPlay(i)
		if i < 0 then
			return 0
		end
		if looped and i >= le then
			return buffer.readf32(src, (ls + (i - ls) % (le - ls)) * 4)
		end
		if i >= length then
			return 0
		end
		return buffer.readf32(src, i * 4)
	end
	local lastS = looped and ls or length
	local nf = math.floor((lastS / rate) / hop) + 2
	local frames = table.create(nf)
	local slice = os.clock()
	local cw, sw = {}, {}
	for i = 1, K do
		cw[i], sw[i] = math.cos(2 * math.pi * freqs[i] / rate), math.sin(2 * math.pi * freqs[i] / rate)
	end
	for j = 0, nf - 1 do
		local c = math.floor(j * hop * rate + 0.5) - nw // 2
		local b = {}
		for i = 1, K do
			local zr, zi, br, bi = 1, 0, 0, 0
			local cr, ci = cw[i], -sw[i]
			for t = 0, nw - 1 do
				local x = readPlay(c + t) * win[t + 1] ^ 2
				br += x * zr
				bi += x * zi
				zr, zi = zr * cr - zi * ci, zr * ci + zi * cr
			end
			b[i] = { br, bi }
		end
		local sol = complexSolve(M, b, K)
		local row = table.create(K, 0)
		if sol then
			for i = 1, K do
				row[i] = math.floor(2 * math.sqrt(sol[i][1] ^ 2 + sol[i][2] ^ 2) * 1e6 + 0.5) / 1e6
			end
		end
		frames[j + 1] = row
		if os.clock() - slice > 0.01 then
			task.wait()
			slice = os.clock()
		end
	end
	-- 3. the loop: its line spectrum (zero-padded FFT), each line's energy to the sine whose cell it falls in
	local loopAmps
	if looped and le - ls > 16 then
		local nL = le - ls
		local NL = FFT.nextPow2(nL)
		local lr, li = table.create(NL, 0), table.create(NL, 0)
		for i = 1, nL do
			lr[i] = buffer.readf32(src, (ls + i - 1) * 4)
		end
		FFT.transform(lr, li)
		local lo, hi = {}, {}
		for i = 1, K do
			lo[i] = math.max(freqs[i] - f0 / 2, (i > 1) and (freqs[i - 1] + freqs[i]) / 2 or 0)
			hi[i] = math.min(freqs[i] + f0 / 2, (i < K) and (freqs[i] + freqs[i + 1]) / 2 or rate / 2)
		end
		local e = table.create(K, 0)
		local lhz = rate / NL
		local scale = 2 / (nL * nL) -- |X|^2 of a zero-padded rectangular DFT -> mean-square power (both sides)
		for bin = 2, NL // 2 do
			local fr = (bin - 1) * lhz
			for i = 1, K do
				if fr >= lo[i] and fr < hi[i] then
					e[i] += (lr[bin] ^ 2 + li[bin] ^ 2) * scale * (nL / NL)
					break
				end
			end
		end
		loopAmps = table.create(K, 0)
		for i = 1, K do
			loopAmps[i] = math.floor(math.sqrt(2 * e[i]) * 1e6 + 0.5) / 1e6
		end
	end
	local ratios = table.create(K, 0)
	for i = 1, K do
		ratios[i] = math.floor(freqs[i] / f0 * 1e5 + 0.5) / 1e5
	end
	a.partials = ratios
	a.frames = frames
	a.loopAmps = loopAmps
	a.groups = nil
	a.cycle = nil
	a.phases = nil
	a.peaks = true
	a.choice = "peaks"
	return a
end

local function bellNeed(a, pcm, info, o)
	-- how badly the bundles fit this sample's overtones (loudness-weighted dB), from the harmonic table
	local forced = table.clone(o)
	forced.Voice = "coherent"
	forced.PhaseHz = 16000
	forced.PhasePairs = nil
	forced.PhaseBursts = nil
	local ok, ph = pcall(function()
		return phaseVoice(analyseOnce(pcm, info, forced), pcm, info, forced)
	end)
	if not ok or not ph or not ph.frames or #ph.frames < 2 then
		return 0
	end
	local lastS = a.looped and math.min(pcm.length, pcm.loopEnd) or pcm.length
	local nf = math.min(#ph.frames, math.floor((lastS / pcm.sampleRate) / ph.hop) + 1)
	return bundleError(a, table.move(ph.frames, 1, nf, 1, {}), #ph.partials)
end

-- Held loop (Hold = "auto"): the attack plays exactly as before (8 sines, the bundles, the noise), but once the note
-- settles into its loop, the loop is played as exact sines read off the loop itself (every harmonic above HoldFloor
-- dB, its own level and phase) instead of sines + smeared bundles. That removes the bundles' buzz from held notes
-- (the brass fix, for samples with a long attack) without the static of rebuilding a long attack from many sines.
-- Only for loops that hold a whole number of periods (then the DFT is the loop as it repeats).
local function holdLoop(a, pcm, info, o)
	if not a.looped or not a.frames or #a.frames < 2 or not a.loopStart then
		return nil
	end
	local rate = pcm.sampleRate
	local src = pcm.data[1]
	local ls, le = pcm.loopStart, pcm.loopEnd
	local nL = le - ls
	local f0 = 440 * 2 ^ ((info.root - 69) / 12) * 2 ^ (-(info.pitchCorrection or 0) / 1200) * (a.fundamental or 1)
	local periods = nL * f0 / rate
	local m = math.floor(periods + 0.5)
	if m < 1 or math.abs(periods - m) > 0.08 * m or nL < 16 then
		return nil
	end
	local kTop = math.min(math.floor((nL / 2 - 1) / m), math.floor(rate * 0.47 / f0))
	local re, imv, top = {}, {}, 0
	for k = 1, kTop do
		local w = 2 * math.pi * k * m / nL
		local sr, si = 0, 0
		local cr, ci = math.cos(w), -math.sin(w)
		local zr, zi = 1, 0
		for i = 0, nL - 1 do
			local x = buffer.readf32(src, (ls + i) * 4)
			sr += x * zr
			si += x * zi
			zr, zi = zr * cr - zi * ci, zr * ci + zi * cr
		end
		re[k], imv[k] = 2 * sr / nL, 2 * si / nL
		top = math.max(top, math.sqrt(re[k] ^ 2 + imv[k] ^ 2))
	end
	if top <= 0 then
		return nil
	end
	-- a loop that is mostly noise (not its harmonics) stays as it was
	local hE, tE = 0, 0
	for k = 1, kTop do
		hE += (re[k] ^ 2 + imv[k] ^ 2) / 2
	end
	for i = 0, nL - 1 do
		tE += buffer.readf32(src, (ls + i) * 4) ^ 2
	end
	tE /= nL
	if tE <= 0 or hE / tE < (tonumber(o.HoldMinShare) or 0.8) then
		return nil
	end
	local fl = top * 10 ^ ((tonumber(o.HoldFloor) or -50) / 20)
	local loopK = {}
	for k = 1, kTop do
		if math.sqrt(re[k] ^ 2 + imv[k] ^ 2) > fl then
			table.insert(loopK, k)
		end
	end
	local cap = tonumber(o.HoldMax) or 40
	if #loopK > cap then
		table.sort(loopK, function(x, y)
			return re[x] ^ 2 + imv[x] ^ 2 > re[y] ^ 2 + imv[y] ^ 2
		end)
		loopK = table.move(loopK, 1, cap, 1, {})
		table.sort(loopK)
	end
	-- the parts: the attack's sines (harmonics 1..P), then the loop's other harmonics, then the attack's bundles
	local P = #a.partials
	local G = a.groups and #a.groups or 0
	local partials, index = {}, {}
	for i, k in ipairs(a.partials) do
		partials[i] = k
		index[k] = i
	end
	for _, k in ipairs(loopK) do
		if not index[k] then
			table.insert(partials, k)
			index[k] = #partials
		end
	end
	local S = #partials
	local loopAmps = table.create(S + G, 0)
	local phases = table.create(S, 0)
	for k = 1, kTop do
		local i = index[k]
		if i then
			local amp = math.sqrt(re[k] ^ 2 + imv[k] ^ 2)
			local keep = false
			for _, q in ipairs(loopK) do
				if q == k then
					keep = true
					break
				end
			end
			loopAmps[i] = keep and math.floor(amp * 1e6 + 0.5) / 1e6 or 0
			local cyc = (math.atan2(imv[k], re[k]) + math.pi / 2) / (2 * math.pi)
			phases[i] = math.floor(((cyc - k * m * ls / nL) % 1) * 1000 + 0.5) / 1000
		end
	end
	-- frames: the attack as analysed (sines, then bundles), up to the loop start, then a short crossfade into the loop
	local hop = a.hop
	local nAtt = math.max(1, math.floor(a.loopStart / hop + 1e-9) + 1)
	local frames = {}
	for j = 1, math.min(nAtt, #a.frames) do
		local src0 = a.frames[j]
		local row = table.create(S + G, 0)
		for i = 1, P do
			row[i] = src0[i] or 0
		end
		for g = 1, G do
			row[S + g] = src0[P + g] or 0
		end
		frames[j] = row
	end
	local last = frames[#frames]
	local xf = math.max(1, math.floor((tonumber(o.HoldCrossfade) or 0.04) / hop + 0.5))
	for q = 1, xf do
		local t = q / xf
		local row = table.create(S + G, 0)
		for i = 1, S + G do
			row[i] = math.floor(((last[i] or 0) * (1 - t) + loopAmps[i] * t) * 1e6 + 0.5) / 1e6
		end
		table.insert(frames, row)
	end
	a.partials = partials
	a.frames = frames
	a.loopAmps = loopAmps
	a.phases = phases
	a.cycle = nil
	a.loopStart = math.floor(((#frames - 1) * hop) * 1e4 + 0.5) / 1e4 -- the loop amplitudes take over after the crossfade
	a.hold = true
	a.choice = "hold"
	return a
end

local function analyseCore(pcm, info, options)
	local o = options or {}
	local mode = o.Voice
	if mode == nil then
		mode = Instruments.Defaults.Voice
	end
	local plain = table.clone(o)
	plain.Voice = false
	local a = analyseOnce(pcm, info, plain)
	if mode == "auto" and a.kind == "tonal" and a.check and a.check.err >= (o.VoiceMinErr or Instruments.Defaults.VoiceMinErr) then
		local forced = table.clone(o)
		forced.Voice = "force"
		local b = analyseOnce(pcm, info, forced)
		local hmode = o.Harmonic
		if hmode == nil then
			hmode = Instruments.Defaults.Harmonic
		end
		-- with exact harmonics available, a looped sample is only taken as a voice when the steady harmonic model
		-- clearly fails it (a sung vowel, check error >= HarmonicVoiceErr dB); a very periodic instrument whose
		-- check merely improves (a detuned piano, an organ) gets exact harmonics instead
		local weakVoice = hmode == "auto" and a.looped and a.check.err < (tonumber(o.HarmonicVoiceErr) or 1.2)
		if b.voice and not weakVoice and b.check and b.check.err <= a.check.err * (o.VoiceGain or Instruments.Defaults.VoiceGain) then
			-- a voice-like sample: the harmonic measurement decides first (steered pairs replace the older voice mode)
			local hm = o.Harmonic
			if hm == nil then
				hm = Instruments.Defaults.Harmonic
			end
			-- (a looped voice keeps the voice analysis: closer to the original than fixed harmonics)
			if hm == "auto" and not a.looped then
				local h = harmonicChoice(a, pcm, info, o, true)
				if h then
					return h
				end
			end
			return b
		end
	elseif mode == "phase" and a.kind == "tonal" then
		local forced = table.clone(o)
		forced.Voice = "coherent"
		return phaseVoice(analyseOnce(pcm, info, forced), pcm, info, o)
	elseif (mode == "force" or mode == "coherent") and a.kind == "tonal" then
		local forced = table.clone(o)
		forced.Voice = mode
		return analyseOnce(pcm, info, forced)
	end
	local cycleMode = o.Cycle
	if cycleMode == nil then
		cycleMode = Instruments.Defaults.Cycle
	end
	if cycleMode == "exact" and a.kind == "tonal" and a.looped then
		a = exactCycle(a, pcm, info, o)
		if a.exactCycle then
			return a
		end
	end
	local pk = o.Peaks
	if pk == nil then
		pk = Instruments.Defaults.Peaks
	end
	local need = nil
	local function bundleMisfit()
		need = need or bellNeed(a, pcm, info, o)
		return need
	end
	if pk and a.kind == "tonal" and not a.voice and (pk == "force" or bundleMisfit() >= (tonumber(o.PeaksMinError) or Instruments.Defaults.PeaksMinError)) then
		local p = peaksVoice(a, pcm, info, o)
		if p then
			return p
		end
	end
	local hold = o.Hold
	if hold == nil then
		hold = Instruments.Defaults.Hold
	end
	if hold and a.kind == "tonal" and not a.voice and a.looped and (hold == "force" or bundleMisfit() >= (tonumber(o.HoldMinError) or Instruments.Defaults.HoldMinError)) then
		local h = holdLoop(a, pcm, info, o)
		if h then
			return h
		end
	end
	local hm = o.Harmonic
	if hm == nil then
		hm = Instruments.Defaults.Harmonic
	end
	if hm == "auto" and a.kind == "tonal" and not a.voice then
		local h = harmonicChoice(a, pcm, info, o, not a.looped)
		if h then
			return h
		end
	end
	return a
end

-- Sample playback character (Images = true). The original is a sample played back by resampling with linear
-- interpolation, which (1) softens each harmonic h by sinc^2(h*f0/rate) and (2) adds faint mirror images of the
-- spectrum at k*rate +- h*f0 (scaled with the note: fixed ratios k*rate/f0 +- h of the note's pitch, level
-- sinc^2(k +- h*f0/rate)). For a high sample played far below its root (CASINO's channel 5) those images sit at
-- 4-12 kHz only ~20-40 dB down: they are the "crisp" top of the original. Each image above ImagesFloor dB of the
-- loudest harmonic becomes a sine of its own (fixed ratio; above the original's own Nyquist it folds back, like the
-- original). Its level follows the harmonic it mirrors, frame by frame.
local function sinc2(x)
	if math.abs(x) < 1e-9 then
		return 1
	end
	local v = math.sin(math.pi * x) / (math.pi * x)
	return v * v
end

local function playbackImages(a, pcm, info, o)
	if a.kind ~= "tonal" or a.pairs or a.voice or not a.partials or #a.partials == 0 or not a.frames then
		return a
	end
	local rate = pcm.sampleRate
	local f0 = 440 * 2 ^ ((info.root - 69) / 12) * 2 ^ (-(info.pitchCorrection or 0) / 1200) * (a.fundamental or 1)
	local R = rate / f0 -- the sample rate in harmonics of the root
	local P = #a.partials
	local groups = a.groups or {}
	local G = #groups
	local GR = WaveBank.BundleGroups
	-- harmonic amplitude h of a row: the sine's own, or the bundle group's spread as 1/h
	local function harmonicAmp(row, h)
		for i = 1, P do
			if a.partials[i] == h then
				return row[i] or 0
			end
		end
		if a.peaks then
			return 0
		end
		for j = 1, G do
			local g = GR[groups[j]]
			if g and h >= g[1] and h <= g[2] then
				local w = 0
				for q = g[1], g[2] do
					w += q ^ -2
				end
				return (row[P + j] or 0) * (1 / h) / math.sqrt(w)
			end
		end
		return 0
	end
	-- the harmonics present (sines' ratios, and the bundles' ranges below the sample's Nyquist)
	local hs = {}
	if a.peaks then
		for i = 1, P do
			hs[i] = a.partials[i]
		end
	else
		local hTop = math.floor(R / 2)
		for h = 1, hTop do
			table.insert(hs, h)
		end
	end
	-- 1. in-band softening of the sines (bundles: their group's mid harmonic)
	local function soften(row)
		for i = 1, P do
			row[i] = (row[i] or 0) * sinc2(a.partials[i] / R)
		end
		for j = 1, G do
			local g = GR[groups[j]]
			if g then
				row[P + j] = (row[P + j] or 0) * sinc2(math.sqrt(g[1] * g[2]) / R)
			end
		end
	end
	-- 2. images
	local strongest = 0
	local ref = a.loopAmps or a.frames[math.min(#a.frames, 3)]
	for _, row in ipairs(a.frames) do
		for i = 1, P do
			strongest = math.max(strongest, row[i] or 0)
		end
	end
	if ref then
		for i = 1, P do
			strongest = math.max(strongest, ref[i] or 0)
		end
	end
	if strongest <= 0 then
		return a
	end
	local floorAmp = strongest * 10 ^ ((tonumber(o.ImagesFloor) or -55) / 20)
	local cands = {}
	for k = 1, 2 do
		for _, h in ipairs(hs) do
			for _, sgn in ipairs({ -1, 1 }) do
				local ratio = k * R + sgn * h
				local gain = sinc2(k + sgn * h / R)
				if ratio > 0.5 and gain > 0 then
					local peak = 0
					for _, row in ipairs(a.frames) do
						peak = math.max(peak, harmonicAmp(row, h) * gain)
					end
					if ref then
						peak = math.max(peak, harmonicAmp(ref, h) * gain)
					end
					if peak > floorAmp then
						table.insert(cands, { ratio = ratio, h = h, gain = gain, peak = peak })
					end
				end
			end
		end
	end
	table.sort(cands, function(x, y)
		return x.peak > y.peak
	end)
	local cap = tonumber(o.ImagesMax) or 16
	while #cands > cap do
		table.remove(cands)
	end
	local nI = #cands
	local function extend(row)
		if not row then
			return row
		end
		local out = table.create(P + nI + G, 0)
		for i = 1, P do
			out[i] = row[i] or 0
		end
		for q, c in ipairs(cands) do
			out[P + q] = math.floor(harmonicAmp(row, c.h) * c.gain * 1e6 + 0.5) / 1e6
		end
		for j = 1, G do
			out[P + nI + j] = row[P + j] or 0
		end
		return out
	end
	for j, row in ipairs(a.frames) do
		local nr = extend(row)
		local tmp = table.clone(row)
		soften(tmp)
		for i = 1, P do
			nr[i] = math.floor(tmp[i] * 1e6 + 0.5) / 1e6
		end
		for g = 1, G do
			nr[P + nI + g] = math.floor(tmp[P + g] * 1e6 + 0.5) / 1e6
		end
		a.frames[j] = nr
	end
	if a.loopAmps then
		local nr = extend(a.loopAmps)
		local tmp = table.clone(a.loopAmps)
		soften(tmp)
		for i = 1, P do
			nr[i] = math.floor((tmp[i] or 0) * 1e6 + 0.5) / 1e6
		end
		for g = 1, G do
			nr[P + nI + g] = math.floor((tmp[P + g] or 0) * 1e6 + 0.5) / 1e6
		end
		a.loopAmps = nr
	end
	if nI > 0 then
		for q, c in ipairs(cands) do
			a.partials[P + q] = math.floor(c.ratio * 1e5 + 0.5) / 1e5
		end
		if a.phases then
			for q = 1, nI do
				a.phases[P + q] = (q * 0.618) % 1
			end
		end
		a.imageFrom = P + 1 -- partials from here on are playback images (fold above the original's Nyquist)
		a.imageFoldHz = tonumber(o.ImagesFoldHz) or 16384 -- the original's output Nyquist (32.7 kHz mixing): images above it fold back
	end
	return a
end

-- Smooth (Smooth = true): every sine is played as two sines at one fixed volume; its loudness comes from how far
-- apart their phases are steered (the method of the accepted "tum" voice). The engine takes a new volume only once per
-- audio block (~21 ms) and then holds it, so a fading note is a staircase of levels, heard as a faint reverb/echo on
-- held accompaniment. The pair's phase difference changes smoothly inside each block (speeds are exact per block),
-- so the fade is smooth. Costs two players per sine (the bundles are unchanged).
local function smoothPairs(a, info, o)
	if a.kind ~= "tonal" or a.pairs or a.voice or a.phaseFrames or not a.partials or #a.partials == 0 or not a.frames or #a.frames == 0 then
		return a
	end
	local N = #a.partials
	local G = a.groups and #a.groups or 0
	local hop = a.hop
	local f0 = 440 * 2 ^ ((info.root - 69) / 12) * 2 ^ (-(info.pitchCorrection or 0) / 1200) * (a.fundamental or 1)
	local nf = #a.frames
	-- the strongest SmoothPairs harmonics (peak over the note) become pairs; they move to the front
	local peak = table.create(N, 0)
	for _, row in ipairs(a.frames) do
		for i = 1, N do
			peak[i] = math.max(peak[i], row[i] or 0)
		end
	end
	if a.loopAmps then
		for i = 1, N do
			peak[i] = math.max(peak[i], a.loopAmps[i] or 0)
		end
	end
	local order = {}
	for i = 1, N do
		order[i] = i
	end
	table.sort(order, function(x, y)
		return peak[x] > peak[y]
	end)
	local K = math.min(N, tonumber(o.SmoothPairs) or 3)
	local chosen = table.move(order, 1, K, 1, {})
	table.sort(chosen)
	local isChosen = {}
	for _, i in ipairs(chosen) do
		isChosen[i] = true
	end
	local rest = {}
	for i = 1, N do
		if not isChosen[i] then
			table.insert(rest, i)
		end
	end
	local src = table.clone(chosen) -- new index -> old index: chosen (pairs), chosen again, then the rest
	for _, i in ipairs(chosen) do
		table.insert(src, i)
	end
	for _, i in ipairs(rest) do
		table.insert(src, i)
	end
	local oldPartials, oldPhases = a.partials, a.phases
	local U = table.create(nf)
	local phi = 0
	for j = 1, nf do
		local row = table.create(K, 0)
		for k = 1, K do
			local old = chosen[k]
			local psi = oldPhases and oldPhases[old] or 0
			row[k] = math.floor((oldPartials[old] * phi + psi) * 1e4 + 0.5) / 1e4
		end
		U[j] = row
		local cents = a.pitch and a.pitch[math.min(j, #a.pitch)] or 0
		phi += hop * f0 * 2 ^ (cents / 1200)
	end
	local function widen(row)
		if not row then
			return nil
		end
		local S = #src
		local out = table.create(S + G, 0)
		for i = 1, S do
			out[i] = (i > K and i <= 2 * K) and 0 or (row[src[i]] or 0)
		end
		for g = 1, G do
			out[S + g] = row[N + g] or 0
		end
		return out
	end
	for j = 1, nf do
		a.frames[j] = widen(a.frames[j])
	end
	a.loopAmps = widen(a.loopAmps)
	local parts, phs = {}, {}
	for i, old in ipairs(src) do
		parts[i] = oldPartials[old]
		phs[i] = oldPhases and oldPhases[old] or nil
	end
	a.partials = parts
	a.phases = oldPhases and phs or nil
	a.phaseFrames = U
	a.pairs = true
	a.smooth = true
	a.imageFrom = nil -- (no fold-back in pair mode)
	return a
end

-- Modes. A struck one-shot (a tongue drum, a kalimba, a bell-like tone) often carries two or three close modes in
-- one harmonic: they beat, so the harmonic's level swings by 10-20 dB at a few Hz and its pitch wobbles at each
-- dip. Played as one sine with a level per frame, that swing becomes a staircase of 21 ms volume steps (a
-- scuffle). Each strong harmonic is fitted instead as a sum of damped sinusoids (matrix pencil on the harmonic's
-- band, heterodyned and decimated): a mode is a frequency, a decay rate and a start amplitude and phase, played at
-- one volume for the whole note. a.modes = { { k, r = f / f0, a = amplitude at t = 0, l = 1/s (exp(l t)),
-- p = sine phase at t = 0 (cycles) } }, a.modeK[k] = true for the harmonics they replace.
local function cmul(ar, ai, br, bi)
	return ar * br - ai * bi, ar * bi + ai * br
end
local function modeRoots(Phi, M)
	-- eigenvalues of the M x M complex matrix Phi[i][j] = {re, im}: characteristic polynomial (Faddeev-LeVerrier),
	-- roots by Durand-Kerner
	if M == 1 then
		return { { Phi[1][1][1], Phi[1][1][2] } }
	end
	local function matmul(A, B)
		local C = {}
		for i = 1, M do
			C[i] = {}
			for j = 1, M do
				local sr, si = 0, 0
				for q = 1, M do
					local r1, i1 = cmul(A[i][q][1], A[i][q][2], B[q][j][1], B[q][j][2])
					sr += r1
					si += i1
				end
				C[i][j] = { sr, si }
			end
		end
		return C
	end
	local c = {} -- c[d] = coefficient of z^d, c[M] = 1
	c[M] = { 1, 0 }
	local Mk = {}
	for i = 1, M do
		Mk[i] = {}
		for j = 1, M do
			Mk[i][j] = { 0, 0 }
		end
	end
	for k = 1, M do
		-- Mk = Phi * M(k-1) + c[M-k+1] I
		local P = matmul(Phi, Mk)
		local cc = c[M - k + 1]
		for i = 1, M do
			P[i][i][1] += cc[1]
			P[i][i][2] += cc[2]
		end
		Mk = P
		local AM = matmul(Phi, Mk)
		local tr, ti = 0, 0
		for i = 1, M do
			tr += AM[i][i][1]
			ti += AM[i][i][2]
		end
		c[M - k] = { -tr / k, -ti / k }
	end
	local roots = {}
	for i = 1, M do
		local ang = 2 * math.pi * (i - 1) / M + 0.4
		roots[i] = { 0.9 * math.cos(ang), 0.9 * math.sin(ang) }
	end
	for _ = 1, 300 do
		local moved = 0
		for i = 1, M do
			local zr, zi = roots[i][1], roots[i][2]
			-- p(z) by Horner
			local pr, pi = 1, 0
			for d = M - 1, 0, -1 do
				pr, pi = cmul(pr, pi, zr, zi)
				pr += c[d][1]
				pi += c[d][2]
			end
			local dr, di = 1, 0
			for j = 1, M do
				if j ~= i then
					dr, di = cmul(dr, di, zr - roots[j][1], zi - roots[j][2])
				end
			end
			local den = dr * dr + di * di
			if den > 1e-300 then
				local qr, qi = (pr * dr + pi * di) / den, (pi * dr - pr * di) / den
				roots[i][1], roots[i][2] = zr - qr, zi - qi
				moved = math.max(moved, qr * qr + qi * qi)
			end
		end
		if moved < 1e-26 then
			break
		end
	end
	return roots
end

local function modesFit(a, pcm, info, o)
	local rate = pcm.sampleRate
	local src = pcm.data[1]
	local f0 = 440 * 2 ^ ((info.root - 69) / 12) * 2 ^ (-(info.pitchCorrection or 0) / 1200) * (a.fundamental or 1)
	local n = math.min(pcm.length, math.floor((o.MaxAnalysis or 1.5) * rate))
	local frames, partials = a.frames, a.partials
	if not frames or #frames < 4 or not partials then
		return nil
	end
	local P = #partials
	for i = 1, P do
		if partials[i] ~= i then
			return nil
		end
	end
	local peaks, top = table.create(P, 0), 0
	for _, row in ipairs(frames) do
		for i = 1, P do
			local x = row[i] or 0
			if x > peaks[i] then
				peaks[i] = x
			end
			if x > top then
				top = x
			end
		end
	end
	if top <= 0 then
		return nil
	end
	local order = {}
	for i = 1, P do
		if peaks[i] >= top * 10 ^ ((tonumber(o.ModesStrong) or -24) / 20) and i * f0 < 0.45 * rate then
			table.insert(order, i)
		end
	end
	table.sort(order, function(x, y)
		return peaks[x] > peaks[y]
	end)
	local taps = math.floor(4 * rate / f0) // 2 * 2 + 1
	local hl = taps // 2
	local dec = math.max(1, math.floor(rate / (1.25 * f0)))
	local fsd = rate / dec
	if n < taps + 24 * dec then
		return nil
	end
	local h, hs = table.create(taps, 0), 0
	for j = 0, taps - 1 do
		local u = f0 * (j - hl) / rate
		local sc = (u == 0) and 1 or math.sin(math.pi * u) / (math.pi * u)
		h[j + 1] = sc * (0.5 - 0.5 * math.cos(2 * math.pi * (j + 1) / (taps + 1)))
		hs += h[j + 1]
	end
	for j = 1, taps do
		h[j] /= hs
	end
	local x = table.create(n, 0)
	for m = 1, n do
		x[m] = buffer.readf32(src, (m - 1) * 4)
	end
	local maxOrder = math.clamp(tonumber(o.ModesOrder) or 4, 1, 6)
	local minSNR = tonumber(o.ModesMinSNR) or 15
	local maxModes = tonumber(o.ModesMax) or 10
	local modes, modeK = {}, {}
	local yieldable = coroutine.isyieldable()
	local xr, xi = table.create(n, 0), table.create(n, 0)
	for _, k in ipairs(order) do
		if #modes >= maxModes then
			break
		end
		-- heterodyne by k f0
		local w = 2 * math.pi * k * f0 / rate
		local cr, ci = math.cos(w), -math.sin(w)
		local zr, zi = 1, 0
		for m = 1, n do
			xr[m], xi[m] = x[m] * zr, x[m] * zi
			zr, zi = zr * cr - zi * ci, zr * ci + zi * cr
			if m % 4096 == 0 then
				local q = 1 / math.sqrt(zr * zr + zi * zi)
				zr, zi = zr * q, zi * q
			end
		end
		-- low-pass (+-f0/2) and decimate: band samples at c = hl, hl + dec, ...
		local yr, yi = {}, {}
		local c = hl
		while c + hl < n do
			local sr, si = 0, 0
			local base = c - hl
			for j = 1, taps do
				local hj = h[j]
				sr += hj * xr[base + j]
				si += hj * xi[base + j]
			end
			table.insert(yr, sr)
			table.insert(yi, si)
			c += dec
		end
		-- fit from the harmonic's attack peak on (within the first 150 ms): before it the harmonic is still rising,
		-- which damped modes can only draw as large cancelling terms; the attack itself stays on the frames
		local jp, pkv = 1, -1
		for t = 1, math.min(#yr, math.ceil(0.15 * fsd)) do
			local e = yr[t] * yr[t] + yi[t] * yi[t]
			if e > pkv then
				jp, pkv = t, e
			end
		end
		if jp > 1 then
			local r2, i2 = {}, {}
			for t = jp, #yr do
				table.insert(r2, yr[t])
				table.insert(i2, yi[t])
			end
			yr, yi = r2, i2
		end
		local N = #yr
		if N < 24 then
			continue
		end
		local L = N // 3
		local C, R = L + 1, N - L
		-- G = Y^H Y (Hankel rows y[r .. r + L])
		local Gr, Gi = {}, {}
		for p = 1, C do
			Gr[p], Gi[p] = table.create(C, 0), table.create(C, 0)
		end
		for p = 1, C do
			for q = p, C do
				local sr, si = 0, 0
				for r = 0, R - 1 do
					local ar, ai = yr[r + p], -yi[r + p]
					local br, bi = yr[r + q], yi[r + q]
					sr += ar * br - ai * bi
					si += ar * bi + ai * br
				end
				Gr[p][q], Gi[p][q] = sr, si
				Gr[q][p], Gi[q][p] = sr, -si
			end
			if yieldable and p % 16 == 0 then
				task.wait()
			end
		end
		-- dominant subspace by orthogonal iteration
		local Qr, Qi = {}, {}
		for col = 1, maxOrder do
			Qr[col], Qi[col] = table.create(C, 0), table.create(C, 0)
			for i = 1, C do
				Qr[col][i] = math.cos(i * col * 0.731 + col)
				Qi[col][i] = math.sin(i * (col + 1) * 0.413)
			end
		end
		for _ = 1, 60 do
			for col = 1, maxOrder do
				local qr, qi = Qr[col], Qi[col]
				local nr, ni = table.create(C, 0), table.create(C, 0)
				for i = 1, C do
					local sr, si = 0, 0
					local gr, gi = Gr[i], Gi[i]
					for j = 1, C do
						sr += gr[j] * qr[j] - gi[j] * qi[j]
						si += gr[j] * qi[j] + gi[j] * qr[j]
					end
					nr[i], ni[i] = sr, si
				end
				-- Gram-Schmidt against the earlier columns
				for prev = 1, col - 1 do
					local pr, pim = Qr[prev], Qi[prev]
					local dr, di = 0, 0
					for i = 1, C do
						dr += pr[i] * nr[i] + pim[i] * ni[i]
						di += pr[i] * ni[i] - pim[i] * nr[i]
					end
					for i = 1, C do
						nr[i] -= dr * pr[i] - di * pim[i]
						ni[i] -= dr * pim[i] + di * pr[i]
					end
				end
				local nn = 0
				for i = 1, C do
					nn += nr[i] * nr[i] + ni[i] * ni[i]
				end
				nn = math.sqrt(nn)
				if nn < 1e-300 then
					nn = 1
				end
				for i = 1, C do
					nr[i] /= nn
					ni[i] /= nn
				end
				Qr[col], Qi[col] = nr, ni
			end
		end
		-- the Hankel rows y[r..r+L] = sum alpha z^r (1, z, z^2, ...) span the conjugates of G's eigenvectors
		for col = 1, maxOrder do
			local qi = Qi[col]
			for i = 1, C do
				qi[i] = -qi[i]
			end
		end
		local yE = 0
		for i = 1, N do
			yE += yr[i] * yr[i] + yi[i] * yi[i]
		end
		local best, bestSet = -math.huge, nil
		local fits = {}
		for M = 1, maxOrder do
			-- Phi = (V1^H V1)^-1 (V1^H V2), V1 = rows 1..C-1, V2 = rows 2..C of the first M columns
			local A, B = {}, {}
			for i = 1, M do
				A[i], B[i] = {}, {}
				for j = 1, M do
					local ar, ai, br, bi = 0, 0, 0, 0
					for r = 1, C - 1 do
						local ur, ui = Qr[i][r], -Qi[i][r]
						local v1r, v1i = Qr[j][r], Qi[j][r]
						local v2r, v2i = Qr[j][r + 1], Qi[j][r + 1]
						ar += ur * v1r - ui * v1i
						ai += ur * v1i + ui * v1r
						br += ur * v2r - ui * v2i
						bi += ur * v2i + ui * v2r
					end
					A[i][j] = { ar, ai }
					B[i][j] = { br, bi }
				end
			end
			local Phi = {}
			for i = 1, M do
				Phi[i] = {}
			end
			local okPhi = true
			for j = 1, M do
				local col = {}
				for i = 1, M do
					col[i] = B[i][j]
				end
				local sol = complexSolve(A, col, M)
				if not sol then
					okPhi = false
					break
				end
				for i = 1, M do
					Phi[i][j] = sol[i]
				end
			end
			if okPhi then
				local roots = modeRoots(Phi, M)
				-- amplitudes: least squares y_n = sum_m alpha_m z_m^n
				local ZZ, Zy = {}, {}
				for i = 1, M do
					ZZ[i] = {}
					for j = 1, M do
						ZZ[i][j] = { 0, 0 }
					end
					Zy[i] = { 0, 0 }
				end
				local pw = {}
				for i = 1, M do
					pw[i] = { 1, 0 }
				end
				for t = 1, N do
					for i = 1, M do
						local ar, ai = pw[i][1], -pw[i][2]
						Zy[i][1] += ar * yr[t] - ai * yi[t]
						Zy[i][2] += ar * yi[t] + ai * yr[t]
						for j = 1, M do
							local r1, i1 = cmul(ar, ai, pw[j][1], pw[j][2])
							ZZ[i][j][1] += r1
							ZZ[i][j][2] += i1
						end
					end
					for i = 1, M do
						pw[i][1], pw[i][2] = cmul(pw[i][1], pw[i][2], roots[i][1], roots[i][2])
					end
				end
				local alpha = complexSolve(ZZ, Zy, M)
				if alpha then
					local eE = 0
					for i = 1, M do
						pw[i] = { 1, 0 }
					end
					for t = 1, N do
						local mr, mi = 0, 0
						for i = 1, M do
							local r1, i1 = cmul(alpha[i][1], alpha[i][2], pw[i][1], pw[i][2])
							mr += r1
							mi += i1
							pw[i][1], pw[i][2] = cmul(pw[i][1], pw[i][2], roots[i][1], roots[i][2])
						end
						eE += (yr[t] - mr) ^ 2 + (yi[t] - mi) ^ 2
					end
					local snr = 10 * math.log10(yE / math.max(eE, 1e-30))
					-- usable: well conditioned (modes that mostly cancel each other would need exact phases to stay quiet)
					-- and decaying or nearly steady (no decay file plays a swell)
					local sumA, maxLam = 0, -math.huge
					for i = 1, M do
						sumA += math.sqrt(alpha[i][1] ^ 2 + alpha[i][2] ^ 2)
						local mag = math.sqrt(roots[i][1] ^ 2 + roots[i][2] ^ 2)
						maxLam = math.max(maxLam, math.log(math.max(mag, 1e-30)) * fsd)
					end
					if snr >= minSNR and sumA <= 2.5 * math.sqrt(pkv) and maxLam <= 0.5 then
						fits[M] = { snr = snr, roots = roots, alpha = alpha }
						if snr > best then
							best = snr
						end
					end
				end
			end
		end
		for M = 1, maxOrder do
			local fit = fits[M]
			if fit and fit.snr >= best - 3 then
				bestSet = fit
				bestSet.M = M
				break
			end
		end
		if bestSet and #modes + bestSet.M <= maxModes then
			local s0 = hl + (jp - 1) * dec -- sample index of the first fitted band sample
			local t0 = s0 / rate
			local list = {}
			local ok = true
			for i = 1, bestSet.M do
				local zr, zi = bestSet.roots[i][1], bestSet.roots[i][2]
				local mag = math.sqrt(zr * zr + zi * zi)
				local lam = math.log(math.max(mag, 1e-30)) * fsd
				local df = math.atan2(zi, zr) * fsd / (2 * math.pi)
				local al = bestSet.alpha[i]
				local A = 2 * math.sqrt(al[1] * al[1] + al[2] * al[2])
				local f = k * f0 + df
				if math.abs(df) > 0.45 * f0 or lam > 0.5 or lam < -400 then
					ok = false
					break
				end
				local phT0 = math.atan2(al[2], al[1]) + w * s0
				local A0 = A * math.exp(-lam * t0)
				local ph0 = phT0 - 2 * math.pi * f * t0
				local peak = A0 * math.max(1, math.exp(lam * n / rate))
				if peak >= top * 0.003 then
					table.insert(list, { k = k, r = math.floor(f / f0 * 1e6 + 0.5) / 1e6, a = math.floor(A0 * 1e5 + 0.5) / 1e5, l = math.floor(lam * 1e4 + 0.5) / 1e4, p = math.floor(((ph0 + math.pi / 2) / (2 * math.pi)) % 1 * 1e4 + 0.5) / 1e4 })
				end
			end
			if ok and #list > 0 then
				for _, md in ipairs(list) do
					table.insert(modes, md)
				end
				modeK[k] = math.floor(t0 * 1e4 + 0.5) / 1e4 -- sample time the modes take over from the frames
			end
		end
		if yieldable then
			task.wait()
		end
	end
	if #modes == 0 then
		return nil
	end
	return modes, modeK
end

function Instruments.analyse(pcm, info, options)
	local o = options or {}
	local a = analyseCore(pcm, info, o)
	local md = o.Modes
	if md == nil then
		md = Instruments.Defaults.Modes
	end
	if md and a and a.kind == "tonal" and not a.looped and not a.voice and not a.phaseFrames and not a.pairs and not a.exactCycle and not a.smooth then
		local modes, modeK = modesFit(a, pcm, info, o)
		if modes then
			a.modes, a.modeK = modes, modeK
		end
	end
	local imgs = o.Images
	if imgs == nil then
		imgs = Instruments.Defaults.Images
	end
	local smooth = o.Smooth
	if smooth == nil then
		smooth = Instruments.Defaults.Smooth
	end
	if imgs and a and a.kind == "tonal" then
		if smooth then
			o = table.clone(o)
			o.ImagesMax = o.ImagesMax or 6
		end
		a = playbackImages(a, pcm, info, o)
	end
	if smooth and a and a.kind == "tonal" then
		a = smoothPairs(a, info, o)
	end
	return a
end

-- info: { name, root, tune (cents, includes pitch correction), scale, pitchCorrection,
--         atten (dB), env = {...} }
local function makePreset(info, a, key, mode)
	local env = info.env
	local atten = 10 ^ (-(info.atten or 0) / 20)
	local semisFromRoot = (key - info.root) * info.scale / 100 + info.tune / 100
	local preset = {
		name = info.name,
		delay = env.delay or 0, attack = env.attack or 0, hold = env.hold or 0,
		decay = env.decay or 0, sustain = env.sustain or 1, release = math.max(env.release or 0, 0.01),
		transpose = (key - info.root) * (info.scale / 100 - 1) + (info.tune - (info.pitchCorrection or 0)) / 100,
		speed = 2 ^ (semisFromRoot / 12), -- sample-time seconds per real second
		wave = a.wave, gain = a.volume * atten, fitError = a.fitError, tonalRatio = a.tonalRatio,
		atten = atten, source = "sf2",
	}
	if a.noise then
		-- noise chain levels over sample time; the voice's SoundFont envelope applies on top, like any note
		preset.noise = a.noise
		preset.looped = a.looped
		preset.loopStart = a.loopStart
	elseif mode ~= "wave" and a.partials and #a.partials > 0 then
		preset.additive = a
		preset.atten = atten * (a.energyComp or 1)
	elseif not a.looped then
		-- single-wave mode on a one-shot: let the envelope stand in for the sample's own decay
		preset.sustain = 0
		preset.decay = math.max(a.length or 0.3, 0.05) * 2
	end
	return preset
end
Instruments.makePreset = makePreset

local function regionInfo(region)
	return {
		name = region.instrument, root = region.rootKey, tune = region.tuneCents, scale = region.scaleTuning,
		pitchCorrection = region.sample.pitchCorrection, atten = region.attenuation, env = region.env,
		loopMode = region.loopMode,
	}
end
Instruments.regionInfo = regionInfo

local sfCache = setmetatable({}, { __mode = "k" })

function Instruments.analyseRegion(sf, region, options)
	local cache = sfCache[sf]
	if not cache then
		cache = {}
		sfCache[sf] = cache
	end
	local ck = region.sampleIndex .. ":" .. region.rootKey .. ":" .. region.loopMode
	local a = cache[ck]
	if not a then
		a = Instruments.analyse(Sf2.samplePcm(sf, region), {
			root = region.rootKey, pitchCorrection = region.sample.pitchCorrection, loopMode = region.loopMode,
		}, options)
		cache[ck] = a
	end
	return a, ck
end

function Instruments.fromSoundFont(sf, bank, program, key, velocity, options)
	local region = Sf2.regions(sf, bank, program, key, velocity or 100)[1]
	if not region then
		return nil
	end
	local a = Instruments.analyseRegion(sf, region, options)
	return makePreset(regionInfo(region), a, key, options and options.Mode)
end

-- Baked bank (Tools/Baker): { presets = { { bank, program, name, regions = { {kl,kh,vl,vh,info,sample} } } },
--                            samples = { [key] = analysis } }
function Instruments.fromBank(bankData, bank, program, key, velocity, options)
	velocity = velocity or 100
	local index = bankData._index
	if not index then
		index = {}
		for _, p in ipairs(bankData.presets) do
			index[p.bank * 128 + p.program] = p
		end
		bankData._index = index
	end
	local preset = index[bank * 128 + program] or (bank ~= 128 and index[program]) or nil
	if not preset then
		return nil
	end
	-- AudioLab attribute SampleVariant = "phase" plays a sample's alternative analysis (bank key
	-- "<sample>@phase") where the bank has one
	local variant = AudioLab:GetAttribute("SampleVariant")
	for _, r in ipairs(preset.regions) do
		if key >= r.kl and key <= r.kh and velocity >= r.vl and velocity <= r.vh then
			local a = (type(variant) == "string" and bankData.samples[r.sample .. "@" .. variant]) or bankData.samples[r.sample]
			if a then
				return makePreset(r.info, a, key, options and options.Mode)
			end
		end
	end
	return nil
end

return Instruments
