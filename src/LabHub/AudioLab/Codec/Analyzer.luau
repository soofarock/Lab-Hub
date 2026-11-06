--!native
--!optimize 2
-- FFT analysis: turns PCM into control frames for the WaveBank synth.
--
-- Per frame (fps per second):
--   1. Windowed FFT, local maxima that stand well above their spectral neighbourhood
--      (tonal peaks), refined with parabolic interpolation.
--   2. Greedy harmonic grouping: strongest peak -> fundamental (checks sub-multiples),
--      collect harmonics k*f0, refine f0.
--   3. Waveform fit: least-squares match of the harmonic amplitudes against each
--      WaveBank wave's harmonic profile; volume = fitted gain / asset gain.
--   4. Residual (everything not explained by voices) -> octave noise-band levels.
--   5. Voices are assigned to slots so a slot keeps following the same sound
--      (keeps in-game Sounds continuous instead of hopping between instances).
--   6. Transient correction: the analysis window (~40-64 ms) smears sudden changes, so
--      each frame's levels are rescaled by short-window / long-window loudness when
--      they disagree strongly (boosts onsets, removes pre-echo before them).
-- Peak amplitudes are measured from the energy around the peak (main lobe), so tones
-- that sweep in pitch (energy spread over several bins) keep their full level.

local AudioLab = script:FindFirstAncestor("AudioLab")
local FFT = require(AudioLab.DSP.FFT)
local Signal = require(AudioLab.DSP.Signal)
local WaveBank = require(AudioLab.Codec.WaveBank)
local Format = require(AudioLab.Codec.Format)

local Analyzer = {}

Analyzer.Defaults = {
	fps = 60,
	slots = 8,
	minFreq = 40,
	maxFreq = 7040, -- top of WaveBank's highest range
	maxHarmonics = 32,
	tonalRatio = 3.7, -- peak must exceed its neighbourhood median magnitude by this factor
	maxPeaks = 48,
	absFloor = 1e-4, -- -80 dBFS sinusoid amplitude
	relFloorDb = -60, -- relative to the frame's strongest peak
	windowSeconds = 0.04,
	minVoiceVolume = 10 ^ (-66 / 20),
	transients = true,
	transientBoost = 1.4, -- apply correction when short/long loudness ratio exceeds this
	transientCut = 0.7, -- ... or falls below this
}

local function merge(options)
	local o = {}
	for k, v in pairs(Analyzer.Defaults) do
		o[k] = v
	end
	if options then
		for k, v in pairs(options) do
			o[k] = v
		end
	end
	return o
end

-- strongest unused peak within tol of f
local function findPeak(peaks, used, f, tol)
	local best, bestAmp = nil, -1
	for i, p in ipairs(peaks) do
		if not used[i] and math.abs(p.freq - f) <= tol and p.amp > bestAmp then
			best, bestAmp = i, p.amp
		end
	end
	return best
end

-- energyMatch: gain matches the harmonics' total energy instead of the least-squares projection
-- (keeps loudness right when the shape fits poorly; used for instrument presets).
local function fitWave(h, K, energyMatch)
	local hh = 0
	for k = 1, K do
		hh += h[k] * h[k]
	end
	local bestWave, bestGain, bestErr = 1, 0, math.huge
	for wi, wave in ipairs(WaveBank.Waves) do
		local t = WaveBank.profile(wi, K)
		local dot, tt = 0, 0
		for k = 1, K do
			dot += h[k] * t[k]
			tt += t[k] * t[k]
		end
		if tt > 0 then
			local g = math.max(0, dot / tt)
			local err = (hh - g * dot) / math.max(hh, 1e-20) + (wi - 1) * 1e-3 -- prefer simpler on ties
			if err < bestErr then
				if energyMatch then
					g = math.sqrt(hh / tt)
				end
				bestWave, bestGain, bestErr = wi, g / wave.gain, err
			end
		end
	end
	return bestWave, bestGain, bestErr, hh
end
Analyzer.fitWave = fitWave

-- Loudness ratio (short window around center) / (analysis window), as an amplitude factor.
local function transientGain(src, length, center, n, w, sumSq, shortHalf)
	local long = 0
	local start = center - n // 2
	for i = 1, n do
		local idx = start + i - 1
		if idx >= 0 and idx < length then
			local v = buffer.readf32(src, idx * 4) * w[i]
			long += v * v
		end
	end
	long /= sumSq
	local short, cnt = 0, 0
	for idx = math.max(0, center - shortHalf), math.min(length - 1, center + shortHalf) do
		local v = buffer.readf32(src, idx * 4)
		short += v * v
		cnt += 1
	end
	if cnt == 0 or long < 1e-12 then
		return (short > 1e-12) and 4 or 1
	end
	return math.sqrt((short / cnt) / long)
end

-- signal: Signal (any channel count). Returns clip table for Format.pack, plus stats.
function Analyzer.analyze(signal, options)
	local o = merge(options)
	local mono = Signal.toMono(signal)
	local sr = mono.sampleRate
	local n = math.max(256, FFT.nextPow2(sr * o.windowSeconds))
	local half = n // 2
	local hop = sr / o.fps
	local ws = FFT.windowStats("hann", n)
	local ampScale = 2 / ws.sum -- |X| -> sinusoid amplitude
	local powScale = 2 / (n * ws.sumSq) -- one-sided sum |X|^2 -> mean square
	local binHz = sr / n
	local nyq = sr / 2
	local maxF = math.min(o.maxFreq, nyq * 0.98)
	local relFloor = 10 ^ (o.relFloorDb / 20)

	-- noise band bin ranges (1-based magnitude indices)
	local bandRanges = {}
	for b = 1, WaveBank.CodecBands do
		local band = WaveBank.NoiseBands[b]
		local lo = math.max(2, math.ceil(band.low / binHz) + 1)
		local hi = math.min(half, math.floor(math.min(band.high, nyq) / binHz) + 1)
		bandRanges[b] = { lo, hi }
	end
	local bandCount = WaveBank.CodecBands

	local mags = table.create(half + 1, 0)
	local pow = table.create(half + 1, 0)
	local hood = table.create(28, 0)
	local frames = {}
	local prev = {} -- slot -> {wave, midi}
	local stats = { voiceFrames = 0, peakFrames = 0, maxVoices = 0, fitError = 0, fits = 0 }
	local yieldable = coroutine.isyieldable()
	local window = FFT.window("hann", n)
	local srcBuf = mono.data[1]
	local shortHalf = math.max(8, math.floor(hop * 0.75))
	stats.transientFrames = 0

	FFT.stft(mono, n, hop, "hann", function(frameIndex, re, im, center)
		FFT.magnitudes(re, im, mags)

		-- 1. tonal peaks
		local peaks = {}
		for i = 3, half do
			local v = mags[i]
			if v > mags[i - 1] and v >= mags[i + 1] and v * ampScale > o.absFloor then
				-- median of the neighbourhood (excluding the main lobe): robust to nearby
				-- strong peaks such as a fundamental next to a weak harmonic
				table.clear(hood)
				for j = math.max(2, i - 16), i - 3 do
					table.insert(hood, mags[j])
				end
				for j = i + 3, math.min(half + 1, i + 16) do
					table.insert(hood, mags[j])
				end
				local median = 0
				if #hood > 0 then
					table.sort(hood)
					median = hood[(#hood + 1) // 2]
				end
				if v >= o.tonalRatio * median then
					local a = math.log(mags[i - 1] + 1e-12)
					local b = math.log(v)
					local c = math.log(mags[i + 1] + 1e-12)
					local den = a - 2 * b + c
					local p = (den ~= 0) and math.clamp(0.5 * (a - c) / den, -0.5, 0.5) or 0
					local freq = (i - 1 + p) * binHz
					if freq >= o.minFreq and freq <= maxF then
						local ampPeak = math.exp(b - 0.25 * (a - c) * p) * ampScale
						local e = 0
						for j = math.max(2, i - 3), math.min(half, i + 3) do
							e += mags[j] * mags[j]
						end
						-- sinusoid of amplitude A has mean square A^2/2 = powScale * sum|X|^2 over its main lobe;
						-- cap so a close neighbour peak isn't counted twice
						local ampEnergy = math.sqrt(2 * powScale * e)
						table.insert(peaks, { freq = freq, amp = math.min(ampEnergy, ampPeak * 1.5), bin = i })
					end
				end
			end
		end
		table.sort(peaks, function(x, y)
			return x.amp > y.amp
		end)
		if #peaks > 0 then
			local floorAmp = peaks[1].amp * relFloor
			local keep = math.min(#peaks, o.maxPeaks)
			for i = 1, keep do
				if peaks[i].amp < floorAmp then
					keep = i - 1
					break
				end
			end
			for i = #peaks, keep + 1, -1 do
				peaks[i] = nil
			end
			stats.peakFrames += 1
		end

		-- 2 + 3. harmonic grouping and waveform fit
		local used = {}
		local voices = {}
		for ci, cand in ipairs(peaks) do
			if #voices >= o.slots then
				break
			end
			if not used[ci] then
				local f0 = cand.freq
				for d = 4, 2, -1 do
					local fc = cand.freq / d
					if fc >= o.minFreq then
						local tol = math.max(binHz * 0.75, fc * 0.02)
						local p1 = findPeak(peaks, used, fc, tol)
						if p1 and peaks[p1].amp >= 0.1 * cand.amp then
							local up = findPeak(peaks, used, fc * (d + 1), math.max(binHz * 0.75, fc * (d + 1) * 0.02))
							local down = (d - 1 >= 2) and findPeak(peaks, used, fc * (d - 1), math.max(binHz * 0.75, fc * (d - 1) * 0.02)) or nil
							if up or down then
								f0 = fc
								break
							end
						end
					end
				end

				local baseIndex = WaveBank.rangeFor(f0)
				local K = math.max(1, math.min(o.maxHarmonics, WaveBank.harmonicCount(baseIndex), math.floor(maxF / f0)))
				local h = table.create(K, 0)
				local wSum, fSum = 0, 0
				local estimate = f0
				for k = 1, K do
					local target = k * estimate
					if target > maxF then
						break
					end
					local pi = findPeak(peaks, used, target, math.max(binHz * 0.75, target * 0.02))
					if pi then
						local pk = peaks[pi]
						used[pi] = true
						h[k] = pk.amp
						local wgt = pk.amp * pk.amp
						wSum += wgt
						fSum += wgt * pk.freq / k
						estimate = fSum / wSum
					end
				end
				used[ci] = true
				if wSum > 0 then
					local wave, volume, err = fitWave(h, K)
					if volume >= o.minVoiceVolume then
						table.insert(voices, { wave = wave, freq = estimate, volume = volume, energy = wSum, err = err })
						stats.fitError += err
						stats.fits += 1
					end
				end
			end
		end

		-- 4. residual noise bands
		for i = 1, half + 1 do
			pow[i] = mags[i] * mags[i]
		end
		for i in pairs(used) do
			local bin = peaks[i].bin
			for j = math.max(1, bin - 3), math.min(half + 1, bin + 3) do
				pow[j] = 0
			end
		end
		local bandVols = table.create(bandCount, 0)
		for b = 1, bandCount do
			local r = bandRanges[b]
			local s = 0
			for j = r[1], r[2] do
				s += pow[j]
			end
			bandVols[b] = math.sqrt(powScale * s) / WaveBank.NoiseRms
		end

		-- 5. slot assignment (continuity)
		table.sort(voices, function(x, y)
			return x.energy > y.energy
		end)
		local assigned = {}
		local pending = {}
		for _, v in ipairs(voices) do
			v.midi = Format.freqToMidi(v.freq)
			local bestSlot, bestDiff = nil, 1.0
			for s = 1, o.slots do
				local pv = prev[s]
				if pv and not assigned[s] then
					local diff = math.abs(pv.midi - v.midi) + (pv.wave == v.wave and 0 or 0.5)
					if diff < bestDiff then
						bestSlot, bestDiff = s, diff
					end
				end
			end
			if bestSlot then
				assigned[bestSlot] = v
			else
				table.insert(pending, v)
			end
		end
		for _, v in ipairs(pending) do
			local slot = nil
			for s = 1, o.slots do -- prefer slots that were silent last frame
				if not assigned[s] and not prev[s] then
					slot = s
					break
				end
			end
			if not slot then
				for s = 1, o.slots do
					if not assigned[s] then
						slot = s
						break
					end
				end
			end
			if slot then
				assigned[slot] = v
			end
		end
		-- 6. transient correction
		local tg = 1
		if o.transients then
			local raw = transientGain(srcBuf, mono.length, center, n, window, ws.sumSq, shortHalf)
			if raw > o.transientBoost or raw < o.transientCut then
				tg = math.clamp(raw, 0.05, 4)
				stats.transientFrames += 1
				for b = 1, bandCount do
					bandVols[b] *= tg
				end
			end
		end

		local frameVoices = {}
		local newPrev = {}
		local count = 0
		for s, v in pairs(assigned) do
			frameVoices[s] = { wave = v.wave, freq = v.freq, volume = v.volume * tg }
			newPrev[s] = { wave = v.wave, midi = v.midi }
			count += 1
		end
		prev = newPrev
		stats.voiceFrames += count
		stats.maxVoices = math.max(stats.maxVoices, count)
		frames[frameIndex + 1] = { voices = frameVoices, bands = bandVols }

		if yieldable and frameIndex % 64 == 63 then
			task.wait()
		end
	end)

	-- trailing silent frame so playback fades out instead of holding the last frame
	table.insert(frames, { voices = {}, bands = table.create(bandCount, 0) })

	stats.frames = #frames
	stats.frameSize = n
	stats.meanVoices = stats.voiceFrames / #frames
	stats.meanFitError = stats.fits > 0 and stats.fitError / stats.fits or 0
	return {
		fps = o.fps, slots = o.slots, bands = bandCount, sourceRate = sr, sourceLength = mono.length,
		bankVersion = WaveBank.Version, frames = frames,
	}, stats
end

return Analyzer
