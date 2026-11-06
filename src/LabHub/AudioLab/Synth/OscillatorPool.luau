-- In-game voice pool built on the Audio API: looping WaveBank AudioPlayers driven by
-- PlaybackSpeed (pitch) and Volume.
--
--   local pool = OscillatorPool.new({ Parent = SoundService, Slots = 8, Bands = 8, Stereo = false, Buses = 16 })
--   pool:setVoice(slot, waveIndex, freqHz, volume, bus?)  -- waveIndex 0 or volume 0 = silent; bus = stereo bus
--       volume OscillatorPool.PREPARE (-1): take and start the player silently, from the start of its loop
--       (all parts of a note prepared in the same frame start in phase); PREPARE_HOLD (-2): keep it ready
--   pool:setBusPan(bus, pan)                              -- pan 0 (left) .. 0.5 (centre) .. 1 (right)
--   pool:setBand(band, volume, volumeRight?)              -- stereo: separate left/right noise levels
--   pool:update(dt)                                       -- every frame (smoothing, idle cleanup)
--   pool.output                                           -- AudioFader with the whole mix
--   pool:silence(), pool:destroy()
--   OscillatorPool.preload(timeout?)                      -- load every WaveBank asset once per session
--   config: KeepWarm (players never stop while running: a stopped AudioPlayer takes ~22 ms to start again,
--           which made some notes late and clipped), Smoothing (fall, 1/s, default 40), AttackSmoothing (rise, default 250), MasterGain,
--           DecorrelateNoise (stereo: right noise loops start at another position),
--           PhaseReset (a silent player that starts sounding is first seeked to the top of its loop, so parts that
--           start in the same frame are in phase: two voices on the same note then add like a sample player's
--           copies instead of at a random phase, which swung their level by up to 10 dB),
--           IdleStop / IdleDestroy (seconds before an unused layer stops / is removed), DeviceOutput,
--           Limiter (default true: AudioLimiter at LimiterCeiling dB, default -1, before the speakers)
--
-- Mono chain:   AudioPlayer -> Wire -> AudioFader (master) -> AudioDeviceOutput
-- Stereo chain: AudioPlayer -> bus fader -> left/right faders -> AudioChannelMixer (Left/Right) -> master
--               noise bands: left set -> noise-left fader -> Left, right set -> noise-right fader -> Right
-- Pan is equal-power (SoundFont convention), normalised so a centred bus is as loud as the mono chain.
-- Players are shared: each (wave, range) asset has a list of idle players that any slot can take. A slot
-- that changes asset fades its old player out (it returns to the idle list) and takes a new one. Recently
-- freed players keep looping silently (no ~22 ms restart); only WarmReserve of them stay running, the rest
-- stop after IdleStop and are destroyed after IdleDestroy. This keeps the running-player count near the
-- audible count and avoids creating players while music plays.
-- Range choice has hysteresis. Noise bands are divided by WaveBank.NoiseGain (playback level).
-- Harmonic bundles (wave > WaveBank.BundleWave0) are only ever slowed down (speed <= BundleMaxSpeed);
-- a bundle whose asset doesn't exist for the note's range (all harmonics above 20 kHz) is silent.
-- Volume and PlaybackSpeed are only written when they change (hundreds of players run per frame).

local AudioLab = script:FindFirstAncestor("AudioLab")
local WaveBank = require(AudioLab.Codec.WaveBank)

local OscillatorPool = {}
OscillatorPool.__index = OscillatorPool
OscillatorPool.PREPARE = -1
OscillatorPool.PREPARE_HOLD = -2

local HYSTERESIS = 1.25
local SILENT = 1e-4
-- An AudioFader with two or more input wires outputs exactly
-- -3.01 dB relative to a single input, independent of input count. Faders that collect many inputs are
-- given a permanent silent extra input so this is constant, and the loss is undone here.
local MIX_CALIBRATION = math.sqrt(2)

-- Preload ----------------------------------------------------------------------------------
-- A WaveBank asset that hasn't been played in this session takes ~0.3 s to load on first use,
-- which silences the start of the first note that needs it. Preloading keeps one
-- loaded player per FILE (the atlas packs are 4 files, the full per-sound manifest ~117) alive for the session, and
-- ContentProvider fetches the bytes in parallel. Every client starts this on join from ReplicatedFirst (the server
-- copies AudioLab.Preload there; its Loader needs no require), and AudioLabClient calls this as well: it reuses the
-- loader's players and adds any file they don't cover. It follows the Manifest attribute (a new Revision reloads what
-- changed).
-- Progress is on SoundService.AudioLabPreload attributes: State ("loading" | "ready" | "partial"), Total, Ready, Failed,
-- Revision. "partial" = the time limit passed with files still loading (they keep loading in the background).
local PRELOAD_LIMIT = 90 -- seconds before State becomes "partial" (the big atlas files are ~10 MB each)
local preloadState, preloadRevision = nil, nil
local preloadInfo = { State = "idle", Total = 0, Ready = 0, Failed = 0, Revision = 0 }

local function publishPreload(folder)
	if folder and folder.Parent then
		for k, v in pairs(preloadInfo) do
			folder:SetAttribute(k, v)
		end
	end
end

function OscillatorPool.preloadStatus()
	return table.clone(preloadInfo)
end

function OscillatorPool.preload(timeout)
	WaveBank.refresh() -- the manifest may have changed (attribute Manifest): new files are loaded in the background
	if preloadState == "done" and preloadRevision ~= WaveBank.Revision then
		preloadState = nil
	end
	if preloadState == "done" then
		return true
	end
	if preloadState == nil then
		preloadState = "loading"
		local revision = WaveBank.Revision
		preloadRevision = revision
		-- reuse an existing preload folder (every script context requires its own copy of this module)
		local soundService = game:GetService("SoundService")
		local folder = soundService:FindFirstChild("AudioLabPreload") or Instance.new("Folder")
		folder.Name = "AudioLabPreload"
		-- one player per distinct id: keep the ones already loaded, drop the ones the manifest no longer uses
		local wanted = {}
		for name, id in pairs(WaveBank.Assets) do
			if id ~= "" and wanted[id] == nil then
				wanted[id] = name
			end
		end
		local byId = {}
		-- players the preload loader started on join are reused: those files are already loading
		local early = game:GetService("ReplicatedFirst"):FindFirstChild("AudioLabPreload")
		local earlyFiles = early and early:FindFirstChild("Files")
		if earlyFiles then
			for _, p in ipairs(earlyFiles:GetChildren()) do
				if p:IsA("AudioPlayer") and wanted[p.Asset] and not byId[p.Asset] then
					byId[p.Asset] = p
				end
			end
		end
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("AudioPlayer") and wanted[child.Asset] and not byId[child.Asset] then
				byId[child.Asset] = child
			else
				child:Destroy()
			end
		end
		local players = {}
		for id, name in pairs(wanted) do
			local p = byId[id]
			if not p then
				p = Instance.new("AudioPlayer")
				p.Name = name
				p.Asset = id
				p.Parent = folder
			end
			table.insert(players, p)
		end
		folder.Parent = soundService
		preloadInfo.State, preloadInfo.Total, preloadInfo.Ready, preloadInfo.Failed, preloadInfo.Revision =
			"loading", #players, 0, 0, revision
		publishPreload(folder)
		-- fetch the bytes (all files at once) ...
		task.spawn(function()
			pcall(function()
				game:GetService("ContentProvider"):PreloadAsync(players, function(_, status)
					if status == Enum.AssetFetchStatus.Failure or status == Enum.AssetFetchStatus.TimedOut then
						preloadInfo.Failed += 1
					end
				end)
			end)
		end)
		-- ... and wait until every player reports ready
		task.spawn(function()
			local t0 = os.clock()
			while os.clock() - t0 < PRELOAD_LIMIT and preloadRevision == revision do
				local ready = 0
				for _, p in ipairs(players) do
					if p.IsReady then
						ready += 1
					end
				end
				preloadInfo.Ready = ready
				if ready == #players then
					break
				end
				publishPreload(folder)
				task.wait(0.1)
			end
			if preloadRevision ~= revision then
				return -- the manifest changed meanwhile: the newer preload reports
			end
			local ready = 0
			for _, p in ipairs(players) do
				if p.IsReady then
					ready += 1
				end
			end
			preloadInfo.Ready = ready
			preloadInfo.State = (ready == #players) and "ready" or "partial"
			preloadState = "done"
			publishPreload(folder)
			local al = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("AudioLab")
			if preloadInfo.State == "partial" and al and al:GetAttribute("Debug") == true then
				warn(("[AudioLab] preload: %d of %d files ready after %d s; the rest keep loading"):format(ready, #players, PRELOAD_LIMIT))
			end
		end)
	end
	if timeout and timeout > 0 then
		local t0 = os.clock()
		while preloadState ~= "done" and os.clock() - t0 < timeout do
			task.wait(0.05)
		end
	end
	return preloadState == "done"
end

-- Player store ----------------------------------------------------------------------------
-- Creating or destroying a few hundred AudioPlayers (and their wires) in one frame hitches for 100+ ms, which is
-- what switching songs did. Pools take their players from this store and give them back when they are destroyed,
-- so the next song reuses players that are already loaded and running (silent, wired to nothing). Players that
-- stay unused stop after KEEP_RUNNING seconds and are destroyed (a few per frame) after KEEP_STORED.
local KEEP_RUNNING = 30 -- a stopped song's players stay running this long, so the next song reuses them without a cold start
local Store = { free = {}, folder = nil, count = 0, created = 0, live = 0, giving = {}, doomed = {}, conn = nil, nextAge = 0 }

-- Player limit: the most AudioPlayers AudioLab makes on this device in a session. Players are never destroyed while
-- the session runs (creating and destroying instances every few seconds strains phones, weak laptops and Studio): an
-- unused player is stopped and kept for the next note. At the limit, a part that needs a file no idle player has takes
-- the longest-idle player of another file and switches its Asset (every file is preloaded, so it starts from the cache);
-- if every player is busy the part stays silent (the synth plays the loudest parts first).
-- Default: 128 on touch-only devices (phones, tablets), 320 elsewhere. Attribute PlayerLimit on the AudioLab module
-- overrides it (16 or more).
function OscillatorPool.playerLimit()
	local host = script:FindFirstAncestor("AudioLab")
	local v = host and host:GetAttribute("PlayerLimit")
	if type(v) == "number" and v >= 16 then
		return math.floor(v)
	end
	local UIS = game:GetService("UserInputService")
	return (UIS.TouchEnabled and not UIS.KeyboardEnabled) and 128 or 320
end
Store.pinned = setmetatable({}, { __mode = "k" }) -- players made by warmUp: kept running, never destroyed

-- Stops every idle stored player that is still running (a stopped song's players run silently for KEEP_RUNNING s).
-- A client plays only about 400 AudioPlayers at once, all audio together: Synth.TexturePlayer calls this before a
-- clip that needs hundreds of them. The next song starts these again (a stopped player restarts in ~22 ms).
function OscillatorPool.stopIdle()
	local n = 0
	for _, list in pairs(Store.free) do
		for _, rec in ipairs(list) do
			if rec.player.Parent and rec.player.IsPlaying and not Store.pinned[rec.player] then
				rec.player:Stop()
				n += 1
			end
		end
	end
	return n
end

-- Starting a player is expensive: 61 Play() calls in one frame took 59 ms, and while a frame runs no part is updated,
-- so the whole mix froze. During live playback (pool.startBudget, set by MidiSynth when it plays) at most START_BUDGET
-- players are started or created per frame, across every pool; the rest wait a frame (the synth asks again each frame).
local START_BUDGET = 8
local frameNo, budgetFrame, budgetUsed = 0, -1, 0
game:GetService("RunService").Heartbeat:Connect(function()
	frameNo += 1
end)
local function takeStart(pool)
	local cap = pool.startBudget
	if not cap then
		return true
	end
	if budgetFrame ~= frameNo then
		budgetFrame, budgetUsed = frameNo, 0
	end
	if budgetUsed >= cap then
		return false
	end
	budgetUsed += 1
	return true
end
OscillatorPool.START_BUDGET = START_BUDGET

function Store.getFolder()
	if not Store.folder or not Store.folder.Parent then
		-- one folder per script context (Client / Server / Edit), shared by every copy of this module in it
		local run = game:GetService("RunService")
		local context = (not run:IsRunning() and "Edit") or (run:IsClient() and "Client") or "Server"
		local name = "AudioLabPlayers_" .. context
		local soundService = game:GetService("SoundService")
		local f = soundService:FindFirstChild(name)
		if not f then
			f = Instance.new("Folder")
			f.Name = name
			f.Parent = soundService
		end
		Store.folder = f
	end
	return Store.folder
end

local function storeWork()
	local t0 = os.clock()
	-- players handed back by destroyed pools
	while #Store.giving > 0 and os.clock() - t0 < 0.002 do
		local job = Store.giving[1]
		local p, info = next(job.owned)
		if p == nil then
			table.remove(Store.giving, 1)
		else
			job.owned[p] = nil
			Store.give(p, info)
		end
	end
	-- mixing nodes of destroyed pools
	while #Store.doomed > 0 and os.clock() - t0 < 0.004 do
		local d = Store.doomed[1]
		local kid = d.kids[d.i]
		if kid then
			d.i += 1
			kid:Destroy()
		else
			d.folder:Destroy()
			table.remove(Store.doomed, 1)
		end
	end
	-- ageing: stop players that stay unused (they are kept, never destroyed)
	local now = os.clock()
	if now >= Store.nextAge then
		Store.nextAge = now + 1
		if Store.folder and Store.folder.Parent then
			Store.live = #Store.folder:GetChildren()
		end
		local budget = 24
		for asset, list in pairs(Store.free) do
			for i = #list, 1, -1 do
				local rec = list[i]
				local age = now - rec.since
				if rec.player.Parent == nil then
					table.remove(list, i)
					Store.count -= 1
				elseif age > KEEP_RUNNING and budget > 0 and rec.player.IsPlaying and not Store.pinned[rec.player] then
					budget -= 1
					rec.player:Stop()
				end
			end
			if #list == 0 then
				Store.free[asset] = nil
			end
		end
	end
	local stillRunning = false
	for _, list in pairs(Store.free) do
		for _, rec in ipairs(list) do
			if rec.player.IsPlaying then
				stillRunning = true
				break
			end
		end
		if stillRunning then
			break
		end
	end
	if not stillRunning and #Store.giving == 0 and #Store.doomed == 0 and Store.conn then
		Store.conn:Disconnect()
		Store.conn = nil
	end
end

local function storeAwake()
	if not Store.conn then
		Store.conn = game:GetService("RunService").Heartbeat:Connect(storeWork)
	end
end

-- Atlas sounds (Codec.Manifests.Atlas): many sounds share one uploaded file and each plays its own region of it. Such a
-- player is stored under "<id>#<sound name>" (not just the id), loops inside [loopStart, loopEnd] (a one-shot loops its own
-- span, as the individual files loop whole) and every TimePosition write is relative to the start of that region.
local startOf = setmetatable({}, { __mode = "k" })
local function baseName(name)
	return (name:gsub("_R$", ""))
end
local function keyFor(name, id)
	local base = baseName(name)
	return WaveBank.Regions[base] and (id .. "#" .. base) or id
end
local function applyRegion(p, name)
	local reg = WaveBank.Regions[baseName(name)]
	if not reg then
		startOf[p] = nil
		return
	end
	local a, b
	if reg.loopStart then
		a, b = reg.loopStart, reg.loopEnd
	else
		a, b = reg.onset, reg.stopAt
	end
	startOf[p] = a
	p.Looping = true
	p.LoopRegion = NumberRange.new(a, b)
	p.TimePosition = a
end
local function seek(p, secs)
	p.TimePosition = (startOf[p] or 0) + secs
end

function Store.give(p, info)
	if p.Parent == nil then
		return
	end
	info.wire.TargetInstance = nil
	p.Volume = 0
	local list = Store.free[info.asset]
	if not list then
		list = {}
		Store.free[info.asset] = list
	end
	table.insert(list, { player = p, wire = info.wire, asset = info.asset, since = os.clock() })
	Store.count += 1
	storeAwake()
end

function Store.queueGive(owned)
	table.insert(Store.giving, { owned = owned })
	storeAwake()
end

function Store.queueDestroy(folder)
	table.insert(Store.doomed, { folder = folder, kids = folder:GetChildren(), i = 1 })
	storeAwake()
end

-- a stored player for this asset (the most recently given: it is still running), or nil
function Store.take(assetId)
	local list = Store.free[assetId]
	while list and #list > 0 do
		local rec = table.remove(list)
		Store.count -= 1
		if rec.player.Parent ~= nil then
			return rec.player, rec.wire
		end
	end
	return nil
end

-- the longest-stored player of any file other than `key` (for reuse under the player limit), or nil
function Store.takeOther(key)
	local best, bestList, bestI
	for k, list in pairs(Store.free) do
		if k ~= key then
			for i, rec in ipairs(list) do
				if rec.player.Parent ~= nil and (not best or rec.since < best.since) then
					best, bestList, bestI = rec, list, i
				end
			end
		end
	end
	if best then
		table.remove(bestList, bestI)
		Store.count -= 1
		return best.player, best.wire
	end
	return nil
end

-- a new running, silent, unwired player added to the store (nothing once the player limit is reached)
function Store.make(name, assetId)
	if Store.live >= OscillatorPool.playerLimit() then
		return false
	end
	Store.live += 1
	local key = keyFor(name, assetId)
	local p = Instance.new("AudioPlayer")
	p.Name = name
	p.Asset = assetId
	p.Looping = true
	p.Volume = 0
	applyRegion(p, name)
	p.Parent = Store.getFolder()
	local w = Instance.new("Wire")
	w.Name = "Out"
	w.SourceInstance = p
	w.Parent = p
	p:Play()
	Store.created += 1
	Store.pinned[p] = true
	Store.give(p, { wire = w, asset = key })
	return true
end

local function wire(parent, from, to, toPin)
	local w = Instance.new("Wire")
	w.SourceInstance = from
	w.TargetInstance = to
	if toPin then
		w.TargetName = toPin
	end
	w.Parent = parent
	return w
end

local function newFader(parent, name, volume)
	local f = Instance.new("AudioFader")
	f.Name = name
	f.Volume = volume or 1
	f.Parent = parent
	return f
end

-- a fader that will collect several inputs: add a silent constant input so the -3 dB is permanent
local function newBusFader(parent, name)
	local f = newFader(parent, name, 1)
	local dummy = Instance.new("AudioPlayer")
	dummy.Name = "keepalive"
	dummy.Volume = 0
	dummy.Parent = f
	wire(f, dummy, f)
	return f
end

local function panGains(pan)
	local theta = math.clamp(pan, 0, 1) * math.pi / 2
	return math.cos(theta) * math.sqrt(2), math.sin(theta) * math.sqrt(2)
end
OscillatorPool.panGains = panGains

function OscillatorPool.new(config)
	config = config or {}
	OscillatorPool.preload() -- also applies the wanted asset manifest (WaveBank.refresh)
	local self = setmetatable({}, OscillatorPool)
	self.slotCount = config.Slots or 8
	self.bandCount = config.Bands or #WaveBank.NoiseBands
	self.smoothing = config.Smoothing or 40
	self.attackSmoothing = config.AttackSmoothing or 250
	self.bandFall = config.BandFallSmoothing or 150 -- noise bands release faster than the pitched parts: a consonant or breath burst ends sharply
	self.warmReserve = config.WarmReserve or 48 -- idle players kept running (instant reuse)
	self.idleStop = config.IdleStop or 2.0 -- idle players beyond the reserve, or older than this, stop
	self.idleDestroy = config.IdleDestroy or math.huge -- idle players are kept (stopped) for reuse, never destroyed mid-session
	self.bandsWarm = config.BandsWarm == true
	self.phaseReset = config.PhaseReset == true
	-- a slot that goes silent keeps its player (muted) this long before giving it back, so a part that
	-- flickers (budget edge, quiet threshold, re-struck note) resumes on the same running player
	self.holdTime = config.HoldTime or 0.15 -- noise players keep looping while running (drum hits start instantly)
	self.stereo = config.Stereo == true
	self.decorrelate = config.DecorrelateNoise == true
	self.owned = {} -- player -> { wire, asset }: given back to the store when the pool is destroyed
	self.folder = Instance.new("Folder")
	self.folder.Name = config.Name or "AudioLabVoices"
	self.output = newFader(self.folder, "Master")
	self.masterGain = config.MasterGain or 1
	if config.DeviceOutput ~= false then
		self.device = Instance.new("AudioDeviceOutput")
		self.device.Name = "Speakers"
		self.device.Parent = self.folder
		if config.Limiter ~= false then
			-- brick-wall limiter on the speaker path: lets the mix run at full level without clipping
			self.limiter = Instance.new("AudioLimiter")
			self.limiter.Name = "Limiter"
			self.limiter.MaxLevel = config.LimiterCeiling or -1
			self.limiter.Release = 0.12
			self.limiter.Parent = self.folder
			wire(self.folder, self.output, self.limiter)
			wire(self.folder, self.limiter, self.device)
		else
			wire(self.folder, self.output, self.device)
		end
	end
	if self.stereo then
		-- the master has a single input (the mixer): no calibration needed there
		self.output.Volume = self.masterGain
		self.mixer = Instance.new("AudioChannelMixer")
		self.mixer.Name = "StereoMixer"
		self.mixer.Parent = self.folder
		wire(self.folder, self.mixer, self.output)
		self.buses = {}
		for b = 1, config.Buses or 16 do
			local input = newBusFader(self.folder, "Bus" .. b)
			local left = newFader(self.folder, "Bus" .. b .. "L", 1)
			local right = newFader(self.folder, "Bus" .. b .. "R", 1)
			wire(self.folder, input, left)
			wire(self.folder, input, right)
			wire(self.folder, left, self.mixer, "Left")
			wire(self.folder, right, self.mixer, "Right")
			self.buses[b] = { input = input, left = left, right = right, pan = 0.5 }
			self:setBusPan(b, 0.5)
		end
		self.noiseLeft = newBusFader(self.folder, "NoiseL")
		self.noiseRight = newBusFader(self.folder, "NoiseR")
		self.noiseLeft.Volume = MIX_CALIBRATION
		self.noiseRight.Volume = MIX_CALIBRATION
		wire(self.folder, self.noiseLeft, self.mixer, "Left")
		wire(self.folder, self.noiseRight, self.mixer, "Right")
	else
		self.output.Volume = self.masterGain * MIX_CALIBRATION
	end
	self.folder.Parent = config.Parent or game:GetService("SoundService")
	-- slot = { rec = active player record?, activeKey, layers = { [activeKey] = rec }, range, brange }
	self.slots = {}
	for s = 1, self.slotCount do
		self.slots[s] = { layers = {}, range = nil, brange = nil, activeKey = nil, rec = nil }
	end
	self.fresh = {} -- players started ahead of need that haven't proven they are running yet (see ready)
	self.free = {} -- [key] = { idle records, oldest first }
	self.fading = {} -- released records still fading out
	self.clock = 0
	self.manageTimer = 0
	self.stats = { created = 0, reused = 0, started = 0 }
	self.bands = {}
	for b = 1, self.bandCount do
		local id = WaveBank.noiseAssetId(b)
		local band = { target = 0, current = 0, comp = 1 / (WaveBank.noiseGain and WaveBank.noiseGain(b) or (WaveBank.NoiseGain and WaveBank.NoiseGain[b]) or 1) }
		if id then
			-- the band's file is shared with other bands (WaveBank.noiseSource): its speed puts it on this band
			local speed = WaveBank.noiseSpeed and WaveBank.noiseSpeed(b) or 1
			band.player = self:_newPlayer(WaveBank.noiseAssetName(b), id, self.stereo and self.noiseLeft or self.output, true)
			band.player.PlaybackSpeed = speed
			if self.stereo then
				band.right = { target = 0, current = 0, player = self:_newPlayer(WaveBank.noiseAssetName(b) .. "_R", id, self.noiseRight, true) }
				band.right.player.PlaybackSpeed = speed
				if self.decorrelate then
					-- start the right side's loop elsewhere: identical noise on both sides sounds centred
					seek(band.right.player, 0.61)
				end
			end
		end
		self.bands[b] = band
	end
	self.warned = {}
	return self
end

-- the longest-idle player of this pool for any file other than `key` (taken out of its idle list), or nil
function OscillatorPool:_takeOtherIdle(key)
	local best, bestList, bestI
	for k, list in pairs(self.free) do
		if k ~= key then
			for i, rec in ipairs(list) do
				if rec.player.Parent ~= nil and (not best or (rec.idleSince or 0) < (best.idleSince or 0)) then
					best, bestList, bestI = rec, list, i
				end
			end
		end
	end
	if best then
		table.remove(bestList, bestI)
		return best.player, best.wire
	end
	return nil
end

-- a player for this file: a stored one, a new one while under the player limit (or `force`: the noise bands), else an
-- idle player of another file switched to this one; nil when every player is busy
function OscillatorPool:_newPlayer(name, assetId, target, force)
	target = target or self.output
	local key = keyFor(name, assetId)
	local p, w = Store.take(key)
	if not p and not force and Store.live >= OscillatorPool.playerLimit() then
		p, w = Store.takeOther(key)
		if not p then
			p, w = self:_takeOtherIdle(key)
		end
		if not p then
			return nil
		end
		if p.IsPlaying then
			p:Stop()
		end
		p.Asset = assetId
		p.Looping = true
		applyRegion(p, name)
		Store.pinned[p] = nil
		self.stats.switched = (self.stats.switched or 0) + 1
	end
	if p then
		p.Name = name
		p.Volume = 0
		w.TargetInstance = target
	else
		Store.live += 1
		p = Instance.new("AudioPlayer")
		p.Name = name
		p.Asset = assetId
		p.Looping = true
		p.Volume = 0
		applyRegion(p, name)
		p.Parent = Store.getFolder()
		w = wire(p, p, target)
		w.Name = "Out"
		Store.created += 1
	end
	self.owned[p] = { wire = w, asset = key }
	return p, w
end

function OscillatorPool:setMasterGain(gain)
	self.masterGain = gain
	self.output.Volume = gain * (self.stereo and 1 or MIX_CALIBRATION)
end

function OscillatorPool:setBusPan(bus, pan)
	local b = self.buses and self.buses[bus]
	if not b then
		return
	end
	b.pan = pan
	local l, r = panGains(pan)
	-- bus inputs carry the permanent -3 dB of a multi-input fader; centred = the mono chain's level per side
	b.left.Volume = l * MIX_CALIBRATION
	b.right.Volume = r * MIX_CALIBRATION
end

function OscillatorPool:_warnMissing(name)
	if not self.warned[name] then
		self.warned[name] = true
		warn(("[AudioLab] asset %s has no id in WaveBank.Assets; that voice is silent"):format(name))
	end
end

function OscillatorPool:_pickRange(slot, freq)
	local r = slot.range
	if r then
		local bases = WaveBank.Bases
		local low = (r > 1) and math.sqrt(bases[r - 1] * bases[r]) or 0
		local high = (r < #bases) and math.sqrt(bases[r] * bases[r + 1]) or math.huge
		if freq >= low / HYSTERESIS and freq <= high * HYSTERESIS then
			return r
		end
	end
	r = WaveBank.rangeFor(freq)
	slot.range = r
	return r
end

-- bundles: keep the current base while the note fits under it (speed <= max) and isn't far below
function OscillatorPool:_pickBundleRange(slot, freq)
	local r = slot.brange
	local bases = WaveBank.BundleBases
	if r and freq <= bases[r] * WaveBank.BundleMaxSpeed and (r == 1 or freq >= bases[r] / 2 / HYSTERESIS) then
		return r
	end
	r = WaveBank.bundleRange(freq)
	slot.brange = r
	return r
end

-- take an idle player for this asset (the most recently freed one: it is still running), or make one
function OscillatorPool:_acquire(key, wave, range, target)
	local list = self.free[key]
	local rec = list and table.remove(list)
	if rec then
		self.stats.reused += 1
	else
		local name = WaveBank.assetName(wave, range)
		local id = WaveBank.assetId(wave, range)
		if not id then
			self:_warnMissing(name)
			return nil
		end
		if not takeStart(self) then
			-- over this frame's start budget: the synth asks again next frame (block-ahead: made in between, startPending)
			self.pendingMake = self.pendingMake or {}
			local pm = self.pendingMake[key]
			if pm then
				pm.n += 1
			else
				self.pendingMake[key] = { wave = wave, range = range, target = target, n = 1 }
			end
			return nil
		end
		local p, w = self:_newPlayer(name, id, target)
		if not p then
			return nil -- every player is busy: this part stays silent
		end
		rec = { player = p, wire = w, key = key, target = 0, current = 0, bus = target }
		if self.trackFresh then
			table.insert(self.fresh, p) -- warm-up: ready() waits for it to start producing samples
		end
		self.stats.created += 1
	end
	rec.idleSince = nil
	if rec.bus ~= target then
		rec.wire.TargetInstance = target -- note on another channel: route to its bus
		rec.bus = target
	end
	return rec
end

function OscillatorPool:_release(slot)
	local rec = slot.rec
	if not rec then
		return
	end
	rec.target = 0
	rec.fast = false
	table.insert(self.fading, rec)
	slot.rec = nil
	if slot.activeKey then
		slot.layers[slot.activeKey] = nil
	end
	slot.activeKey = nil
end

function OscillatorPool:setVoice(slotIndex, wave, freq, volume, bus, phase, fast)
	local slot = self.slots[slotIndex]
	if not slot then
		return
	end
	if wave == 0 or volume == 0 or freq <= 0 then
		local rec = slot.rec
		if rec then
			rec.target = 0
			slot.muteAt = slot.muteAt or self.clock
		end
		return
	end
	local wasMuted = slot.muteAt ~= nil
	slot.muteAt = nil
	local range
	-- tracked sine: the looping sine at the base index carried in the wave (the synth follows its position)
	local isFine = wave > WaveBank.FineWave0 -- a fine harmonic bundle (see WaveBank.FineGroups)
	local isRough = wave == WaveBank.RoughWave -- the rough sine (one file, any pitch)
	local isTrack = not isFine and not isRough and WaveBank.TrackWave0 ~= nil and wave > WaveBank.TrackWave0 and wave <= WaveBank.DecayWave0
	local isDecay = not isFine and not isRough and WaveBank.DecayWave0 ~= nil and wave > WaveBank.DecayWave0
	if isRough then
		range = 1
	elseif isFine then
		range = self:_pickBundleRange(slot, freq)
		if not range or not WaveBank.fineHarmonics(wave - WaveBank.FineWave0, range) then
			self:_release(slot)
			return
		end
	elseif isTrack then
		range = wave - WaveBank.TrackWave0
		wave = 1
	elseif isDecay then
		-- decaying sine: the range is part of the wave index (the synth tracks the file position at that base)
		local _, r = WaveBank.decayInfo(wave)
		range = r
	elseif WaveBank.PulseWave0 and wave > WaveBank.PulseWave0 then
		range = WaveBank.pulseRange(wave - WaveBank.PulseWave0, freq, slot.prange)
		slot.prange = range
		if not range then
			self:_release(slot)
			return
		end
	elseif wave > WaveBank.BundleWave0 then
		range = self:_pickBundleRange(slot, freq)
		if not range or not WaveBank.bundleHarmonics(wave - WaveBank.BundleWave0, range) then
			self:_release(slot)
			return
		end
	elseif wave == 1 and WaveBank.SineRange then
		range = WaveBank.SineRange -- one sine file plays every pitch
	else
		range = self:_pickRange(slot, freq)
	end
	local key = wave * 100 + range
	local target = self.output
	if self.stereo then
		local b = self.buses[bus or 1] or self.buses[1]
		target = b.input
	end
	local rec = slot.rec
	if rec and rec.key ~= key then
		self:_release(slot) -- changing wave or range: the old player fades out, a new one fades in
		rec = nil
	end
	if not rec then
		rec = self:_acquire(key, wave, range, target)
		if not rec then
			return
		end
		slot.rec = rec
		slot.activeKey = key
		slot.layers[key] = rec
		wasMuted = true
	elseif rec.bus ~= target then
		rec.wire.TargetInstance = target
		rec.bus = target
	end
	rec.fast = fast == true or fast == "exact" -- coherent voice part: no extra smoothing, exact pitch (it must stay in step with its neighbours)
	local p = rec.player
	local base = isRough and WaveBank.RoughBase or ((wave > WaveBank.BundleWave0 and not isDecay) and WaveBank.BundleBases[range] or WaveBank.Bases[range])
	local speed = freq / base
	local startAt = phase and phase / base or 0 -- the asset is one second of an integer number of periods: phase cycles = phase / base seconds
	-- "exact": a phase-steered part; its speed carries the phase correction for this frame, so it is always sent
	local tol = (fast == "exact") and 0 or (fast == true and 0.00006 or 0.0004)
	if not rec.speed or math.abs(speed - rec.speed) > rec.speed * tol then
		rec.speed = speed
		p.PlaybackSpeed = speed
	end
	-- a decaying sine always starts where the synth says (phase / base = seconds into the file): its envelope is the
	-- file position, and the synth sets the volume for exactly that level
	if wasMuted and volume > 0 and p.IsPlaying and (isDecay or isTrack or (self.phaseReset and rec.current <= 1e-3)) then
		seek(p, startAt) -- silent until now: start this part at the top of its loop (plus its phase offset)
	end
	if volume == -1 then
		-- prepare: restart from the top (every part of the note in phase), stay silent
		seek(p, startAt)
		rec.target, rec.current = 0, 0
		rec.sent = 0
		p.Volume = 0
	end
	if not p.IsPlaying then
		if not takeStart(self) then
			-- over this frame's start budget: started next frame (the synth asks again; block-ahead: in between, startPending)
			self.pendingStart = self.pendingStart or {}
			self.pendingStart[rec] = startAt
			return
		end
		seek(p, startAt) -- AudioPlayer:Stop() keeps the position; start each note the same way
		p:Play()
		self.stats.started += 1
	end
	if volume > 0 then
		rec.target = volume
	end
end

-- Block-ahead mode (MidiSynth): the frames between two synth renders start the players the last render was refused by
-- the start budget, so they are running when the next render wants them. (The synth clears both lists before each render.)
function OscillatorPool:startPending()
	local ps, pm = self.pendingStart, self.pendingMake
	if ps then
		for rec, at in pairs(ps) do
			if not takeStart(self) then
				return
			end
			ps[rec] = nil
			local p = rec.player
			if p.Parent and not p.IsPlaying then
				seek(p, at)
				p:Play()
				self.stats.started += 1
			end
		end
	end
	if pm then
		for key, m in pairs(pm) do
			local id = WaveBank.assetId(m.wave, m.range)
			while id and m.n > 0 do
				if not takeStart(self) then
					return
				end
				m.n -= 1
				local p, w = self:_newPlayer(WaveBank.assetName(m.wave, m.range), id, m.target)
				if not p then
					break
				end
				if not p.IsPlaying then
					p:Play()
					self.stats.started += 1
				end
				local list = self.free[key]
				if not list then
					list = {}
					self.free[key] = list
				end
				table.insert(list, { player = p, wire = w, key = key, target = 0, current = 0, bus = m.target, idleSince = self.clock })
				self.stats.created += 1
			end
			pm[key] = nil
		end
	end
end

local function driveBand(b, volume)
	b.target = volume * (b.comp or 1)
	if volume > 0 and not b.player.IsPlaying then
		b.player:Play()
	end
end

function OscillatorPool:setBand(band, volume, volumeRight)
	local b = self.bands[band]
	if not b then
		return
	end
	if not b.player then
		if volume > 0 then
			self:_warnMissing(WaveBank.noiseAssetName(band))
		end
		return
	end
	driveBand(b, volume)
	if b.right then
		b.right.comp = b.comp
		driveBand(b.right, volumeRight or volume)
	end
end

local function smoothBand(b, alpha, alphaUp, keepWarm)
	if b.current == b.target and b.sent == b.current then
		return
	end
	b.current += (b.target - b.current) * ((b.target > b.current) and alphaUp or alpha)
	if math.abs(b.current - b.target) < 1e-6 then
		b.current = b.target
	end
	b.sent = b.current
	b.player.Volume = b.current
	if not keepWarm and b.target == 0 and b.current < SILENT and b.player.IsPlaying then
		b.player:Stop()
	end
end

local FAST_FALL = 300
local function step(rec, alpha, alphaUp, alphaFast)
	local cur, target = rec.current, rec.target
	if cur == target then
		return
	end
	if rec.fast then
		alpha = alphaFast
	end
	cur += (target - cur) * ((target > cur) and alphaUp or alpha)
	if math.abs(cur - target) < 1e-6 or (target == 0 and cur < SILENT) then
		cur = target
	end
	rec.current = cur
	local sent = rec.sent
	if sent == nil or cur == target or math.abs(cur - sent) > 0.017 * sent + 1e-5 then
		rec.sent = cur
		rec.player.Volume = cur
	end
end

-- idle players: keep the newest WarmReserve running, stop the rest (or any idle > IdleStop), destroy
-- stopped ones idle > IdleDestroy (never, by default).
-- Players idle less than IDLE_MIN seconds are never stopped for the reserve: stopping a player a chord just freed and
-- starting it again at the next chord cost ~30 Stop + Play calls a second (a Play costs ~1 ms of the frame).
local IDLE_MIN = 4
function OscillatorPool:_manageIdle()
	local now = self.clock
	local warm = {}
	for key, list in pairs(self.free) do
		for i = #list, 1, -1 do
			local rec = list[i]
			local idle = now - (rec.idleSince or now)
			if rec.player.IsPlaying then
				if idle > self.idleStop then
					rec.player:Stop()
				else
					table.insert(warm, rec)
				end
			elseif idle > self.idleDestroy then
				self.owned[rec.player] = nil
				rec.player:Destroy()
				table.remove(list, i)
			end
		end
		if #list == 0 then
			self.free[key] = nil
		end
	end
	if #warm > self.warmReserve then
		table.sort(warm, function(a, b)
			return a.idleSince > b.idleSince
		end)
		for i = self.warmReserve + 1, #warm do
			if now - warm[i].idleSince >= IDLE_MIN then
				warm[i].player:Stop()
			end
		end
	end
end

function OscillatorPool:update(dt)
	local alpha = 1 - math.exp(-self.smoothing * dt)
	local alphaUp = 1 - math.exp(-self.attackSmoothing * dt)
	local alphaFast = 1 - math.exp(-FAST_FALL * dt)
	local alphaBand = 1 - math.exp(-self.bandFall * dt)
	self.clock += dt
	if self.warmPending then
		self.warmPending = nil
		self:warm()
	end
	local hold = self.holdTime
	for _, slot in ipairs(self.slots) do
		local rec = slot.rec
		if rec then
			step(rec, alpha, alphaUp, alphaFast)
			if slot.muteAt and rec.current <= 0 and self.clock - slot.muteAt >= hold then
				slot.muteAt = nil
				self:_release(slot)
			end
		end
	end
	local fading = self.fading
	local i = 1
	while i <= #fading do
		local rec = fading[i]
		step(rec, alpha, alphaUp, alphaFast)
		if rec.current <= 0 then
			-- silent: back to the idle list (still running, so the next note on this asset starts instantly)
			fading[i] = fading[#fading]
			fading[#fading] = nil
			rec.idleSince = self.clock
			local list = self.free[rec.key]
			if not list then
				list = {}
				self.free[rec.key] = list
			end
			table.insert(list, rec)
		else
			i += 1
		end
	end
	self.manageTimer += dt
	if self.manageTimer >= 0.25 then
		self.manageTimer = 0
		self:_manageIdle()
	end
	for _, b in ipairs(self.bands) do
		if b.player then
			smoothBand(b, alphaBand, alphaUp, self.bandsWarm)
			if b.right then
				smoothBand(b.right, alphaBand, alphaUp, self.bandsWarm)
			end
		end
	end
end

-- counts for meters and tests: running players, audible players, idle players
function OscillatorPool:counts()
	local running, audible, idle = 0, 0, 0
	local function look(rec)
		if rec.player.IsPlaying then
			running += 1
			if rec.current > 1e-3 then
				audible += 1
			end
		end
	end
	for _, slot in ipairs(self.slots) do
		if slot.rec then
			look(slot.rec)
		end
	end
	for _, rec in ipairs(self.fading) do
		look(rec)
	end
	for _, list in pairs(self.free) do
		for _, rec in ipairs(list) do
			idle += 1
			look(rec)
		end
	end
	for _, b in ipairs(self.bands) do
		for _, side in ipairs({ b, b.right }) do
			if side and side.player and side.player.IsPlaying then
				running += 1
				if side.current > 1e-3 then
					audible += 1
				end
			end
		end
	end
	return running, audible, idle
end

function OscillatorPool:silence()
	for s = 1, self.slotCount do
		self:setVoice(s, 0, 0, 0)
	end
	for b = 1, self.bandCount do
		self:setBand(b, 0, 0)
	end
end

-- start every noise band player now (silent), so the first drum hit isn't late
function OscillatorPool:warm()
	for _, b in ipairs(self.bands) do
		for _, side in ipairs({ b, b.right }) do
			if side and side.player and not side.player.IsPlaying then
				if takeStart(self) then
					seek(side.player, (self.decorrelate and side == b.right) and 0.61 or 0)
					side.player:Play()
					table.insert(self.fresh, side.player)
				else
					self.warmPending = true -- the rest start over the next frames (update)
				end
			end
		end
	end
end

-- create running, silent players for (wave, range) keys ahead of need: counts[key] = how many are wanted
-- in total (idle ones already there count). A voice that starts then takes a running player at once
-- instead of waiting for a new AudioPlayer to load and start (so the first moments of a clip aren't thin).
function OscillatorPool:prewarm(counts)
	local target = self.stereo and self.buses[1].input or self.output
	for key, want in pairs(counts) do
		local wave, range = key // 100, key % 100
		local id = WaveBank.assetId(wave, range)
		if id then
			local list = self.free[key]
			if not list then
				list = {}
				self.free[key] = list
			end
			for _ = #list + 1, want do
				if Store.live >= OscillatorPool.playerLimit() and not Store.free[keyFor(WaveBank.assetName(wave, range), id)] then
					break -- at the limit, prewarming would only take players from other files
				end
				local p, w = self:_newPlayer(WaveBank.assetName(wave, range), id, target)
				if not p then
					break
				end
				seek(p, 0)
				p:Play()
				table.insert(self.fresh, p)
				table.insert(list, { player = p, wire = w, key = key, target = 0, current = 0, bus = target, idleSince = self.clock })
				self.stats.created += 1
			end
		end
	end
end

-- true once every player started by prewarm() / warm() has loaded its asset and is really producing
-- samples (its TimePosition has moved): a player is silent for a moment after Play(), which cut the
-- attack of a hit that starts at once
function OscillatorPool:ready()
	local fresh = self.fresh
	local i = 1
	while i <= #fresh do
		local p = fresh[i]
		if p.Parent == nil or (p.IsReady and (p.TimePosition > (startOf[p] or 0) or not p.IsPlaying)) then
			fresh[i] = fresh[#fresh]
			fresh[#fresh] = nil
		else
			i += 1
		end
	end
	return #fresh == 0
end

-- stop every player (pause / stop); players stay in the idle lists for reuse
function OscillatorPool:stopAll()
	for _, slot in ipairs(self.slots) do
		slot.muteAt = nil
		self:_release(slot)
	end
	for _, rec in ipairs(self.fading) do
		rec.target, rec.current = 0, 0
		rec.sent = 0
		rec.player.Volume = 0
		rec.idleSince = self.clock
		local list = self.free[rec.key] or {}
		self.free[rec.key] = list
		table.insert(list, rec)
	end
	table.clear(self.fading)
	for _, list in pairs(self.free) do
		for _, rec in ipairs(list) do
			if rec.player.IsPlaying then
				rec.player:Stop()
			end
		end
	end
	for _, b in ipairs(self.bands) do
		for _, side in ipairs({ b, b.right }) do
			if side and side.player then
				side.target, side.current, side.sent = 0, 0, 0
				side.player.Volume = 0
				if side.player.IsPlaying then
					side.player:Stop()
				end
			end
		end
	end
end

-- Destroying a pool hands its players back to the store (see above) and takes its mixing nodes apart a few
-- milliseconds per frame (destroy(true)): a few hundred players freed in one frame hitched for 100+ ms.
function OscillatorPool:destroy(gradual)
	local owned, folder = self.owned, self.folder
	self.owned = {}
	self.slots, self.bands, self.free, self.fading = {}, {}, {}, {}
	if gradual then
		self.output.Volume = 0 -- silent at once
		Store.queueGive(owned)
		Store.queueDestroy(folder)
	else
		for p, info in pairs(owned) do
			Store.give(p, info)
		end
		folder:Destroy()
	end
end

-- Create players ahead of use, a few per frame (call from a script that can wait, e.g. at game start):
-- they wait in the store, so the first song doesn't have to create ~100 players in its first second.
--   OscillatorPool.warmUp({ PerSine = 10, PerNoise = 2, PerFrame = 6 })
function OscillatorPool.warmUp(options)
	options = options or {}
	local perSine, perNoise, perFrame = options.PerSine or 10, options.PerNoise or 2, options.PerFrame or 6
	local perBundle = options.PerBundle or 0
	local sine = 1
	for i, w in ipairs(WaveBank.Waves) do
		if w.name == "sine" then
			sine = i
		end
	end
	local jobs = {}
	for range = 1, #WaveBank.Bases do
		local id = WaveBank.assetId(sine, range)
		if id then
			for _ = 1, perSine do
				table.insert(jobs, { WaveBank.assetName(sine, range), id })
			end
		end
	end
	if perBundle > 0 then
		for g = 1, #WaveBank.BundleGroups do
			for r = 1, #WaveBank.BundleBases do
				local id = WaveBank.Assets[WaveBank.bundleAssetName(g, r)]
				if id then
					for _ = 1, perBundle do
						table.insert(jobs, { WaveBank.bundleAssetName(g, r), id, perBundle })
					end
				end
			end
		end
	end
	for b = 1, #WaveBank.NoiseBands do
		local id = WaveBank.noiseAssetId(b)
		if id then
			for _ = 1, perNoise do
				table.insert(jobs, { WaveBank.noiseAssetName(b), id })
			end
		end
	end
	OscillatorPool.preload(30)
	local made = 0
	for n, job in ipairs(jobs) do
		local have = Store.free[keyFor(job[1], job[2])]
		if not have or #have < (job[3] or perSine) then
			if not Store.make(job[1], job[2]) then
				break -- player limit reached
			end
			made += 1
		end
		if n % perFrame == 0 then
			task.wait()
		end
	end
	return made
end

OscillatorPool.Store = Store

return OscillatorPool
