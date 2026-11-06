--!native
--!optimize 2
-- Offline renderer: plays an RBAC clip through the same waveform/noise definitions the
-- uploaded assets use, producing PCM. Used to check codec quality and to export a WAV you
-- can listen to before uploading anything. Mirrors the in-game Player's behaviour:
-- per-slot phase-continuous oscillators, linear interpolation of pitch/volume between
-- frames, crossfade when a slot changes waveform, range picked per pitch.
--
--   Renderer.render(clipOrBytes, { sampleRate = 44100 }) -> Signal (mono)

local AudioLab = script:FindFirstAncestor("AudioLab")
local Signal = require(AudioLab.DSP.Signal)
local WaveBank = require(AudioLab.Codec.WaveBank)
local Format = require(AudioLab.Codec.Format)

local Renderer = {}

function Renderer.render(clip, options)
	if typeof(clip) == "buffer" or type(clip) == "string" then
		clip = Format.unpack(clip)
	end
	options = options or {}
	local rate = options.sampleRate or WaveBank.AssetRate
	local fps = clip.fps
	local total = math.floor(clip.frameCount / fps * rate)
	local out = Signal.new(rate, 1, total)
	local dst = out.data[1]
	local slots, bands = clip.slots, clip.bands
	local yieldable = coroutine.isyieldable()

	local noise = {}
	for b = 1, bands do
		noise[b] = WaveBank.noiseLoop(b)
		if yieldable then
			task.wait()
		end
	end
	local noiseLen = WaveBank.NoiseLength
	local noiseStep = WaveBank.AssetRate / rate
	local cycleLen = WaveBank.CycleLength

	-- phases[slot][wave] in cycles, so a slot crossfading between waves keeps both continuous
	local phases = table.create(slots)
	for s = 1, slots do
		phases[s] = table.create(#WaveBank.Waves, 0)
	end

	local f0 = Format.readFrame(clip, 0)
	local f1 = Format.readFrame(clip, 1)
	local current = 0

	local function oscillate(s, wave, midi, vol, gainWeight)
		if wave == 0 or vol <= 0 or gainWeight <= 0 then
			return 0
		end
		local freq = Format.midiToFreq(midi)
		local tbl = WaveBank.cycle(wave, WaveBank.rangeFor(freq))
		local ph = phases[s][wave]
		local pos = ph * cycleLen
		local i = math.floor(pos)
		local frac = pos - i
		local v = tbl[i + 1] + (tbl[i + 2] - tbl[i + 1]) * frac
		ph += freq / rate
		phases[s][wave] = ph - math.floor(ph)
		return v * vol * gainWeight
	end

	for t = 0, total - 1 do
		local fpos = t / rate * fps
		local fi = math.floor(fpos)
		if fi ~= current then
			current = fi
			f0 = Format.readFrame(clip, fi, f0)
			f1 = Format.readFrame(clip, fi + 1, f1)
		end
		local a = fpos - fi
		local sample = 0
		for s = 1, slots do
			local w0, w1 = f0.waves[s], f1.waves[s]
			local v0, v1 = f0.volumes[s], f1.volumes[s]
			if w0 ~= 0 or w1 ~= 0 then
				if w0 == w1 then
					local midi = f0.pitches[s] + (f1.pitches[s] - f0.pitches[s]) * a
					sample += oscillate(s, w0, midi, v0 + (v1 - v0) * a, 1)
				else
					-- fade out the old wave, fade in the new one; a silent side holds the other's pitch
					local p0 = (w0 ~= 0) and f0.pitches[s] or f1.pitches[s]
					local p1 = (w1 ~= 0) and f1.pitches[s] or f0.pitches[s]
					sample += oscillate(s, w0, p0, v0, 1 - a)
					sample += oscillate(s, w1, p1, v1, a)
				end
			end
		end
		local npos = (t * noiseStep) % noiseLen
		local ni = math.floor(npos)
		for b = 1, bands do
			local vol = f0.bands[b] + (f1.bands[b] - f0.bands[b]) * a
			if vol > 0 then
				sample += noise[b][ni + 1] * vol
			end
		end
		buffer.writef32(dst, t * 4, sample)
		if yieldable and t % 32768 == 32767 then
			task.wait()
		end
	end
	return out
end

return Renderer
