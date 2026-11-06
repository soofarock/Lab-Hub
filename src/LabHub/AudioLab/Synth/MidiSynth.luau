--!optimize 2
-- Real-time MIDI synthesizer and sequencer on the WaveBank voice pool.
--
--   local synth = MidiSynth.new({
--       Parent = SoundService,      -- where the voice folder goes
--       Voices = 48,                -- polyphony (default 48 with a Bank/SoundFont, else 24)
--       MasterGain = 1,
--       Bank = bakedBank,           -- from Assets.bank / Importer.loadBank (preferred: no SF2 decoding)
--       SoundFont = sf,             -- or a decoded SF2 (Sf2.decode); analysed lazily per sample
--       Mode = "additive",          -- "additive" (default with Bank/SoundFont) or "wave" (one waveform)
--       Partials = 10,              -- max sine voices per note (default: the most any baked sample uses)
--       DrumChannel = 9,            -- synthesized kit channel; default nil with Bank/SoundFont, false = none
--       DeviceOutput = true,        -- false: don't play to the speakers (e.g. when wiring to an AudioEmitter)
--       Stereo = true,              -- channel pan (CC10); default on unless DeviceOutput = false (3D emitters are mono)
--       MaxPlayers = 192,           -- most players sounding at once; the quietest parts are dropped first
--       BankSelect = "mma",         -- how CC0/CC32 pick the SoundFont bank: "mma" (MSB*128+LSB, falls back to
--                                   -- MSB then LSB), "gs" (MSB only) or "xg" (LSB only)
--   })
--   synth:play(midiBytesOrDecoded, { Loop = false, Speed = 1, StartTime = 0 })
--       Loop = true repeats the region between loop markers ("LOOP_START"/"LOOP_END", "loopStart"/
--       "loopEnd" as marker or text meta events, or CC 111 for the start), else the whole song.
--   synth.Ended:Connect(...)            -- fires when a non-looping song finishes
--   synth:noteOn(ch, key, vel) / noteOff(ch, key) / controlChange(ch, cc, value)
--   synth:programChange(ch, program) / pitchBend(ch, value)   -- value -8192..8191
--   synth:pause(), synth:resume(), synth:seek(seconds), synth:getTime(), synth:getDuration()
--   synth:setMute(ch, bool), synth:setSolo(ch, bool), synth.activity[ch] (0..1, for meters)
--   synth:stop(), synth:destroy()
--   synth.pool.output                   -- AudioFader carrying the mix
--
-- Envelopes follow SoundFont semantics: delay, linear attack, hold, decay and release as the time
-- for a fall of 96 dB, sustain as a level. Additive notes follow the analysed sample in its own clock
-- (faster for higher keys, as a sample player would), with the envelope on top.

local RunService = game:GetService("RunService")
local AudioLab = script:FindFirstAncestor("AudioLab")
local OscillatorPool = require(AudioLab.Synth.OscillatorPool)
local Instruments = require(AudioLab.Synth.Instruments)
local WaveBank = require(AudioLab.Codec.WaveBank)
local Midi = require(AudioLab.Formats.Midi)
-- Synth.SourceFilter (kept inside this module)
local SourceFilter = (function()
-- Source-filter voices for sustained, voice-like samples (a sung "ah").
--
-- The additive engine rebuilds such a note from 17-29 sine players. Each one is a separate player the engine starts,
-- times and steps on its own, and their sum is heard as "mixed" rather than one voice. Here a note is how a voice is
-- made: one source and a vocal tract.
--   * a band-limited saw loop (WaveBank wave_saw_<base>) at the note's pitch: every harmonic in one waveform, so they
--     stay locked together
--   * the pink-noise loop (pink_noise) for the breath between and above the harmonics
--   * 8 AudioFilters, moved every block along the sample's baked frames (a.sf, baked from the SoundFont sample):
--     a formant cascade (LowShelf, 4 Peaks, HighShelf) shared by both sources (filters 1..npre on the saw only), and a
--     tilt for the noise (Highpass24, HighShelf) before it joins
-- 2 players + 8 filters per note, created once per voice and reused (no instances made or destroyed while playing).
--
-- AudioFilter is the RBJ cookbook biquad (Lowpass/Highpass 24 = two Butterworth sections),
-- a new setting takes effect from the next audio block and the coefficients glide to it over ~27 ms without clicks.
-- So filters are written for the END of the coming block (the glide is then mostly done in it) and a note's filters are
-- set to its first frame before its volume rises.
--
--   local sf = SourceFilter.new(pool)             -- pool: OscillatorPool (output / buses)
--   local h = sf:start(a, speed, bus, tau0)       -- a voice for one note; nil when every voice is busy (the caller plays
--                                                 -- the note another way)
--   sf:update(h, tauC, tauF, speed, bendR, gain)  -- sample times: block centre (levels, pitch) and block end (filters)
--   sf:free(h), sf:sweep(), sf:stopAll(), sf:destroy()
--   SourceFilter.frame(a.sf, tau, out) -> out         -- the interpolated frame (pure)
--
-- AudioLab attribute SourceFilter = false plays these samples on the additive engine instead.

local Base64 = require(AudioLab.Util.Base64)

local SourceFilter = {}
SourceFilter.__index = SourceFilter

SourceFilter.MaxVoices = 8
SourceFilter.IdleStop = 20 -- seconds a free voice's players keep running (a cold player is late on its first block)
local SAW_BASES = { 55, 220, 880, 3520 }
local MAX_SPEED = 2
local FILTERS = 8

-- decoded frames per a.sf: columns already in their final units
--   f0 = ratio to f0ref, gs / gn = linear gains (gain calibration included), filter f = Hz, g = dB, q = q
local decoded = setmetatable({}, { __mode = "k" })
local function decode(sf)
	local d = decoded[sf]
	if d then
		return d
	end
	local raw = Base64.decode(sf.data)
	local cols, nfr = sf.cols, sf.nfr
	local nc = #cols
	-- column -> (filter, field) and the stored value's unit
	local kind, target, field = table.create(nc), table.create(nc), table.create(nc)
	for c, name in ipairs(cols) do
		if name == "f0" or name == "gs" or name == "gn" then
			kind[c] = name
		else
			local i, p = string.match(name, "^(%d+):(%a)$")
			kind[c], target[c], field[c] = p, tonumber(i), p
		end
	end
	local data = table.create(nfr * nc)
	for j = 0, nfr - 1 do
		for c = 1, nc do
			data[j * nc + c] = buffer.readi16(raw, (j * nc + c - 1) * 2)
		end
	end
	d = { nc = nc, nfr = nfr, kind = kind, target = target, field = field, data = data, gainDb = sf.gain or 0 }
	decoded[sf] = d
	return d
end

-- sample time -> fractional frame (a looped sample repeats the baked second pass of its loop)
local function framePos(sf, d, tau)
	local ls, le = sf.ls, sf.le
	if ls and le and le > ls and tau >= ls then
		local L = le - ls
		tau = ls + L + (tau - ls) % L
	end
	return math.clamp(tau / sf.hop, 0, d.nfr - 1)
end

-- out = { f0 = ratio, gs, gn = linear, f = {..}, g = {..}, q = {..} } for the frame at sample time tau
function SourceFilter.frame(sf, tau, out)
	local d = decode(sf)
	out = out or {}
	out.f, out.g, out.q = out.f or table.create(FILTERS), out.g or table.create(FILTERS), out.q or table.create(FILTERS)
	local fx = sf.fixed
	for i = 1, #sf.types do
		out.f[i], out.g[i], out.q[i] = fx[i].f, fx[i].g, fx[i].q
	end
	local x = framePos(sf, d, tau)
	local j = math.floor(x)
	local a = x - j
	local j2 = math.min(j + 1, d.nfr - 1)
	local nc, data = d.nc, d.data
	for c = 1, nc do
		local v0, v1 = data[j * nc + c], data[j2 * nc + c]
		local v = v0 + (v1 - v0) * a
		local k = d.kind[c]
		if k == "f0" then
			out.f0 = 2 ^ (v / 4800)
		elseif k == "gs" then
			out.gs = 10 ^ ((v / 100 + d.gainDb) / 20)
		elseif k == "gn" then
			out.gn = 10 ^ ((v / 100 + d.gainDb) / 20)
		elseif k == "f" then
			out.f[d.target[c]] = 2 ^ (v / 1000)
		elseif k == "g" then
			out.g[d.target[c]] = v / 100
		else
			out.q[d.target[c]] = 2 ^ (v / 1000)
		end
	end
	return out
end

-- lowest saw base that reaches f within MAX_SPEED (the most harmonics below Nyquist)
function SourceFilter.sawBase(f)
	for _, b in ipairs(SAW_BASES) do
		if f / b <= MAX_SPEED then
			return b
		end
	end
	return SAW_BASES[#SAW_BASES]
end

local function wire(parent, from, to)
	local w = Instance.new("Wire")
	w.SourceInstance = from
	w.TargetInstance = to
	w.Parent = parent
	return w
end

function SourceFilter.new(pool)
	local self = setmetatable({}, SourceFilter)
	self.pool = pool
	self.folder = Instance.new("Folder")
	self.folder.Name = "SourceFilter"
	self.folder.Parent = pool.folder
	self.voices = {}
	self.tmp = {}
	self.clock = 0
	return self
end

function SourceFilter:_newVoice()
	local f = Instance.new("Folder")
	f.Name = "SF" .. (#self.voices + 1)
	local filters = table.create(FILTERS)
	for i = 1, FILTERS do
		local ft = Instance.new("AudioFilter")
		ft.Name = "F" .. i
		ft.Parent = f
		filters[i] = ft
	end
	local noise = Instance.new("AudioPlayer")
	noise.Name = "Pink"
	noise.Looping = true
	noise.Volume = 0
	noise.Parent = f
	local vc = {
		folder = f, filters = filters, noise = noise, saws = {}, busy = false, idleAt = 0,
		noiseIn = wire(f, noise, filters[7]), -- pink -> noise chain (7, 8) -> the formant chain at npre + 1
		noiseChain = wire(f, filters[7], filters[8]),
		join = wire(f, filters[8], filters[1]),
		out = wire(f, filters[6], self.pool.output),
		chain = {},
	}
	for i = 1, 5 do
		vc.chain[i] = wire(f, filters[i], filters[i + 1])
	end
	f.Parent = self.folder
	table.insert(self.voices, vc)
	return vc
end

function SourceFilter:_saw(vc, base)
	local p = vc.saws[base]
	if not p then
		p = Instance.new("AudioPlayer")
		p.Name = "Saw" .. base
		p.Looping = true
		p.Volume = 0
		p.Asset = WaveBank.Assets[("wave_saw_%d"):format(base)] or ""
		wire(vc.folder, p, vc.filters[1])
		p.Parent = vc.folder
		vc.saws[base] = p
	end
	return p
end

-- sets a voice's filter types and routing for one sample, and every filter to the frame at tau (speed: formant scale)
function SourceFilter:_route(vc, sf)
	if vc.routed == sf then
		return
	end
	vc.routed = sf
	-- the layout baked for every sample: formant filters 1-6, noise filters 7-8
	local types = sf.types
	assert(#types == FILTERS and (sf.nh or 6) == 6, "SourceFilter: unsupported filter layout")
	for i = 1, FILTERS do
		vc.filters[i].FilterType = Enum.AudioFilterType[types[i]]
	end
	vc.join.TargetInstance = vc.filters[(sf.npre or 0) + 1]
end

function SourceFilter:_setFilters(vc, fr, speed)
	local nt = #vc.routed.types
	for i = 1, nt do
		local ft = vc.filters[i]
		local f = math.clamp(fr.f[i] * speed, 20, 20000)
		if ft.Frequency ~= f then
			ft.Frequency = f
		end
		local g = math.clamp(fr.g[i], -30, 30)
		if ft.Gain ~= g then
			ft.Gain = g
		end
		local q = math.clamp(fr.q[i], 0.1, 10)
		if ft.Q ~= q then
			ft.Q = q
		end
	end
end

-- a voice for one note, or nil when all are busy. bus: OscillatorPool bus number (the channel's pan), or nil
function SourceFilter:start(a, speed, bus, tau0)
	local sf = a.sf
	local best
	for _, vc in ipairs(self.voices) do
		if not vc.busy then
			-- prefer the voice that last played this sample at this speed: its filters are already where the note starts
			if vc.routed == sf and vc.speed == speed then
				best = vc
				break
			end
			best = best or vc
		end
	end
	if not best then
		if #self.voices >= SourceFilter.MaxVoices then
			return nil
		end
		best = self:_newVoice()
	end
	local vc = best
	vc.busy = true
	self:_route(vc, sf)
	local fr = SourceFilter.frame(sf, tau0 or 0, self.tmp)
	local base = SourceFilter.sawBase(sf.f0ref * fr.f0 * speed)
	vc.base, vc.speed = base, speed
	self:_setFilters(vc, fr, speed)
	local target = self.pool.output
	if self.pool.stereo and self.pool.buses then
		local b = self.pool.buses[bus or 1] or self.pool.buses[1]
		target = b and b.input or target
	end
	if vc.out.TargetInstance ~= target then
		vc.out.TargetInstance = target
	end
	local saw = self:_saw(vc, base)
	for b, p in pairs(vc.saws) do
		if b ~= base and p.Volume ~= 0 then
			p.Volume = 0
		end
	end
	saw.Volume = 0
	saw.PlaybackSpeed = math.clamp(sf.f0ref * fr.f0 * speed / base, 0.05, MAX_SPEED * 1.05)
	if not saw.IsPlaying then
		saw:Play()
	end
	local nz = vc.noise
	if nz.Asset == "" then
		nz.Asset = WaveBank.Assets.pink_noise or ""
	end
	nz.Volume = 0
	if not nz.IsPlaying then
		nz.TimePosition = math.random() * 2.5 -- every voice its own stretch of the loop (equal noise would comb)
		nz:Play()
	end
	return vc
end

-- tauC: sample time at the middle of the block this write plays in (levels, pitch); tauF: at its end (filters)
-- gain: the note's linear gain (envelope x channel x velocity x master); bendR: pitch-bend ratio
function SourceFilter:update(vc, tauC, tauF, speed, bendR, gain)
	local sf = vc.routed
	local fr = SourceFilter.frame(sf, tauC, self.tmp)
	local saw = vc.saws[vc.base]
	local sp = math.clamp(sf.f0ref * fr.f0 * speed * bendR / vc.base, 0.05, MAX_SPEED * 1.05)
	if saw.PlaybackSpeed ~= sp then
		saw.PlaybackSpeed = sp
	end
	saw.Volume = fr.gs * gain
	vc.noise.Volume = fr.gn * gain
	fr = SourceFilter.frame(sf, tauF, self.tmp)
	self:_setFilters(vc, fr, speed)
end

-- the note is over: silent, and its filters go back to the onset frame of the same sample (the likeliest next note)
function SourceFilter:free(vc)
	if not vc or not vc.busy then
		return
	end
	vc.busy = false
	vc.idleAt = os.clock()
	for _, p in pairs(vc.saws) do
		p.Volume = 0
	end
	vc.noise.Volume = 0
	local sf = vc.routed
	if sf then
		task.delay(0.05, function()
			-- (after the release block has been played with the note's own filters)
			if not vc.busy and vc.routed == sf and vc.folder.Parent then
				self:_setFilters(vc, SourceFilter.frame(sf, 0, {}), vc.speed or 1)
			end
		end)
	end
end

-- stops the players of voices free for longer than IdleStop (call now and then)
function SourceFilter:sweep()
	local now = os.clock()
	for _, vc in ipairs(self.voices) do
		if not vc.busy and now - vc.idleAt > SourceFilter.IdleStop then
			for _, p in pairs(vc.saws) do
				if p.IsPlaying then
					p:Stop()
				end
			end
			if vc.noise.IsPlaying then
				vc.noise:Stop()
			end
		end
	end
end

function SourceFilter:stopAll()
	for _, vc in ipairs(self.voices) do
		self:free(vc)
		for _, p in pairs(vc.saws) do
			p:Stop()
		end
		vc.noise:Stop()
	end
end

function SourceFilter:destroy()
	self.voices = {}
	self.folder:Destroy()
end

return SourceFilter
end)()

local MidiSynth = {}
MidiSynth.__index = MidiSynth

local DEFAULT_DRUM_CHANNEL = 9
local SILENT = 1e-3
local FLOOR_DB = 96
local END_DB = 60 -- voices below -60 dB are freed
local SINE = Instruments.WaveIndex.sine
local SINE_GAIN = WaveBank.Waves[SINE].gain
local LOOKAHEAD = 0 -- seconds: note-ons prepared this early so every part starts on time and in phase (0 = off: restarting players to align phases stutters)
-- mix headroom: keeps loud songs under full scale, so the limiter only catches rare peaks, as in a SoundFont player.
local USE_RESIDUAL = true -- breath / consonant noise of pitched samples through the noise bands: without it vocal-type samples lose 3-9 dB above 2.5 kHz
-- -4.5 dB: the SoundFont centre pan law (a centred part is -3 dB per ear) plus room so the limiter rarely engages
-- (pumping, crushed bass).
local HEADROOM = 10 ^ (-4.5 / 20)
-- The engine reads a player's volume once per audio block (1024 samples, ~21 ms) and holds it for the whole block;
-- a write lands on the next block boundary. A one-shot's level at the instant of the write is the wrong value for that:
-- the first block of a note would play the t = 0 analysis frame (10-20 dB under the strike), so struck notes would
-- start soft and ~20 ms late, then jump up. Each write is the part's RMS level over
-- the block it will actually play in (sample time from the block clock), taken at BLOCK_TAPS points.
local BLOCK_AVG = true -- also for voice samples (attribute VoiceBlockAvg = false turns that off)
local BLOCK_TAPS = 4
local NOISE_TAPS = 6 -- taps per block for the analysed noise samples' block RMS
local MAX_PARTIAL_HZ = 17500 -- sine loops are pure, so they can be sped up this far without aliasing (880 Hz x 20 = 17.6 kHz, Roblox's speed limit)
local GROUP_COUNT = #WaveBank.BundleGroups
local BUNDLE_AMP = WaveBank.BundleRms * math.sqrt(2) -- sine-equivalent amplitude of a bundle at volume 1
local CHAIN = WaveBank.NoiseChain
local CHAIN_N = #CHAIN

local function newChannel()
	return {
		program = 0, bankMsb = 0, bankLsb = 0, volume = 100, expression = 127, pan = 64,
		bend = 0, bendRange = 2, sustain = false, rpnMsb = 127, rpnLsb = 127,
	}
end

-- Velocity, channel volume (CC7) and expression (CC11) scale the amplitude linearly (value / 127). 
-- (The General MIDI square law, 40 * log10, would be 3-5 dB off wherever channel volumes differ.)
local function curve(v)
	return v / 127
end
-- Channel volume (CC7) and expression (CC11): square law. A song fades out by stepping CC7 down to ~9; with the linear
-- curve that only reached -23 dB (the fade never finished), the original goes silent (-46 dB). Velocity stays linear.
local function ccCurve(v)
	return (v / 127) ^ 2
end

function MidiSynth.new(config)
	config = config or {}
	local self = setmetatable({}, MidiSynth)
	self.bank = config.Bank
	self.soundFont = config.SoundFont
	local hasInstruments = self.bank ~= nil or self.soundFont ~= nil
	-- SoundFont songs (long releases, many channels) need more polyphony: a long SoundFont song peaked at 36 notes
	self.voiceCount = config.Voices or (hasInstruments and 48 or 24)
	self.masterGain = config.MasterGain or 1 -- full SoundFont level; the pool's limiter catches peaks
	self.mode = config.Mode or (hasInstruments and "additive" or "wave")
	local maxPartials = Instruments.Defaults.Partials
	if self.bank and self.bank.samples then
		maxPartials = 1
		for _, a in pairs(self.bank.samples) do
			maxPartials = math.max(maxPartials, a.partials and #a.partials or 1)
		end
	end
	-- slots per voice: the sines (8, or more for older banks), one per harmonic bundle group, then the modes
	local maxModes = 0
	if self.bank and self.bank.samples then
		for _, a in pairs(self.bank.samples) do
			maxModes = math.max(maxModes, a.modes and #a.modes or 0)
		end
	end
	self.sineSlots = math.max(maxPartials, WaveBank.Sines)
	self.modeSlots = (self.mode == "additive") and maxModes or 0
	self.partials = (self.mode == "additive") and (self.sineSlots + GROUP_COUNT + self.modeSlots) or 1
	self.instrumentOptions = { Mode = self.mode, Partials = self.partials }
	-- slots per voice: the parts above, then one per fine harmonic group (WaveBank.FineGroups; used instead of the octave bundles
	-- when the harmonics pack is in the manifest)
	self.stride = self.partials + ((self.mode == "additive") and #WaveBank.FineGroups or 0)
	-- then one rough-sine partner per harmonic of the voice samples that have roughness frames (a.rough)
	local maxRough = 0
	if self.mode == "additive" and self.bank and self.bank.samples then
		for _, a in pairs(self.bank.samples) do
			if a.rough and a.rough[1] then
				maxRough = math.max(maxRough, #a.rough[1])
			end
		end
	end
	self.roughSlots = math.min(maxRough, 10) -- harmonics above 10 carry very little roughness
	self.roughBase = self.stride
	self.stride += self.roughSlots
	self.bankSelect = config.BankSelect or "mma"
	-- most parts sounding at once: 3/4 of the device's player limit (OscillatorPool.playerLimit: 320 -> 240 on computers,
	-- 128 -> 96 on phones), the rest is headroom for parts fading out and idle players; the quietest parts drop first
	local limit = OscillatorPool.playerLimit()
	self.maxPlayers = config.MaxPlayers or math.floor(limit * 0.75)
	self.prewarm = config.Prewarm
	if config.DrumChannel == false then
		self.drumChannel = nil
	elseif config.DrumChannel ~= nil then
		self.drumChannel = config.DrumChannel
	else
		self.drumChannel = (not hasInstruments) and DEFAULT_DRUM_CHANNEL or nil
	end
	local stereo = config.Stereo
	if stereo == nil then
		stereo = config.DeviceOutput ~= false
	end
	self.pool = OscillatorPool.new({
		Parent = config.Parent, Slots = self.voiceCount * self.stride, Bands = #WaveBank.NoiseBands,
		Smoothing = 300, AttackSmoothing = 2000, MasterGain = 1, BandsWarm = true, PhaseReset = true,
		Name = config.Name or "MidiSynth", DeviceOutput = config.DeviceOutput,
		Stereo = stereo, Buses = 16,
		-- idle players stay running (silent) 20 s and up to 256 of them: stopping them sooner makes busy passages
		-- restart dozens of players in one frame when they come back (their notes lose the start: stutter)
		-- (every running player costs the audio engine, silent or not: the reserve is a quarter of the player limit)
		WarmReserve = config.WarmReserve or math.floor(limit / 4), IdleStop = config.IdleStop or 20,
	})
	self.stereo = stereo
	self.baseWarmReserve, self.baseIdleStop = config.WarmReserve or math.floor(limit / 4), config.IdleStop or 20
	self.channels = {}
	for c = 0, 15 do
		self.channels[c] = newChannel()
	end
	self.voices = {}
	for v = 1, self.voiceCount do
		self.voices[v] = { active = false, slot = (v - 1) * self.stride + 1, amps = {} }
	end
	self.noiseHits = {}
	self.bandLevels = table.create(#WaveBank.NoiseBands, 0)
	self.clock = 0
	self._ended = Instance.new("BindableEvent")
	self.Ended = self._ended.Event
	self.stats = { notes = 0, stolen = 0, drums = 0 }
	self.missingWarned = {}
	self.muted, self.solo, self.activity = {}, {}, {}
	for c = 0, 15 do
		self.activity[c] = 0
	end
	return self
end

function MidiSynth:_audible(ch)
	if self.muted[ch] then
		return false
	end
	if next(self.solo) ~= nil then
		return self.solo[ch] == true
	end
	return true
end

function MidiSynth:setMute(ch, on)
	self.muted[ch] = on and true or nil
	if on then
		self:allNotesOff(ch, true)
	end
end

function MidiSynth:setSolo(ch, on)
	self.solo[ch] = on and true or nil
	for c = 0, 15 do
		if not self:_audible(c) then
			self:allNotesOff(c, true)
		end
	end
end

-- candidate SoundFont bank numbers for a channel, most specific first
function MidiSynth:_banks(c)
	local style = self.bankSelect
	if style == "gs" then
		return { c.bankMsb }
	elseif style == "xg" then
		return { c.bankLsb }
	end
	local list = { c.bankMsb * 128 + c.bankLsb }
	if c.bankLsb ~= 0 then
		table.insert(list, c.bankMsb)
		if c.bankMsb == 0 then
			list[1] = c.bankLsb
		else
			table.insert(list, c.bankLsb)
		end
	end
	return list
end

function MidiSynth:_preset(ch, key, velocity)
	local c = self.channels[ch]
	local p = nil
	if not (self.bank or self.soundFont) then
		return Instruments.gm(c.program)
	end
	local banks = self:_banks(c)
	for _, b in ipairs(banks) do
		if self.bank then
			p = Instruments.fromBank(self.bank, b, c.program, key, velocity, self.instrumentOptions)
		else
			p = Instruments.fromSoundFont(self.soundFont, b, c.program, key, velocity, self.instrumentOptions)
		end
		if p then
			return p
		end
	end
	local mk = banks[1] * 128 + c.program
	if not self.missingWarned[mk] then
		self.missingWarned[mk] = true
		local al = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
		if al and al:GetAttribute("Debug") == true then -- (a debug note: the fallback is fine)
			warn(("[AudioLab] no instrument for bank %d program %d (key %d); using the General MIDI preset"):format(banks[1], c.program, key))
		end
	end
	return Instruments.gm(c.program)
end

function MidiSynth:_silenceVoice(v)
	for i = 0, self.stride - 1 do
		self.pool:setVoice(v.slot + i, 0, 0, 0)
	end
	v.ron = nil
	if v.sfv then
		self.sf:free(v.sfv)
		v.sfv = nil
	end
end

function MidiSynth:_allocate()
	local best, bestScore = nil, math.huge
	for _, v in ipairs(self.voices) do
		if not v.active then
			return v
		end
		local score = (v.stage == "release" and 0 or 10) + v.level + v.startClock * 1e-6
		if score < bestScore then
			best, bestScore = v, score
		end
	end
	self.stats.stolen += 1
	self:_silenceVoice(best)
	return best
end

function MidiSynth:_start(v, fields)
	local slot, amps = v.slot, v.amps
	table.clear(v)
	v.slot, v.amps = slot, amps
	for k, val in pairs(fields) do
		v[k] = val
	end
	v.active = true
	v.level = 0
	v.atten = 0
	v.age = 0
	v.sampleTime = 0
	v.ph, v.fq, v.on = nil, nil, nil -- phase-steered parts start from the sample's own phase
	v.son, v.bon, v.pOff = nil, nil, nil
	v.pv, v.pvMax, v.pvTop, v.amps1, v.nextB, v.bS = nil, nil, nil, nil, nil, nil
	v.prange = nil
	v.stageTime = 0
	v.stage = ((v.preset.delay or 0) > 0) and "delay" or "attack"
	v.startClock = self.clock
	v.fresh = true -- first rendered frame starts at sample time 0 (don't skip the attack)
end

function MidiSynth:noteOn(ch, key, velocity, gate)
	if velocity <= 0 then
		return self:noteOff(ch, key)
	end
	if not self:_audible(ch) then
		return
	end
	self.activity[ch] = math.max(self.activity[ch] or 0, velocity / 127)
	local c = self.channels[ch]
	local velGain = curve(velocity)
	if ch == self.drumChannel then
		local spec = Instruments.drum(key)
		self.stats.drums += 1
		if spec.noise then
			table.insert(self.noiseHits, { kit = spec.noise, age = 0, gain = velGain, fresh = true, pan = c.pan / 127, channel = ch })
		end
		if spec.tone then
			local t = spec.tone
			self:_start(self:_allocate(), {
				channel = ch, key = key, velGain = velGain, drum = t,
				preset = { wave = t.wave, gain = t.gain, attack = 0.001, decay = t.decay * 2.2, sustain = 0, release = 0.06 },
			})
		end
		return
	end
	local preset = self:_preset(ch, key, velocity)
	self.stats.notes += 1
	-- SoundFont noise samples are ordinary voices (no pool slots): the envelope, note-off and release
	-- apply exactly as for tonal notes
	-- gate: seconds until the note should sound (sequencer lookahead); its players start silently now
	-- volume and expression are read when the note starts
	self:_start(self:_allocate(), { channel = ch, key = key, velGain = velGain, preset = preset, gate = (gate and gate > 0) and gate or nil, vol = c.volume, expr = c.expression })
end

-- Releases the oldest sounding voice for (ch, key). Overlapping notes on the same key are common
-- (legato re-strikes); releasing every match would cut the newer note short.
function MidiSynth:noteOff(ch, key)
	local c = self.channels[ch]
	local oldest = nil
	for _, v in ipairs(self.voices) do
		if v.active and v.channel == ch and v.key == key and v.stage ~= "release" and not v.held and not v.relPending then
			if not oldest or v.startClock < oldest.startClock then
				oldest = v
			end
		end
	end
	if oldest then
		if c.sustain then
			oldest.held = true
		elseif oldest.fresh then
			-- not rendered yet (a note shorter than a block starts and ends in the same step): it sounds for its first
			-- block before the release begins, otherwise it would release from level 0 and never be heard (snare rolls)
			oldest.relPending = true
		else
			oldest.stage = "release"
		end
	end
end

function MidiSynth:_releaseHeld(ch)
	for _, v in ipairs(self.voices) do
		if v.active and v.channel == ch and v.held then
			v.held = nil
			v.stage = "release"
		end
	end
end

function MidiSynth:allNotesOff(ch, immediate)
	for _, v in ipairs(self.voices) do
		if v.active and (ch == nil or v.channel == ch) then
			if immediate then
				v.active = false
				self:_silenceVoice(v)
			else
				v.held = nil
				v.stage = "release"
			end
		end
	end
	if immediate then
		for i = #self.noiseHits, 1, -1 do
			if ch == nil or self.noiseHits[i].channel == ch then
				table.remove(self.noiseHits, i)
			end
		end
	end
end

function MidiSynth:controlChange(ch, cc, value)
	local c = self.channels[ch]
	if cc == 0 then
		c.bankMsb = value
	elseif cc == 32 then
		c.bankLsb = value
	elseif cc == 7 then
		c.volume = value
	elseif cc == 10 then
		c.pan = value
		self.pool:setBusPan(ch + 1, value / 127)
	elseif cc == 11 then
		c.expression = value
	elseif cc == 64 then
		local on = value >= 64
		if c.sustain and not on then
			c.sustain = false
			self:_releaseHeld(ch)
		end
		c.sustain = on
	elseif cc == 101 then
		c.rpnMsb = value
	elseif cc == 100 then
		c.rpnLsb = value
	elseif cc == 6 then
		if c.rpnMsb == 0 and c.rpnLsb == 0 then
			c.bendRange = value
		end
	elseif cc == 120 then
		self:allNotesOff(ch, true)
	elseif cc == 123 then
		self:allNotesOff(ch, false)
	elseif cc == 121 then
		local keepProgram, keepBank = c.program, c.bankMsb
		self.channels[ch] = newChannel()
		self.channels[ch].program, self.channels[ch].bankMsb = keepProgram, keepBank
	end
end

function MidiSynth:programChange(ch, program)
	self.channels[ch].program = program
end

-- Pitch bend arrives as a staircase: vocal channels often send a bend event every ~36 ms, ~16 cents apart. Applied as
-- instant steps they are heard as a blocky glide on a near-pure vocal tone. Bends that follow each other closely (within
-- BEND_GAP) and are small (within BEND_SNAP semitones) are ramped over BEND_RAMP seconds instead; a new gesture, a big jump
-- (a scoop, a reset) or a seek is applied at once. Attribute BendRamp (seconds; 0 = off) on the AudioLab module overrides it.
local BEND_RAMP = 0.04
local BEND_GAP = 0.15
local BEND_SNAP = 0.5

function MidiSynth:pitchBend(ch, value)
	local c = self.channels[ch]
	local target = value / 8192
	local ramp = script.Parent.Parent:GetAttribute("BendRamp") or BEND_RAMP
	if ramp > 0 and self.playing and c.bendAt and (self.time or 0) - c.bendAt < BEND_GAP and (self.time or 0) >= c.bendAt
		and math.abs(target - c.bend) * c.bendRange <= BEND_SNAP then
		c.bendTarget = target
		c.bendRate = math.abs(target - c.bend) / ramp
	else
		c.bend, c.bendTarget = target, nil
	end
	c.bendAt = self.time or 0
end

-- Moves every ramping channel's bend toward its target by `dt` song seconds (called once per update).
function MidiSynth:_stepBend(dt)
	local channels = self.channels
	for ch = 0, 15 do
		local c = channels[ch]
		local target = c and c.bendTarget
		if target then
			local d = target - c.bend
			local step = c.bendRate * dt
			if math.abs(d) <= step then
				c.bend, c.bendTarget = target, nil
			else
				c.bend += (d > 0) and step or -step
			end
		end
	end
end

function MidiSynth:reset()
	self:allNotesOff(nil, true)
	for c = 0, 15 do
		self.channels[c] = newChannel()
		self.pool:setBusPan(c + 1, 0.5)
	end
end

-- envelope step; returns false when the voice has finished
local function stepEnvelope(v, p, dt)
	v.stageTime += dt
	local stage = v.stage
	if stage == "delay" then
		v.level = 0
		if v.stageTime >= p.delay then
			v.stage, v.stageTime = "attack", 0
		end
	elseif stage == "attack" then
		if p.attack <= 0 then
			v.level = 1
		else
			v.level += dt / p.attack
		end
		if v.level >= 1 then
			v.level, v.atten = 1, 0
			v.stage, v.stageTime = ((p.hold or 0) > 0) and "hold" or "decay", 0
		end
	elseif stage == "hold" then
		if v.stageTime >= p.hold then
			v.stage, v.stageTime = "decay", 0
		end
	elseif stage == "decay" then
		local target = (p.sustain > 0) and math.min(-20 * math.log10(p.sustain), FLOOR_DB) or FLOOR_DB
		if p.decay <= 0 then
			v.atten = target
		else
			v.atten = math.min(target, v.atten + dt * FLOOR_DB / p.decay)
		end
		v.level = 10 ^ (-v.atten / 20)
		if p.sustain <= 0 and v.atten >= END_DB then
			return false
		end
	elseif stage == "release" then
		if v.atten == 0 and v.level < 1 then
			v.atten = -20 * math.log10(math.max(v.level, 1e-5))
		end
		if p.release <= 0 then
			v.atten = FLOOR_DB
		else
			v.atten += dt * FLOOR_DB / p.release
		end
		v.level = 10 ^ (-v.atten / 20)
		if v.atten >= END_DB then
			return false
		end
	end
	return true
end

-- interpolated analysis amplitudes at sample time tau; returns nil when a one-shot has ended
-- sample time inside the analysed frames: past loopStart, analyses with cycle = true repeat the loop
local function loopTime(a, tau)
	if a.cycle then
		local ls, ll = a.loopStart or 0, a.loopLength or 0
		if tau >= ls and ll > 0 then
			return ls + (tau - ls) % ll
		end
	end
	return tau
end

-- A cycled loop: the frame after the last one is the frame at the same moment of the loop's next pass (i2, frac2 =
-- its position among the frames, i2 may need clamping). Without it the last ~2 frames of every pass fell back to the
-- loop's steady spectrum and the partials jumped there and back once per pass: a tick at the loop rate.
local function wrapPos(a, i, nf)
	local ll = a.loopLength or 0
	if not a.cycle or ll <= 0 or (nf - 1) * a.hop < (a.loopStart or 0) + ll - a.hop * 1.5 then
		return nil
	end
	local v = (i + 1) - ll / a.hop
	local i2 = math.floor(v)
	return i2, v - i2
end

-- the baked pitch track is measured every 10 ms with about +-10 cents of measurement jitter; played
-- raw it retunes every partial of the note each frame, a warble. Smooth it over 50 ms,
-- and when what is left moves less than 12 cents it is just a tuning offset: hold that constant.
local PITCH_SMOOTH = 5
local PITCH_FLAT_CENTS = 12
local cleanPitch = setmetatable({}, { __mode = "k" })
local function cleanedPitch(a)
	local c = cleanPitch[a]
	if c ~= nil then
		return c
	end
	local pc = a.pitch
	if not pc or #pc == 0 then
		cleanPitch[a] = false
		return false
	end
	local n, h, sm = #pc, PITCH_SMOOTH // 2, table.create(#pc)
	local lo, hi, sum = math.huge, -math.huge, 0
	for i = 1, n do
		local t, k = 0, 0
		for j = math.max(1, i - h), math.min(n, i + h) do
			t += pc[j]
			k += 1
		end
		local v = t / k
		sm[i] = v
		sum += v
		lo = math.min(lo, v)
		hi = math.max(hi, v)
	end
	if hi - lo < PITCH_FLAT_CENTS then
		c = { constant = 2 ^ ((sum / n) / 1200) }
	else
		c = { track = sm }
	end
	cleanPitch[a] = c
	return c
end

-- pitch ratio from the sample's own pitch track (vibrato, slides, detuning), 1 when it has none
local function pitchRatio(a, tau)
	local cp = cleanedPitch(a)
	if not cp then
		return 1
	end
	if cp.constant then
		return cp.constant
	end
	local pc = cp.track
	local fpos = loopTime(a, tau) / a.hop
	local i = math.floor(fpos)
	local n = #pc
	if i + 1 >= n then
		local i2, f2 = wrapPos(a, i, n)
		if i2 then
			local p0 = pc[math.min(i + 1, n)]
			local pa, pb = pc[math.clamp(i2 + 1, 1, n)], pc[math.clamp(i2 + 2, 1, n)]
			return 2 ^ ((p0 + (pa + (pb - pa) * f2 - p0) * math.min(fpos - i, 1)) / 1200)
		end
		return 2 ^ (pc[n] / 1200)
	end
	return 2 ^ ((pc[i + 1] + (pc[i + 2] - pc[i + 1]) * (fpos - i)) / 1200)
end

-- a loop shorter than 3 analysis frames is a steady waveform (e.g. a 15 ms single-cycle buzz): cycling the frames
-- inside it amplitude-modulates every partial at the loop rate (x playback speed), 
-- CleanVoice (attribute): per sample, its fixed harmonic levels and its mean tuning
local cleanAmps = setmetatable({}, { __mode = "k" })
local meanPitchCache = setmetatable({}, { __mode = "k" })
local function meanPitch(a)
	local m = meanPitchCache[a]
	if not m then
		local pc, s, n = a.pitch, 0, 0
		if pc then
			local from = math.floor((a.loopStart or 0) / (a.hop or 0.01)) + 1
			for i = math.min(from, #pc), #pc do
				s += pc[i]
				n += 1
			end
		 end
		m = 2 ^ ((n > 0 and s / n or 0) / 1200)
		meanPitchCache[a] = m
	end
	return m
end

local function steadyLoop(a)
	return (a.loopLength or 0) < a.hop * 3
end

-- Rough-sine levels (a.rough: per frame, per harmonic, the RMS of the harmonic's fast motion; same frame grid as the
-- harmonic frames), at sample time tau
local function roughAmps(a, tau, out)
	local fr = a.rough
	local nf = fr and #fr or 0
	if nf == 0 then
		return nil
	end
	if a.cycle then
		tau = loopTime(a, tau)
	end
	local fpos = math.max(tau, 0) / (a.roughHop or a.hop)
	local i = math.floor(fpos)
	if i + 1 >= nf then
		return fr[nf]
	end
	local f0, f1 = fr[i + 1], fr[i + 2]
	local frac = fpos - i
	for k = 1, #f0 do
		out[k] = f0[k] + (f1[k] - f0[k]) * frac
	end
	for k = #out, #f0 + 1, -1 do
		out[k] = nil
	end
	return out
end

local function additiveAmps(a, tau, out)
	local frames = a.frames
	local nf = #frames
	if a.cycle and nf > 0 and not (a.loopAmps and steadyLoop(a)) then
		tau = loopTime(a, tau)
	elseif a.looped and (nf == 0 or tau >= (a.loopStart or 0)) then
		return a.loopAmps
	end
	if not a.looped and tau >= a.length then
		return nil
	end
	local fpos = tau / a.hop
	local i = math.floor(fpos)
	if i + 1 >= nf then
		local i2, f2 = wrapPos(a, i, nf)
		if i2 and a.cycle then
			local f0 = frames[math.min(i + 1, nf)]
			local ra, rb = frames[math.clamp(i2 + 1, 1, nf)], frames[math.clamp(i2 + 2, 1, nf)]
			local frac = math.min(fpos - i, 1)
			for k = 1, #f0 do
				local target = ra[k] + (rb[k] - ra[k]) * f2
				out[k] = f0[k] + (target - f0[k]) * frac
			end
			for k = #out, #f0 + 1, -1 do
				out[k] = nil -- the table is reused across notes: drop parts of a previous, larger sample
			end
			return out
		end
		return a.looped and (a.loopAmps or frames[nf]) or frames[nf]
	end
	local f0, f1 = frames[i + 1], frames[i + 2]
	local frac = fpos - i
	for k = 1, #f0 do
		out[k] = f0[k] + (f1[k] - f0[k]) * frac
	end
	for k = #out, #f0 + 1, -1 do
		out[k] = nil -- the table is reused across notes: drop parts of a previous, larger sample
	end
	return out
end

-- Decaying parts. Per partial of a one-shot: its decay time constant in sample seconds (log-linear fit from the
-- partial's peak down to 30 dB under it), false when it doesn't decay steadily. Cached per analysis.
local DECAY = true
local DECAY_MAX_TAU = 1.8 -- slower decays step < 0.1 dB per block: plain sines are fine
local DECAY_MIN_TAU = 0.012
local decayOk, decayRevision = nil, nil
local function decayReady()
	-- the decaying sines are in use when the active manifest has them (WaveBank.Assets)
	if decayOk == nil or decayRevision ~= WaveBank.Revision then
		decayRevision = WaveBank.Revision
		decayOk = WaveBank.DecayWave0 ~= nil and WaveBank.assetId(WaveBank.decayWave(1, 1), 1) ~= nil
	end
	return decayOk
end
local decayTaus = setmetatable({}, { __mode = "k" })
local function sampleTaus(a)
	local c = decayTaus[a]
	if c ~= nil then
		return c
	end
	c = false
	local frames = a.frames
	if not a.looped and frames and #frames >= 4 then
		c = {}
		local hop = a.hop
		for i = 1, #frames[1] do
			local peak, jp = 0, 1
			for j, row in ipairs(frames) do
				if (row[i] or 0) > peak then
					peak, jp = row[i], j
				end
			end
			local tau = false
			if peak > 0 then
				local sw, st, sy, stt, sty = 0, 0, 0, 0, 0
				local floor = peak * 10 ^ (-30 / 20)
				local n = 0
				for j = jp, #frames do
					local x = frames[j][i] or 0
					if x < floor then
						break
					end
					local w = x / peak
					local t, y = (j - 1) * hop, math.log(x)
					sw += w
					st += w * t
					sy += w * y
					stt += w * t * t
					sty += w * t * y
					n += 1
				end
				local den = sw * stt - st * st
				if n >= 4 and den > 0 then
					local slope = (sw * sty - st * sy) / den
					if slope < 0 then
						tau = -1 / slope
					end
				end
			end
			c[i] = tau and { tau = tau, peak = (jp - 1) * hop } or false
		end
	end
	decayTaus[a] = c
	return c
end

-- Tracked parts: each sine's file position is followed block by block (the block clock), so the part can move to
-- another file at the same sine phase on a block boundary: the old player stops and the new one starts on the same
-- boundary, in phase, with no seam. rate = the decay the part should have now (1/s, amplitude e-folds per second).
-- Returns the wave (a decaying sine, or the looping sine at a fixed base), the volume corrected for the file's own
-- envelope, and the phase (cycles; the pool starts a new player there).
local function trackPart(v, key, f, vol, ph, rate, blockB, blockDur)
	v.dst = v.dst or {}
	local st = v.dst[key]
	if not st then
		local r = WaveBank.rangeFor(f)
		local base = WaveBank.Bases[r]
		st = { r = r, base = base, n = 0, pos = ((ph or 0) % 1) / base, b = blockB + 1, speed = f / base }
		v.dst[key] = st
	else
		-- file position at the block this write lands on (blocks so far ran at the speed set then)
		local nb = blockB + 1 - st.b
		if nb > 0 then
			st.pos += nb * blockDur * st.speed
			st.b = blockB + 1
		end
		if st.n == 0 then
			st.pos %= 1 -- the looping sine is one second of whole cycles
		end
	end
	st.speed = f / st.base
	local wantN = st.n
	if rate < 1 / DECAY_MIN_TAU then -- faster than any file (a click-short release): the volume does it
		local fileTau = (rate > 0) and (st.speed / rate) or math.huge
		if st.n > 0 then
			local cur = WaveBank.decayTau(st.n)
			if rate < 1 / (DECAY_MAX_TAU * 1.3) then
				wantN = 0 -- stopped decaying (reached its sustain level)
			elseif math.max(fileTau / cur, cur / fileTau) > 1.35 then
				wantN = math.clamp(math.floor(math.log(fileTau / 0.025, 1.6) + 1.5), 1, WaveBank.DecayCount)
			end
		elseif rate > 1.3 / DECAY_MAX_TAU then
			wantN = math.clamp(math.floor(math.log(fileTau / 0.025, 1.6) + 1.5), 1, WaveBank.DecayCount)
		end
		if wantN > 0 then
			local t = WaveBank.decayTau(wantN)
			if math.max(fileTau / t, t / fileTau) > 1.6 then
				wantN = (st.n > 0 and math.max(fileTau / WaveBank.decayTau(st.n), WaveBank.decayTau(st.n) / fileTau) <= 1.6) and st.n or 0
			end
		end
	end
	local function envAt(n, pos)
		return (n > 0) and math.exp(-(pos + 0.5 * blockDur * st.speed) / WaveBank.decayTau(n)) or 1
	end
	local env = envAt(st.n, st.pos)
	-- re-arm a decaying file that is running out (its envelope is far down: the correction would be huge)
	-- (or close to the end of its file: the long decays' files are cut at WaveBank.DecayFileMax; two blocks of margin)
	local rearm = st.n > 0 and (st.pos > math.min(WaveBank.decayTau(st.n) * WaveBank.DecayLength * 0.6,
		WaveBank.decayFileLength(st.n) - 2 * blockDur * st.speed - 0.02) or vol / env > 2.5)
	if wantN ~= st.n or rearm then
		local phase = (st.pos * st.base) % 1 -- sine phase (cycles) at the boundary: the new file starts there
		st.n = wantN
		st.pos = phase / st.base
		env = envAt(st.n, st.pos)
		v.dsw = (v.dsw or 0) + 1
	end
	local wave = (st.n > 0) and WaveBank.decayWave(st.n, st.r) or WaveBank.trackWave(st.r)
	return wave, vol / env, st.pos * st.base
end

-- noise chain row at sample time tau: (row0, row1, frac) or nil when a one-shot has ended
-- per-frame player budget: every part a voice wants this frame is collected, then the loudest
-- maxPlayers are played (parts already sounding get a 1.5x edge so the choice doesn't flicker)
local reqSlot, reqWave, reqFreq, reqVol, reqBus, reqPri, reqOrder, reqPhase = {}, {}, {}, {}, {}, {}, {}, {}
local reqFast = {}

local function noiseRows(p, tau)
	local nz = p.noise
	if nz.loop and p.looped and tau >= (p.loopStart or 0) then
		return nz.loop, nz.loop, 0
	end
	local frames = nz.frames
	local fpos = tau / nz.hop
	local i = math.floor(fpos)
	if i + 1 > #frames then
		if nz.loop and p.looped then
			return nz.loop, nz.loop, 0
		end
		return nil
	end
	return frames[i + 1], frames[i + 2] or frames[i + 1], fpos - i
end

-- Switches (attributes on the AudioLab module, all off by default; read every frame):
-- NoBundles, NoPhaseReset, NoResidual
local debugHost = script.Parent.Parent
-- The residual is measured leak-free (see Instruments.peakShare), so its low part is real (the thump of a note played
-- far below its sample's root) and nothing is cut by default. Attribute ResidualCutMax (Hz) cuts it below that.
local RESIDUAL_CUT_MAX = 0
-- parts quieter than this (about -68 dB, before the master) are inaudible next to anything else: no player for them
local PART_FLOOR = 0.0004
-- Phase-locked voice (samples with phaseFrames): each harmonic is one sine whose speed follows the sample's own phase,
-- so the voice keeps its natural pitch movement (plain fixed harmonics sound robotic).
-- The "pairs" form (two sines per harmonic, loudness set by steering their phases apart at predicted audio-block
-- boundaries) is off: the engine does not apply property writes on an exact block, so its parts can jump off pitch
-- for 21 ms at a time (freezes and high static).
-- Attributes: PhaseLockedVoice = true brings pairs back, NoPhaseFollow = true plays plain fixed harmonics.
local PLDiag = {}
local PHASE_PULL = 0.005 -- largest phase correction, as a fraction of the part's frequency (under 9 cents)
local PHASE_DEV = 0.015 -- how far a harmonic may move from k x the note's pitch (26 cents)
local PHASE_REANCHOR = 0.12 -- cycles: a larger phase error re-anchors the part instead of being pulled back
-- (TimePosition can't steer the phases: it is an estimate the engine extrapolates from the speed last set, not the
-- audio actually played.)
local function phaseLocked(a)
	return a.phaseFrames ~= nil and debugHost:GetAttribute("NoPhaseFollow") ~= true
end
local VOICE_LEAD = 0.010
local VOICE_LEAD_RAMP = 0.025 -- seconds
local VOICE_SHARP, VOICE_SHARP_DT = 0.8, 0.010
local ROUGH_SMOOTH = 0.05 -- seconds (attribute RoughSmooth; 0 = off)
local VOICE_SMOOTH = 0.015 -- seconds: default one-pole smoothing of a voice's harmonic levels (attribute VoiceSmooth; 0 = off)
local VOICE_SHARP_FLOOR = 0.5 -- the unsharp mask may lower a part to at most half its level
local RESIDUAL_LOW_BINS = 4 -- chain positions 1-4 (88-250 Hz): the over-sized part
-- The stored noise of many samples is far larger than what the partial fit left over (a bass with a 0.10 fit
-- error carried noise 2x its own tone). Scale each sample's noise (above the low bins) so its level is at most
-- 1.5x the leftover its fit error implies (never below 12% of the tone, so breathy samples keep theirs).
-- The low bins are the exception to that scaling (a note played far below its root has a real thump there), but a
-- sample whose low-bin noise is LOUDER THAN ITS OWN TONE is measuring leakage: partials closer together than the
-- analysis can resolve (a bass whose period-2 loop gives a 41 Hz comb) are counted as noise. Such samples keep
-- only LOW_RESIDUAL_KEEP of their tone's rms in the low bins (the original's valleys between harmonics sit 30-38 dB down). Attributes: NoLowResidualCap, LowResidualKeep.
local LOW_RESIDUAL_TRIGGER = 1.0
local LOW_RESIDUAL_KEEP = 0.1
local residualScales = setmetatable({}, { __mode = "k" })
local function residualScale(a, res)
	if a.voice or debugHost:GetAttribute("NoResidualScale") == true then
		-- voice samples carry their noise measured against the tone (valley level); NoResidualScale turns the scaling off
		return 1, 1
	end
	-- attribute ResidualFloor: a fixed noise level as a fraction of the tone's rms (ignores the fit error)
	local floorAttr = debugHost:GetAttribute("ResidualFloor")
	local keepAttr = debugHost:GetAttribute("LowResidualKeep")
	local capOff = debugHost:GetAttribute("NoLowResidualCap") == true
	local cached = residualScales[a]
	if cached and cached.floor == floorAttr and cached.keep == keepAttr and cached.capOff == capOff then
		return cached.v, cached.low
	end
	local s, sLow = 1, 1
	local rf, af = res.frames, a.frames
	if rf and af and #rf > 0 and #af > 0 then
		local rp, tp, rl = 0, 0, 0
		for _, f in ipairs(rf) do
			for d = 1, #f do
				if d <= RESIDUAL_LOW_BINS then
					rl += f[d] * f[d]
				else
					rp += f[d] * f[d]
				end
			end
		end
		for _, f in ipairs(af) do
			for _, amp in ipairs(f) do
				tp += amp * amp / 2
			end
		end
		rp = math.sqrt(rp / #rf)
		rl = math.sqrt(rl / #rf)
		tp = math.sqrt(tp / #af)
		if not capOff and tp > 0 and rl > LOW_RESIDUAL_TRIGGER * tp then
			sLow = (keepAttr or LOW_RESIDUAL_KEEP) * tp / rl
		end
		local fit = math.clamp(a.fitError or 0.3, 0, 0.98)
		local implied = fit / math.sqrt(1 - fit * fit)
		local target = floorAttr and floorAttr * tp or math.max(1.5 * implied, 0.12) * tp
		if rp > target and rp > 0 then
			s = target / rp
		end
	end
	residualScales[a] = { floor = floorAttr, keep = keepAttr, capOff = capOff, v = s, low = sLow }
	return s, sLow
end

-- Attribute PhaseSpread: each sine partial starts at its own fixed pseudo-random phase instead of
-- all at zero, so the summed waveform isn't a peaky pulse train (zero-phase harmonics add into a buzz)
-- Diagnostics (attribute NoDiag = true turns them off): warns in the output when the engine sees a long frame, an audio
-- stall (no 21 ms block for a while) or blocks arriving bunched, a burst of player starts, or more players wanted than
-- the limit.
local DIAG_GAP = 0.07 -- seconds without an audio block that count as a stall
-- (only with the AudioLab folder's Debug attribute)
local ALRoot = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
local function audioDebug()
	return ALRoot ~= nil and ALRoot:GetAttribute("Debug") == true
end
local function diag(self, dt, nreq, budget)
	if debugHost:GetAttribute("NoDiag") == true or self.blockClockFn or not audioDebug() then
		return
	end
	local d = self._dg
	local now = os.clock()
	local B = self:_blockClock()
	local started = self.pool.stats.started
	if not d then
		d = { B = B, at = now, started = started, last = {}, born = now }
		self._dg = d
		warn(("[AudioLab] %s started"):format(self.pool.folder.Name))
		return
	end
	local function say(kind, msg)
		if now - (d.last[kind] or 0) > 0.5 then
			d.last[kind] = now
			warn(("[AudioLab] %s @%.2fs (%.1fs after start): %s"):format(self.pool.folder.Name, self:getTime(), now - d.born, msg))
		end
	end
	if dt > 0.025 and not self.warming and not self.warmGain then -- the warm-up steps 50 ms of song per call
		say("frame", ("frame took %.0f ms"):format(dt * 1000))
	end
	if B ~= d.B then
		local jump = B - d.B
		if jump >= 3 and dt < 0.03 then
			say("bunch", ("%d audio blocks arrived in one %.0f ms frame"):format(jump, dt * 1000))
		end
		d.B, d.at = B, now
	elseif now - d.at > DIAG_GAP then
		say("stall", ("no audio block for %.0f ms"):format((now - d.at) * 1000))
	end
	if started - d.started >= 25 then
		say("starts", ("%d players started at once"):format(started - d.started))
	end
	d.started = started
	if nreq > budget then
		say("budget", ("wanted %d players, limit %d (quietest dropped)"):format(nreq, budget))
	end
end

local function partialPhase(k)
	local x = math.sin(k * 12.9898 + 78.233) * 43758.5453
	return x - math.floor(x)
end
local CHAIN_FC = {}
for d = 1, WaveBank.ChainBins do
	CHAIN_FC[d] = WaveBank.ChainBase * 2 ^ ((d - 1) / 2)
end

-- Source-filter notes (samples with a.sf, see Synth.SourceFilter): one saw + one noise player through 8 moving filters
-- instead of 17-29 sine parts. Returns false when the note plays on the additive engine instead: attribute
-- SourceFilter = false on the AudioLab module (read every frame), or every source-filter voice busy.
function MidiSynth:_sfStep(v, p, c, chGain, blockHalf)
	if v.sfNo or debugHost:GetAttribute("SourceFilter") == false then
		if v.sfv then
			self.sf:free(v.sfv)
			v.sfv = nil
		end
		return false
	end
	local a = p.additive
	local sp = p.speed or 1
	local tauC, tauF
	if blockHalf then
		-- block-ahead: this write lands on the block's start; levels for its middle, filters for its end
		tauC = v.sampleTime + blockHalf * sp
		tauF = v.sampleTime + 2 * blockHalf * sp
	else
		-- per frame: the write lands on the next boundary; filters a block further on (their ~27 ms glide)
		tauC = v.sampleTime + VOICE_LEAD * sp
		tauF = tauC + (self.blockDur or 1024 / 48000) * sp
	end
	if not v.sfv then
		self.sf = self.sf or SourceFilter.new(self.pool)
		local h = self.sf:start(a, sp, v.channel + 1, tauC)
		if not h then
			v.sfNo = true
			return false
		end
		v.sfv = h
		for i = 0, self.stride - 1 do
			self.pool:setVoice(v.slot + i, 0, 0, 0) -- sine parts it had (the attribute switched on mid-note)
		end
	end
	local bendR = (c.bend ~= 0) and 2 ^ (c.bend * c.bendRange / 12) or 1
	self.sf:update(v.sfv, tauC, tauF, sp, bendR, v.level * (p.atten or 1) / (a.energyComp or 1) * chGain)
	return true
end

-- One-shot onset bursts (sharp-start noise assets): a few players per asset, reused round-robin.
function MidiSynth:_playBurst(name, volume, speed, bus, delay)
	if self.burstHook then
		self.burstHook(name, volume, speed, bus)
	end
	local id = WaveBank.Assets[name]
	if not id or id == "" or volume <= 0 then
		return
	end
	local pool = self.pool
	self.burstPlayers = self.burstPlayers or {}
	local list = self.burstPlayers[name]
	if not list then
		list = {}
		self.burstPlayers[name] = list
	end
	local p
	for _, q in ipairs(list) do
		if not q.IsPlaying then
			p = q
			break
		end
	end
	if not p then
		if #list >= 8 then
			p = table.remove(list, 1)
			table.insert(list, p)
		else
			p = Instance.new("AudioPlayer")
			p.Name = name
			p.Asset = id
			p.Looping = false
			local w = Instance.new("Wire")
			w.Name = "Out"
			w.SourceInstance = p
			w.Parent = p
			p.Parent = pool.output
			table.insert(list, p)
		end
	end
	local target = pool.output
	if pool.stereo and pool.buses then
		local b = pool.buses[bus] or pool.buses[1]
		target = b and b.input or target
	end
	local w = p:FindFirstChild("Out")
	if w and w.TargetInstance ~= target then
		w.TargetInstance = target
	end
	p.Volume = volume
	p.PlaybackSpeed = speed
	local reg = WaveBank.Regions[name]
	if reg and reg.stopAt then
		-- atlas pack: the burst is a region of a shared file; start at its onset and stop where it ends (the file goes on
		-- with the next sound)
		-- delay: seconds of silence before the onset (the start lands on a block boundary; the file holds silence ahead of
		-- every sound, so starting that much earlier places the onset inside the block)
		local pre = math.min((delay or 0) * speed, reg.lead or 0)
		p.TimePosition = reg.onset - pre
		if not p.IsPlaying then
			p:Play()
		end
		local token = (p:GetAttribute("BurstToken") or 0) + 1
		p:SetAttribute("BurstToken", token)
		task.delay((reg.stopAt - reg.onset + pre) / math.max(speed, 0.05), function()
			if p.Parent and p:GetAttribute("BurstToken") == token then
				p:Stop()
			end
		end)
		return
	end
	p.TimePosition = 0
	if not p.IsPlaying then
		p:Play()
	end
end

-- The engine's audio block clock: a silent looping player's TimePosition moves once per block (1024 output samples),
-- so watching it tells which block boundary has just passed. Returns (index of the last boundary seen, block length).
function MidiSynth:_blockClock()
	if self.blockClockFn then
		return self.blockClockFn()
	end
	local cp = self.clockPlayer
	if not cp then
		cp = Instance.new("AudioPlayer")
		cp.Name = "BlockClock"
		cp.Asset = WaveBank.assetId(SINE, WaveBank.SineRange or 1) or ""
		cp.Looping = true
		cp.Volume = 0
		cp.Parent = self.pool.output or self.holder
		local w = Instance.new("Wire")
		w.Name = "Out"
		w.SourceInstance = cp
		w.TargetInstance = self.pool.output
		w.Parent = cp
		cp:Play()
		self.clockPlayer = cp
		self.blockIndex, self.blockDur, self.clockLast = 0, 1024 / 48000, nil
		self.clockSum, self.clockSteps = 0, 0
	end
	local pos = cp.TimePosition
	local last = self.clockLast
	if last then
		local d = pos - last
		if d < -0.5 then
			d += (cp.TimeLength > 0 and cp.TimeLength or 1)
		end
		if d > 1e-4 then
			local n = math.max(1, math.floor(d / self.blockDur + 0.5))
			self.blockIndex += n
			self.clockSum += d
			self.clockSteps += n
			if self.clockSteps >= 50 then
				-- 1024 samples at the device rate (21.3 ms at 48 kHz, 23.2 ms at 44.1 kHz)
				self.blockDur = self.clockSum / self.clockSteps
			end
		end
	end
	self.clockLast = pos
	return self.blockIndex, self.blockDur
end

function MidiSynth:update(dt)
	self.clock += dt
	self:_stepBend(dt)
	local pool = self.pool
	-- block-ahead mode (see _build): song seconds from the start of the block being written to its middle; nil per frame
	local blockHalf = self.blockHalf
	if self.warmTrimAt and self.clock >= self.warmTrimAt then
		self.warmTrimAt = nil
		pool.warmReserve, pool.idleStop = self.baseWarmReserve, self.baseIdleStop
	end
	local noBundles = debugHost:GetAttribute("NoBundles") == true
	-- pulse bundles are opt-in (attribute Pulses = true); a buzz from the bundles' even harmonics is fixed by
	-- Cycle = "exact" instead
	local noPulses = debugHost:GetAttribute("Pulses") ~= true
	local phaseSpread = debugHost:GetAttribute("PhaseSpread") == true
	local bundleGain = debugHost:GetAttribute("BundleGain") or 1
	local noResidual = debugHost:GetAttribute("NoResidual") == true
	pool.phaseReset = debugHost:GetAttribute("NoPhaseReset") ~= true
	local master = self.masterGain * HEADROOM * (self.warmGain or 1)
	local levels = self.bandLevels
	self.bandLevelsR = self.bandLevelsR or table.create(#levels, 0)
	local levelsR = self.bandLevelsR
	for b = 1, #levels do
		levels[b] = 0
		levelsR[b] = 0
	end
	local stereo = self.stereo
	local panGains = OscillatorPool.panGains
	local sineSlots = self.sineSlots
	local nreq = 0
	local realPool = pool
	local prep = nil -- set while a gated voice is processed: its parts are prepared, not played
	local function want(slot, wave, freq, vol, bus, phase, fast)
		if prep and wave ~= 0 and freq > 0 then
			vol = prep
		end
		if wave == 0 or vol == 0 or freq <= 0 then
			realPool:setVoice(slot, 0, 0, 0)
			return
		end
		nreq += 1
		reqSlot[nreq], reqWave[nreq], reqFreq[nreq], reqVol[nreq], reqBus[nreq], reqPhase[nreq] = slot, wave, freq, vol, bus, phase
		reqFast[nreq] = fast
	end
	pool = { setVoice = function(_, ...)
		want(...)
	end }
	local activity = self.activity
	local fall = math.exp(-dt * 6)
	for c = 0, 15 do
		activity[c] *= fall
	end
	for _, v in ipairs(self.voices) do
		if v.active and v.channel then
			local a = v.level * (v.velGain or 1) ^ 0.5
			if a > activity[v.channel] then
				activity[v.channel] = a
			end
		end
	end
	for _, v in ipairs(self.voices) do
		if v.active then
			local p = v.preset
			-- a note started during this frame renders its very start first; the sample clock
			-- only advances from the next frame (otherwise short attacks are skipped entirely)
			local alive
			if v.gate then
				-- not sounding yet: parts are prepared (first frame restarts them in phase), envelope waits
				prep = v.gatePrepared and OscillatorPool.PREPARE_HOLD or OscillatorPool.PREPARE
				v.gatePrepared = true
				v.gate -= dt
				if v.gate <= 0 then
					v.gate = nil
				end
				alive = true
			else
				prep = nil
				local fresh = v.fresh
				local clockDt = fresh and 0 or dt
				v.fresh = nil
				v.age += clockDt
				-- block-ahead: a note that starts on this block's boundary is drawn at the block's middle
				alive = stepEnvelope(v, p, (fresh and blockHalf) or dt)
				if v.relPending then
					v.relPending = nil
					if alive and v.stage ~= "release" then
						v.stage, v.stageTime = "release", 0
					end
				end
				if alive and v.stage ~= "delay" then
					v.sampleTime += clockDt * (p.speed or 1)
				end
			end
			local c = self.channels[v.channel]
			local semis
			if v.drum then
				local d = v.drum
				local f = d.to
				if d.sweep > 0 and v.age < d.sweep * 4 then
					f = d.to + (d.from - d.to) * math.exp(-v.age / d.sweep)
				end
				semis = 12 * math.log(f / 440, 2) + 69
			else
				semis = v.key + (p.transpose or 0) + c.bend * c.bendRange
			end
			local freq = 440 * 2 ^ ((semis - 69) / 12)
			-- channel volume (CC7) and expression (CC11) apply live to sounding notes, as in the original: a song fades a
			-- held chord by stepping CC7 down (KP3CLEAR). (Freezing them at note-on lost every one of those fades.)
			local chGain = v.velGain * ccCurve(self.freezeVolume and (v.vol or c.volume) or c.volume) * ccCurve(self.freezeVolume and (v.expr or c.expression) or c.expression) * master
			if alive and p.noise then
				local nt = v.sampleTime + (blockHalf and blockHalf * (p.speed or 1) or 0)
				local r0, r1, frac = noiseRows(p, nt)
				if not r0 and nt ~= v.sampleTime then
					nt = v.sampleTime -- the block's middle is past the sample's end: its start still plays
					r0, r1, frac = noiseRows(p, nt)
				end
				if not r0 then
					alive = false
				else
					local g = v.level * (p.atten or 1) * chGain
					local gl, gr = 1, 1
					if stereo then
						gl, gr = panGains(c.pan / 127)
					end
					local nz = p.noise
					-- a flam (clap): its hits are played as bursts at exact offsets; the chain only carries what follows them
					local gate = 1
					local hits = nz.hits
					if hits and not prep and v.hitsOn == nil then
						v.hitsOn = WaveBank.Regions.burst_4000_t6 ~= nil and debugHost:GetAttribute("NoClapHits") ~= true
						if v.hitsOn then
							local hsp = p.speed or 1
							local hg = tonumber(debugHost:GetAttribute("ClapHitGain")) or 0.56
							for _, h in ipairs(hits) do
								local bname = h.hz < 3000 and "burst_2000_t6" or (h.hz < 6000 and "burst_4000_t6" or "burst_8000_t6")
								local spec = WaveBank.Bursts[bname]
								self:_playBurst(bname, g * hg * h.amp / ((spec and spec.rms5) or 0.2), hsp, v.channel + 1, h.t / hsp)
							end
						end
					end
					if hits and v.hitsOn then
						gate = math.clamp((nt - (hits[#hits].t + 0.004)) / 0.010, 0, 1)
					end
					local pk = nz.peakAmps
					local fpos = nt / nz.hop
					local fi = math.floor(fpos)
					local ff = fpos - fi
					local ra, rb = pk and pk[fi + 1], pk and (pk[fi + 2] or pk[fi + 1])
					local fa, fb = pk and nz.peakFreqFrames[fi + 1], pk and (nz.peakFreqFrames[fi + 2] or nz.peakFreqFrames[fi + 1])
					local speed = p.speed or 1
					-- block-ahead: each level is the RMS over the block's own span (NOISE_TAPS taps; nothing past the
					-- sample's end), not the block's middle: the 10 ms frames of a short breath don't alias into a
					-- 47 Hz staircase, and the block that straddles the end stops at the end instead of playing on
					local taps = nil
					if blockHalf and debugHost:GetAttribute("NoiseBlockAvg") ~= false then
						taps = {}
						local blkS = 2 * blockHalf * speed
						for q = 1, NOISE_TAPS do
							local tq = v.sampleTime + blkS * (q - 0.5) / NOISE_TAPS
							local q0, q1, qf = noiseRows(p, tq)
							taps[q] = q0 and { t = tq, r0 = q0, r1 = q1, f = qf } or false
						end
					end
					local function peakAmp(i)
						if not taps then
							return (ra and ra[i] and (ra[i] + (rb[i] - ra[i]) * ff) or 0)
						end
						local e = 0
						for q = 1, NOISE_TAPS do
							local tp = taps[q]
							if tp and pk then
								local fp = tp.t / nz.hop
								local j = math.floor(fp)
								local xa, xb = pk[j + 1], pk[j + 2] or pk[j + 1]
								if xa and xa[i] then
									local x = xa[i] + ((xb and xb[i] or xa[i]) - xa[i]) * (fp - j)
									e += x * x
								end
							end
						end
						return math.sqrt(e / NOISE_TAPS)
					end
					for i = 1, sineSlots do
						local amp = peakAmp(i) * gate
						if amp > 0 then
							local f
							local fA = fa and fa[i]
							if fA then
								local fB = (fb and fb[i]) or fA
								f = (fA + (fB - fA) * ff) * speed
							else
								-- the block's middle lies past the analysed frames (its RMS still has sound from earlier
								-- taps): the pitch of the last frame that has this part
								local pff = nz.peakFreqFrames
								local last = pff and pff[math.min(fi + 1, #pff)]
								f = (last and last[i] or 0) * speed
							end
							if f > 0 and f < MAX_PARTIAL_HZ then
								pool:setVoice(v.slot + i - 1, SINE, f, g * amp / SINE_GAIN, v.channel + 1)
							else
								pool:setVoice(v.slot + i - 1, 0, 0, 0)
							end
						else
							pool:setVoice(v.slot + i - 1, 0, 0, 0)
						end
					end
					-- a sample played above its root key moves up the chain: 2 positions per octave
					local shift = 2 * math.log(p.speed or 1, 2)
					local function chainAt(q0, q1, qf, i0, t)
						local l = 0
						if i0 >= 1 and i0 <= CHAIN_N then
							l += (q0[i0] + (q1[i0] - q0[i0]) * qf) * (1 - t)
						end
						if i0 + 1 >= 1 and i0 + 1 <= CHAIN_N then
							l += (q0[i0 + 1] + (q1[i0 + 1] - q0[i0 + 1]) * qf) * t
						end
						return l
					end
					for d = 1, CHAIN_N do
						local sp = d - shift
						local i0 = math.floor(sp)
						local t = sp - i0
						local l
						if taps then
							local e = 0
							for q = 1, NOISE_TAPS do
								local tp = taps[q]
								if tp then
									local x = chainAt(tp.r0, tp.r1, tp.f, i0, t)
									e += x * x
								end
							end
							l = math.sqrt(e / NOISE_TAPS)
						else
							l = chainAt(r0, r1, frac, i0, t)
						end
						if l > 0 then
							l *= g * gate
							local band = CHAIN[d]
							levels[band] += (l * gl) ^ 2
							levelsR[band] += (l * gr) ^ 2
						end
					end
				end
			elseif alive and p.additive and p.additive.sf and not prep and self:_sfStep(v, p, c, chGain, blockHalf) then
				-- (played by the source-filter voice: _sfStep)
			elseif alive and p.additive then
				local a = p.additive
				-- a coherent voice follows fast spectral changes (a vowel is ~50 ms long): the engine applies a volume change
				-- about one frame (+ its own ramp) after it is written, so write the level that is due then
				local ampTime = v.sampleTime
				if blockHalf then
					-- block-ahead: the write lands exactly on the block's start, so the level due is the block's middle (no lead)
					ampTime += blockHalf * (p.speed or 1)
					if a.length and ampTime >= a.length then
						ampTime = math.max(v.sampleTime, a.length - 1e-4)
					end
				elseif a.voice and VOICE_LEAD > 0 and ampTime + VOICE_LEAD * (p.speed or 1) < (a.length or 0) then
					ampTime += VOICE_LEAD * (p.speed or 1) * math.clamp((v.sampleTime - VOICE_LEAD_RAMP) / 0.02, 0, 1) -- no lead on the first update: it would skip the opening frame (the consonant burst)
				end
				local amps = additiveAmps(a, ampTime, v.amps)
				local blockB, blockDur = nil, nil
				if amps and BLOCK_AVG and (not a.voice or debugHost:GetAttribute("VoiceBlockAvg") ~= false) and not a.phaseFrames and debugHost:GetAttribute("NoBlockAvg") ~= true then
					local B, blk = self:_blockClock()
					blockB, blockDur = B, blk
					-- the block where sample time 0 plays: players start on the boundary after the first write
					-- a note that waited (prepared, or in its envelope delay) starts on the boundary after its first sounding
					-- write (not the boundary of its last waiting write, which would skip its first block of attack)
					if prep or v.stage == "delay" then
						v.blk0, v.blkWait = B + 1, true
					elseif not v.blk0 or v.blkWait then
						v.blk0, v.blkWait = B + 1, nil
					end
					local span = blk * (p.speed or 1)
					local s0 = (B + 1 - v.blk0) * span
					v.bq, v.bt = v.bq or {}, v.bt or {}
					local acc = v.bq
					local n0 = #amps
					for k = 1, n0 do
						acc[k] = 0
					end
					for k = #acc, n0 + 1, -1 do
						acc[k] = nil
					end
					for q = 1, BLOCK_TAPS do
						local r = additiveAmps(a, s0 + span * (q - 0.5) / BLOCK_TAPS, v.bt)
						if r then
							for k = 1, n0 do
								local x = r[k] or 0
								acc[k] += x * x
							end
						end
					end
					for k = 1, n0 do
						acc[k] = math.sqrt(acc[k] / BLOCK_TAPS)
					end
					amps = acc
				end
				local vsharp = tonumber(debugHost:GetAttribute("VoiceSharp")) or VOICE_SHARP -- attribute VoiceSharp: 0 = no unsharp mask
				local sharpFloor = tonumber(debugHost:GetAttribute("VoiceSharpFloor")) or VOICE_SHARP_FLOOR
				if amps and a.voice and vsharp > 0 and not phaseLocked(a) then
					-- unsharp mask in time: the analysis window (16 ms) and the engine's ramp round off the edges of the vowel;
					-- pushing each part away from the mean of its neighbours restores the sharp up and down of the original
					local sp = p.speed or 1
					local len = a.length or 0
					local tA, tB = math.max(0, ampTime - VOICE_SHARP_DT * sp), math.min(len - 1e-4, ampTime + VOICE_SHARP_DT * sp)
					v.sA, v.sB, v.sS = v.sA or {}, v.sB or {}, v.sS or {}
					local ca = additiveAmps(a, tA, v.sA)
					local cb = additiveAmps(a, tB, v.sB)
					if ca and cb then
						local out = v.sS
						for k = 1, #amps do
							local c = amps[k]
							local x = c + vsharp * (c - 0.5 * ((ca[k] or c) + (cb[k] or c)))
							-- never below VOICE_SHARP_FLOOR x the part's own level: at a natural dip the mask would drive a
							-- harmonic to 0, switching the part off and restarting it at phase 0 a block later (stutter)
							out[k] = math.clamp(x, c * sharpFloor, c * 3)
						end
						amps = out
					end
				end
				-- attribute VoiceSmooth (seconds): one-pole smoothing of every harmonic's level over time. The
				-- engine applies a level once per 21 ms block, so a fast swing becomes a staircase whose steps are heard as a buzz.
				local vsm = tonumber(debugHost:GetAttribute("VoiceSmooth")) or VOICE_SMOOTH
				if amps and a.voice and vsm and vsm > 0 and not prep then
					local sm = v.vsm
					if not sm then
						sm = {}
						v.vsm = sm
					end
					-- a new note (sample time went back) starts from its own opening frame, and the first 40 ms stay unsmoothed (the consonant)
					if not v.vsmT or v.sampleTime < v.vsmT or v.sampleTime < 0.04 then
						table.clear(sm)
					end
					v.vsmT = v.sampleTime
					local alpha = 1 - math.exp(-math.clamp(dt, 1 / 240, 1 / 20) / vsm)
					for k = 1, #amps do
						local x, y = amps[k], sm[k]
						sm[k] = y and (y + (x - y) * alpha) or x
					end
					for k = #sm, #amps + 1, -1 do
						sm[k] = nil
					end
					amps = sm
				end
				-- attribute CleanVoice: a voice plays as a clean tone. Every harmonic holds the level it has
				-- in the sample's loop (only the first CLEAN_K), the pitch holds the sample's mean tuning, and the noise layer is
				-- off: nothing changes during the note except the note's own envelope.
				local clean = a.voice and not phaseLocked(a) and debugHost:GetAttribute("CleanVoice") == true
				if amps and clean then
					local ca = cleanAmps[a]
					if not ca then
						ca = {}
						local la = a.loopAmps or {}
						local K = tonumber(debugHost:GetAttribute("CleanVoiceK")) or 6
						for k = 1, #amps do
							ca[k] = (k <= K and la[k]) or 0
						end
						cleanAmps[a] = ca
					end
					amps = ca
				end
				if not amps then
					alive = false
				else
					local g = v.level * p.atten * chGain / SINE_GAIN
					local partials = a.partials
					-- samples that repeat every two root periods are analysed an octave down
					local fund = freq * (a.fundamental or 1) * (clean and meanPitch(a) or pitchRatio(a, v.sampleTime))
					local strongest = 0
					for i = 1, math.min(#partials, self.partials, #amps) do
						strongest = math.max(strongest, amps[i])
					end
					local groups = a.groups
					local P = #partials
					if groups then
						for j = 1, #groups do
							strongest = math.max(strongest, amps[P + j])
						end
					end
					local floorAmp = strongest * 0.003 -- skip parts 50 dB below the strongest (saves players)
					if phaseLocked(a) then
						-- phase-locked voice: each harmonic follows the sample's own phase. Its speed for the coming
						-- frame is chosen so it reaches the phase the sample has at the next update (the frame's
						-- correction rides on the speed), which keeps the shape of every vocal pulse
						local U = a.phaseFrames
						local nU = #U
						local hopA = a.hop
						local sp = p.speed or 1
						local dtn = math.clamp(dt, 1 / 240, 1 / 20)
						local s0 = v.sampleTime
						local bendR = (c.bend ~= 0) and 2 ^ (c.bend * c.bendRange / 12) or 1

						local function target(k, st)
							local fpos = math.max(st, 0) / hopA
							local j = math.floor(fpos)
							if j + 2 > nU then
								local r1, r0 = U[nU], U[math.max(1, nU - 1)]
								return r1[k] + (r1[k] - r0[k]) * (fpos - (nU - 1))
							end
							local ra, rb = U[j + 1], U[j + 2]
							return ra[k] + (rb[k] - ra[k]) * (fpos - j)
						end
						v.ph, v.fq, v.on = v.ph or {}, v.fq or {}, v.on or {}
						local ph, fq, on = v.ph, v.fq, v.on
						local s1 = s0 + dtn * sp
						if a.pairs and debugHost:GetAttribute("PhaseLockedVoice") == true then
							-- Two sines per harmonic at one volume for the whole note; the loudness a = 2 V cos(2 pi d) is
							-- set by steering them to phases target +- d (no volume change every frame: the engine ramps a
							-- volume change and then holds it, which is heard as a faint echo).
							-- The engine reads a player's speed once per audio block (1024 samples, ~21 ms) and applies it
							-- for the whole block, exactly. So the parts are steered per block: while block n runs, the
							-- speed for block n+1 is chosen so each sine lands on its target phase at the end of block n+1.
							local K = #U[1]
							local B, blk = self:_blockClock()
							local gFull = p.atten * chGain / SINE_GAIN
							v.pv = v.pv or {}
							local pv = v.pv
							if not v.pvMax then
								-- per-harmonic peak over the whole sample, once per note
								local mx = {}
								local top = 0
								for _, row in ipairs(a.frames) do
									for j = 1, K do
										local x = row[j] or 0
										if x > (mx[j] or 0) then
											mx[j] = x
										end
										if x > top then
											top = x
										end
									end
								end
								v.pvMax, v.pvTop = mx, top
							end
							local len = (a.length or 1) - 1e-4
							local function need(j, st, out)
								local am = additiveAmps(a, math.min(st, len), out)
								return am and (am[j] or 0) * g or 0
							end
							-- block bookkeeping: v.nextB = boundary that ends the block whose speed is already decided,
							-- v.bS = sample time at the boundary that starts it
							local decide = false
							local fresh = v.nextB == nil
							if fresh then
								if prep then
									for i = 1, sineSlots do
										pool:setVoice(v.slot + i - 1, 0, 0, 0)
									end
								else
									v.nextB = B + 2 -- a seek written now lands on boundary B + 1
									v.bS = 0
									decide = true
									-- the consonant: onset bursts start with the note's sines, on the same block boundary
									if a.bursts then
										for _, b in ipairs(a.bursts) do
											self:_playBurst(b.name, b.gain * p.atten * chGain, sp, v.channel + 1)
										end
									end
								end
							elseif B >= v.nextB - 1 then
								-- blocks that started before the decision ran at the speed already set
								while B > v.nextB - 1 do
									for i, f in pairs(fq) do
										ph[i] += f * blk
									end
									v.bS += blk * sp
									v.nextB += 1
								end
								decide = true
							end
							if v.nextB then
								v.namps = v.namps or {}
								-- fresh: the decided block starts at v.bS; otherwise the next block starts where the current one ends
								local sStart = fresh and 0 or (v.bS + blk * sp)
								local sEnd = sStart + blk * sp
								for j = 1, K do
									local slotA, slotB = v.slot + j - 1, v.slot + K + j - 1
									local mxj = v.pvMax[j] or 0
									v.pOff = v.pOff or {}
									if decide and a.smooth then
										-- a pair whose level has faded to nothing stops (both players at once: their sum is ~0),
										-- and starts again fresh if the level comes back
										local nEnd = need(j, sEnd, v.namps)
										if nEnd < PART_FLOOR * 0.5 then
											if not v.pOff[j] then
												v.pOff[j] = true
												pv[j], ph[j], ph[K + j] = nil, nil, nil
											end
										elseif v.pOff[j] and nEnd > PART_FLOOR then
											v.pOff[j] = nil
										end
									end
									if v.pOff[j] then
										pool:setVoice(slotA, 0, 0, 0)
										pool:setVoice(slotB, 0, 0, 0)
									elseif mxj > v.pvTop * 0.003 and gFull * mxj > PART_FLOOR then
										for side = 1, 2 do
											local i = (side == 1) and j or (K + j)
											local slot = (side == 1) and slotA or slotB
											if decide then
												local sg = (side == 1) and 1 or -1
												local V = pv[j]
												local n1 = need(j, sEnd, v.namps)
												if not V or n1 > 2 * V then
													V = math.max(gFull * mxj, n1) * 0.5 * 1.05
													pv[j] = V
												end
												local d1 = math.acos(math.clamp(n1 / (2 * V), 0, 1)) / (2 * math.pi)
												local u0, u1 = target(j, sStart) * bendR, target(j, sEnd) * bendR
												local startPh
												if fresh or ph[i] == nil then
													local n0 = need(j, sStart, v.namps)
													startPh = u0 + sg * math.acos(math.clamp(n0 / (2 * V), 0, 1)) / (2 * math.pi)
												else
													startPh = ph[i] + fq[i] * blk -- phase where the running block ends
												end
												local adv = u1 - u0
												local err = (u1 + sg * d1) - (startPh + adv)
												err -= math.floor(err + 0.5)
												local f = (adv + err) / blk
												if f <= 1 or f >= MAX_PARTIAL_HZ then
													f = math.clamp(adv / blk, 1, MAX_PARTIAL_HZ - 1)
												end
												ph[i], fq[i] = startPh, f -- ph = phase where the decided block starts
											end
											pool:setVoice(slot, SINE, fq[i], pv[j], v.channel + 1, ph[i] % 1, "exact")
										end
									else
										pool:setVoice(slotA, 0, 0, 0)
										pool:setVoice(slotB, 0, 0, 0)
									end
								end
								if decide then
									if not fresh then
										v.bS = sStart
									end
									if not fresh then
										v.nextB += 1
									end
								end
							end
							-- smooth mode: the strongest harmonics are pairs (above); the rest are ordinary sines
							v.son = v.son or {}
							local son = v.son
							for i = 2 * K + 1, sineSlots do
								local k = a.smooth and partials[i]
								local lim = son[i] and 0.3 or 1
								if k and (amps[i] or 0) > floorAmp * lim and g * amps[i] > PART_FLOOR * lim then
									son[i] = true
									local f = fund * k
									if f < MAX_PARTIAL_HZ and f > 20 then
										pool:setVoice(v.slot + i - 1, SINE, f, g * amps[i], v.channel + 1, (a.phases and a.phases[i]) or nil, false)
									else
										pool:setVoice(v.slot + i - 1, 0, 0, 0)
									end
								else
									son[i] = nil
									pool:setVoice(v.slot + i - 1, 0, 0, 0)
								end
							end
						else
						local Kp = #U[1] -- harmonics that have phase data (the partial list can be longer)
						v.fundNow = fund -- read by in-game checks
						for i = 1, sineSlots do
							local k = i <= Kp and partials[i]
							local slot = v.slot + i - 1
							-- Bend: the sample's phase is a running total, so multiplying it by the bend ratio would make the target
							-- jump every time the bend moved (a scoop = a chain of jumps). Instead the bend's extra
							-- cycles are summed frame by frame: target = sample phase + bo, speed = sample speed x bend ratio.
							local bo, rr0, rr1 = v.bo, nil, nil
							if not bo then
								bo = {}
								v.bo = bo
							end
							local fixBend = debugHost:GetAttribute("NoBendFix") ~= true
							local off = 0
							if k then
								rr0, rr1 = target(i, s0), target(i, s1)
								if fixBend then
									off = bo[i] or 0
									if not prep then
										bo[i] = off + (rr1 - rr0) * (bendR - 1)
									end
								end
							end
							-- the player keeps running at its last speed while it is muted (and a new one is started at the
							-- tracked phase), so the tracked phase advances every frame, sounding or not
							local cur = ph[i]
							if cur then
								cur += fq[i] * dt
								ph[i] = cur
							end
							-- on/off with hysteresis: a part that flickers around the floor would restart every frame
							local lim = on[i] and 0.3 or 1
							if k and (amps[i] or 0) > floorAmp * lim and g * amps[i] > PART_FLOOR * lim then
								local t0, adv
								if fixBend then
									t0 = rr0 + off
									adv = (rr1 - rr0) * bendR
								else
									t0 = rr0 * bendR
									adv = rr1 * bendR - t0
								end
								if not cur then
									cur = t0
								end
								local f
								if prep then
									f = adv / dtn -- not sounding yet: run at the nominal speed, corrected when the note starts
								else
									local err = t0 - cur
									err -= math.floor(err + 0.5)
									-- a big phase error is not pulled back: the part re-anchors on its current phase and follows
									-- the sample's phase increments from there. (After the PHASE_DEV clamp below overrides a messy
									-- onset frame the part can be most of a cycle off its target, and the gentle pull, <= 0.5 % +
									-- 0.5 Hz, would leave a short one-shot sharp, every harmonic at its own offset.)
									if fixBend and math.abs(err) > PHASE_REANCHOR and not prep then
										bo[i] = (bo[i] or 0) - err
										t0 -= err
										err = 0
									end
									-- pulled back toward the sample's phase gently: a frame the engine applied late (or a stall)
									-- never turns into an audible pitch jump
									local nominal = adv / dtn
									local lim = math.abs(nominal) * PHASE_PULL + 0.5
									f = nominal + math.clamp(err / dtn, -lim, lim)
								end
								-- the sample's phase on a weak harmonic is barely measurable: following it made that harmonic jump
								-- 10-60% between frames. Each harmonic moves freely within PHASE_DEV of its place in the series.
								local ref = fund * k
								if ref > 0 then
									local fBefore = f
									f = math.clamp(f, ref * (1 - PHASE_DEV), ref * (1 + PHASE_DEV))
									if debugHost:GetAttribute("PLDiag") == true and not prep and i == 1 then
										-- diagnostics: how often the first harmonic is clamped / how far it is from its target
										local d = PLDiag[v.channel]
										if not d then
											d = { n = 0, clamp = 0, errAbs = 0, errMax = 0, devSum = 0, dev = 0 }
											PLDiag[v.channel] = d
										end
										local e = math.abs(t0 - cur)
										e = math.abs(e - math.floor(e + 0.5))
										d.n += 1
										d.errAbs += e
										d.errMax = math.max(d.errMax, e)
										if f ~= fBefore then d.clamp += 1 end
										d.devSum += math.abs(fBefore / ref - 1)
										if d.n % 100 == 0 then
											debugHost:SetAttribute("PL" .. v.channel, string.format("n=%d clamped=%.0f%% errAvg=%.3f errMax=%.2f cyc devAvg=%.2f%% fund=%.1f", d.n, 100 * d.clamp / d.n, d.errAbs / d.n, d.errMax, 100 * d.devSum / d.n, fund))
										end
									end
								end
								if f > 1 and f < MAX_PARTIAL_HZ then
									pool:setVoice(slot, SINE, f, g * amps[i], v.channel + 1, cur % 1, "exact")
									ph[i], fq[i], on[i] = cur, f, true
								else
									pool:setVoice(slot, 0, 0, 0)
									on[i] = nil
								end
							else
								pool:setVoice(slot, 0, 0, 0)
								on[i] = nil
							end
						end
						end
					else
					v.son = v.son or {}
					local son = v.son
					-- Tracked parts (see trackPart): while a part decays (the envelope's decay to silence or its release, or
					-- the sample's own decay past the partial's peak) it plays from the decaying sine closest to its decay
					local track = DECAY and blockB and not prep and not a.exactCycle and not a.phases and decayReady() and debugHost:GetAttribute("NoDecay") ~= true
					local envRate = 0
					if track then
						if v.stage == "decay" and (p.decay or 0) > 0 then
							local target = (p.sustain > 0) and math.min(-20 * math.log10(p.sustain), FLOOR_DB) or FLOOR_DB
							if v.atten < target - 1 then
								envRate = FLOOR_DB / p.decay / 8.686 -- amplitude e-folds per second
							end
						elseif v.stage == "release" then
							envRate = (p.release or 0) > 0 and FLOOR_DB / p.release / 8.686 or math.huge
						end
					end
					local sTaus = track and sampleTaus(a) or nil
					local sp = p.speed or 1
					-- modes (Instruments modesFit): the harmonics they replace play from the frames until the modes take over
					local modes = a.modes and blockB and #a.modes <= self.modeSlots and debugHost:GetAttribute("NoModes") ~= true and a.modes or nil
					local fund0 = freq * (a.fundamental or 1)
					local tauNow = blockB and (blockB + 1 - (v.blk0 or blockB + 1)) * blockDur or 0 -- real seconds since the note's first block
					local function switchTau(k)
						-- real time of the first block boundary at or after the modes' start (sample time a.modeK[k])
						return math.ceil(a.modeK[k] / (blockDur * sp) - 1e-9) * blockDur
					end
					for i = 1, sineSlots do
						local k = partials[i]
						local modeK = modes and k and a.modeK[k]
						if modeK and tauNow >= switchTau(k) then
							k = nil -- the modes play this harmonic now
						end
						-- on/off with hysteresis: a part hovering at the floor would drop out and come back every few
						-- frames (a shuffling texture on single tones); once on it stays on down to 0.3x
						local lim = son[i] and 0.3 or 1
						if k and (amps[i] or 0) > floorAmp * lim and g * amps[i] > PART_FLOOR * lim then
							son[i] = true
							local f = fund * k
							local fold = a.imageFrom and i >= a.imageFrom and a.imageFoldHz
							if fold and f > fold then
								f = 2 * fold - f -- a playback image above the original's Nyquist folds back, as it did there
							end
							local startPh = (a.phases and a.phases[i]) or (a.phaseFrames and a.phaseFrames[1][i] and a.phaseFrames[1][i] % 1)
							local wave, vol, ph, fastMode = SINE, g * amps[i], startPh or (phaseSpread and partialPhase(k) or nil), a.exactCycle and "exact" or (a.voice == true)
							if modeK then
								-- start phase chosen so the frames' sine is in phase with the modes where they take over
								v.mph = v.mph or {}
								local mp = v.mph[i]
								if not mp then
									local tw = switchTau(k)
									local cr, ci = 0, 0
									for _, md in ipairs(modes) do
										if md.k == k then
											local amp = md.a * math.exp(md.l * sp * tw)
											local th = 2 * math.pi * (md.p + md.r * fund0 * tw)
											cr += amp * math.cos(th)
											ci += amp * math.sin(th)
										end
									end
									mp = (math.atan2(ci, cr) / (2 * math.pi) - f * (tw - tauNow)) % 1
									v.mph[i] = mp
								end
								ph = mp
							end
							if track and f < MAX_PARTIAL_HZ and f > 20 then
								local rate = envRate
								local sd = sTaus and sTaus[i]
								if sd and v.sampleTime >= sd.peak then
									rate += sp / sd.tau
								end
								wave, vol, ph = trackPart(v, i, f, vol, ph, rate, blockB, blockDur)
								fastMode = "exact"
							end
							if f < MAX_PARTIAL_HZ and f > 20 then
								pool:setVoice(v.slot + i - 1, wave, f, vol, v.channel + 1, ph, fastMode)
							else
								pool:setVoice(v.slot + i - 1, 0, 0, 0)
							end
						else
							son[i] = nil
							pool:setVoice(v.slot + i - 1, 0, 0, 0)
						end
					end
					-- the modes: one sine each at its own frequency, phase and decay
					local mBase = sineSlots + GROUP_COUNT
					for j = 1, self.modeSlots do
						local md = modes and modes[j]
						local key = mBase + j
						local slot = v.slot + key - 1
						local on = false
						if md and tauNow >= switchTau(md.k) then
							local f = md.r * fund0 -- (freq carries the bend)
							local amp = md.a * math.exp(md.l * (tauNow + 0.5 * blockDur) * sp)
							local lim = son[key] and 0.3 or 1
							if f > 20 and f < MAX_PARTIAL_HZ and amp > floorAmp * lim and g * amp > PART_FLOOR * lim then
								on = true
								son[key] = true
								local wave, vol, ph, fastMode = SINE, g * amp, (md.p + md.r * fund0 * tauNow) % 1, nil
								if track then
									wave, vol, ph = trackPart(v, key, f, vol, ph, envRate + math.max(0, -md.l) * sp, blockB, blockDur)
									fastMode = "exact"
								end
								pool:setVoice(slot, wave, f, vol, v.channel + 1, ph, fastMode)
							end
						end
						if not on then
							son[key] = nil
							pool:setVoice(slot, 0, 0, 0)
						end
					end
					-- rough sines: next to each harmonic of a voice sample, a narrow band of noise at the level of that harmonic's
					-- fast motion (WaveBank.RoughWave). Without it a voice built from steady sines sounds 8-bit.
					if self.roughSlots > 0 and (a.rough or v.ron) then
						local rr = a.rough and debugHost:GetAttribute("NoRough") ~= true and roughAmps(a, ampTime, v.ramps or {}) or nil
						if rr then
							v.ramps = rr ~= a.rough[#a.rough] and rr or v.ramps
						end
						-- the rough layer is a noise texture: its level need not follow the 10 ms frames. Each block's step
						-- in its level is a sideband pair 47 Hz either side of the harmonic (half of the sub-fundamental skirt
						-- of a high vocal note); a one-pole follower (RoughSmooth seconds) keeps the texture with smaller steps
						local rsm = tonumber(debugHost:GetAttribute("RoughSmooth")) or ROUGH_SMOOTH
						if rr and rsm > 0 and not prep then
							v.rsm = v.rsm or {}
							local al = 1 - math.exp(-math.clamp(dt, 1 / 240, 1 / 20) / rsm)
							local out = v.rsm
							for k = 1, #rr do
								local y = out[k]
								out[k] = y and (y + (rr[k] - y) * al) or rr[k]
							end
							for k = #out, #rr + 1, -1 do
								out[k] = nil
							end
							rr = out
						end
						local rg = v.level * p.atten * chGain / WaveBank.RoughRms * (tonumber(debugHost:GetAttribute("RoughGain")) or 1)
						v.ron = v.ron or {}
						for j = 1, self.roughSlots do
							local slot = v.slot + self.roughBase + j - 1
							local k = partials[j]
							local r = rr and rr[j] or 0
							local lim = v.ron[j] and 0.3 or 1
							local f = k and fund * k or 0
							if k and r > floorAmp * lim and rg * r > PART_FLOOR * lim and f > 20 and f < MAX_PARTIAL_HZ then
								-- a new partner starts somewhere random in the 3.9 s loop, so chops don't all repeat one pattern
								local ph = (not v.ron[j]) and math.random() * 3000 or nil
								v.ron[j] = true
								pool:setVoice(slot, WaveBank.RoughWave, f, rg * r, v.channel + 1, ph)
							elseif v.ron[j] then
								v.ron[j] = nil
								pool:setVoice(slot, 0, 0, 0)
							end
						end
						if not next(v.ron) then
							v.ron = nil
						end
					end
					end
					-- harmonic bundles: one player per higher octave of harmonics
					local base = v.level * p.atten * chGain / BUNDLE_AMP
					local r = WaveBank.bundleRange(fund)
					for gi = 1, GROUP_COUNT do
						local slot = v.slot + sineSlots + gi - 1
						local amp = 0
						local wasFine = v.fon and v.fon[gi]
						if v.fon then
							v.fon[gi] = nil -- set again below when the fine bundles are used this frame
						end
						if groups and r then
							for j = 1, #groups do
								if groups[j] == gi then
									amp = amps[P + j]
									break
								end
							end
						end
						-- pulse bundles (every harmonic of the group peaking together, once per period, in step with the
						-- sines) replace the older smeared bundles wherever a pulse file fits the note: the smeared ones buzz
						-- bundles get the same on/off hysteresis as the sines
						v.bon = v.bon or {}
						local blim = v.bon[gi] and 0.3 or 1
						local bOn = amp > floorAmp * blim and base * amp > PART_FLOOR * 4 * blim
						v.bon[gi] = bOn or nil
						local pr = (bOn and not noBundles and not noPulses and WaveBank.pulseRange) and WaveBank.pulseRange(gi, fund, v.prange and v.prange[gi]) or nil
						if pr then
							v.prange = v.prange or {}
							v.prange[gi] = pr
							local pc = WaveBank.pulseCoverage(gi, pr, fund)
							local rms = WaveBank.PulseRms[gi * 100 + pr]
							if pc > 0 and rms then
								pool:setVoice(slot, WaveBank.PulseWave0 + gi, fund, v.level * p.atten * chGain * amp * math.sqrt(pc) / (math.sqrt(2) * rms) * bundleGain, v.channel + 1, WaveBank.PulseClick, "exact")
							else
								pool:setVoice(slot, 0, 0, 0)
							end
						elseif bOn and not noBundles and self.stride > self.partials and WaveBank.fineReady(gi, r) then
							-- fine harmonic bundles (harmonics pack): this octave's level, shared among its narrower groups by the 1/k tilt
							pool:setVoice(slot, 0, 0, 0)
							v.fon = v.fon or {}
							v.fon[gi] = true
							for _, f in ipairs(WaveBank.FineOf[gi]) do
								local fslot = v.slot + self.partials + f - 1
								local share = WaveBank.fineShare(gi, f, r)
								if share > 0 then
									pool:setVoice(fslot, WaveBank.FineWave0 + f, fund, base * amp * math.sqrt(share) / WaveBank.fineGain(f, r) * bundleGain, v.channel + 1)
								else
									pool:setVoice(fslot, 0, 0, 0)
								end
							end
						elseif bOn and not noBundles then
							local cov = WaveBank.bundleCoverage(gi, r, fund)
							local gain = WaveBank.BundleGain[gi * 100 + r] or 1
							if cov > 0 then
								pool:setVoice(slot, WaveBank.BundleWave0 + gi, fund, base * amp * math.sqrt(cov) / gain * bundleGain, v.channel + 1)
							else
								pool:setVoice(slot, 0, 0, 0)
							end
						else
							pool:setVoice(slot, 0, 0, 0)
						end
						if wasFine and not (v.fon and v.fon[gi]) then
							for _, f in ipairs(WaveBank.FineOf[gi]) do
								pool:setVoice(v.slot + self.partials + f - 1, 0, 0, 0)
							end
						end
					end
					-- residual noise (attack clicks, breath): through the shared noise bands, key-shifted like
					-- a sample, with the voice's envelope
					local res = USE_RESIDUAL and not noResidual and not (a.voice and (debugHost:GetAttribute("CleanVoice") == true or debugHost:GetAttribute("NoVoiceNoise") == true)) and a.residual or nil
					if res then
						local fpos = loopTime(a, v.sampleTime + (blockHalf and blockHalf * (p.speed or 1) or 0)) / res.hop
						local fi = math.floor(fpos)
						local rframes = res.frames
						local r0 = rframes[math.min(fi + 1, #rframes)]
						local r1 = rframes[math.min(fi + 2, #rframes)]
						local frac = fpos - fi
						if fi + 2 > #rframes then
							local i2, f2 = wrapPos(a, fi, #rframes)
							if i2 then
								r1 = rframes[math.clamp(i2 + 1 + (f2 >= 0.5 and 1 or 0), 1, #rframes)]
								frac = math.min(frac, 1)
							end
						end
						local rScale, rLow = residualScale(a, res)
						local gn = v.level * p.atten * chGain * rScale
						if r0 and gn > 0 then
							local gl, gr = 1, 1
							if stereo then
								gl, gr = panGains(c.pan / 127)
							end
							local shift = 2 * math.log(p.speed or 1, 2)
							local cut = math.min((debugHost:GetAttribute("ResidualCut") or 8) * fund, debugHost:GetAttribute("ResidualCutMax") or RESIDUAL_CUT_MAX) / 1.19
							for d = 1, CHAIN_N do
								if CHAIN_FC[d] <= cut then
									continue
								end
								local sp = d - shift
								local i0 = math.floor(sp)
								local tt = sp - i0
								local l = 0
								if i0 >= 1 and i0 <= CHAIN_N then
									l += (r0[i0] + (r1[i0] - r0[i0]) * frac) * (1 - tt) * (i0 <= RESIDUAL_LOW_BINS and rLow or 1)
								end
								if i0 + 1 >= 1 and i0 + 1 <= CHAIN_N then
									l += (r0[i0 + 1] + (r1[i0 + 1] - r0[i0 + 1]) * frac) * tt * (i0 + 1 <= RESIDUAL_LOW_BINS and rLow or 1)
								end
								if l > 0 then
									l *= gn
									local band = CHAIN[d]
									levels[band] += (l * gl) ^ 2
									levelsR[band] += (l * gr) ^ 2
								end
							end
						end
					end
				end
			elseif alive then
				pool:setVoice(v.slot, p.wave, freq, v.level * p.gain * chGain, v.channel + 1)
			end
			if not alive then
				v.active = false
				self:_silenceVoice(v)
			end
		end
	end
	prep = nil
	pool = realPool
	if self.sf and self.clock - (self.sfSweepAt or 0) > 2 then
		self.sfSweepAt = self.clock
		self.sf:sweep()
	end
	local budget = self.maxPlayers
	diag(self, self.frameDt or dt, nreq, budget)
	if nreq <= budget then
		for i = 1, nreq do
			pool:setVoice(reqSlot[i], reqWave[i], reqFreq[i], reqVol[i], reqBus[i], reqPhase[i], reqFast[i])
		end
	else
		local slots = pool.slots
		for i = 1, nreq do
			local sl = slots[reqSlot[i]]
			reqPri[i] = (reqVol[i] < 0) and 1e9 or reqVol[i] * ((sl and sl.rec) and 1.5 or 1)
			reqOrder[i] = i
		end
		for i = nreq + 1, #reqOrder do
			reqOrder[i] = nil
		end
		table.sort(reqOrder, function(a, b)
			return reqPri[a] > reqPri[b]
		end)
		for r = 1, nreq do
			local i = reqOrder[r]
			if r <= budget then
				pool:setVoice(reqSlot[i], reqWave[i], reqFreq[i], reqVol[i], reqBus[i], reqPhase[i], reqFast[i])
			else
				pool:setVoice(reqSlot[i], 0, 0, 0)
			end
		end
		self.stats.dropped = (self.stats.dropped or 0) + (nreq - budget)
	end
	-- noise: synthesized kit hits and analysed percussion samples, summed per band
	local dc = self.channels[self.drumChannel or DEFAULT_DRUM_CHANNEL]
	local kitGain = ccCurve(dc.volume) * ccCurve(dc.expression) * master
	for i = #self.noiseHits, 1, -1 do
		local h = self.noiseHits[i]
		if h.fresh then
			h.fresh = nil
			h.age += blockHalf or 0 -- block-ahead: a hit starting on this block's boundary is drawn at its middle
		else
			h.age += dt
		end
		local keep = true
		local gl, gr = 1, 1
		if stereo then
			gl, gr = panGains(h.pan or 0.5)
		end
		if h.kit then
			local env = math.exp(-h.age * 5 / h.kit.decay) * h.gain * kitGain
			if env < SILENT then
				keep = false
			else
				for j, band in ipairs(h.kit.bands) do
					local l = h.kit.levels[j] * env
					levels[band] += (l * gl) ^ 2
					levelsR[band] += (l * gr) ^ 2
				end
			end
		else
			local s = h.sample
			local tau = h.age * s.speed
			local fpos = tau / s.hop
			local fi = math.floor(fpos)
			local frames = s.frames
			local env = 10 ^ (-(h.age * FLOOR_DB / s.decay) / 20) * h.gain
			if fi + 1 > #frames or env < SILENT then
				keep = false
			else
				local f0, f1 = frames[fi + 1], frames[fi + 2] or frames[fi + 1]
				local frac = fpos - fi
				for j, band in ipairs(s.bands) do
					local l = (f0[j] + (f1[j] - f0[j]) * frac) * env
					levels[band] += (l * gl) ^ 2
					levelsR[band] += (l * gr) ^ 2
				end
			end
		end
		if not keep then
			table.remove(self.noiseHits, i)
		end
	end
	for b = 1, #levels do
		pool:setBand(b, math.sqrt(levels[b]), math.sqrt(levelsR[b]))
	end
	pool:update(dt)
end

function MidiSynth:activeVoices()
	local n = 0
	for _, v in ipairs(self.voices) do
		if v.active then
			n += 1
		end
	end
	return n + #self.noiseHits
end

function MidiSynth:_dispatch(ev)
	local kind = ev.kind
	if kind == "noteOn" then
		self:noteOn(ev.channel, ev.a, ev.b)
	elseif kind == "noteOff" then
		self:noteOff(ev.channel, ev.a)
	elseif kind == "cc" then
		self:controlChange(ev.channel, ev.a, ev.b)
	elseif kind == "program" then
		self:programChange(ev.channel, ev.a)
	elseif kind == "pitchBend" then
		self:pitchBend(ev.channel, ev.a)
	end
end

function MidiSynth.findLoop(midi)
	local startTime, endTime = nil, nil
	for _, ev in ipairs(midi.events) do
		if ev.kind == "meta" and (ev.metaType == 6 or ev.metaType == 1 or ev.metaType == 7) then
			local t = string.lower(string.gsub(ev.data or "", "[%s_%-]", ""))
			if t == "loopstart" or t == "loop" or string.sub(t, 1, 9) == "loopstart" then
				startTime = startTime or ev.time
			elseif t == "loopend" or string.sub(t, 1, 7) == "loopend" then
				endTime = endTime or ev.time
			end
		elseif ev.kind == "cc" and ev.a == 111 then
			startTime = startTime or ev.time
		end
	end
	startTime = startTime or 0
	endTime = endTime or midi.duration
	if endTime <= startTime then
		startTime, endTime = 0, midi.duration
	end
	return startTime, endTime
end

local function firstEventAt(events, t)
	local lo, hi = 1, #events + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if events[mid].time < t then
			lo = mid + 1
		else
			hi = mid
		end
	end
	return lo
end

function MidiSynth:play(midi, options)
	if typeof(midi) == "buffer" or type(midi) == "string" then
		midi = Midi.decode(midi)
	end
	options = options or {}
	self:stop()
	self.midi = midi
	self.loop = options.Loop == true
	self.speed = options.Speed or 1
	self.loopStartTime, self.loopEndTime = MidiSynth.findLoop(midi)
	self.loopCount = 0
	self:seek(options.StartTime or 0)
	self:_connect()
end

-- Jump to a time (seconds): silences everything and rebuilds every channel's controller and
-- program state from the events before that time. Works while playing or paused.
function MidiSynth:seek(t)
	local midi = self.midi
	if not midi then
		return
	end
	t = math.clamp(t, 0, midi.duration)
	self:allNotesOff(nil, true)
	for c = 0, 15 do
		self.channels[c] = newChannel()
		self.pool:setBusPan(c + 1, 0.5)
	end
	local events = midi.events
	-- notes that began before t and are still held at t must sound too (seeking into the middle of a song
	-- keeps every sustained instrument playing)
	local open = {}
	do
		local i = 1
		while i <= #events and events[i].time < t do
			local ev = events[i]
			if ev.kind == "noteOn" and (ev.b or 0) > 0 then
				open[ev.channel * 128 + ev.a] = i
			elseif ev.kind == "noteOn" or ev.kind == "noteOff" then
				open[ev.channel * 128 + ev.a] = nil
			end
			i += 1
		end
	end
	local heldAt = {}
	for _, i in pairs(open) do
		heldAt[i] = true
	end
	local idx = 1
	while idx <= #events and events[idx].time < t do
		local ev = events[idx]
		if ev.kind ~= "noteOn" and ev.kind ~= "noteOff" then
			self:_dispatch(ev)
		elseif heldAt[idx] then
			self:noteOn(ev.channel, ev.a, ev.b)
		end
		idx += 1
	end
	self.eventIndex = idx
	self.preIndex = idx
	self.pre = {}
	self.time = t
	self.bsB = nil -- block-ahead: the next block starts the song clock again at its middle
end

function MidiSynth:getTime()
	return self.warmT0 or self.time or 0
end

function MidiSynth:getDuration()
	return self.midi and self.midi.duration or 0
end

function MidiSynth:pause()
	self._token = (self._token or 0) + 1
	self.warming, self.warmT0, self.warmGain, self.pool.trackFresh = false, nil, nil, false
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	self.paused = true
	self.playing = false
	self:allNotesOff(nil, true)
	self.pool:silence()
	self.pool:update(1)
	self.pool:stopAll()
	if self.sf then
		self.sf:stopAll()
	end
end

function MidiSynth:resume()
	if self.midi and not self.conn and not self.warming then
		self:_connect()
	end
end

-- Start-up warm-up. A cold AudioPlayer is silent for a moment, so the first seconds of a song lost the
-- attacks of whatever notes started on players created on the spot. Before the clock starts, the first
-- PREROLL seconds of music are played through the real sequencer at -60 dB (a few steps per frame, so there
-- is no hitch), which creates and starts exactly the players those notes need; then everything is put back
-- to the start position and the song waits until every fresh player is really producing samples.
local PREROLL, PREROLL_STEP, PREROLL_PER_FRAME, WARM_GAIN = 1.0, 1 / 20, 1, 1e-3 -- one step per frame: its player starts spread out

function MidiSynth:_preroll(step, token)
	local pool = self.pool
	local t0, loops = self.time, self.loopCount
	self.warmT0 = t0
	self.warmGain = WARM_GAIN
	pool.trackFresh = true
	pool.warmReserve, pool.idleStop = 256, 4 -- keep everything the warm-up starts running until the song is under way
	for k = 1, math.floor(PREROLL / PREROLL_STEP + 0.5) do
		step(PREROLL_STEP / self.speed)
		if k % PREROLL_PER_FRAME == 0 then
			task.wait()
			if self._token ~= token then
				return
			end
		end
	end
	self.warmGain = nil
	self:seek(t0)
	self.loopCount = loops
	pool:update(0.25)
	pool:update(0.05)
	local waited = 0
	while not pool:ready() and waited < 1.0 do
		waited += task.wait()
		if self._token ~= token then
			return
		end
	end
end

function MidiSynth:_connect()
	self.paused = false
	self.playing = true
	-- live playback: at most a few player starts per frame (a burst of starts freezes the frame, see OscillatorPool)
	self.pool.startBudget = OscillatorPool.START_BUDGET
	self.pool:warm()
	local frame, step = self:_build()
	self._token = (self._token or 0) + 1
	local token = self._token
	if self.prewarm == false then
		self.conn = RunService.Heartbeat:Connect(frame)
		return
	end
	self.warming = true
	task.spawn(function()
		local ok, err = pcall(self._preroll, self, step, token)
		if self._token ~= token then
			return
		end
		self.warming, self.warmT0, self.warmGain, self.pool.trackFresh = false, nil, nil, false
		self.warmTrimAt = self.clock + 3
		if not ok then
			warn("MidiSynth warm-up failed: " .. tostring(err))
		end
		if self.playing and not self.conn then
			self.conn = RunService.Heartbeat:Connect(frame)
		end
	end)
end

function MidiSynth:_build()
	local midi = self.midi
	local events = midi.events
	local step = function(dt)
		self.time += dt * self.speed
		if self.loop and self.time >= self.loopEndTime then
			while self.eventIndex <= #events do
				local ev = events[self.eventIndex]
				if ev.time > self.loopEndTime or (ev.time == self.loopEndTime and ev.kind == "noteOn") then
					break
				end
				self:_dispatch(ev)
				self.eventIndex += 1
			end
			self:allNotesOff(nil, false)
			self.time = self.loopStartTime + (self.time - self.loopEndTime)
			self.eventIndex = firstEventAt(events, self.loopStartTime)
			self.preIndex = self.eventIndex
			self.pre = {}
			self.loopCount += 1
		end
		local pre = self.pre
		while self.eventIndex <= #events and events[self.eventIndex].time <= self.time do
			local idx = self.eventIndex
			if not pre[idx] then
				self:_dispatch(events[idx])
			end
			pre[idx] = nil
			self.eventIndex += 1
		end
		-- lookahead: note-ons in the next LOOKAHEAD seconds start their players now (silently), so every
		-- part is running and in phase when the note is due. A channel with a program/controller change
		-- before its note in that window is left to normal dispatch.
		local look = self.time + LOOKAHEAD
		if self.loop then
			look = math.min(look, self.loopEndTime)
		end
		local pi = math.max(self.preIndex or 1, self.eventIndex)
		local blocked = nil
		while pi <= #events and events[pi].time <= look do
			local ev = events[pi]
			if ev.kind == "noteOn" and (ev.b or 0) > 0 then
				if not (blocked and blocked[ev.channel]) and not pre[pi] then
					pre[pi] = true
					self:noteOn(ev.channel, ev.a, ev.b, ev.time - self.time)
				end
			elseif ev.kind ~= "noteOff" and ev.kind ~= "meta" then
				blocked = blocked or {}
				blocked[ev.channel or -1] = true
			end
			pi += 1
		end
		self.preIndex = pi
		self:update(dt * self.speed)
		if not self.warmGain and not self.loop and self.eventIndex > #events and self.time >= midi.duration and self:activeVoices() == 0 then
			self:stop()
			self._ended:Fire()
		end
	end
	-- Block-ahead mode (attribute BlockAhead = true on the AudioLab folder; read every frame, so it can be flipped while a
	-- song plays). The engine reads each player's speed and volume once per audio block (1024 samples, ~21 ms) and a write
	-- lands on the next block boundary. Per frame, the synth renders "now" ~5 times per block and only the last render
	-- before the boundary counts, so a note starts up to a whole block (plus frame jitter) after its time. Here the synth
	-- renders once per block, as soon as a block starts, for the block after it: the song clock stands at the middle of
	-- that block, so every note starts on the boundary nearest its time, every level is the block's own, and the frames
	-- in between only start players that were held back by the start budget.
	self.bsB = nil
	local function frame(dt)
		local pool = self.pool
		if debugHost:GetAttribute("BlockAhead") ~= true then
			self.bsB, self.blockHalf, self.frameDt = nil, nil, nil
			pool.pendingStart, pool.pendingMake = nil, nil
			step(dt)
			return
		end
		local B, blk = self:_blockClock()
		local last = self.bsB
		if last == B then
			self.pool:startPending()
			return
		end
		self.bsB = B
		self.blockHalf = 0.5 * blk * self.speed
		self.frameDt = dt
		pool.pendingStart, pool.pendingMake = nil, nil
		if last == nil then
			step(0.5 * blk) -- first block: the song clock moves to its middle
		else
			step((B - last) * blk) -- the blocks that passed (after a stall the song catches up)
		end
	end
	return frame, step
end

function MidiSynth:stop()
	self._token = (self._token or 0) + 1
	self.warming, self.warmT0, self.warmGain, self.pool.trackFresh = false, nil, nil, false
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	if self.playing then
		self.playing = false
		self:allNotesOff(nil, true)
		self.pool:silence()
		self.pool:update(1)
		self.pool:stopAll()
		if self.sf then
			self.sf:stopAll()
		end
	end
end

function MidiSynth:destroy(gradual)
	if gradual then
		-- the pool is detached (silent) and freed bit by bit: no need to stop every player first
		self._token = (self._token or 0) + 1
		self.warming, self.warmT0, self.warmGain = false, nil, nil
		if self.conn then
			self.conn:Disconnect()
			self.conn = nil
		end
		self.playing = false
	else
		self:stop()
	end
	if self.sf then
		self.sf:destroy()
		self.sf = nil
	end
	self.pool:destroy(gradual)
	self._ended:Destroy()
end

return MidiSynth
