-- Plays a clip through an OscillatorPool. Two clip formats:
--   RBAC (v1): waveform voices + octave noise bands (Codec.Analyzer)
--   RBA3 (v3): tracked sine partials + high noise bands (Codec.Partials), used for imported recordings;
--              stereo v3 clips play through PAN_BUSES fixed-pan buses (each voice keeps one pan) and
--              left / right noise levels
--
--   local player = Player.new(clipBytesOrClip, { Parent = SoundService, MasterGain = 0.5 })
--   player:play({ Loop = false, Speed = 1, LoopLength = nil })  -- LoopLength: loop every n seconds instead of the clip's length
--                                                                (silence past its end; a video's sound loops with the picture)
--   player.Ended:Connect(function() ... end)
--   player:pause(); player:resume(); player:seek(t); player:getTime(); player:getDuration()
--   player:stop(); player:destroy()
--
-- Pass { Pool = existingPool } to share voices between players (one clip at a time per pool).
-- A v3 clip can be a window onto a longer sound that arrives as it plays (FrameLab's streams): clip.base is the frame
-- its first frame stands for, clip.frameCount the frames it holds, clip.duration the whole sound's length; frames
-- outside it are silent. clip.want(t), when there, is told the time being played (so the window can follow it).
-- player.pool.output is the AudioFader carrying the mix (wire an AudioAnalyzer to it to measure).
-- { DeviceOutput = false } skips the speaker output (silent measuring).
--
-- Timing: with the AudioLab attribute BlockAhead = true (the default here) the clip is rendered once per audio block
-- (1024 samples, ~21 ms), for the block after it, exactly like MidiSynth: the engine applies a volume / speed write on a
-- block boundary, so the frame values written are the ones for the middle of the block that sounds next. Without it the
-- clip is applied on every Heartbeat (the older behaviour; up to a block of jitter in when each change lands).

local RunService = game:GetService("RunService")
local AudioLab = script:FindFirstAncestor("AudioLab")
local Format = require(AudioLab.Codec.Format)
local Partials = require(AudioLab.Codec.Partials)
local WaveBank = require(AudioLab.Codec.WaveBank)
local OscillatorPool = require(AudioLab.Synth.OscillatorPool)
local debugHost = script.Parent.Parent -- the AudioLab module: its attributes switch debug modes

local Player = {}
Player.__index = Player

local SINE = 1
local SINE_GAIN = WaveBank.Waves[SINE].gain
-- v3 clips reproduce the source level; leave room so the limiter only catches rare peaks
local V3_HEADROOM = 10 ^ (-0.5 / 20)
local C0 = 16.351597831287414
local PAN_BUSES = 15 -- pan positions for stereo v3 clips (a voice's pan is fixed for its whole life)

local AMP3 = table.create(256, 0) -- RBA3 level code -> linear amplitude
for q = 1, 255 do
	AMP3[q + 1] = 10 ^ ((q - 100) / 20)
end

-- RBA4 texture clips (Codec.Texture: short sound effects) play through Synth.TexturePlayer (same interface)
local function isTexture(clip)
	if typeof(clip) == "buffer" then
		return buffer.len(clip) >= 4 and buffer.readstring(clip, 0, 4) == "RBA4"
	elseif type(clip) == "string" then
		return string.sub(clip, 1, 4) == "RBA4"
	end
	return type(clip) == "table" and clip.texture == true
end

function Player.new(clip, config)
	if isTexture(clip) then
		return require(AudioLab.Synth.TexturePlayer).new(clip, config)
	end
	if typeof(clip) == "buffer" or type(clip) == "string" then
		if Partials.isClip(clip) then
			clip = Partials.unpack(clip)
		else
			clip = Format.unpack(clip)
		end
	end
	config = config or {}
	-- v2 only added assets (bundles, extra noise bands); clips use the v1 waves and octave bands, so
	-- older clips stay valid. Newer clips than this WaveBank would need assets it doesn't know.
	if clip.bankVersion > WaveBank.Version then
		warn(("[AudioLab] clip encoded for WaveBank v%d, current is v%d"):format(clip.bankVersion, WaveBank.Version))
	end
	local self = setmetatable({}, Player)
	self.clip = clip
	self.v3 = clip.version == 3
	self.ownsPool = config.Pool == nil
	local bands = clip.bands
	if self.v3 then
		bands = 0
		for _, b in ipairs(clip.noise) do
			bands = math.max(bands, b)
		end
	end
	self.pool = config.Pool or OscillatorPool.new({
		Parent = config.Parent, Slots = clip.slots, Bands = bands,
		MasterGain = config.MasterGain,
		-- v3 frames already carry the attack and decay: follow them closely
		WarmReserve = config.WarmReserve or (self.v3 and 72 or nil),
		IdleStop = config.IdleStop or (self.v3 and 8 or nil),
		Smoothing = config.Smoothing or (self.v3 and 90 or nil),
		AttackSmoothing = config.AttackSmoothing or (self.v3 and 400 or nil),
		Name = config.Name, DeviceOutput = config.DeviceOutput,
		-- noise players keep looping silently so hi-hats start without the ~22 ms restart
		BandsWarm = self.v3 or nil,
		Stereo = (self.v3 and clip.stereo) or nil,
		Buses = (self.v3 and clip.stereo) and PAN_BUSES or nil,
		DecorrelateNoise = (self.v3 and clip.stereo) or nil,
	})
	if self.v3 and clip.stereo and config.Pool == nil then
		for b = 1, PAN_BUSES do
			self.pool:setBusPan(b, (b - 1) / (PAN_BUSES - 1))
		end
	end
	if not self.v3 then
		self.f0 = Format.readFrame(clip, 0)
		self.f1 = Format.readFrame(clip, 1)
	end
	self.loaded = 0
	self.time = 0
	self.playing = false
	-- v3: voices start on players that are already running (see _prewarm), and the control values are
	-- set for the middle of the next update interval instead of its start (a value is held until the
	-- next Heartbeat, so half an update of lag is removed)
	self.prewarm = self.v3 and config.Prewarm ~= false
	self.lead = self.v3 and (config.Lead or 0.5) or 0
	self._ended = Instance.new("BindableEvent")
	self.Ended = self._ended.Event
	return self
end

function Player:_apply(t)
	local clip = self.clip
	local fpos = t * clip.fps
	local fi = math.floor(fpos)
	if fi ~= self.loaded then
		self.loaded = fi
		Format.readFrame(clip, fi, self.f0)
		Format.readFrame(clip, fi + 1, self.f1)
	end
	local a = fpos - fi
	local f0, f1 = self.f0, self.f1
	local pool = self.pool
	for s = 1, clip.slots do
		local w0, w1 = f0.waves[s], f1.waves[s]
		if w0 ~= 0 and w0 == w1 then
			local midi = f0.pitches[s] + (f1.pitches[s] - f0.pitches[s]) * a
			local vol = f0.volumes[s] + (f1.volumes[s] - f0.volumes[s]) * a
			pool:setVoice(s, w0, Format.midiToFreq(midi), vol)
		elseif w0 ~= 0 and a < 0.5 then
			pool:setVoice(s, w0, Format.midiToFreq(f0.pitches[s]), f0.volumes[s] * (1 - a))
		elseif w1 ~= 0 then
			pool:setVoice(s, w1, Format.midiToFreq(f1.pitches[s]), f1.volumes[s] * a)
		else
			pool:setVoice(s, 0, 0, 0)
		end
	end
	for b = 1, clip.bands do
		pool:setBand(b, f0.bands[b] + (f1.bands[b] - f0.bands[b]) * a)
	end
end

-- v3: each voice is a sine; levels and pitch (in cents) interpolate between frames. A voice that starts
-- takes its new pitch at once (it was silent), a voice that ends fades at its last pitch.
function Player:_apply3(t)
	local clip = self.clip
	if clip.want then
		clip.want(t)
	end
	local fpos = t * clip.fps - (clip.base or 0)
	local nfr = clip.frameCount
	if clip.base and (fpos < 0 or fpos > nfr - 1) then
		-- (a window clip: outside the frames it holds)
		for v = 1, clip.slots do
			self.pool:setVoice(v, 0, 0, 0)
		end
		for q = 1, clip.nN do
			self.pool:setBand(clip.noise[q], 0, clip.nzR and 0 or nil)
		end
		return
	end
	local j0 = math.min(math.floor(fpos), nfr - 1)
	local j1 = math.min(j0 + 1, nfr - 1)
	local a = math.clamp(fpos - j0, 0, 1)
	local K = clip.slots
	local amp, pitch = clip.amp, clip.pitch
	local o0, o1 = j0 * K, j1 * K
	local pool = self.pool
	local gain = V3_HEADROOM / SINE_GAIN
	local pan = clip.pan -- stereo: pan code per voice, 0 = left .. 255 = right
	for v = 0, K - 1 do
		local q0, q1 = buffer.readu8(amp, o0 + v), buffer.readu8(amp, o1 + v)
		if q0 == 0 and q1 == 0 then
			pool:setVoice(v + 1, 0, 0, 0)
		else
			local cents, level
			if q0 > 0 and q1 > 0 then
				local c0, c1 = buffer.readu16(pitch, (o0 + v) * 2), buffer.readu16(pitch, (o1 + v) * 2)
				cents = c0 + (c1 - c0) * a
				local l0 = AMP3[q0 + 1]
				level = l0 + (AMP3[q1 + 1] - l0) * a
			elseif q1 > 0 then
				cents = buffer.readu16(pitch, (o1 + v) * 2)
				level = AMP3[q1 + 1] * a
			else
				cents = buffer.readu16(pitch, (o0 + v) * 2)
				level = AMP3[q0 + 1] * (1 - a)
			end
			local bus = nil
			if pan then
				local code = buffer.readu8(pan, (q0 > 0 and o0 or o1) + v)
				bus = math.floor(code / 255 * (PAN_BUSES - 1) + 0.5) + 1
			end
			pool:setVoice(v + 1, SINE, C0 * 2 ^ (cents / 1200), level * gain, bus)
		end
	end
	local nz, nzR, nN = clip.nz, clip.nzR, clip.nN
	for q = 0, nN - 1 do
		local l0 = AMP3[buffer.readu8(nz, j0 * nN + q) + 1]
		local l1 = AMP3[buffer.readu8(nz, j1 * nN + q) + 1]
		local left = (l0 + (l1 - l0) * a) * V3_HEADROOM
		if nzR then
			local r0 = AMP3[buffer.readu8(nzR, j0 * nN + q) + 1]
			local r1 = AMP3[buffer.readu8(nzR, j1 * nN + q) + 1]
			pool:setBand(clip.noise[q + 1], left, (r0 + (r1 - r0) * a) * V3_HEADROOM)
		else
			pool:setBand(clip.noise[q + 1], left)
		end
	end
end

-- Block-ahead: one write holds for a whole 21 ms block, i.e. 2.6 clip frames. Sampling the frames at the block's
-- middle aliases the envelope: a hit shorter than a block is caught or missed depending on where the middle falls, and
-- the block that straddles the clip's end plays at full level past the end. Here every level is the RMS of the clip over
-- the block's own span (BLOCK_TAPS taps, nothing outside 0..duration), and a voice that sounds anywhere in the block takes
-- the pitch of its loudest tap.
local BLOCK_TAPS = 8
local function levelAt(clip, v, fpos)
	local nfr = clip.frameCount
	if fpos < 0 or fpos > nfr then
		return 0, 0
	end
	local K = clip.slots
	local j0 = math.min(math.floor(fpos), nfr - 1)
	local j1 = math.min(j0 + 1, nfr - 1)
	local a = math.clamp(fpos - j0, 0, 1)
	local q0, q1 = buffer.readu8(clip.amp, j0 * K + v), buffer.readu8(clip.amp, j1 * K + v)
	if q0 == 0 and q1 == 0 then
		return 0, 0
	end
	local pitch = clip.pitch
	if q0 > 0 and q1 > 0 then
		local c0, c1 = buffer.readu16(pitch, (j0 * K + v) * 2), buffer.readu16(pitch, (j1 * K + v) * 2)
		local l0 = AMP3[q0 + 1]
		return l0 + (AMP3[q1 + 1] - l0) * a, c0 + (c1 - c0) * a
	elseif q1 > 0 then
		return AMP3[q1 + 1] * a, buffer.readu16(pitch, (j1 * K + v) * 2)
	end
	return AMP3[q0 + 1] * (1 - a), buffer.readu16(pitch, (j0 * K + v) * 2)
end

function Player:_apply3block(t, span)
	local clip = self.clip
	if clip.want then
		clip.want(t)
	end
	local base = clip.base or 0
	local fps = clip.fps
	local K = clip.slots
	local pool = self.pool
	local gain = V3_HEADROOM / SINE_GAIN
	local dur = clip.duration
	local pan = clip.pan
	local taps = {}
	for q = 1, BLOCK_TAPS do
		local tq = t + span * ((q - 0.5) / BLOCK_TAPS - 0.5)
		taps[q] = (tq >= 0 and tq <= dur and tq * fps - base >= 0) and tq * fps - base or -1
	end
	for v = 0, K - 1 do
		local e, best, cents, any = 0, 0, 0, nil
		for q = 1, BLOCK_TAPS do
			local fp = taps[q]
			if fp >= 0 then
				local l, c = levelAt(clip, v, fp)
				if l > 0 then
					e += l * l
					if l > best then
						best, cents, any = l, c, math.floor(fp)
					end
				end
			end
		end
		if e <= 0 then
			pool:setVoice(v + 1, 0, 0, 0)
		else
			local bus = nil
			if pan then
				local code = buffer.readu8(pan, math.min(any, clip.frameCount - 1) * K + v)
				bus = math.floor(code / 255 * (PAN_BUSES - 1) + 0.5) + 1
			end
			pool:setVoice(v + 1, SINE, C0 * 2 ^ (cents / 1200), math.sqrt(e / BLOCK_TAPS) * gain, bus)
		end
	end
	local nz, nzR, nN = clip.nz, clip.nzR, clip.nN
	local nfr = clip.frameCount
	for q = 0, nN - 1 do
		local eL, eR = 0, 0
		for i = 1, BLOCK_TAPS do
			local fp = taps[i]
			if fp >= 0 and fp <= nfr then
				local j0 = math.min(math.floor(fp), nfr - 1)
				local j1 = math.min(j0 + 1, nfr - 1)
				local a = math.clamp(fp - j0, 0, 1)
				local l0, l1 = AMP3[buffer.readu8(nz, j0 * nN + q) + 1], AMP3[buffer.readu8(nz, j1 * nN + q) + 1]
				local l = l0 + (l1 - l0) * a
				eL += l * l
				if nzR then
					local r0, r1 = AMP3[buffer.readu8(nzR, j0 * nN + q) + 1], AMP3[buffer.readu8(nzR, j1 * nN + q) + 1]
					local r = r0 + (r1 - r0) * a
					eR += r * r
				end
			end
		end
		local left = math.sqrt(eL / BLOCK_TAPS) * V3_HEADROOM
		if nzR then
			pool:setBand(clip.noise[q + 1], left, math.sqrt(eR / BLOCK_TAPS) * V3_HEADROOM)
		else
			pool:setBand(clip.noise[q + 1], left)
		end
	end
end

-- count, per sine range, how many voices sound at once in [t, t + window] and have the pool ready that
-- many running players (+2 spare for range changes)
function Player:_prewarm(t, window)
	local clip = self.clip
	local K, fps, nfr = clip.slots, clip.fps, clip.frameCount
	local amp, pitch = clip.amp, clip.pitch
	local base = clip.base or 0
	local fa = math.clamp(math.floor(t * fps - base), 0, nfr - 1)
	local fb = math.clamp(math.floor((t + window) * fps - base), fa, nfr - 1)
	local peak = {}
	for f = fa, fb, 2 do
		local count = {}
		local o = f * K
		for v = 0, K - 1 do
			if buffer.readu8(amp, o + v) > 0 then
				local r = WaveBank.SineRange or WaveBank.rangeFor(C0 * 2 ^ (buffer.readu16(pitch, (o + v) * 2) / 1200))
				count[r] = (count[r] or 0) + 1
			end
		end
		for r, c in pairs(count) do
			if c > (peak[r] or 0) then
				peak[r] = c
			end
		end
	end
	local counts = {}
	for r, c in pairs(peak) do
		counts[SINE * 100 + r] = c + 2
	end
	self.pool:prewarm(counts)
end

-- The audio block counter: a silent looping player wired into the pool's output; its TimePosition advances one block at a time,
-- so how many blocks have passed is read off it. Returns blockIndex, secondsPerBlock.
function Player:_blockClock()
	local cp = self.clockPlayer
	if not cp then
		cp = Instance.new("AudioPlayer")
		cp.Name = "BlockClock"
		cp.Asset = WaveBank.assetId(SINE, WaveBank.SineRange or 1) or ""
		cp.Looping = true
		cp.Volume = 0
		cp.Parent = self.pool.output
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
				self.blockDur = self.clockSum / self.clockSteps -- 1024 samples at the device rate
			end
		end
	end
	self.clockLast = pos
	return self.blockIndex, self.blockDur
end

function Player:play(options)
	options = options or {}
	self:stop()
	self.loop = options.Loop == true
	self.speed = options.Speed or 1
	self.loopLength = (type(options.LoopLength) == "number" and options.LoopLength > 0) and options.LoopLength or nil
	self.time = options.StartTime or 0
	self.loaded = -1
	self:_connect()
end

function Player:seek(t)
	self.time = math.clamp(t, 0, math.max(self.clip.duration, (self.loop and self.loopLength) or 0))
	self.loaded = -1
	if self.prewarm and self.playing then
		self:_prewarm(self.time, 1)
	end
end

function Player:getTime()
	return self.time or 0
end

function Player:getDuration()
	return self.clip.duration
end

function Player:pause()
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	self.paused = true
	self.playing = false
	self.pool:silence()
	self.pool:update(1)
end

function Player:resume()
	if not self.conn then
		self:_connect()
	end
end

function Player:_connect()
	self.playing = true
	self.paused = false
	local duration = self.clip.duration
	local apply = self.v3 and self._apply3 or self._apply
	if self.v3 and self.pool.warm then
		self.pool:warm()
	end
	-- the clock waits (at most a second) until the first voices' players are loaded and running
	local waitFrom, settle = nil, 0
	if self.prewarm then
		self:_prewarm(self.time, 2)
		waitFrom = os.clock()
		-- players started just now need a moment before their first sound is really out
		settle = (#self.pool.fresh > 0) and 0.12 or 0
	end
	-- moves the clip clock by `delta` clip seconds; false when a clip that does not loop has ended
	local function advance(delta)
		self.time += delta
		local len = (self.loop and self.loopLength) or duration
		if self.time >= len then
			if self.loop then
				self.time %= len
			else
				self:stop()
				self._ended:Fire()
				return false
			end
		end
		return true
	end
	self.bsB = nil
	self.conn = RunService.Heartbeat:Connect(function(dt)
		if waitFrom then
			local waited = os.clock() - waitFrom
			if (waited >= settle and self.pool:ready()) or waited > 1 then
				waitFrom = nil
			end
			return
		end
		local pool = self.pool
		if debugHost:GetAttribute("BlockAhead") == true then
			-- once per audio block, for the block after it: the clip clock stands at the middle of that block, so every
			-- level is the block's own and a voice starts on the nearest block boundary; the frames in between only start
			-- the players that were held back by the start budget
			local B, blk = self:_blockClock()
			local last = self.bsB
			if last == B then
				pool:startPending()
				return
			end
			self.bsB = B
			pool.pendingStart, pool.pendingMake = nil, nil
			local real = (last == nil) and (0.5 * blk) or ((B - last) * blk) -- the blocks that passed (a stall catches up)
			local blockRms = self.v3 and debugHost:GetAttribute("ClipBlockRms") ~= false
			if blockRms then
				-- the levels are already each block's own RMS (they carry every decay): no extra fall smoothing, which
				-- would leave a -16 dB block of tail after every stop and smear fast decays by a block
				pool.smoothing, pool.bandFall = 2000, 2000
			end
			if not advance(real * self.speed) then
				if blockRms then
					pool:update(real) -- the clip ended inside the block just played: silence lands on the next boundary
				end
				return
			end
			if self.v3 and debugHost:GetAttribute("ClipBlockRms") ~= false then
				self:_apply3block(self.time, blk * self.speed)
			else
				apply(self, math.min(self.time, duration))
			end
			pool:update(real)
			return
		end
		self.bsB = nil
		pool.pendingStart, pool.pendingMake = nil, nil
		if not advance(dt * self.speed) then
			return
		end
		apply(self, math.min(self.time + self.lead * dt * self.speed, duration))
		pool:update(dt)
	end)
end

function Player:stop()
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	if self.playing then
		self.playing = false
		self.pool:silence()
		-- let the pool fade out instead of cutting
		local pool = self.pool
		local fade
		local left = 0.25
		fade = RunService.Heartbeat:Connect(function(dt)
			left -= dt
			if self.playing or left <= 0 then
				fade:Disconnect()
				return
			end
			pool:update(dt)
		end)
	end
end

function Player:destroy(gradual)
	if gradual then
		if self.conn then
			self.conn:Disconnect()
			self.conn = nil
		end
		self.playing = false
	else
		self:stop()
	end
	if self.clockPlayer then
		self.clockPlayer:Destroy()
		self.clockPlayer = nil
	end
	if self.ownsPool then
		self.pool:destroy(gradual)
	end
	self._ended:Destroy()
end

return Player
