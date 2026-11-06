--!native
--!optimize 2
-- Clip codec v3 ("RBA3") for imported recordings (WAV / AIFF / MP3): the sound is rebuilt from tracked
-- sinusoids (each one a looping sine asset driven by PlaybackSpeed and Volume) plus the high noise bands
-- (hi-hats, cymbals, breath). Below NoiseFloorHz there is no noise: a hiss bed there drowned the music.
--
--   local bytes, stats = Partials.encode(signal, options?)   -- signal: AudioLab Signal (any channel count)
--   local clip = Partials.unpack(bytes)                       -- for the player (decodes all frames once)
--   Partials.isClip(bytes)
--
-- Analysis, per control frame (Fps per second):
--   1. Peaks from two FFTs centred on the frame: a long one below Split Hz (resolves bass notes), a
--      half-length one above (sharper in time). Parabolic interpolation on the log magnitude.
--   2. Tracking into Slots voices. Voices already sounding claim their continuation first (nearest
--      peak within ~70 cents); a short dropout (Bridge frames) is held at the level measured at that
--      pitch; when free voices run short, the quietest voices end so a much louder new peak (EvictRatio)
--      can start next frame; new peaks only start in voices that were silent last frame (a voice never
--      jumps pitch while audible). Tracks shorter than MinLife frames are dropped (flicker sounds like
--      a low-bitrate codec).
--   3. High noise: the power between spectral peaks in the half-octave bins above 1.4 kHz, fitted with
--      the WaveBank noise assets centred >= NoiseFloorHz / 2 (non-negative least squares); only those
--      centred >= NoiseFloorHz are kept.
--   4. Loudness correction: per octave band and frame, everything is scaled so the model's energy
--      matches a short (~23 ms) FFT of the source. This keeps hits punchy and gaps quiet.
--   5. Quantisation with hysteresis (pitch in cents, level in dB) and per-voice delta planes,
--      compressed with zstd when EncodingService is available.
-- Stereo sources (Stereo = true, the default): tracking runs on the mid signal (L + R) / 2; each voice
-- gets an equal-power pan from its left and right energy at its own pitch, and its level from the
-- average of both channels (so side content isn't lost); the high noise is fitted per side; the
-- loudness correction uses both channels.

local AudioLab = script and script:FindFirstAncestor("AudioLab")
local FFT, WaveBank
if AudioLab then
	FFT = require(AudioLab.DSP.FFT)
	WaveBank = require(AudioLab.Codec.WaveBank)
else
	FFT, WaveBank = require("./FFT"), require("./wavebank_stub") -- standalone Luau (outside Roblox)
end

local Partials = {}

Partials.Magic = "RBA3"
Partials.Version = 3
Partials.HeaderSize = 24

Partials.Defaults = {
	Fps = 120,
	Slots = 96,
	Split = 700, -- Hz: long FFT below, half-length FFT above
	LongSeconds = 0.0929, -- long FFT length (4096 samples at 44.1 kHz)
	MaxFreq = 16000,
	AbsFloor = 3e-5, -- smallest peak amplitude considered
	Candidates = 160, -- loudest peaks per frame considered for tracking
	TrackCents = 70, -- largest pitch step a voice may follow between frames
	Bridge = 3, -- frames a voice may survive without a peak
	MinLife = 6, -- shorter tracks are dropped
	Reserve = 0.1, -- share of voices kept free for new peaks
	EvictRatio = 4, -- a new peak this many times louder may replace the quietest voice
	NoiseFloorHz = 1000, -- noise assets centred below this are not used
	NoiseBinStart = 7, -- first half-octave noise-fit bin: 62.5 * 2^(k/2) Hz (9 = 1.41 kHz, 7 = 707 Hz)
	NoiseShort = true, -- fit the noise from the short FFT (sharper onsets)
	ShortLoud = true, -- loudness target above 500 Hz from a half-length FFT (tighter attacks)
	LoudBassH = true, -- loudness target below 500 Hz from a longer FFT (less leakage from loud neighbours)
	LoudMid = 2000, -- Hz: 500 Hz .. this from the middle FFT, above it from the shortest
	TimeShape = 2, -- 1: low voices take their level shape from a shorter FFT; 2: all voices
	TimeShapeMin = 0.1,
	TimeShapeMax = 1.3,
	GainMin = 0.05,
	GainMax = 8,
	HysteresisCents = 2,
	HysteresisDb = 0.75,
	Yield = nil, -- function called every YieldEvery frames (task.wait in Studio)
	YieldEvery = 24,
	Compress = true,
	Stereo = true, -- keep stereo sources stereo (pan per voice, noise per side)
	PanHysteresis = 0.06, -- pan changes smaller than this (0..1 scale) are not stored
	-- a noise asset is only used when its whole band lies below the source's Nyquist (x NyquistSlack): an
	-- 8 / 16 kHz recording has nothing up there, and a band reaching past it would play hiss the original never had
	NyquistSlack = 1.06,
	BirthProminenceDb = nil, -- a new track only starts on a peak at least this prominent (nil: any peak); noise-like
	-- peaks are left to the noise bands, so noisy sounds aren't rebuilt from dozens of short sines
	RelFloorDb = nil, -- peaks quieter than this many dB under the clip's loudest sample are not tracked (nil: off)
	FrameRangeDb = nil, -- peaks more than this many dB under the frame's loudest peak are not tracked (nil: off)
	-- short clips (sound effects, <= ShortSeconds): noisy peaks go to the noise bands (which reach down to 250 Hz)
	-- instead of a cloud of short sines, quiet peaks under the frame's loudest are skipped and at most 64 voices are used.
	-- Longer recordings (music) keep the settings above (a noise bed under 1 kHz would drown the music).
	ShortSeconds = 5,
	Short = { BirthProminenceDb = 6, NoiseFloorHz = 250, NoiseBinStart = 3, FrameRangeDb = 30, Slots = 64 },
}

local ENV_EDGES = { 0, 125, 250, 500, 1000, 2000, 4000, 8000, math.huge }
local ENV_BANDS = #ENV_EDGES - 1
local C0 = 16.351597831287414 -- Hz, pitch code 0
local LOG2 = math.log(2)

local function envBand(f)
	for b = ENV_BANDS, 1, -1 do
		if f >= ENV_EDGES[b] then
			return b
		end
	end
	return 1
end

local function merge(options)
	local o = {}
	for k, v in pairs(Partials.Defaults) do
		o[k] = v
	end
	if options then
		for k, v in pairs(options) do
			o[k] = v
		end
	end
	return o
end

local function toMono(signal)
	local len = signal.length
	local out = buffer.create(math.max(len, 1) * 4)
	local ch = signal.channels
	local inv = 1 / ch
	for i = 0, len - 1 do
		local s = 0
		for c = 1, ch do
			s += buffer.readf32(signal.data[c], i * 4)
		end
		buffer.writef32(out, i * 4, s * inv)
	end
	return out
end

-- windowed frame centred on sample c into re/im (1-indexed), zero outside the signal
local function fill(src, len, c, n, w, re, im)
	local start = c - n // 2
	for i = 1, n do
		local idx = start + i - 1
		local v = 0
		if idx >= 0 and idx < len then
			v = buffer.readf32(src, idx * 4)
		end
		re[i] = v * w[i]
		im[i] = 0
	end
end

-- peaks of one spectrum between fmin and fmax: appends to pf/pa, returns new count
local function findPeaks(re, im, n, binHz, ampScale, fmin, fmax, floor, logm, pf, pa, count, pp)
	local half = n // 2
	for k = 1, half + 1 do
		local a, b = re[k], im[k]
		logm[k] = 0.5 * math.log(a * a + b * b + 1e-24)
	end
	local lo = math.max(3, math.floor(fmin / binHz) + 1)
	local hi = math.min(half, math.floor(fmax / binHz) + 2)
	local logFloor = math.log(floor / ampScale)
	for k = lo, hi do
		local v = logm[k]
		if v > logm[k - 1] and v >= logm[k + 1] and v > logFloor then
			local a, c = logm[k - 1], logm[k + 1]
			local den = a - 2 * v + c
			local p = 0
			if den ~= 0 then
				p = math.clamp(0.5 * (a - c) / den, -0.5, 0.5)
			end
			local f = (k - 1 + p) * binHz
			if f >= fmin and f < fmax then
				count += 1
				pf[count] = f
				pa[count] = math.exp(v - 0.25 * (a - c) * p) * ampScale
				if pp then
					-- prominence: the peak's power over the mean power 3..8 bins either side (outside a Hann main
					-- lobe a sinusoid falls > 30 dB; a peak of noise stands only ~5-8 dB above its neighbourhood)
					local sum, nb = 0, 0
					for d = 3, 8 do
						for _, q in ipairs({ k - d, k + d }) do
							if q >= 1 and q <= half + 1 then
								sum += math.exp(2 * logm[q])
								nb += 1
							end
						end
					end
					pp[count] = (nb > 0) and 4.3429 * (2 * v - math.log(sum / nb + 1e-30)) or 99
				end
			end
		end
	end
	return count
end

-- energy-based level of the spectrum within +-halfHz of f (compares two window lengths)
local function bandLevel(re, im, n, binHz, powScale, f, halfHz)
	local k = math.floor(f / binHz + 0.5) + 1
	local w = math.max(1, math.floor(halfHz / binHz + 0.5))
	local e = 0
	for i = math.max(1, k - w), math.min(n // 2 + 1, k + w) do
		e += re[i] * re[i] + im[i] * im[i]
	end
	return math.sqrt(2 * e * powScale)
end

-- level of a sinusoid at frequency f from a spectrum: sqrt(2 * power within +-2 bins)
local function levelAt(re, im, n, binHz, powScale, f)
	local k = math.floor(f / binHz + 0.5) + 1
	local half = n // 2
	local e = 0
	for i = math.max(1, k - 2), math.min(half + 1, k + 2) do
		e += re[i] * re[i] + im[i] * im[i]
	end
	return math.sqrt(2 * e * powScale)
end

-- energy within +-2 bins of frequency f (unscaled: used for left / right / mid ratios)
local function lobe(re, im, n, binHz, f)
	local k = math.floor(f / binHz + 0.5) + 1
	local half = n // 2
	local e = 0
	for i = math.max(1, k - 2), math.min(half + 1, k + 2) do
		e += re[i] * re[i] + im[i] * im[i]
	end
	return e
end

-- power between spectral peaks in each noise-fit bin (peaks: local maxima 6 dB above their 9-bin
-- minimum, masked +-2 bins), scaled up to the bin's full width
local function residual(re, im, logP, bins, half, binH, powH, resid)
	for k = 1, half + 1 do
		local a, b = re[k], im[k]
		logP[k] = 10 * math.log10((a * a + b * b) * powH + 1e-20)
	end
	for cb, bin in ipairs(bins) do
		local lo = math.max(2, math.floor(bin.lo / binH) + 2)
		local hi = math.min(half, math.ceil(bin.hi / binH))
		local sum, kept, total = 0, 0, 0
		for k = lo, hi do
			total += 1
			local masked = false
			for d = -2, 2 do
				local q = k + d
				if q > 1 and q <= half then
					local v = logP[q]
					if v > logP[q - 1] and v >= logP[q + 1] then
						local mn = v
						for r = math.max(1, q - 4), math.min(half + 1, q + 4) do
							if logP[r] < mn then
								mn = logP[r]
							end
						end
						if v - mn >= 6 then
							masked = true
							break
						end
					end
				end
			end
			if not masked then
				local a, b = re[k], im[k]
				sum += (a * a + b * b) * powH
				kept += 1
			end
		end
		resid[cb] = (kept > 0) and (sum * total / kept) or 0
	end
end

-- noise fit: assets centred >= NoiseFloorHz / 2 are fitted to the half-octave bins from 1.4 kHz up,
-- then only those centred >= NoiseFloorHz are kept (the lower ones absorb the 1.4-4 kHz residual
-- in the fit, as fitting every band and dropping the low ones did in the prototype, so the 4 kHz
-- asset isn't forced to cover the bin below it alone and overshoot)
local function noiseModel(o, nyquist)
	local fitIds = {}
	for b = 1, #WaveBank.NoiseBands do
		local band = WaveBank.NoiseBands[b]
		if band.center >= o.NoiseFloorHz / 2 and band.low < nyquist and (not o.NyquistSlack or band.high <= nyquist * o.NyquistSlack) then
			table.insert(fitIds, b)
		end
	end
	table.sort(fitIds, function(x, y)
		return WaveBank.NoiseBands[x].center < WaveBank.NoiseBands[y].center
	end)
	local ids, keepIndex = {}, {}
	for j, id in ipairs(fitIds) do
		if WaveBank.NoiseBands[id].center >= o.NoiseFloorHz then
			table.insert(ids, id)
			table.insert(keepIndex, j)
		end
	end
	-- half-octave chain bins from 1.41 kHz up (62.5 * 2^(k/2), k = 9..)
	local bins = {}
	local k = o.NoiseBinStart
	while true do
		local lo = 62.5 * 2 ^ (k / 2)
		if lo >= nyquist then
			break
		end
		local hi = math.min(62.5 * 2 ^ ((k + 1) / 2), nyquist)
		table.insert(bins, { lo = lo, hi = hi })
		k += 1
	end
	local rms2 = WaveBank.NoiseRms * WaveBank.NoiseRms
	local M = {}
	for c, bin in ipairs(bins) do
		M[c] = {}
		for j, id in ipairs(fitIds) do
			local band = WaveBank.NoiseBands[id]
			local ov = math.max(0, math.min(bin.hi, band.high) - math.max(bin.lo, band.low))
			M[c][j] = rms2 * ov / (band.high - band.low)
		end
	end
	-- power of each kept asset (at volume 1) per loudness band
	local fold = {}
	for j, id in ipairs(ids) do
		fold[j] = table.create(ENV_BANDS, 0)
		local band = WaveBank.NoiseBands[id]
		for b = 1, ENV_BANDS do
			local ov = math.max(0, math.min(ENV_EDGES[b + 1], band.high, nyquist) - math.max(ENV_EDGES[b], band.low))
			fold[j][b] = rms2 * ov / (band.high - band.low)
		end
	end
	local bandOf = {}
	for j, id in ipairs(ids) do
		bandOf[j] = envBand(WaveBank.NoiseBands[id].center)
	end
	return ids, bins, M, fold, bandOf, #fitIds, keepIndex
end

-- non-negative least squares for small systems (coordinate descent on powers)
local function nnls(M, r, nVar, p)
	local nRow = #M
	for j = 1, nVar do
		p[j] = 0
	end
	local res = table.create(nRow)
	for c = 1, nRow do
		res[c] = r[c]
	end
	for _ = 1, 40 do
		for j = 1, nVar do
			local num, den = 0, 0
			for c = 1, nRow do
				local m = M[c][j]
				num += m * res[c]
				den += m * m
			end
			if den > 0 then
				local nv = math.max(0, p[j] + num / den)
				local d = nv - p[j]
				if d ~= 0 then
					for c = 1, nRow do
						res[c] -= M[c][j] * d
					end
					p[j] = nv
				end
			end
		end
	end
end

function Partials.analyze(signal, options)
	local o = merge(options)
	if o.Short and o.ShortSeconds and signal.length / signal.sampleRate <= o.ShortSeconds then
		for k, v in pairs(o.Short) do
			if options == nil or options[k] == nil then
				o[k] = v
			end
		end
	end
	local sr = signal.sampleRate
	local len = signal.length
	local src = toMono(signal)
	local stereo = o.Stereo ~= false and signal.channels >= 2
	local srcA, srcB = signal.data[1], signal.data[2] -- left, right (stereo only)
	local K = o.Slots
	local hop = sr / o.Fps
	local nfr = math.floor(len / hop) + 1
	-- nearest power of two (4096 at 44.1 / 48 kHz, 2048 at 22.05 kHz)
	local nL = 2 ^ math.floor(math.log(sr * o.LongSeconds, 2) + 0.5)
	local nH = nL // 2
	local nS = nL // 4
	local nQ = nS // 2
	local wQ, sQ = FFT.window("hann", nQ), FFT.windowStats("hann", nQ)
	local binQ, powQ = sr / nQ, 2 / (nQ * sQ.sumSq)
	local reQ, imQ = table.create(nQ, 0), table.create(nQ, 0)
	local reQa, imQa, reQb, imQb = table.create(nQ, 0), table.create(nQ, 0), table.create(nQ, 0), table.create(nQ, 0)
	local shortLoud, tshape = o.ShortLoud, o.TimeShape
	local wL, wH, wS = FFT.window("hann", nL), FFT.window("hann", nH), FFT.window("hann", nS)
	local sL, sH, sS = FFT.windowStats("hann", nL), FFT.windowStats("hann", nH), FFT.windowStats("hann", nS)
	local binL, binH, binS = sr / nL, sr / nH, sr / nS
	local ampL, ampH = 2 / sL.sum, 2 / sH.sum
	local powL, powH, powS = 2 / (nL * sL.sumSq), 2 / (nH * sH.sumSq), 2 / (nS * sS.sumSq)
	local split, maxF = o.Split, math.min(o.MaxFreq, sr * 0.49)
	local nyquist = sr / 2

	local reL, imL = table.create(nL, 0), table.create(nL, 0)
	local reH, imH = table.create(nH, 0), table.create(nH, 0)
	local reS, imS = table.create(nS, 0), table.create(nS, 0)
	-- per side spectra (stereo): a = left, b = right; the mid spectra above are their average
	local reLa, imLa, reLb, imLb, reHa, imHa, reHb, imHb, reSa, imSa, reSb, imSb
	if stereo then
		reLa, imLa, reLb, imLb = table.create(nL, 0), table.create(nL, 0), table.create(nL, 0), table.create(nL, 0)
		reHa, imHa, reHb, imHb = table.create(nH, 0), table.create(nH, 0), table.create(nH, 0), table.create(nH, 0)
		reSa, imSa, reSb, imSb = table.create(nS, 0), table.create(nS, 0), table.create(nS, 0), table.create(nS, 0)
	end
	local logL, logH = table.create(nL // 2 + 1, 0), table.create(nH // 2 + 1, 0)
	local pf, pa, pp = table.create(1024, 0), table.create(1024, 0), table.create(1024, 0)
	local candP = table.create(1024, 0)
	local order = table.create(1024, 0)

	-- outputs (frame-major): freq, amp, track id per voice; noise volumes; short-FFT band energies
	local F = buffer.create(nfr * K * 4)
	local A = buffer.create(nfr * K * 4)
	local T = buffer.create(nfr * K * 4)
	local ids, bins, M, fold, noiseBand, nFit, keepIndex = noiseModel(o, nyquist)
	local nN = #ids
	local V = buffer.create(math.max(1, nfr * nN) * 4) -- noise volumes (left side when stereo)
	local VR = stereo and buffer.create(math.max(1, nfr * nN) * 4) or nil -- right side
	local P = stereo and buffer.create(nfr * K * 4) or nil -- pan per voice, 0 (left) .. 1 (right)
	local E = buffer.create(nfr * ENV_BANDS * 8)

	local prevF, prevA, prevT, miss = table.create(K, 0), table.create(K, 0), table.create(K, -1), table.create(K, 0)
	local nf, na, nt = table.create(K, 0), table.create(K, 0), table.create(K, -1)
	local nextId = 0
	local tol = 2 ^ (o.TrackCents / 1200) - 1
	local candF, candA, taken = table.create(o.Candidates, 0), table.create(o.Candidates, 0), table.create(o.Candidates, false)
	local resid = table.create(#bins, 0)
	local pw = table.create(math.max(nFit, 1), 0)
	local pwR = table.create(math.max(nFit, 1), 0)
	local logP = table.create(nH // 2 + 1, 0)
	local births, bridged, evicted = 0, 0, 0
	local absFloor = o.AbsFloor
	if o.RelFloorDb then
		local pk = 0
		for i = 0, len - 1 do
			pk = math.max(pk, math.abs(buffer.readf32(src, i * 4)))
		end
		absFloor = math.max(absFloor, pk * 10 ^ (-o.RelFloorDb / 20))
	end
	local alive = table.create(K, 0)

	for j = 0, nfr - 1 do
		local c = math.floor(j * hop)
		if stereo then
			-- FFT is linear: the mid spectrum is the average of the side spectra
			fill(srcA, len, c, nL, wL, reLa, imLa)
			FFT.transform(reLa, imLa)
			fill(srcB, len, c, nL, wL, reLb, imLb)
			FFT.transform(reLb, imLb)
			for i = 1, nL do
				reL[i], imL[i] = 0.5 * (reLa[i] + reLb[i]), 0.5 * (imLa[i] + imLb[i])
			end
			fill(srcA, len, c, nH, wH, reHa, imHa)
			FFT.transform(reHa, imHa)
			fill(srcB, len, c, nH, wH, reHb, imHb)
			FFT.transform(reHb, imHb)
			for i = 1, nH do
				reH[i], imH[i] = 0.5 * (reHa[i] + reHb[i]), 0.5 * (imHa[i] + imHb[i])
			end
			fill(srcA, len, c, nS, wS, reSa, imSa)
			FFT.transform(reSa, imSa)
			fill(srcB, len, c, nS, wS, reSb, imSb)
			FFT.transform(reSb, imSb)
			if shortLoud then
				fill(srcA, len, c, nQ, wQ, reQa, imQa)
				FFT.transform(reQa, imQa)
				fill(srcB, len, c, nQ, wQ, reQb, imQb)
				FFT.transform(reQb, imQb)
			end
		else
			fill(src, len, c, nL, wL, reL, imL)
			FFT.transform(reL, imL)
			fill(src, len, c, nH, wH, reH, imH)
			FFT.transform(reH, imH)
			fill(src, len, c, nS, wS, reS, imS)
			FFT.transform(reS, imS)
			if shortLoud then
				fill(src, len, c, nQ, wQ, reQ, imQ)
				FFT.transform(reQ, imQ)
			end
		end

		-- 1. peaks
		local count = findPeaks(reL, imL, nL, binL, ampL, 30, split, absFloor, logL, pf, pa, 0, pp)
		count = findPeaks(reH, imH, nH, binH, ampH, split, maxF, absFloor, logH, pf, pa, count, pp)
		if o.FrameRangeDb and count > 0 then
			local top = 0
			for i = 1, count do
				top = math.max(top, pa[i])
			end
			local lim = top * 10 ^ (-o.FrameRangeDb / 20)
			local w = 0
			for i = 1, count do
				if pa[i] >= lim then
					w += 1
					pf[w], pa[w], pp[w] = pf[i], pa[i], pp[i]
				end
			end
			count = w
		end
		for i = 1, count do
			order[i] = i
		end
		for i = count + 1, #order do
			order[i] = nil
		end
		table.sort(order, function(x, y)
			return pa[x] > pa[y]
		end)
		local nc = math.min(count, o.Candidates)
		for i = 1, nc do
			candF[i], candA[i], taken[i], candP[i] = pf[order[i]], pa[order[i]], false, pp[order[i]]
		end

		-- 2. tracking: continuations first (loudest voices first)
		for s = 1, K do
			nf[s], na[s], nt[s] = 0, 0, -1
		end
		local nAlive = 0
		for s = 1, K do
			if prevA[s] > 0 then
				nAlive += 1
				alive[nAlive] = s
			end
		end
		for i = nAlive + 1, K do
			alive[i] = nil
		end
		table.sort(alive, function(x, y)
			return prevA[x] > prevA[y]
		end)
		for _, s in ipairs(alive) do
			local f0 = prevF[s]
			local best, bd = 0, math.max(f0 * tol, 0.75 * (f0 < split and binL or binH))
			for i = 1, nc do
				if not taken[i] then
					local d = math.abs(candF[i] - f0)
					if d <= bd then
						best, bd = i, d
					end
				end
			end
			if best > 0 then
				taken[best] = true
				nf[s], na[s], nt[s] = candF[best], candA[best], prevT[s]
				miss[s] = 0
			elseif miss[s] < o.Bridge then
				local lvl
				if f0 < split then
					lvl = levelAt(reL, imL, nL, binL, powL, f0)
				else
					lvl = levelAt(reH, imH, nH, binH, powH, f0)
				end
				nf[s], na[s], nt[s] = f0, math.min(lvl, prevA[s]), prevT[s]
				miss[s] += 1
				bridged += 1
			end
		end
		-- keep a reserve of free voices: the quietest end when a much louder peak is waiting
		local used = 0
		for s = 1, K do
			if nt[s] >= 0 then
				used += 1
			end
		end
		local need = math.floor(o.Reserve * K) - (K - used)
		if need > 0 then
			local weak = {}
			for s = 1, K do
				if nt[s] >= 0 then
					table.insert(weak, s)
				end
			end
			table.sort(weak, function(x, y)
				return na[x] < na[y]
			end)
			local w = 1
			for i = 1, nc do
				if need <= 0 or w > #weak then
					break
				end
				if not taken[i] then
					local s = weak[w]
					if candA[i] > o.EvictRatio * na[s] then
						na[s], nt[s], nf[s] = 0, -1, prevF[s]
						evicted += 1
					end
					w += 1
					need -= 1
				end
			end
		end
		-- births, loudest first (bass slightly de-emphasised), into voices silent last frame
		local bornOrder = {}
		local minProm = o.BirthProminenceDb
		for i = 1, nc do
			if not taken[i] and (not minProm or candP[i] >= minProm) then
				table.insert(bornOrder, i)
			end
		end
		table.sort(bornOrder, function(x, y)
			return candA[x] * math.clamp(candF[x] / 100, 0.5, 1) > candA[y] * math.clamp(candF[y] / 100, 0.5, 1)
		end)
		local s = 1
		for _, i in ipairs(bornOrder) do
			while s <= K and not (nt[s] < 0 and prevA[s] == 0) do
				s += 1
			end
			if s > K then
				break
			end
			nf[s], na[s], nt[s] = candF[i], candA[i], nextId
			nextId += 1
			miss[s] = 0
			births += 1
			s += 1
		end
		local reS_m, imS_m = reS, imS
		if stereo and tshape > 1 then
			for i = 1, nS do
				reS[i], imS[i] = 0.5 * (reSa[i] + reSb[i]), 0.5 * (imSa[i] + imSb[i])
			end
		end
		local base = j * K
		for v = 1, K do
			if nt[v] < 0 then
				nf[v] = prevF[v]
				na[v] = 0
			end
			local outA = na[v]
			if stereo then
				local pan = 0.5
				if outA > 0 then
					local f0 = nf[v]
					local eA, eB, eM
					if f0 < split then
						eA, eB, eM = lobe(reLa, imLa, nL, binL, f0), lobe(reLb, imLb, nL, binL, f0), lobe(reL, imL, nL, binL, f0)
					else
						eA, eB, eM = lobe(reHa, imHa, nH, binH, f0), lobe(reHb, imHb, nH, binH, f0), lobe(reH, imH, nH, binH, f0)
					end
					-- level from the mean of both sides (>= mid level; more when the sides differ in phase)
					outA *= math.clamp(math.sqrt(0.5 * (eA + eB) / math.max(eM, 1e-30)), 1, 4)
					pan = math.atan2(math.sqrt(eB), math.sqrt(eA)) / (math.pi / 2)
				end
				buffer.writef32(P, (base + v - 1) * 4, pan)
			end
			if tshape > 0 and outA > 0 then
				local fv = nf[v]
				local sl, ll
				if fv < split then
					sl = bandLevel(reH, imH, nH, binH, powH, fv, 43)
					ll = bandLevel(reL, imL, nL, binL, powL, fv, 43)
				elseif tshape > 1 then
					sl = bandLevel(reS_m, imS_m, nS, binS, powS, fv, 86)
					ll = bandLevel(reH, imH, nH, binH, powH, fv, 86)
				end
				if ll and ll > 1e-7 then
					outA = outA * math.clamp(sl / ll, o.TimeShapeMin, o.TimeShapeMax)
				end
			end
			buffer.writef32(F, (base + v - 1) * 4, nf[v])
			buffer.writef32(A, (base + v - 1) * 4, outA)
			buffer.writei32(T, (base + v - 1) * 4, nt[v])
			prevF[v], prevA[v], prevT[v] = nf[v], na[v], nt[v]
		end

		-- 3. high noise: power between peaks in each fit bin, fitted with the noise assets (per side)
		if nFit > 0 then
			local nzN, nzBin, nzPow = nH, binH, powH
			local zRe, zIm, zRea, zIma, zReb, zImb = reH, imH, reHa, imHa, reHb, imHb
			if o.NoiseShort then
				nzN, nzBin, nzPow = nS, binS, powS
				zRe, zIm, zRea, zIma, zReb, zImb = reS, imS, reSa, imSa, reSb, imSb
			end
			local half = nzN // 2
			if stereo then
				residual(zRea, zIma, logP, bins, half, nzBin, nzPow, resid)
				nnls(M, resid, nFit, pw)
				residual(zReb, zImb, logP, bins, half, nzBin, nzPow, resid)
				nnls(M, resid, nFit, pwR)
				for q = 1, nN do
					buffer.writef32(V, (j * nN + q - 1) * 4, math.sqrt(pw[keepIndex[q]]))
					buffer.writef32(VR, (j * nN + q - 1) * 4, math.sqrt(pwR[keepIndex[q]]))
				end
			else
				residual(zRe, zIm, logP, bins, half, nzBin, nzPow, resid)
				nnls(M, resid, nFit, pw)
				for q = 1, nN do
					buffer.writef32(V, (j * nN + q - 1) * 4, math.sqrt(pw[keepIndex[q]]))
				end
			end
		end

		-- 4. target loudness per band: low bands from a longer FFT (less leakage from loud neighbours),
		-- high bands from a shorter one (tighter attacks); stereo: mean power of both sides
		do
			local acc = table.create(ENV_BANDS, 0)
			local function addBand(lN, lBin, lPow, fLo, fHi, ra, ia, rb, ib, rm, im_)
				local half = lN // 2
				local b = 1
				for k = 1, half + 1 do
					local f = (k - 1) * lBin
					while f >= ENV_EDGES[b + 1] do
						b += 1
					end
					if f >= fLo and f < fHi then
						if stereo then
							local a, i2, c2, d2 = ra[k], ia[k], rb[k], ib[k]
							acc[b] += 0.5 * (a * a + i2 * i2 + c2 * c2 + d2 * d2) * lPow
						else
							local a, i2 = rm[k], im_[k]
							acc[b] += (a * a + i2 * i2) * lPow
						end
					end
				end
			end
			if shortLoud then
				if o.LoudBassH then
					addBand(nH, binH, powH, 0, 500, reHa, imHa, reHb, imHb, reH, imH)
				else
					addBand(nS, binS, powS, 0, 500, reSa, imSa, reSb, imSb, reS, imS)
				end
				addBand(nS, binS, powS, 500, o.LoudMid, reSa, imSa, reSb, imSb, reS, imS)
				addBand(nQ, binQ, powQ, o.LoudMid, math.huge, reQa, imQa, reQb, imQb, reQ, imQ)
			else
				addBand(nS, binS, powS, 0, math.huge, reSa, imSa, reSb, imSb, reS, imS)
			end
			for q = 1, ENV_BANDS do
				buffer.writef64(E, (j * ENV_BANDS + q - 1) * 8, acc[q])
			end
		end

		if o.Yield and j % o.YieldEvery == o.YieldEvery - 1 then
			o.Yield()
		end
	end

	-- drop short tracks
	local life = table.create(nextId + 1, 0)
	for i = 0, nfr * K - 1 do
		local t = buffer.readi32(T, i * 4)
		if t >= 0 then
			life[t + 1] += 1
		end
	end
	local pruned = 0
	for i = 0, nfr * K - 1 do
		local t = buffer.readi32(T, i * 4)
		if t >= 0 and life[t + 1] < o.MinLife then
			buffer.writef32(A, i * 4, 0)
			pruned += 1
		end
	end

	-- one pan per track: the per-frame estimate is noisy, and a partial belongs to one instrument, which
	-- rarely moves; a steady pan also means voices don't hop between pan buses while they play
	if stereo then
		local wsum, psum = table.create(nextId + 1, 0), table.create(nextId + 1, 0)
		for i = 0, nfr * K - 1 do
			local t = buffer.readi32(T, i * 4)
			local a = buffer.readf32(A, i * 4)
			if t >= 0 and a > 0 then
				local w = a * a
				wsum[t + 1] += w
				psum[t + 1] += w * buffer.readf32(P, i * 4)
			end
		end
		for i = 0, nfr * K - 1 do
			local t = buffer.readi32(T, i * 4)
			if t >= 0 and wsum[t + 1] > 0 then
				buffer.writef32(P, i * 4, psum[t + 1] / wsum[t + 1])
			end
		end
	end

	-- loudness correction per band and frame
	local mean = table.create(ENV_BANDS, 0)
	for j = 0, nfr - 1 do
		for q = 1, ENV_BANDS do
			mean[q] += buffer.readf64(E, (j * ENV_BANDS + q - 1) * 8)
		end
	end
	local floorE = table.create(ENV_BANDS, 0)
	for q = 1, ENV_BANDS do
		floorE[q] = 1e-4 * mean[q] / nfr + 1e-12
	end
	local Mo = table.create(ENV_BANDS, 0)
	local g = table.create(ENV_BANDS, 1)
	local bandOfVoice = table.create(K, 1)
	for j = 0, nfr - 1 do
		for q = 1, ENV_BANDS do
			Mo[q] = 0
		end
		local base = j * K
		for v = 1, K do
			local a = buffer.readf32(A, (base + v - 1) * 4)
			local bnd = envBand(buffer.readf32(F, (base + v - 1) * 4))
			bandOfVoice[v] = bnd
			if a > 0 then
				Mo[bnd] += a * a * 0.5
			end
		end
		for q = 1, nN do
			local vol = buffer.readf32(V, (j * nN + q - 1) * 4)
			local p2 = vol * vol
			if stereo then
				local vr = buffer.readf32(VR, (j * nN + q - 1) * 4)
				p2 = 0.5 * (p2 + vr * vr)
			end
			if p2 > 0 then
				local f2 = fold[q]
				for b = 1, ENV_BANDS do
					Mo[b] += p2 * f2[b]
				end
			end
		end
		for q = 1, ENV_BANDS do
			local t = buffer.readf64(E, (j * ENV_BANDS + q - 1) * 8)
			g[q] = math.clamp(math.sqrt((t + floorE[q]) / (Mo[q] + floorE[q])), o.GainMin, o.GainMax)
		end
		for v = 1, K do
			local i = (base + v - 1) * 4
			local a = buffer.readf32(A, i)
			if a > 0 then
				buffer.writef32(A, i, a * g[bandOfVoice[v]])
			end
		end
		for q = 1, nN do
			local i = (j * nN + q - 1) * 4
			buffer.writef32(V, i, buffer.readf32(V, i) * g[noiseBand[q]])
			if stereo then
				buffer.writef32(VR, i, buffer.readf32(VR, i) * g[noiseBand[q]])
			end
		end
		if o.Yield and j % (o.YieldEvery * 8) == 0 then
			o.Yield()
		end
	end

	return {
		fps = o.Fps, slots = K, frames = nfr, noise = ids, nN = nN, sampleRate = sr, length = len,
		F = F, A = A, V = V, VR = VR, P = P, stereo = stereo,
		stats = { births = births, bridged = bridged, evicted = evicted, pruned = pruned, tracks = nextId },
	}
end

-- plane layout of the raw payload (each plane is frames bytes per voice / band, voice-major):
--   amp (K)  noise (nN)  [noise right (nN)]  pitch low byte (K)  pitch high byte (K)  [pan (K)]
-- amp codes u8 (0 = off, else dB + 100); noise codes the same; pitch codes u16 (cents above C0);
-- pan codes u8 (0 = left .. 255 = right). All delta-coded per plane row (mod 256 / 65536).
local function planes(K, nN, nfr, stereo)
	local ch = stereo and 2 or 1
	local p = {}
	p.amp = 0
	p.noise = nfr * K
	p.noiseR = p.noise + nfr * nN
	p.lo = p.noise + nfr * nN * ch
	p.hi = p.lo + nfr * K
	p.pan = p.hi + nfr * K
	p.size = p.pan + (stereo and nfr * K or 0)
	return p
end

function Partials.pack(model, options)
	local o = merge(options)
	local K, nfr, nN = model.slots, model.frames, model.nN
	local stereo = model.stereo == true
	local pl = planes(K, nN, nfr, stereo)
	local raw = buffer.create(pl.size)
	local hysC, hysD = o.HysteresisCents, o.HysteresisDb
	local hysP = math.max(1, math.floor(o.PanHysteresis * 255 + 0.5))
	local active, writesF, writesA, panMoves = 0, 0, 0, 0
	for v = 0, K - 1 do
		local pf, pq, pp, lastF, lastA, lastP = 0, 0, 128, 0, 0, 0
		for j = 0, nfr - 1 do
			local i = (j * K + v) * 4
			local a = buffer.readf32(model.A, i)
			if a <= 1e-5 then
				pq = 0
			else
				active += 1
				local born = pq == 0
				local f = math.max(buffer.readf32(model.F, i), C0)
				local cents = math.floor(math.log(f / C0) / LOG2 * 1200 + 0.5)
				if born or math.abs(cents - pf) >= hysC then
					pf = math.clamp(cents, 0, 65535)
				end
				if stereo then
					local pc = math.clamp(math.floor(buffer.readf32(model.P, i) * 255 + 0.5), 0, 255)
					if born or math.abs(pc - pp) >= hysP then
						if not born and pc ~= pp then
							panMoves += 1
						end
						pp = pc
					end
				end
				local q = math.clamp(math.floor(20 * math.log10(a) + 100 + 0.5), 1, 255)
				if born or math.abs(q - pq) >= hysD then
					pq = q
				end
			end
			if pf ~= lastF then
				writesF += 1
			end
			if pq ~= lastA then
				writesA += 1
			end
			local df = (pf - lastF) % 65536
			buffer.writeu8(raw, pl.amp + v * nfr + j, (pq - lastA) % 256)
			buffer.writeu8(raw, pl.lo + v * nfr + j, df % 256)
			buffer.writeu8(raw, pl.hi + v * nfr + j, df // 256)
			if stereo then
				buffer.writeu8(raw, pl.pan + v * nfr + j, (pp - lastP) % 256)
				lastP = pp
			end
			lastF, lastA = pf, pq
		end
	end
	for side = 1, stereo and 2 or 1 do
		local src = side == 1 and model.V or model.VR
		local planeV = side == 1 and pl.noise or pl.noiseR
		for q = 0, nN - 1 do
			local pq, last = 0, 0
			for j = 0, nfr - 1 do
				local vol = buffer.readf32(src, (j * nN + q) * 4)
				if vol <= 1e-5 then
					pq = 0
				else
					local c = math.clamp(math.floor(20 * math.log10(vol) + 100 + 0.5), 1, 255)
					if pq == 0 or math.abs(c - pq) >= hysD then
						pq = c
					end
				end
				buffer.writeu8(raw, planeV + q * nfr + j, (pq - last) % 256)
				last = pq
			end
		end
	end
	local payload, flags = raw, 0
	if o.Compress and game then
		local ok, ES = pcall(game.GetService, game, "EncodingService")
		if ok and ES then
			local ok2, c = pcall(function()
				return ES:CompressBuffer(raw, Enum.CompressionAlgorithm.Zstd, 9)
			end)
			if ok2 and c then
				payload, flags = c, 1
			end
		end
	end
	if stereo then
		flags += 2
	end
	local header = Partials.HeaderSize + nN + 4
	local out = buffer.create(header + buffer.len(payload))
	buffer.writestring(out, 0, Partials.Magic)
	buffer.writeu8(out, 4, Partials.Version)
	buffer.writeu8(out, 5, model.fps)
	buffer.writeu8(out, 6, K)
	buffer.writeu8(out, 7, nN)
	buffer.writeu32(out, 8, nfr)
	buffer.writeu32(out, 12, model.sampleRate)
	buffer.writeu32(out, 16, model.length)
	buffer.writeu8(out, 20, WaveBank.Version)
	buffer.writeu8(out, 21, flags)
	for q = 1, nN do
		buffer.writeu8(out, Partials.HeaderSize + q - 1, model.noise[q])
	end
	buffer.writeu32(out, Partials.HeaderSize + nN, buffer.len(raw))
	buffer.copy(out, header, payload)
	local seconds = model.length / model.sampleRate
	return out, {
		seconds = seconds, bytes = buffer.len(out), rawBytes = buffer.len(raw), compressed = bit32.band(flags, 1) ~= 0,
		stereo = stereo, bytesPerSecond = buffer.len(out) / math.max(seconds, 1e-9),
		meanVoices = active / math.max(nfr, 1),
		speedWritesPerSecond = writesF / math.max(seconds, 1e-9), volumeWritesPerSecond = writesA / math.max(seconds, 1e-9),
		panMovesPerSecond = panMoves / math.max(seconds, 1e-9),
	}
end

function Partials.encode(signal, options)
	local t0 = os.clock()
	local model = Partials.analyze(signal, options)
	local bytes, stats = Partials.pack(model, options)
	for k, v in pairs(model.stats) do
		stats[k] = v
	end
	stats.encodeTime = os.clock() - t0
	stats.frames = model.frames
	return bytes, stats
end

function Partials.isClip(bytes)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return buffer.len(buf) >= 4 and buffer.readstring(buf, 0, 4) == Partials.Magic
end

-- decoded clip: per voice amp codes (u8) and pitch codes (u16), per band noise codes (u8), frame-major
-- for the player (all voices of a frame are adjacent)
function Partials.unpack(bytes)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not Partials.isClip(buf) then
		error("not an RBA3 clip")
	end
	local version = buffer.readu8(buf, 4)
	if version ~= Partials.Version then
		error("unsupported RBA3 version " .. version)
	end
	local fps, K, nN = buffer.readu8(buf, 5), buffer.readu8(buf, 6), buffer.readu8(buf, 7)
	local nfr = buffer.readu32(buf, 8)
	local flags = buffer.readu8(buf, 21)
	local noise = table.create(nN)
	for q = 1, nN do
		noise[q] = buffer.readu8(buf, Partials.HeaderSize + q - 1)
	end
	local stereo = bit32.band(flags, 2) ~= 0
	local rawLen = buffer.readu32(buf, Partials.HeaderSize + nN)
	local header = Partials.HeaderSize + nN + 4
	local payload = buffer.create(buffer.len(buf) - header)
	buffer.copy(payload, 0, buf, header)
	local raw = payload
	if bit32.band(flags, 1) ~= 0 then
		raw = game:GetService("EncodingService"):DecompressBuffer(payload, Enum.CompressionAlgorithm.Zstd)
	end
	local pl = planes(K, nN, nfr, stereo)
	if buffer.len(raw) ~= rawLen or rawLen ~= pl.size then
		error("RBA3 clip is truncated or corrupt")
	end
	local amp = buffer.create(nfr * K)
	local pitch = buffer.create(nfr * K * 2)
	local pan = stereo and buffer.create(nfr * K) or nil
	for v = 0, K - 1 do
		local a, f, p = 0, 0, 0
		for j = 0, nfr - 1 do
			a = (a + buffer.readu8(raw, pl.amp + v * nfr + j)) % 256
			f = (f + buffer.readu8(raw, pl.lo + v * nfr + j) + 256 * buffer.readu8(raw, pl.hi + v * nfr + j)) % 65536
			buffer.writeu8(amp, j * K + v, a)
			buffer.writeu16(pitch, (j * K + v) * 2, f)
			if stereo then
				p = (p + buffer.readu8(raw, pl.pan + v * nfr + j)) % 256
				buffer.writeu8(pan, j * K + v, p)
			end
		end
	end
	local function noisePlane(base)
		local nz = buffer.create(math.max(1, nfr * nN))
		for q = 0, nN - 1 do
			local a = 0
			for j = 0, nfr - 1 do
				a = (a + buffer.readu8(raw, base + q * nfr + j)) % 256
				buffer.writeu8(nz, j * nN + q, a)
			end
		end
		return nz
	end
	return {
		version = 3, fps = fps, slots = K, noise = noise, nN = nN, frameCount = nfr,
		sourceRate = buffer.readu32(buf, 12), sourceLength = buffer.readu32(buf, 16),
		bankVersion = buffer.readu8(buf, 20), duration = nfr / fps, stereo = stereo,
		amp = amp, pitch = pitch, pan = pan, nz = noisePlane(pl.noise), nzR = stereo and noisePlane(pl.noiseR) or nil,
	}
end

-- code -> linear amplitude (code 0 = silent)
local AMP = table.create(256, 0)
for q = 1, 255 do
	AMP[q + 1] = 10 ^ ((q - 100) / 20)
end
Partials.ampOf = function(code)
	return AMP[code + 1]
end
Partials.freqOf = function(code)
	return C0 * 2 ^ (code / 1200)
end

return Partials
