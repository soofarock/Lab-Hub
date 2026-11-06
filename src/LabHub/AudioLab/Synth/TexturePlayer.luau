--!optimize 2
-- Plays an RBA4 texture clip (Codec.Texture): every bubble, click and grain is one start of a generic upload file, at an
-- exact time. Same interface as Synth.Player (Player.new hands RBA4 clips here):
--   local p = TexturePlayer.new(clip, { Parent = SoundService, MasterGain = 1, DeviceOutput = true })
--   p:play({ Loop = false }); p.Ended:Connect(...); p:stop(); p:pause(); p:resume(); p:seek(t); p:destroy()
--
-- Timing: the engine applies AudioPlayer writes on the next audio block boundary (1024 samples). A piece that starts d
-- seconds after that boundary is started there with TimePosition = (its start in the file) - d * speed: the file has
-- silence before every piece (the lead-in), so the piece is heard exactly d seconds later. Pieces are scheduled up to
-- LOOK blocks ahead (more when frames are slow), which the lead-ins cover. A player is stopped on the first boundary after
-- its piece ends (or reused there for the next piece).
-- Slow devices: when frames keep arriving more than ~1.6 blocks apart, the sixth-octave grain set is dropped and the
-- half-octave set plays at full weight in its place (well under half the starts; the lows lose a little colour).
-- The pieces live in the codec's upload files (ids in Codec.Manifests.Files); a player stays on one file. Every player
-- a clip needs is made (and loaded) when the clip is opened, and every spot of the files it uses is played once silently
-- (_warmUp), so the first playback sounds like the others.
-- Beds (when tex_beds is uploaded): the grains are not started one by one (~4500 starts a second, ~300 players) but
-- played as one looping player per band (49): tex_beds holds each band's grain stream pre-rendered at a constant level
-- (1 s loops, played with LoopRegion), and the player's volume is set once per audio block from the clip's grain
-- volumes (their power per block). About 63 players for a clip instead of ~310, and nothing sound-specific is uploaded.

local RunService = game:GetService("RunService")
local AudioLab = script:FindFirstAncestor("AudioLab")
local Texture = require(AudioLab.Codec.Texture)
local Files = require(AudioLab.Codec.Manifests.Files)

local TexturePlayer = {}
TexturePlayer.__index = TexturePlayer

local R = 48000
local LAYOUT = Texture.LAYOUT
local BANDS = Texture.BANDS
local MIX_CALIBRATION = math.sqrt(2) -- an AudioFader with several inputs is -3.01 dB (see OscillatorPool)
local MAX_VOLUME = 3
local MIN_LOOK = 2 -- blocks scheduled ahead (at least): a frame that arrives a block late doesn't make pieces late
-- the bed loops: 13 short files tex_beds_01 .. tex_beds_13 (4 loops each, 4.16 s).
-- Band k's loop sits in file BEDS[k][1] at BEDS[k][2] s, 1 s long, with 0.02 s of its own wrap on both
-- sides, peak-normalised in the file by BEDS[k][4] (its level: the expected power of the band's grain stream). The loops
-- are stored reversed (noise sounds the same backwards) and played at speed 1 (see bedSpeed).
local BED_FILES = 13
local BEDS = { -- [band] = { file, start, len, gain }
	{ 1, 0.020000, 1.000000, 2.267203 }, { 1, 1.060000, 1.000000, 2.006382 }, { 1, 2.100000, 1.000000, 2.028231 },
	{ 1, 3.140000, 1.000000, 2.232738 }, { 2, 0.020000, 1.000000, 2.117899 }, { 2, 1.060000, 1.000000, 2.000708 },
	{ 2, 2.100000, 1.000000, 1.314349 }, { 2, 3.140000, 1.000000, 1.675955 }, { 3, 0.020000, 1.000000, 1.668530 },
	{ 3, 1.060000, 1.000000, 1.493324 }, { 3, 2.100000, 1.000000, 1.530395 }, { 3, 3.140000, 1.000000, 1.710341 },
	{ 4, 0.020000, 1.000000, 1.418800 }, { 4, 1.060000, 1.000000, 1.386274 }, { 4, 2.100000, 1.000000, 1.466820 },
	{ 4, 3.140000, 1.000000, 1.128155 }, { 5, 0.020000, 1.000000, 1.334138 }, { 5, 1.060000, 1.000000, 1.291318 },
	{ 5, 2.100000, 1.000000, 1.418072 }, { 5, 3.140000, 1.000000, 1.316535 }, { 6, 0.020000, 1.000000, 1.343831 },
	{ 6, 1.060000, 1.000000, 1.340666 }, { 6, 2.100000, 1.000000, 1.325587 }, { 6, 3.140000, 1.000000, 1.415053 },
	{ 7, 0.020000, 1.000000, 1.285036 }, { 7, 1.060000, 1.000000, 0.918249 }, { 7, 2.100000, 1.000000, 1.297667 },
	{ 7, 3.140000, 1.000000, 1.117693 }, { 8, 0.020000, 1.000000, 1.018590 }, { 8, 1.060000, 1.000000, 1.092079 },
	{ 8, 2.100000, 1.000000, 0.768751 }, { 8, 3.140000, 1.000000, 1.138501 }, { 9, 0.020000, 1.000000, 1.016022 },
	{ 9, 1.060000, 1.000000, 1.021772 }, { 9, 2.100000, 1.000000, 1.034011 }, { 9, 3.140000, 1.000000, 1.241620 },
	{ 10, 0.020000, 1.000000, 1.073985 }, { 10, 1.060000, 1.000000, 1.093674 }, { 10, 2.100000, 1.000000, 0.887936 },
	{ 10, 3.140000, 1.000000, 1.142311 }, { 11, 0.020000, 1.000000, 1.000482 }, { 11, 1.060000, 1.000000, 1.082118 },
	{ 11, 2.100000, 1.000000, 1.069825 }, { 11, 3.140000, 1.000000, 0.958929 }, { 12, 0.020000, 1.000000, 1.138605 },
	{ 12, 1.060000, 1.000000, 0.941378 }, { 12, 2.100000, 1.000000, 1.024534 }, { 12, 3.140000, 1.000000, 0.914992 },
	{ 13, 0.020000, 1.000000, 0.879394 },
}
local function bedFile(i)
	return ("tex_beds_%02d"):format(i)
end
-- A client plays about 400 AudioPlayers at once (all audio together); past that the engine drops
-- players, and a texture clip that starts over it loses most of its pieces. play() counts what else is playing, then
-- plays the full clip, the low-cost set (no sixth-octave grains) or, if even that doesn't fit, skips grains past the
-- budget (bubbles and clicks always play).
local ENGINE_LIMIT = 400
local CLOCK_STEADY = 8 -- block ticks in a row the clock needs before a play starts
local LIMIT_MARGIN = 16
-- (only players wired into something count: AudioLab keeps stopped songs' players running unwired, and those barely
-- take room: 200 of them cost a clip ~2 dB, 200 wired ones ~14 dB)
local function playingElsewhere(mine)
	local n = 0
	for _, d in ipairs(game:GetService("SoundService"):GetDescendants()) do
		if d:IsA("AudioPlayer") and d.IsPlaying and not d:IsDescendantOf(mine) then
			for _, w in ipairs(d:GetConnectedWires("Output")) do
				if w.TargetInstance then
					n += 1
					break
				end
			end
		end
	end
	return n
end
local function assetId(name)
	local id = Files[name]
	return (id and id ~= "") and id or nil
end
TexturePlayer.assetId = assetId

-- true when every upload file of the codec has an id
function TexturePlayer.ready()
	for _, name in ipairs(LAYOUT.allFiles) do
		if not assetId(name) then
			return false, name
		end
	end
	return true
end

-- the beds are used once every tex_beds file is known to load (a new upload is refused while Roblox reviews it, or if
-- it is rejected): until then clips play their grains. Probe players retry every 30 s until all the files load.
local bedsLoaded = false
local bedsChecking = false -- (the first round of probes is still running: a play waits for it, up to 3 s)
do
	local all = true
	for i = 1, BED_FILES do
		if not assetId(bedFile(i)) then
			all = false
		end
	end
	if all then
		bedsChecking = true
		task.spawn(function()
			local loaded = {}
			while not bedsLoaded do
				local probes = {}
				for i = 1, BED_FILES do
					if not loaded[i] then
						local probe = Instance.new("AudioPlayer")
						probe.Name = "AudioLabBedsProbe"
						probe.Asset = assetId(bedFile(i))
						probe.Volume = 0
						probe.Parent = game:GetService("SoundService")
						probes[i] = probe
					end
				end
				local t0 = os.clock()
				repeat
					task.wait(0.1)
					local done = true
					for i, probe in pairs(probes) do
						if probe.IsReady then
							loaded[i] = true
						else
							done = false
						end
					end
				until done or os.clock() - t0 > 30
				for _, probe in pairs(probes) do
					probe:Destroy()
				end
				local n = 0
				for i = 1, BED_FILES do
					if loaded[i] then
						n += 1
					end
				end
				bedsLoaded = n == BED_FILES
				bedsChecking = false
			end
		end)
	end
end
function TexturePlayer.bedsReady()
	return bedsLoaded
end

local function wire(parent, from, to)
	local w = Instance.new("Wire")
	w.SourceInstance = from
	w.TargetInstance = to
	w.Parent = parent
	return w
end

-- every piece of the clip as one start: { t (clip s), file, at (s in that file), lead, speed, vol, dur (real s), band }
-- (beds: the grains are played by the beds, not as pieces)
local function buildEvents(clip, rng, beds)
	local ev = {}
	local L = LAYOUT
	for _, b in ipairs(clip.bubbles) do
		local w = L.tones.where[b.shape]
		table.insert(ev, { t = b.t / R, file = w.file, at = w.start, lead = L.tones.lead, speed = b.speed,
			vol = b.amp * L.tones.gain, dur = L.tones.len[b.shape] / b.speed })
	end
	for _, c in ipairs(clip.clicks) do
		local item = ((c.band - 1) * 3 + (c.tau - 1)) * 3 + c.var
		local w = L.clicks.where[item]
		-- (a click can be played from another spot at a speed: Texture.ClickRemap; gain keeps its energy)
		local speed = w.speed or 1
		table.insert(ev, { t = c.t / R, file = w.file, at = w.start, lead = L.clicks.lead, speed = speed,
			vol = c.amp * L.clicks.gain * (w.gain or 1), dur = (w.flen or L.clicks.len[item]) / speed })
	end
	local G = L.grains
	for bi, vols in ipairs(beds and {} or clip.grains) do
		local g = G.g[bi]
		local hop = g / 2
		local where = G.where[bi]
		for k, v in ipairs(vols) do
			if v > 0 then
				local t = math.floor((k - 1) * hop * R + 0.5) / R
				local w = where[rng:NextInteger(1, G.K)]
				table.insert(ev, { t = t, file = w.file, at = w.start, lead = G.lead, speed = 1,
					vol = v * G.gain[bi], dur = g, band = bi })
			end
		end
	end
	table.sort(ev, function(a, b)
		return a.t < b.t
	end)
	return ev
end

-- per band, per audio block of the clip: the bed's volume (the mean power of the grains centred in that block; blocks
-- without a grain centre - long grains - in between their neighbours), in the file's units
local function bedVolumes(clip)
	local blk = 1024 / R
	local nb = math.max(1, math.ceil(clip.duration / blk))
	local out = {}
	for bi, vols in ipairs(clip.grains) do
		local g = LAYOUT.grains.g[bi]
		local hop = g / 2
		local sum, cnt = table.create(nb, 0), table.create(nb, 0)
		for k, v in ipairs(vols) do
			local b = math.min(math.floor(((k - 1) * hop + g / 2) / blk), nb - 1) + 1
			sum[b] += v * v
			cnt[b] += 1
		end
		local p = table.create(nb, 0)
		local left, right = table.create(nb, 0), table.create(nb, 0)
		local last = 0
		for b = 1, nb do
			if cnt[b] > 0 then
				p[b] = sum[b] / cnt[b]
				last = b
			end
			left[b] = last
		end
		last = 0
		for b = nb, 1, -1 do
			if cnt[b] > 0 then
				last = b
			end
			right[b] = last
		end
		local gain = BEDS[bi] and BEDS[bi][4] or 1
		local v = table.create(nb, 0)
		for b = 1, nb do
			local pb = p[b]
			if cnt[b] == 0 then
				local l, r = left[b], right[b]
				if l > 0 and r > 0 then
					pb = p[l] + (p[r] - p[l]) * (b - l) / (r - l)
				elseif l > 0 then
					pb = p[l]
				elseif r > 0 then
					pb = p[r]
				end
			end
			v[b] = math.sqrt(pb) / gain
		end
		out[bi] = v
	end
	return out
end

-- how many players each file needs at once: a piece takes its player on the boundary where it enters the look-ahead
-- (at most 3 blocks ahead) and frees it on the first boundary after it ends; counted that way (plus a little spare)
-- (ahead: blocks before its boundary a piece takes its player, 2 for the pool, 1 for the usual case; spare: true adds a
-- little)
local function playersNeeded(events, ahead, spare)
	local blk = 1024 / R
	local per = {}
	for _, e in ipairs(events) do
		local list = per[e.file]
		if not list then
			list = {}
			per[e.file] = list
		end
		table.insert(list, { math.floor(e.t / blk) - ahead, 1 }) -- taken on this boundary
		table.insert(list, { math.ceil((e.t + e.dur) / blk), -1 }) -- free again on this one
	end
	local need = {}
	for file, list in pairs(per) do
		table.sort(list, function(a, b)
			if a[1] ~= b[1] then
				return a[1] < b[1]
			end
			return a[2] < b[2] -- (frees first on a tie)
		end)
		local cur, top = 0, 0
		for _, x in ipairs(list) do
			cur += x[2]
			top = math.max(top, cur)
		end
		need[file] = spare and (math.ceil(top * 1.1) + 2) or top
	end
	return need
end

function TexturePlayer.new(clip, config)
	if typeof(clip) == "buffer" or type(clip) == "string" then
		clip = Texture.unpack(clip)
	end
	config = config or {}
	local self = setmetatable({}, TexturePlayer)
	self.clip = clip
	self.texture = true
	self.seed = config.Seed or 1
	self.useBeds = config.Beds ~= false and bedsLoaded
	self.events = buildEvents(clip, Random.new(self.seed), self.useBeds)
	self.folder = Instance.new("Folder")
	self.folder.Name = config.Name or "AudioLabTexture"
	-- players -> Mix (several inputs: keep-alive input so the -3 dB is constant) -> low-pass at the clip's top -> Master
	self.mix = Instance.new("AudioFader")
	self.mix.Name = "Mix"
	self.mix.Volume = MIX_CALIBRATION
	self.mix.Parent = self.folder
	local keep = Instance.new("AudioPlayer")
	keep.Name = "keepalive"
	keep.Volume = 0
	keep.Parent = self.mix
	wire(self.mix, keep, self.mix)
	self.filter = Instance.new("AudioFilter")
	self.filter.Name = "Top"
	self.filter.FilterType = Enum.AudioFilterType.Lowpass48dB
	self.filter.Frequency = math.clamp(clip.fc, 200, 20000)
	self.filter.Parent = self.folder
	wire(self.folder, self.mix, self.filter)
	self.output = Instance.new("AudioFader")
	self.output.Name = "Master"
	self.output.Volume = config.MasterGain or 1
	self.output.Parent = self.folder
	wire(self.folder, self.filter, self.output)
	if config.DeviceOutput ~= false then
		local device = Instance.new("AudioDeviceOutput")
		device.Name = "Speakers"
		device.Parent = self.folder
		if config.Limiter ~= false then
			local lim = Instance.new("AudioLimiter")
			lim.Name = "Limiter"
			lim.MaxLevel = config.LimiterCeiling or -1
			lim.Release = 0.12
			lim.Parent = self.folder
			wire(self.folder, self.output, lim)
			wire(self.folder, lim, device)
		else
			wire(self.folder, self.output, device)
		end
	end
	self.folder.Parent = config.Parent or game:GetService("SoundService")
	-- the parts of an OscillatorPool that players' users reach for (Library volume, the analyzer, Attach)
	local selfRef = self
	self.pool = {
		folder = self.folder,
		output = self.output,
		device = self.folder:FindFirstChild("Speakers"),
		stereo = false,
		setMasterGain = function(_, v)
			selfRef.output.Volume = v
		end,
	}
	self.pools = {} -- upload file name -> { free = { records }, count }
	self.forceLow = config.LowCost == true
	self.lowCost = self.forceLow
	self.budget, self.dropped = math.huge, 0
	self.time = 0
	self.playing = false
	self._ended = Instance.new("BindableEvent")
	self.Ended = self._ended.Event
	-- the block clock: a silent looping player (the loop file); the upload files themselves are preloaded (Manifests Core)
	local cp = Instance.new("AudioPlayer")
	cp.Name = "BlockClock"
	cp.Asset = assetId("tex_loop") or ""
	cp.Looping = true
	cp.Volume = 0
	cp.Parent = self.folder
	wire(cp, cp, self.mix)
	cp:Play()
	self.clockPlayer = cp
	-- the clock's position moves in clumps for a moment after it starts, and whenever the audio engine falls behind (right
	-- after songs are switched): clockSteady counts the block ticks since the last clump, and play waits for a run of them
	-- (the first play started on a clumpy clock and came out late and thinned)
	self.clockSteady = 0
	local lastPos
	self.clockWatch = RunService.Heartbeat:Connect(function()
		if not cp.IsReady then
			return
		end
		local pos = cp.TimePosition
		if lastPos and pos ~= lastPos then
			local d = pos - lastPos
			if d < -0.5 then
				d += (cp.TimeLength > 0 and cp.TimeLength or 1)
			end
			if d > 0 and d < 1.5 * 1024 / R then
				self.clockSteady += 1
			else
				self.clockSteady = 0
			end
		end
		lastPos = pos
	end)
	self.pending = {}
	self.bedsOff = config.Beds == false
	if self.useBeds then
		self:_makeBeds()
	end
	-- make every player now: a player made during playback isn't loaded in time for its first piece
	-- players the clip needs at once: everything, and the low-cost set
	self:_countNeed()
	local needed = playersNeeded(self.events, 2, true)
	for file, count in pairs(needed) do
		local pool = self:_pool(file)
		for _ = 1, count do
			table.insert(pool.free, self:_make(file))
		end
	end
	self:_warmUp()
	local ok, missing = TexturePlayer.ready()
	if not ok then
		warn(("[AudioLab] texture clip: the generic texture files are not all uploaded yet (Codec.Manifests.Files has no id for %s)"):format(missing))
	end
	return self
end

-- the 49 bed players (one per band, looping its band's loop)
function TexturePlayer:_makeBeds()
	self.bedVol = bedVolumes(self.clip)
	self.beds = {}
	for bi = 1, #BANDS do
		local p = Instance.new("AudioPlayer")
		p.Name = "bed_" .. bi
		local b = BEDS[bi]
		p.Asset = assetId(bedFile(b[1]))
		p.Looping = true
		local s, len = b[2], b[3]
		p.LoopRegion = NumberRange.new(s, s + len)
		p.Volume = 0
		p.Parent = self.folder
		wire(p, p, self.mix)
		-- (each band starts somewhere else in its loop)
		self.beds[bi] = { p = p, start = s + ((bi * 0.618034) % 1) * len * 0.9, vol = 0 }
	end
end

-- A clip opened before the bed files had loaded (right after joining, the probe takes a moment) plays its grains; on
-- its next play() it switches to the beds, and its grain players are let go.
function TexturePlayer:_enableBeds()
	if self.beds or self.bedsOff or not bedsLoaded then
		return
	end
	self.useBeds = true
	self.events = buildEvents(self.clip, Random.new(self.seed), true)
	self:_makeBeds()
	self:_countNeed()
	for file, pool in pairs(self.pools) do
		if string.find(file, "grains", 1, true) then
			for _, rec in ipairs(pool.free) do
				rec.p:Destroy()
			end
			pool.free = {}
			pool.count = 0
		end
	end
	-- warm up again: the beds, and the pieces left (the grain players it was warming are gone)
	if self.warmConn then
		self.warmConn:Disconnect()
		self.warmConn = nil
	end
	self:_warmUp()
end

-- players the clip needs at once: everything, and the low-cost set
function TexturePlayer:_countNeed()
	local lowEvents = {}
	for _, e in ipairs(self.events) do
		if not e.band or BANDS[e.band].half then
			table.insert(lowEvents, e)
		end
	end
	self.need = { full = 0, low = 0 }
	for _, c in pairs(playersNeeded(lowEvents, 1)) do
		self.need.low += c
	end
	for _, c in pairs(playersNeeded(self.events, 1)) do
		self.need.full += c
	end
	if self.beds then
		self.need.full += #self.beds
		for _, band in ipairs(BANDS) do
			if band.half then
				self.need.low += 1
			end
		end
	end
end

-- audio block counter (see Synth.Player): a silent looping player's position advances one block at a time
function TexturePlayer:_blockClock()
	local cp = self.clockPlayer
	if not self.blockDur then
		self.blockIndex, self.blockDur, self.clockLast = 0, 1024 / R, nil
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
				self.blockDur = self.clockSum / self.clockSteps
			end
		end
	end
	self.clockLast = pos
	return self.blockIndex, self.blockDur
end

function TexturePlayer:_pool(file)
	local pool = self.pools[file]
	if not pool then
		pool = { free = {}, count = 0 }
		self.pools[file] = pool
	end
	return pool
end

function TexturePlayer:_take(file)
	local rec = table.remove(self:_pool(file).free)
	if rec then
		return rec
	end
	return self:_make(file)
end

-- a new player on `file` (not in the free list yet)
function TexturePlayer:_make(file)
	local pool = self:_pool(file)
	local p = Instance.new("AudioPlayer")
	p.Name = file
	p.Asset = assetId(file) or ""
	p.Looping = false
	p.Volume = 0
	p.Parent = self.folder
	wire(p, p, self.mix)
	pool.count += 1
	return { p = p, file = file }
end

function TexturePlayer:_reset(fromTime)
	-- the next event to schedule, and the busy players
	local ev = self.events
	local i = 1
	while i <= #ev and ev[i].t < fromTime do
		i += 1
	end
	self.nextEvent = i
	self.busy = {}
	self.startBlock = nil
	self.timeOrigin = fromTime
	self.advance = {}
	self.pending = {}
end

-- once per audio block (the first frame that sees a new block): schedule what starts before the look-ahead horizon
function TexturePlayer:_step()
	local B, blk = self:_blockClock()
	if B == self.lastB then
		return
	end
	local adv = self.lastB and (B - self.lastB) or 1
	self.lastB = B
	local st = self.stats
	if st and adv > st.maxAdv then
		st.maxAdv = adv
	end
	-- how far apart frames arrive (in blocks): look further ahead on slow devices, switch to low cost if it persists
	table.insert(self.advance, adv)
	if #self.advance > 60 then
		table.remove(self.advance, 1)
	end
	local maxAdv, sum = 1, 0
	for _, a in ipairs(self.advance) do
		maxAdv = math.max(maxAdv, a)
		sum += a
	end
	local look = math.clamp(maxAdv, MIN_LOOK, 3)
	if not self.slowFrames and #self.advance >= 30 and sum / #self.advance > 1.6 then
		self.slowFrames = true
	end
	-- the player budget follows what else plays (checked every ~12 blocks)
	if not self.budgetAt or B - self.budgetAt >= 12 then
		self.budgetAt = B
		self:_budget()
	end
	if not self.startBlock then
		-- the clip's time origin sits on this boundary: far enough ahead that a slow first frame isn't late
		self.startBlock = B + 1 + 3
	end
	local land = B + 1 -- what is written now is applied on this boundary
	local function clipTime(boundary)
		return self.timeOrigin + (boundary - self.startBlock) * blk
	end
	local tLand = clipTime(land)
	self.time = math.max(self.timeOrigin, tLand)
	self:_bedStep(tLand)
	local horizon = clipTime(land + look)
	-- players whose piece is over by the landing boundary are free
	local freed = {}
	local still = {}
	for _, rec in ipairs(self.busy) do
		if rec.ends <= tLand then
			table.insert(freed, rec)
		else
			table.insert(still, rec)
		end
	end
	self.busy = still
	local spare = {}
	for _, rec in ipairs(freed) do
		local list = spare[rec.file]
		if not list then
			list = {}
			spare[rec.file] = list
		end
		table.insert(list, rec)
	end
	local function start(e)
		local d = e.t - tLand
		local skip = 0
		if d < 0 then
			skip = -d -- late (a stalled frame): start inside the piece
			d = 0
			if st then
				st.late += 1
				st.maxLate = math.max(st.maxLate, skip)
			end
		end
		if skip >= e.dur then
			return
		end
		if e.band and #self.busy >= self.budget then
			self.dropped += 1 -- over the player budget: a grain is skipped (the engine would drop something anyway)
			return
		end
		-- the lead-in covers d * speed seconds of file at most (a fast piece waits in `pending` until it fits)
		local back = math.min((d - skip) * e.speed, e.lead)
		local list = spare[e.file]
		local rec = (list and table.remove(list)) or self:_take(e.file)
		local p = rec.p
		p.TimePosition = e.at - back
		p.PlaybackSpeed = e.speed
		p.Volume = math.min(e.vol, MAX_VOLUME)
		if not p.IsPlaying then
			p:Play()
		end
		rec.ends = e.t + e.dur
		table.insert(self.busy, rec)
	end
	-- pieces that were too far ahead for their lead-in
	local pending = self.pending
	if #pending > 0 then
		local keep = {}
		for _, e in ipairs(pending) do
			if (e.t - tLand) * e.speed <= e.lead or e.t - tLand < blk then
				start(e)
			else
				table.insert(keep, e)
			end
		end
		self.pending = keep
		pending = keep
	end
	-- schedule
	local ev = self.events
	local i = self.nextEvent
	local low = self.lowCost
	while i <= #ev and ev[i].t < horizon do
		local e = ev[i]
		i += 1
		if low and e.band then
			-- low cost: no sixth-octave grains; the half-octave set at full weight (it carries the band's whole power)
			local band = BANDS[e.band]
			if band.half then
				local w = band.w
				e = table.clone(e)
				e.vol /= math.sqrt(w)
				if (e.t - tLand) > e.lead and e.t - tLand >= blk then
					table.insert(pending, e)
				else
					start(e)
				end
			end
		elseif (e.t - tLand) * e.speed > e.lead and e.t - tLand >= blk then
			table.insert(pending, e)
		else
			start(e)
		end
	end
	self.nextEvent = i
	if st then
		st.maxBusy = math.max(st.maxBusy, #self.busy)
		st.lowCost = st.lowCost or self.lowCost
		st.minBudget = math.min(st.minBudget, self.budget)
	end
	-- players not reused: stop on the landing boundary (before the file reaches its next piece)
	for file, list in pairs(spare) do
		local pool = self:_pool(file)
		for _, rec in ipairs(list) do
			if rec.p.IsPlaying then
				rec.p:Stop()
			end
			table.insert(pool.free, rec)
		end
	end
	-- the end: every piece has played
	local dur = self.clip.duration
	if self.nextEvent > #ev and #self.pending == 0 and #self.busy == 0 and tLand >= dur then
		self:_report()
		if self.loop then
			self:_reset(0)
			self.lastB = B
			self:_newStats(0)
		else
			self:_finish()
			self._ended:Fire()
		end
	end
end

-- Every bed reads its loop at its own speed, which also wanders slowly (once every 2 blocks): played at speed 1 the
-- loops came round again together (every hiss band every 0.5 s), and a fading tail pulsed in that rhythm instead of
-- dying away (the hiss repeated with correlation 0.85 at 0.5 s; with these speeds 0.07, as low as the original's own).
-- Speeds stay within 1 +- 0.07: a band's noise moves a few percent in pitch, which noise doesn't show.
local BED_SPREAD, BED_WOBBLE = 0.04, 0.03
local PHI = 0.618034
local function bedSpeed(bi, t)
	local u = (bi * PHI) % 1 * 2 - 1 -- spread over the bands
	local per = 0.35 + 0.3 * ((bi * 0.381966) % 1) -- wobble period 0.35 .. 0.65 s
	local ph = 2 * math.pi * ((bi * 0.7548777) % 1)
	return 1 + BED_SPREAD * u + BED_WOBBLE * math.sin(2 * math.pi * t / per + ph)
end

-- the beds' volumes (and speeds) for the block that starts at clip time t (written now, applied on that block's
-- boundary)
function TexturePlayer:_bedStep(t)
	local beds = self.beds
	if not beds then
		return
	end
	if not self.bedsOn then
		self.bedsOn = true
		self.bedSpeedSet = false
		for _, b in ipairs(beds) do
			b.p.PlaybackSpeed = 1
			b.p.Volume = 0
			b.vol = 0
			b.p.TimePosition = b.start
			if not b.p.IsPlaying then
				b.p:Play()
			end
		end
	end
	local idx = math.floor(t * R / 1024 + 1e-6) + 1
	local before = t < self.timeOrigin - 1e-6 -- (the first blocks, before the clip's time origin: silent)
	local low = self.lowCost
	-- (the drift is off unless AudioLab's attribute BedSpeedDrift = true: drifting beds sound
	-- warbly: the engine resamples each loop at a changing speed)
	local speedNow = AudioLab:GetAttribute("BedSpeedDrift") == true and (idx % 2 == 1 or not self.bedSpeedSet)
	self.bedSpeedSet = true
	local ts = (idx - 1) * 1024 / R
	for bi, b in ipairs(beds) do
		if speedNow then
			b.p.PlaybackSpeed = bedSpeed(bi, ts)
		end
		local list = self.bedVol[bi]
		local v = 0
		if not before and idx >= 1 and idx <= #list then
			v = list[idx]
		end
		if low then
			-- low cost: no sixth-octave beds; the half-octave set at full weight (as the grains do)
			local band = BANDS[bi]
			v = band.half and v / math.sqrt(band.w) or 0
		end
		v = math.min(v, MAX_VOLUME)
		if math.abs(v - b.vol) > 1e-5 then
			b.vol = v
			b.p.Volume = v
		end
	end
end

function TexturePlayer:_finish()
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	self.playing = false
	if self.beds then
		for _, b in ipairs(self.beds) do
			b.p.Volume = 0
			b.vol = 0
			if b.p.IsPlaying then
				b.p:Stop()
			end
		end
		self.bedsOn = false
	end
	for _, pool in pairs(self.pools) do
		for _, rec in ipairs(pool.free) do
			if rec.p.IsPlaying then
				rec.p:Stop()
			end
		end
	end
	for _, rec in ipairs(self.busy or {}) do
		if rec.p.IsPlaying then
			rec.p:Stop()
		end
		table.insert(self:_pool(rec.file).free, rec)
	end
	self.busy = {}
	self.pending = {}
end

-- Before the first play every spot of the files the clip uses is played once, silently (a few per frame): the engine
-- decodes a compressed file where a player jumps in, and a first play that jumps into ~600 new spots at once
-- stutters (spots decoded before play smoothly).
local WARM_PER_FRAME = 16
function TexturePlayer:_warmUp()
	-- every distinct piece: { file, at, lead, dur }
	local seen, queue = {}, {}
	for _, e in ipairs(self.events) do
		local key = e.file .. ":" .. e.at
		if not seen[key] then
			seen[key] = true
			table.insert(queue, { file = e.file, at = e.at, lead = e.lead, len = e.dur * e.speed })
		end
	end
	local recs = {}
	for file, pool in pairs(self.pools) do
		recs[file] = { list = table.clone(pool.free), i = 0 }
	end
	local running = {}
	local busy = {}
	self.warmed = false
	self.warmTotal = #queue
	-- the beds: each played silently for a moment at its starting spot (up to 10 s for them to load)
	local warmStart = os.clock()
	local bedsUntil, bedsDone = nil, self.beds == nil
	self.warmConn = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if not bedsDone then
			if not bedsUntil then
				local ready = true
				for _, b in ipairs(self.beds) do
					if not b.p.IsReady then
						ready = false
						break
					end
				end
				if ready then
					for _, b in ipairs(self.beds) do
						b.p.Volume = 0
						b.p.TimePosition = b.start
						b.p:Play()
					end
					bedsUntil = now + 0.4
				elseif now - warmStart > 10 then
					bedsDone = true
				end
			elseif now >= bedsUntil then
				if not self.playing then
					for _, b in ipairs(self.beds) do
						if b.p.IsPlaying then
							b.p:Stop()
						end
					end
				end
				bedsDone = true
			end
		end
		for i = #running, 1, -1 do
			local r = running[i]
			if now >= r.until_ then
				if r.rec.p.IsPlaying then
					r.rec.p:Stop()
				end
				busy[r.rec] = nil
				table.remove(running, i)
			end
		end
		local started = 0
		local qi = 1
		while qi <= #queue and started < WARM_PER_FRAME do
			local item = queue[qi]
			local set = recs[item.file]
			local rec
			if set and #set.list > 0 then
				for _ = 1, #set.list do
					set.i = set.i % #set.list + 1
					local c = set.list[set.i]
					if not busy[c] and c.p.IsReady then
						rec = c
						break
					end
				end
			end
			if rec then
				table.remove(queue, qi)
				busy[rec] = true
				rec.p.Volume = 0
				rec.p.PlaybackSpeed = 1
				rec.p.TimePosition = math.max(item.at - item.lead, 0)
				rec.p:Play()
				table.insert(running, { rec = rec, until_ = now + item.lead + item.len + 0.03 })
				started += 1
			else
				qi += 1
			end
		end
		if #queue == 0 and #running == 0 and bedsDone then
			self.warmed = true
			self.warmConn:Disconnect()
			self.warmConn = nil
		end
	end)
end

-- one line in the output after every play (or loop): what the player saw, to tell a bad play from a good one
function TexturePlayer:_newStats(waited)
	self.stats = { late = 0, maxLate = 0, maxAdv = 0, maxBusy = 0, lowCost = false, minBudget = math.huge, waited = waited,
		unready = 0, steady = self.clockSteady, n = (self.stats and self.stats.n or 0) + 1 }
end
function TexturePlayer:_unready()
	local n = 0
	for _, b in ipairs(self.beds or {}) do
		if not b.p.IsReady then
			n += 1
		end
	end
	for _, pool in pairs(self.pools) do
		for _, rec in ipairs(pool.free) do
			if not rec.p.IsReady then
				n += 1
			end
		end
	end
	return n
end
function TexturePlayer:_report()
	local st = self.stats
	-- (a testing aid: only with the AudioLab folder's Debug attribute)
	local al = script:FindFirstAncestor("AudioLab")
	if not st or not (al and al:GetAttribute("Debug") == true) then
		return
	end
	print(("[AudioLab] texture play %d: waited %.2f s (not loaded %d, warmed %s, clock ticks %d), late pieces %d (worst %.0f ms), "
		.. "biggest block jump %d, low cost %s, grains skipped %d, players at most %d (+%d beds), budget %s"):format(st.n, st.waited or -1,
		st.unready, tostring(self.warmed), st.steady or -1, st.late, st.maxLate * 1000, st.maxAdv, st.lowCost and "yes" or "no",
		self.dropped, st.maxBusy, self.beds and #self.beds or 0, st.minBudget == math.huge and "-" or tostring(st.minBudget)))
end

function TexturePlayer:_loaded()
	if not self.clockPlayer.IsReady or not self.warmed then
		return false
	end
	for _, b in ipairs(self.beds or {}) do
		if not b.p.IsReady then
			return false
		end
	end
	for _, pool in pairs(self.pools) do
		for _, rec in ipairs(pool.free) do
			if not rec.p.IsReady then
				return false
			end
		end
	end
	return true
end

function TexturePlayer:_connect()
	self.playing = true
	self.paused = false
	self.lastB = nil
	-- wait for every player to be loaded (a half-loaded clip sounds broken; right after joining, loading can take seconds,
	-- so up to 15 s), then for the clock to tick steadily (up to 2 s more: the engine catches up after a song switch)
	local waitFrom = os.clock()
	local loadedAt
	self.conn = RunService.Heartbeat:Connect(function()
		if waitFrom then
			local now = os.clock()
			-- right after joining the bed files are still being checked: the first play waits for that (up to 3 s) so it
			-- plays the beds too instead of falling back to the grains
			if not self.beds and not self.bedsOff then
				if bedsChecking and now - waitFrom < 3 then
					return
				end
				if bedsLoaded then
					self:_enableBeds()
					self:_reset(self.timeOrigin) -- (the events changed)
				end
			end
			if not loadedAt then
				if not self:_loaded() and now - waitFrom < 15 then
					return
				end
				loadedAt = now
			end
			if self.clockSteady < CLOCK_STEADY and now - loadedAt < 2 then
				return
			end
			if self.stats then
				self.stats.waited = os.clock() - waitFrom
				self.stats.unready = self:_unready()
				self.stats.steady = self.clockSteady
			end
			waitFrom = nil
			self.advance = {} -- (how far apart frames arrive is measured from the start of playback)
		end
		self:_step()
	end)
end

-- the budget (players this clip may run) and the mode: full, or low cost when the full set doesn't fit or frames are slow
function TexturePlayer:_budget()
	self.budget = math.max(ENGINE_LIMIT - LIMIT_MARGIN - playingElsewhere(self.folder), 24)
	self.lowCost = self.forceLow or self.slowFrames or self.budget < self.need.full
end

function TexturePlayer:play(options)
	options = options or {}
	self:stop()
	self:_enableBeds()
	-- room under the engine's player limit: silent players other audio left running stop first (they restart quickly)
	pcall(function()
		require(AudioLab.Synth.OscillatorPool).stopIdle()
	end)
	self.dropped = 0
	self:_newStats(os.clock())
	self.slowFrames = false
	self.budgetAt = nil
	self:_budget()
	self.loop = options.Loop == true
	self:_reset(options.StartTime or 0)
	self:_connect()
end

function TexturePlayer:stop()
	if self.playing or self.conn then
		self:_finish()
	end
end

function TexturePlayer:pause()
	local t = self.time
	self:_finish()
	self.paused = true
	self.time = t
end

function TexturePlayer:resume()
	if not self.conn then
		self:_reset(self.time or 0)
		self:_connect()
	end
end

function TexturePlayer:seek(t)
	t = math.clamp(t, 0, self.clip.duration)
	self.time = t
	if self.playing then
		self:_finish()
		self:_reset(t)
		self:_connect()
	end
end

function TexturePlayer:getTime()
	return self.time or 0
end

function TexturePlayer:getDuration()
	return self.clip.duration
end

function TexturePlayer:destroy()
	if self.clockWatch then
		self.clockWatch:Disconnect()
		self.clockWatch = nil
	end
	if self.warmConn then
		self.warmConn:Disconnect()
		self.warmConn = nil
	end
	self:_finish()
	self.folder:Destroy()
	self._ended:Destroy()
end

return TexturePlayer
