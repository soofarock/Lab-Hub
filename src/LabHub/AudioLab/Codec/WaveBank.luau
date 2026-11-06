--!native
--!optimize 2
-- The fixed set of uploaded loops every clip is rebuilt from, and the exact math that
-- defines them. The analyzer, the offline renderer and the in-game player
-- all read this module and the uploaded files follow it, so changing it means remaking and re-uploading assets
-- (bump Version so old clips are detected).
--
-- Waveform assets: 1 second at 44100 Hz, an integer number of cycles of an integer base
-- frequency (so the loop is seamless), band-limited so no harmonic aliases even when the
-- loop is played at MaxSpeed. sample(x) = gain * sum_k a_k * basis_k(x).
-- Noise assets: 65536 samples, one octave band each, circularly band-limited via inverse
-- FFT (seamless loop), scaled to NoiseRms. Bands 1-8 are centred on 125..16000 Hz, bands 9-16 half an
-- octave lower (88..11314 Hz); together they form a chain of overlapping bands every half octave.
-- Harmonic bundles (v2): one loop carries a whole octave of harmonics (9-16, 17-32, 33-64, 65-128) at
-- amplitude ~1/k, rendered at the TOP of a note octave and only ever played at speed <= BundleMaxSpeed,
-- so nothing aliases. Notes use 8 sines for harmonics 1-8 plus one bundle per higher octave.

local AudioLab = script:FindFirstAncestor("AudioLab")
local FFT = require(AudioLab.DSP.FFT)

local WaveBank = {}

WaveBank.Version = 2
WaveBank.AssetRate = 44100
WaveBank.Bases = { 55, 220, 880, 3520 } -- Hz; each covers base/2 .. base*2
WaveBank.MaxSpeed = 2
-- One sine file for every pitch: a pure sine has no harmonics to alias, so the 880 Hz loop is played at any speed
-- Roblox allows (0.01-20x: 8.8 Hz - 17.6 kHz; a 55 Hz sine from it is as clean as the 55 Hz
-- file). Every sine part uses this range, so any idle sine player can take any note. The other waveforms keep
-- their four bases (they have harmonics that would alias when sped up).
WaveBank.SineRange = 3 -- index of 880 in Bases
WaveBank.CycleLength = 2048 -- single-cycle table size for the offline renderer

-- kind: how harmonic k is computed; gain keeps the band-limited peak near 0.9.
WaveBank.Waves = {
	{ name = "sine", kind = "sine", gain = 0.9 },
	{ name = "triangle", kind = "triangle", gain = 0.9 },
	{ name = "saw", kind = "saw", gain = 0.75 },
	{ name = "square", kind = "pulse", duty = 0.5, gain = 0.75 },
	{ name = "pulse25", kind = "pulse", duty = 0.25, gain = 0.5 },
	{ name = "pulse12", kind = "pulse", duty = 0.125, gain = 0.47 },
}

WaveBank.NoiseRms = 0.2
WaveBank.NoiseLength = 65536
-- Playback level of each uploaded noise asset relative to its file
-- (Roblox's audio encoding rolls off the top bands). The in-game pool divides
-- band volumes by these; the offline renderer models the files themselves and ignores them.
WaveBank.NoiseGain = { 0.985, 1.023, 0.997, 0.985, 0.962, 0.942, 0.872, 0.636,
	0.957, 1.004, 1.037, 0.985, 0.978, 0.933, 0.910, 0.771 }
WaveBank.NoiseCenters = { 125, 250, 500, 1000, 2000, 4000, 8000, 16000, 88, 177, 354, 707, 1414, 2828, 5657, 11314 }
-- The clip codec (RBAC) uses the 8 non-overlapping octave bands only.
WaveBank.CodecBands = 8
WaveBank.NoiseBands = {}
for i, c in ipairs(WaveBank.NoiseCenters) do
	WaveBank.NoiseBands[i] = { center = c, low = c / math.sqrt(2), high = math.min(c * math.sqrt(2), WaveBank.AssetRate / 2) }
end

-- The noise chain in ascending frequency: position i is centred on ChainBase * 2^((i-1)/2) Hz and
-- covers half-octave bins i and i+1 (bin i spans ChainEdge * 2^((i-1)/2) .. * 2^(i/2)).
WaveBank.NoiseChain = { 9, 1, 10, 2, 11, 3, 12, 4, 13, 5, 14, 6, 15, 7, 16, 8 }
WaveBank.ChainBase = 125 / math.sqrt(2)
WaveBank.ChainEdge = 62.5
WaveBank.ChainBins = 17
-- share of a band's energy in its lower / upper half-octave (white noise over c/sqrt2 .. c*sqrt2)
WaveBank.ChainLowShare = (1 - 1 / math.sqrt(2)) / (math.sqrt(2) - 1 / math.sqrt(2))

-- Harmonic bundles
WaveBank.BundleBases = { 110, 220, 440, 880, 1760 }
WaveBank.BundleGroups = { { 9, 16 }, { 17, 32 }, { 33, 64 }, { 65, 128 } }
WaveBank.BundleTop = 20000
WaveBank.BundleTilt = 1
WaveBank.BundleRms = 0.25
WaveBank.BundleMaxSpeed = 1.06
WaveBank.BundleWave0 = #WaveBank.Waves -- bundle group g is "wave" BundleWave0 + g in the voice pool
WaveBank.Sines = 8 -- harmonics 1..8 are individual sines
-- playback level of each bundle relative to its file (Roblox's encoding rolls off above ~14 kHz).
-- Key: group * 100 + base index (110, 220, 440, 880, 1760 = 1..5).
WaveBank.BundleGain = {
	[101] = 0.994, [102] = 0.987, [103] = 0.957, [104] = 0.841, [105] = 0.644,
	[201] = 0.969, [202] = 0.953, [203] = 0.846, [204] = 0.653,
	[301] = 0.938, [302] = 0.846, [303] = 0.656,
	[401] = 0.827, [402] = 0.658,
}

-- Which uploaded files are in use is decided by a manifest (Codec.Manifests, chosen by the AudioLab folder's attribute
-- Manifest; see WaveBank.refresh at the end of this module). WaveBank.Assets holds name -> id for the files of the
-- active manifest only (keys match WaveBank.assetName()); a file that isn't in it has no entry and its voice is silent.
-- Without the decaying sines (dsine_*) the decay feature is off and fades are played by volume.
WaveBank.Assets = {}
-- Single-file manifest only: Regions[name] = { id, lead, onset, loopStart, loopEnd } (seconds into the shared file, see
-- Codec.Manifests.Atlas) for every sound; empty when the sounds are individual files.
WaveBank.Regions = {}

-- Bundles -------------------------------------------------------------------------------------
function WaveBank.isBundle(wave)
	return wave > WaveBank.BundleWave0
end

-- harmonics k0..kmax carried by bundle group g at base index r, or nil if that asset doesn't exist
function WaveBank.bundleHarmonics(g, r)
	local grp, base = WaveBank.BundleGroups[g], WaveBank.BundleBases[r]
	if not grp or not base then
		return nil
	end
	local kmax = math.min(grp[2], WaveBank.BundleTop // base)
	if kmax < grp[1] then
		return nil
	end
	return grp[1], kmax
end

-- base index for a note frequency: the lowest base it can be played from at speed <= BundleMaxSpeed
function WaveBank.bundleRange(freq)
	local bases = WaveBank.BundleBases
	for r = 1, #bases do
		if freq <= bases[r] * WaveBank.BundleMaxSpeed then
			return r
		end
	end
	return nil
end

-- fraction of a group's harmonic energy (1/k^2 profile, harmonics below maxHz) that the asset at base
-- index r carries when the note is at freq
local coverageCache = {}
function WaveBank.bundleCoverage(g, r, freq)
	local k0, kmax = WaveBank.bundleHarmonics(g, r)
	if not k0 then
		return 0
	end
	local k1 = WaveBank.BundleGroups[g][2]
	local key = g * 100 + r
	local c = coverageCache[key]
	if not c then
		local num, den = 0, 0
		for k = k0, k1 do
			local w = k ^ (-2 * WaveBank.BundleTilt)
			den += w
			if k <= kmax then
				num += w
			end
		end
		c = num / den
		coverageCache[key] = c
	end
	return c
end

function WaveBank.bundleAssetName(g, r)
	return ("bundle_g%d_%d"):format(g, WaveBank.BundleBases[r])
end

-- Fine harmonic bundles (sounds fbundle_* / lbundle_*, used when the manifest has them): the four octave groups above are
-- played as 14 narrower groups, each from a bundle of its own. "living" bundles (lbundle_*) are 3 s loops in which every
-- harmonic drifts a little on its own (no fixed stack repeating every period); "steady" ones (fbundle_*) are the plain
-- 1/k stacks. AudioLab attribute FineBundles = "steady" (default) | "living" | "off". A fine group is wave FineWave0 + f in
-- the voice pool. The analysis still measures the four octave groups: a coarse group's level is shared among its fine
-- groups by the same 1/k tilt the coarse bundle had, so the spectrum is the same but the waveform no longer buzzes.
WaveBank.FineWave0 = 10000
WaveBank.FineGroups = {
	{ 9, 10 }, { 11, 12 }, { 13, 14 }, { 15, 16 }, { 17, 20 }, { 21, 24 }, { 25, 28 }, { 29, 32 },
	{ 33, 40 }, { 41, 48 }, { 49, 56 }, { 57, 64 }, { 65, 96 }, { 97, 128 },
}
WaveBank.FineOf = { { 1, 2, 3, 4 }, { 5, 6, 7, 8 }, { 9, 10, 11, 12 }, { 13, 14 } } -- fine groups inside each coarse group

function WaveBank.fineMode()
	local m = AudioLab and AudioLab:GetAttribute("FineBundles")
	if m == "living" or m == "off" then
		return m
	end
	return "steady" -- the default: smoother than the living bundles on held notes and vocals
end

function WaveBank.fineAssetName(f, r)
	return ((WaveBank.fineMode() == "steady") and "fbundle_g%d_%d" or "lbundle_g%d_%d"):format(f, WaveBank.BundleBases[r])
end

-- harmonics k0..kmax of fine group f carried by the asset at base index r, or nil if that asset doesn't exist
function WaveBank.fineHarmonics(f, r)
	local grp, base = WaveBank.FineGroups[f], WaveBank.BundleBases[r]
	if not grp or not base then
		return nil
	end
	local kmax = math.min(grp[2], WaveBank.BundleTop // base)
	if kmax < grp[1] then
		return nil
	end
	return grp[1], kmax
end

-- share of coarse group gi's energy (1/k tilt) that fine group f's asset carries at base index r
local fineShareCache = {}
function WaveBank.fineShare(gi, f, r)
	local key = (gi * 100 + f) * 10 + r
	local c = fineShareCache[key]
	if c then
		return c
	end
	local k0, kmax = WaveBank.fineHarmonics(f, r)
	local g = WaveBank.BundleGroups[gi]
	local num, den = 0, 0
	for k = g[1], g[2] do
		den += k ^ (-2 * WaveBank.BundleTilt)
	end
	if k0 then
		for k = k0, kmax do
			num += k ^ (-2 * WaveBank.BundleTilt)
		end
	end
	c = den > 0 and num / den or 0
	fineShareCache[key] = c
	return c
end

-- playback level of a fine bundle relative to its file (the same roll-off of Roblox's encoding as BundleGain
-- for the octave groups: it depends on the highest harmonic's frequency)
local GAIN_AT = { { 1760, 0.994 }, { 3520, 0.975 }, { 7040, 0.95 }, { 14080, 0.84 }, { 19400, 0.65 }, { 20000, 0.64 } }
function WaveBank.fineGain(f, r)
	local _, kmax = WaveBank.fineHarmonics(f, r)
	if not kmax then
		return 1
	end
	local top = kmax * WaveBank.BundleBases[r]
	if top <= GAIN_AT[1][1] then
		return GAIN_AT[1][2]
	end
	for i = 2, #GAIN_AT do
		local a, b = GAIN_AT[i - 1], GAIN_AT[i]
		if top <= b[1] then
			return a[2] + (b[2] - a[2]) * math.log(top / a[1]) / math.log(b[1] / a[1])
		end
	end
	return GAIN_AT[#GAIN_AT][2]
end

-- true when every fine group of coarse group gi that exists at base index r has its file in the active manifest
function WaveBank.fineReady(gi, r)
	if WaveBank.fineMode() == "off" or not r then
		return false
	end
	local any = false
	for _, f in ipairs(WaveBank.FineOf[gi] or {}) do
		if WaveBank.fineHarmonics(f, r) then
			if not WaveBank.Assets[WaveBank.fineAssetName(f, r)] then
				return false
			end
			any = true
		end
	end
	return any
end

-- Harmonic k of a wave: returns (magnitude, sineCoefficient, cosineCoefficient), before gain.
function WaveBank.harmonic(wave, k)
	local kind = wave.kind
	if kind == "sine" then
		if k == 1 then
			return 1, 1, 0
		end
		return 0, 0, 0
	elseif kind == "triangle" then
		if k % 2 == 0 then
			return 0, 0, 0
		end
		local a = 8 / (math.pi * math.pi * k * k)
		local s = (((k - 1) // 2) % 2 == 0) and a or -a
		return a, s, 0
	elseif kind == "saw" then
		local a = 2 / (math.pi * k)
		return a, (k % 2 == 1) and a or -a, 0
	elseif kind == "pulse" then
		local c = 4 / (math.pi * k) * math.sin(math.pi * k * wave.duty)
		if math.abs(c) < 1e-12 then
			return 0, 0, 0
		end
		return math.abs(c), 0, c
	end
	error("unknown wave kind " .. tostring(kind))
end

local profiles = {}
-- Magnitudes a_1..a_K (no gain), cached.
function WaveBank.profile(waveIndex, K)
	local key = waveIndex * 1000 + K
	local p = profiles[key]
	if p then
		return p
	end
	local wave = WaveBank.Waves[waveIndex]
	p = table.create(K)
	for k = 1, K do
		p[k] = (WaveBank.harmonic(wave, k))
	end
	profiles[key] = p
	return p
end

-- Number of harmonics stored in the asset for base index b.
function WaveBank.harmonicCount(baseIndex)
	local base = WaveBank.Bases[baseIndex]
	return math.max(1, math.floor((WaveBank.AssetRate / 2) / (base * WaveBank.MaxSpeed)))
end

-- Base index whose range contains freq (boundaries at geometric midpoints), clamped.
function WaveBank.rangeFor(freq)
	local bases = WaveBank.Bases
	for i = 1, #bases - 1 do
		if freq < math.sqrt(bases[i] * bases[i + 1]) then
			return i
		end
	end
	return #bases
end

function WaveBank.assetName(waveIndex, baseIndex)
	if waveIndex == WaveBank.RoughWave then
		return "rough_880"
	end
	if waveIndex > WaveBank.FineWave0 then
		return WaveBank.fineAssetName(waveIndex - WaveBank.FineWave0, baseIndex)
	end
	if WaveBank.DecayWave0 and waveIndex > WaveBank.DecayWave0 then
		local n, r = WaveBank.decayInfo(waveIndex)
		return ("dsine_%d_t%d"):format(WaveBank.Bases[r], n)
	end
	if WaveBank.PulseWave0 and waveIndex > WaveBank.PulseWave0 then
		return WaveBank.pulseAssetName(waveIndex - WaveBank.PulseWave0, baseIndex)
	end
	if waveIndex > WaveBank.BundleWave0 then
		return WaveBank.bundleAssetName(waveIndex - WaveBank.BundleWave0, baseIndex)
	end
	return ("wave_%s_%d"):format(WaveBank.Waves[waveIndex].name, WaveBank.Bases[baseIndex])
end

function WaveBank.noiseAssetName(band)
	return ("noise_%d_%d"):format(band, WaveBank.NoiseCenters[band])
end

function WaveBank.assetId(waveIndex, baseIndex)
	local id = WaveBank.Assets[WaveBank.assetName(waveIndex, baseIndex)]
	return (id and id ~= "") and id or nil
end

-- Shared noise (manifest flag SharedNoise): two noise files make all 16 bands, because one octave of noise moved up or
-- down by playback speed is still one octave (same band shape, energy outside the band as low as with
-- the dedicated files). The 1 kHz file plays the bands up to 4 kHz (0.09-4x), the 4 kHz file the bands above (1.4-4x),
-- so no loop repeats faster than every 0.37 s. Each band's playback level is its source file's (the dedicated top bands
-- lose level in Roblox's encoding). Without it every band plays its own dedicated file.
WaveBank.SharedNoise = true

function WaveBank.noiseSource(band)
	if not WaveBank.SharedNoise then
		return band, 1
	end
	local c = WaveBank.NoiseCenters[band]
	local src = (c <= 4000) and 4 or 6
	return src, c / WaveBank.NoiseCenters[src]
end

function WaveBank.noiseSpeed(band)
	local _, speed = WaveBank.noiseSource(band)
	return speed
end

function WaveBank.noiseAssetId(band)
	local src = WaveBank.noiseSource(band)
	local id = WaveBank.Assets[WaveBank.noiseAssetName(src)]
	return (id and id ~= "") and id or nil
end

-- playback level of a band = its source file's playback level
WaveBank.NoiseGainFile = table.clone(WaveBank.NoiseGain)
function WaveBank.noiseGain(band)
	return WaveBank.NoiseGainFile[(WaveBank.noiseSource(band))]
end

-- files the active manifest lists that have no id (none for a finished manifest)
function WaveBank.missingAssets()
	local missing = {}
	for name, id in pairs(WaveBank.Assets) do
		if id == "" then
			table.insert(missing, name)
		end
	end
	table.sort(missing)
	return missing
end

-- Evaluate one asset sample: x is the phase in cycles of the base frequency.
local function evaluate(wave, H, x)
	local v = 0
	local tw = 2 * math.pi * x
	for k = 1, H do
		local _, s, c = WaveBank.harmonic(wave, k)
		if s ~= 0 then
			v += s * math.sin(k * tw)
		end
		if c ~= 0 then
			v += c * math.cos(k * tw)
		end
	end
	return v * wave.gain
end
WaveBank.evaluate = evaluate

local cycles = {}
-- Single-cycle table (CycleLength samples) matching the asset for (wave, base range).
function WaveBank.cycle(waveIndex, baseIndex)
	local key = waveIndex * 100 + baseIndex
	local t = cycles[key]
	if t then
		return t
	end
	local wave = WaveBank.Waves[waveIndex]
	local H = WaveBank.harmonicCount(baseIndex)
	local n = WaveBank.CycleLength
	t = table.create(n + 1)
	-- accumulate harmonics with recurrence-free direct sums (built once, cached)
	for i = 0, n - 1 do
		t[i + 1] = 0
	end
	for k = 1, H do
		local _, s, c = WaveBank.harmonic(wave, k)
		if s ~= 0 or c ~= 0 then
			for i = 0, n - 1 do
				local a = 2 * math.pi * k * i / n
				t[i + 1] += s * math.sin(a) + c * math.cos(a)
			end
		end
	end
	for i = 1, n do
		t[i] *= wave.gain
	end
	t[n + 1] = t[1] -- guard sample for interpolation
	cycles[key] = t
	return t
end

local noiseCache = {}
-- Deterministic band-limited noise loop for band index (NoiseLength samples, RMS = NoiseRms).
-- Yields between bands if called from a yieldable thread.
function WaveBank.noiseLoop(band)
	local cached = noiseCache[band]
	if cached then
		return cached
	end
	local n = WaveBank.NoiseLength
	local rate = WaveBank.AssetRate
	local info = WaveBank.NoiseBands[band]
	local re, im = table.create(n, 0), table.create(n, 0)
	local rng = Random.new(1000 + band)
	local lo = math.max(1, math.ceil(info.low * n / rate))
	local hi = math.min(n // 2 - 1, math.floor(info.high * n / rate))
	for k = lo, hi do
		local ph = rng:NextNumber() * 2 * math.pi
		local c, s = math.cos(ph), math.sin(ph)
		re[k + 1], im[k + 1] = c, s
		re[n - k + 1], im[n - k + 1] = c, -s -- Hermitian symmetry -> real output
	end
	FFT.transform(re, im, true)
	local sum = 0
	for i = 1, n do
		sum += re[i] * re[i]
	end
	local scale = WaveBank.NoiseRms / math.sqrt(sum / n)
	for i = 1, n do
		re[i] *= scale
	end
	noiseCache[band] = re
	return re
end

-- Description of every asset, for the external generator script.
function WaveBank.spec()
	local list = {}
	for w, wave in ipairs(WaveBank.Waves) do
		for b, base in ipairs(WaveBank.Bases) do
			table.insert(list, {
				name = WaveBank.assetName(w, b), kind = wave.kind, duty = wave.duty, gain = wave.gain,
				base = base, harmonics = WaveBank.harmonicCount(b), seconds = 1, rate = WaveBank.AssetRate,
			})
		end
	end
	for i, band in ipairs(WaveBank.NoiseBands) do
		table.insert(list, {
			name = WaveBank.noiseAssetName(i), kind = "noise", low = band.low, high = band.high,
			rms = WaveBank.NoiseRms, samples = WaveBank.NoiseLength, rate = WaveBank.AssetRate,
		})
	end
	return list
end

-- Onset bursts (sharp-start noise one-shots) and pulse bundles (phase-aligned harmonic groups), 48 kHz assets.
WaveBank.BurstRate = 48000
WaveBank.Bursts = {
	-- band low/high Hz, decay seconds, rms of the first 5 ms (every file peaks at 0.89),
	-- e1 / e2 = energy (sum of x^2 / rate) in the first 8 ms / from 8 to 30 ms
	burst_1000_t6 = { lo = 707, hi = 1414, decay = 0.006, rms5 = 0.37512, e1 = 0.000794622, e2 = 3.73901e-05 },
	burst_2000_t6 = { lo = 1414, hi = 2828, decay = 0.006, rms5 = 0.38985, e1 = 0.000921627, e2 = 9.81568e-05 },
	burst_4000_t6 = { lo = 2828, hi = 5657, decay = 0.006, rms5 = 0.24087, e1 = 0.000334584, e2 = 1.53993e-05 },
	burst_8000_t6 = { lo = 5657, hi = 11314, decay = 0.006, rms5 = 0.31528, e1 = 0.00060797, e2 = 6.7272e-05 },
	burst_16000_t6 = { lo = 11314, hi = 22000, decay = 0.006, rms5 = 0.26862, e1 = 0.000424941, e2 = 4.64114e-05 },
	burst_wide_t6 = { lo = 300, hi = 20000, decay = 0.006, rms5 = 0.17791, e1 = 0.000187856, e2 = 1.55009e-05 },
	burst_1000_t25 = { lo = 707, hi = 1414, decay = 0.025, rms5 = 0.36819, e1 = 0.000871177, e2 = 0.000663153 },
	burst_2000_t25 = { lo = 1414, hi = 2828, decay = 0.025, rms5 = 0.33141, e1 = 0.00114652, e2 = 0.00104145 },
	burst_4000_t25 = { lo = 2828, hi = 5657, decay = 0.025, rms5 = 0.26079, e1 = 0.000469537, e2 = 0.000679583 },
	burst_8000_t25 = { lo = 5657, hi = 11314, decay = 0.025, rms5 = 0.32573, e1 = 0.000769306, e2 = 0.000567513 },
	burst_16000_t25 = { lo = 11314, hi = 22000, decay = 0.025, rms5 = 0.31612, e1 = 0.000762994, e2 = 0.000653037 },
	burst_wide_t25 = { lo = 300, hi = 20000, decay = 0.025, rms5 = 0.27635, e1 = 0.000543358, e2 = 0.000498372 },
}
WaveBank.PulseRate = 48000
WaveBank.Pulses = {
	-- [group] = { harmonics k1..k2, bases }
	-- amp = amplitude of harmonic k is amp / k; top = highest harmonic in the file per base (the rest is above 21.6 kHz)
	[2] = { k1 = 17, k2 = 32, amp = 1.40166, bases = { 110, 220 }, top = { [110] = 32, [220] = 32 } },
	[3] = { k1 = 33, k2 = 64, amp = 1.38606, bases = { 110, 220 }, top = { [110] = 64, [220] = 64 } },
	[4] = { k1 = 65, k2 = 128, amp = { [110] = 1.3783, [220] = 2.24382 }, bases = { 110, 220 }, top = { [110] = 128, [220] = 98 } },
	[5] = { k1 = 129, k2 = 196, amp = 2.2367, bases = { 110 }, top = { [110] = 196 } },
}
-- the click of a pulse bundle sits half a period after the loop start
WaveBank.PulseClick = 0.5
-- pulse group g is "wave" PulseWave0 + g in the voice pool (same groups as BundleGroups; base index 1 = 110, 2 = 220)
WaveBank.PulseWave0 = WaveBank.BundleWave0 + 10
-- rms of each pulse file at volume 1, key group * 100 + base index
WaveBank.PulseRms = { [201] = 0.17115, [202] = 0.17115, [301] = 0.12109, [302] = 0.12109, [401] = 0.08564, [402] = 0.11607, [501] = 0.08208 }

-- Decaying sines: a sine at base frequency under exp(-t / tau), 0.9 peak (as the looping sine), 48 kHz, 7 tau long
-- (-61 dB, the last 2 ms faded to zero), for every base and tau = 0.025 * 1.6^(n - 1) s (n = 1..11: 25 ms .. 2.75 s).
-- The engine holds a player's volume for a whole 21 ms block, so a decay drawn with volume writes is a staircase:
-- sidebands +-47 Hz around every harmonic, a rough, "reverby" tail on struck and plucked notes. A decaying
-- part plays from the file whose decay (tau / speed) is closest to its own; its volume only corrects the difference.
-- Decay wave index = DecayWave0 + (n - 1) * #Bases + base index.
WaveBank.DecayRate = 48000
WaveBank.DecayCount = 11
WaveBank.DecayLength = 7
-- every upload file is at most 4.16 s, so the long decays (n = 8..11: 7 tau would be 4.7 .. 19 s) are cut there (the last
-- 2 ms faded); the synth re-arms a decaying part before its file runs out (MidiSynth: a fresh file from the start, in
-- phase, the volume correcting the envelope), as it already did at 0.6 x DecayLength
WaveBank.DecayFileMax = 4.16
function WaveBank.decayFileLength(n)
	return math.min(WaveBank.DecayLength * WaveBank.decayTau(n), WaveBank.DecayFileMax)
end
WaveBank.DecayWave0 = WaveBank.BundleWave0 + 20
-- a tracked sine (the looping sine at a fixed base, its position followed by the synth) is TrackWave0 + base index
WaveBank.TrackWave0 = WaveBank.DecayWave0 - #WaveBank.Bases
-- Rough sine (file rough_880): noise centred on 880 Hz, 3% wide, RMS 0.25, looping. A voice sample's harmonic k also
-- plays one at k x f0 (speed k f0 / 880, so the band stays 3% wide at any pitch), at the level of that harmonic's fast
-- motion: the roughness a steady sine per 21 ms block cannot carry (without it a voice sounds 8-bit).
WaveBank.RoughWave = 9000
WaveBank.RoughBase = 880
WaveBank.RoughRms = 0.25
function WaveBank.trackWave(r)
	return WaveBank.TrackWave0 + r
end
function WaveBank.decayTau(n)
	return 0.025 * 1.6 ^ (n - 1)
end
function WaveBank.decayWave(n, r)
	return WaveBank.DecayWave0 + (n - 1) * #WaveBank.Bases + r
end
function WaveBank.decayInfo(wave)
	local j = wave - WaveBank.DecayWave0 - 1
	return j // #WaveBank.Bases + 1, j % #WaveBank.Bases + 1
end

function WaveBank.pulseAssetName(g, r)
	return ("pulse_g%d_%d"):format(g, WaveBank.BundleBases[r])
end

-- base index to play pulse group g at note frequency freq: the lowest base at speed <= BundleMaxSpeed, else the
-- 220 Hz file sped up as long as its top harmonic stays below 23 kHz (no aliasing); nil when no pulse file fits.
-- current: the base already in use (kept while it still fits, so a vibrato doesn't flip files)
function WaveBank.pulseRange(g, freq, current)
	local info = WaveBank.Pulses[g]
	if not info then
		return nil
	end
	local function fits(r)
		local base = WaveBank.BundleBases[r]
		local top = info.top and info.top[base]
		if not top or not WaveBank.Assets[WaveBank.pulseAssetName(g, r)] then
			return false
		end
		local speed = freq / base
		return speed <= WaveBank.BundleMaxSpeed or (r == 2 and top * freq <= 23000)
	end
	if current and fits(current) then
		return current
	end
	for r = 1, 2 do
		local base = WaveBank.BundleBases[r]
		if freq <= base * WaveBank.BundleMaxSpeed and fits(r) then
			return r
		end
	end
	if fits(2) then
		return 2
	end
	return nil
end

-- fraction of group g's energy (1/k^2) that the pulse file at base index r carries, counting only harmonics a
-- listener hears at this note (below 20 kHz)
function WaveBank.pulseCoverage(g, r, freq)
	local grp, info = WaveBank.BundleGroups[g], WaveBank.Pulses[g]
	if not grp or not info then
		return 0
	end
	local top = info.top[WaveBank.BundleBases[r]] or 0
	local num, den = 0, 0
	for k = grp[1], grp[2] do
		if k * freq > 20000 then
			break
		end
		local w = k ^ (-2 * WaveBank.BundleTilt)
		den += w
		if k <= top then
			num += w
		end
	end
	return den > 0 and num / den or 0
end

-- Manifests ---------------------------------------------------------------------------------------
local Manifests = require(script.Parent.Manifests)
WaveBank.Manifest = nil -- name of the manifest in use
WaveBank.Revision = 0 -- counts manifest changes (preload and the synth's caches watch it)

-- The manifest asked for: attribute Manifest on the AudioLab module ("Lean", "Full" or "Atlas"; default Manifests.Default).
function WaveBank.wantedManifest()
	local want = AudioLab and AudioLab:GetAttribute("Manifest")
	if type(want) ~= "string" or want == "" then
		want = Manifests.Default
	end
	return want
end

-- Applies the wanted manifest if it changed (cheap when it didn't): fills WaveBank.Assets and sets SineRange and
-- SharedNoise. Called when a pool is created (every song / clip start) and by preload. Returns true if it changed.
function WaveBank.refresh()
	local want = WaveBank.wantedManifest()
	if want == WaveBank.Manifest then
		return false
	end
	local profile = Manifests.Profiles[want]
	if not profile then
		warn(("[AudioLab] no manifest named %q (have: %s); using %s"):format(want, table.concat((function()
			local t = {}
			for k in pairs(Manifests.Profiles) do
				table.insert(t, k)
			end
			table.sort(t)
			return t
		end)(), ", "), Manifests.Default))
		want = Manifests.Default
		profile = Manifests.Profiles[want]
	end
	if profile.source == "atlas" and not Manifests.Atlas.wired then
		warn(("[AudioLab] manifest %s is not playable yet (the voice pool has no loop-region support); using %s"):format(want, profile.fallback))
		want = profile.fallback
		profile = Manifests.Profiles[want]
		if want == WaveBank.Manifest then
			return false
		end
	end
	if profile.source == "atlas" and next(Manifests.atlasSounds(profile)) == nil then
		local to = profile.fallback or Manifests.Default
		warn(("[AudioLab] manifest %s has no uploaded atlas pack (Codec/Manifests/Atlas); using %s"):format(want, to))
		want = to
		profile = Manifests.Profiles[want]
		if want == WaveBank.Manifest then
			return false
		end
	end
	table.clear(WaveBank.Assets)
	table.clear(WaveBank.Regions)
	if profile.source == "atlas" then
		for name, region in pairs(Manifests.atlasSounds(profile)) do
			WaveBank.Assets[name] = region.id -- a sound's file is its pack's file
			WaveBank.Regions[name] = region
		end
		-- individual files the packs do not hold (the tracked sine bases of the decays)
		for _, name in ipairs(profile.extraFiles or {}) do
			if WaveBank.Assets[name] == nil and Manifests.Files[name] then
				WaveBank.Assets[name] = Manifests.Files[name]
			end
		end
	else
		for name, id in pairs(Manifests.Files) do
			if profile.include(name) then
				WaveBank.Assets[name] = id
			end
		end
	end
	-- the files every profile uses (Manifests.Core: the rough sine)
	for _, name in ipairs(Manifests.Core or {}) do
		if Manifests.Files[name] then
			WaveBank.Assets[name] = Manifests.Files[name]
		end
	end
	WaveBank.SineRange = profile.SineRange
	WaveBank.SharedNoise = profile.SharedNoise
	-- NoiseGain[band] = the playback level of the file that band plays from
	for b = 1, #WaveBank.NoiseCenters do
		WaveBank.NoiseGain[b] = WaveBank.NoiseGainFile[(WaveBank.noiseSource(b))]
	end
	WaveBank.Manifest = want
	WaveBank.Revision += 1
	-- the entry count says which level is in use (also on the AudioLab folder: attributes ManifestActive, ManifestEntries)
	local entries, files = Manifests.count(want)
	WaveBank.Entries, WaveBank.Files = entries, files
	local summary = ("%s: %d entries from %d file%s"):format(want, entries, files, files == 1 and "" or "s")
	WaveBank.ManifestSummary = summary
	if AudioLab then
		AudioLab:SetAttribute("ManifestActive", summary)
		AudioLab:SetAttribute("ManifestEntries", entries)
	end
	if AudioLab and AudioLab:GetAttribute("Debug") == true then -- (a testing aid: the AudioLab folder's Debug attribute)
		print("[AudioLab] manifest " .. summary)
	end
	return true
end

WaveBank.refresh()

return WaveBank
