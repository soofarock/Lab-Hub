-- Audio attached to instances, with a registry so any script can find it.
--
--   local h = Attach.attach(part, {
--       Midi = "MySong/music.mid", SoundFont = "MySong/instruments.sf2",   -- MIDI + instruments
--       -- or Clip = "sfx/splash" / File = "sfx/splash.wav"
--       Loop = true, Volume = 0.5, AutoPlay = true,
--       Spatial = true,    -- default for BaseParts, Attachments and Models: plays from an AudioEmitter
--       Range = 40,        -- spatial: full volume out to this many studs, half at twice it, silent at 6 x
--                          -- (default: Roblox's own falloff; or the instance's AudioLabRange attribute)
--   })
--   Attach.get(part) -> handle (or nil);  Attach.detach(part)
--   h:play(), h:stop(), h:setVolume(v), h:isPlaying(), h:destroy(); h.Ended; h.output (AudioFader)
--
--   Server-driven playback: an instance with AudioLabSynced = true follows the server's playhead (see AudioLab.Sync;
--   the server calls Sync.play(part, {...}), clients play locally and stay in sync, late joiners included).
--   The player's own music comes first: while it plays (SoundService attribute AudioLabLocalMusic = true, set by
--   Tools.Library), synced world audio (TVs, speakers; not the player's own channels) is silent on this client and picks
--   up again at the server's playhead when the music pauses or stops. AudioLab attribute LocalMusicFirst = false turns
--   that off.
--   Attach.bindTag("AudioLab")  -- attach every instance tagged "AudioLab" from its attributes:
--       AudioLabMidi, AudioLabSoundFont, AudioLabClip, AudioLabFile (strings), AudioLabLoop,
--       AudioLabAutoPlay, AudioLabSpatial (booleans), AudioLabVolume (number), AudioLabMode ("additive"/"wave")
--
-- Run on the client (LocalScript): the audio plays where it is created. Spatial output needs an
-- AudioListener; with SoundService.DefaultListenerLocation = Camera Roblox provides one in play mode.
-- Handles are removed automatically when their instance is destroyed. Coroutines/task threads share
-- this registry; Actors each have their own (call attach from the synchronized phase).

local CollectionService = game:GetService("CollectionService")
local AudioLab = script:FindFirstAncestor("AudioLab")
local Assets = require(AudioLab.Tools.Assets)
local MidiSynth = require(AudioLab.Synth.MidiSynth)
local Player = require(AudioLab.Synth.Player)
local Sync = require(AudioLab.Sync)

local Attach = {}
local handles = setmetatable({}, { __mode = "k" })
local loopLength -- (below) a synced clip's loop length from its instance, or nil

local Handle = {}
Handle.__index = Handle

local function spatialTarget(instance)
	if instance:IsA("BasePart") or instance:IsA("Attachment") then
		return instance
	end
	if instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

function Attach.attach(instance, options)
	assert(typeof(instance) == "Instance", "Attach.attach expects an Instance")
	options = options or {}
	Attach.detach(instance)
	local h = setmetatable({ instance = instance, options = options }, Handle)
	local target = (options.Spatial ~= false) and spatialTarget(instance) or nil
	local folder = Instance.new("Folder")
	folder.Name = "AudioLab"
	folder.Parent = instance
	h.folder = folder
	if options.Midi then
		local instruments = options.SoundFont and Assets.instruments(options.SoundFont) or {}
		h.kind = "midi"
		h.midi = Assets.midi(options.Midi)
		h.player = MidiSynth.new({
			Parent = folder, Voices = options.Voices, MasterGain = options.Volume or 0.5,
			Bank = instruments.Bank, SoundFont = instruments.SoundFont, Mode = options.Mode,
			Partials = options.Partials, DrumChannel = options.DrumChannel, DeviceOutput = target == nil,
		})
	elseif options.Clip or options.File then
		h.kind = "clip"
		h.player = Player.new(Assets.clip(options.Clip or options.File), {
			Parent = folder, MasterGain = options.Volume or 1, DeviceOutput = target == nil,
		})
	else
		folder:Destroy()
		error("Attach.attach needs Midi, Clip or File")
	end
	h.output = h.player.pool.output
	h.Ended = h.player.Ended
	if target then
		local emitter = Instance.new("AudioEmitter")
		emitter.Name = "AudioLabEmitter"
		emitter.Parent = target
		local wire = Instance.new("Wire")
		wire.Name = "ToEmitter"
		wire.SourceInstance = h.output
		wire.TargetInstance = emitter
		wire.Parent = folder
		h.emitter = emitter
		local range = options.Range or instance:GetAttribute("AudioLabRange")
		if type(range) == "number" and range > 0 then
			pcall(emitter.SetDistanceAttenuation, emitter, { [0] = 1, [range] = 1, [range * 2] = 0.5, [range * 6] = 0 })
		end
	end
	handles[instance] = h
	h._destroying = instance.Destroying:Connect(function()
		h:destroy()
	end)
	if options.AutoPlay ~= false then
		h:play()
	end
	return h
end

function Attach.get(instance)
	return handles[instance]
end

function Attach.detach(instance)
	local h = handles[instance]
	if h then
		h:destroy()
	end
end

function Attach.all()
	local list = {}
	for _, h in pairs(handles) do
		table.insert(list, h)
	end
	return list
end

function Handle:play(options)
	options = options or {}
	local loop = options.Loop
	if loop == nil then
		loop = self.options.Loop == true
	end
	if self.kind == "midi" then
		self.player:play(self.midi, { Loop = loop, Speed = options.Speed, StartTime = options.StartTime })
	else
		self.player:play({ Loop = loop, Speed = options.Speed, StartTime = options.StartTime, LoopLength = loopLength(self) })
	end
end

function Handle:stop()
	self.player:stop()
end

function Handle:isPlaying()
	return self.player.playing == true
end

function Handle:setVolume(v)
	if self.kind == "midi" then
		self.player.masterGain = v
	else
		self.player.pool:setMasterGain(v)
	end
end

function Handle:destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true
	if self._destroying then
		self._destroying:Disconnect()
	end
	if self._yieldConn then
		self._yieldConn:Disconnect()
	end
	pcall(function()
		self.player:destroy(true) -- players are freed a few per frame (no hitch)
	end)
	if self.emitter then
		self.emitter:Destroy()
	end
	if self.folder then
		self.folder:Destroy()
	end
	if handles[self.instance] == self then
		handles[self.instance] = nil
	end
end

-- Keeps a handle on the server's playhead (attributes written by AudioLab.Sync). Checked on every state change and twice a
-- second: starts late joiners in the right place, follows pause / seek / speed, and re-seeks when a client has drifted.
function loopLength(h)
	local v = h.instance and h.instance:GetAttribute("AudioLabLoopLength")
	return (type(v) == "number" and v > 0) and v or nil
end
local function syncInfo(h)
	if not h._syncInfo then
		if h.kind == "midi" then
			local ls, le = MidiSynth.findLoop(h.midi)
			h._syncInfo = { duration = h.midi.duration, loopStart = ls, loopEnd = le }
		else
			local d = h.player:getDuration()
			h._syncInfo = { duration = d, loopStart = 0, loopEnd = d }
		end
	end
	h._syncInfo.loop = h.options.Loop == true
	-- a clip with a loop length (AudioLab.Sync LoopLength: a video's sound) loops on that instead of its own length
	if h.kind ~= "midi" then
		local len = loopLength(h)
		h._syncInfo.duration = len or h.player:getDuration()
		h._syncInfo.loopEnd = h._syncInfo.duration
	end
	return h._syncInfo
end

function Attach.startSync(h)
	if not h then
		return
	end
	local instance = h.instance
	local token = {}
	h._sync = token
	local appliedSeq = nil
	local SoundService = game:GetService("SoundService")
	-- world audio steps aside while this player's own music plays (it gets the players and the attention)
	local function yielded()
		return instance:GetAttribute("AudioLabChannel") == nil and SoundService:GetAttribute("AudioLabLocalMusic") == true
			and AudioLab:GetAttribute("LocalMusicFirst") ~= false
	end
	local function reconcile()
		if h.destroyed or h._sync ~= token then
			return
		end
		local st = Sync.state(instance)
		if not st then
			return
		end
		if yielded() then
			appliedSeq = nil -- back on the server's playhead when the music stops
			if h:isPlaying() then
				h:stop()
			end
			return
		end
		if st.state ~= "playing" then
			appliedSeq = nil
			if h:isPlaying() then
				h:stop()
			end
			return
		end
		local info = syncInfo(h)
		local lead = instance:GetAttribute("AudioLabSyncLead") or Sync.Lead
		local target, finished = Sync.target(st, workspace:GetServerTimeNow() + lead, info)
		if finished then
			appliedSeq = st.seq
			if h:isPlaying() then
				h:stop()
			end
			return
		end
		if target < 0 then -- a delayed start that has not begun: wait for it
			appliedSeq = nil
			if h:isPlaying() then
				h:stop()
			end
			task.delay(-target / math.max(st.speed, 0.01), reconcile)
			return
		end
		if appliedSeq ~= st.seq then
			appliedSeq = st.seq
			h:play({ Loop = info.loop, Speed = st.speed, StartTime = target })
			return
		end
		if not h:isPlaying() then
			return -- a one-shot that ended
		end
		local drift = h.player:getTime() - target
		if info.loop and info.loopEnd > info.loopStart then
			local len = info.loopEnd - info.loopStart
			drift = (drift + len / 2) % len - len / 2
		end
		if math.abs(drift) > Sync.Tolerance then
			h.player:seek(target)
		end
	end
	h._reconcile = reconcile
	if h._yieldConn then
		h._yieldConn:Disconnect()
	end
	h._yieldConn = SoundService:GetAttributeChangedSignal("AudioLabLocalMusic"):Connect(function()
		task.defer(reconcile)
	end)
	local isChannel = instance:GetAttribute("AudioLabChannel") ~= nil
	local lastReport = 0
	task.spawn(function()
		while not h.destroyed and h._sync == token do
			reconcile()
			if isChannel and os.clock() - lastReport >= 2 then -- the server learns what this player is really playing
				lastReport = os.clock()
				pcall(Sync.report, instance, h:isPlaying(), h.player:getTime())
			end
			task.wait(0.5)
		end
	end)
end

local ATTRS = { "AudioLabSynced", "AudioLabMidi", "AudioLabSoundFont", "AudioLabClip", "AudioLabFile", "AudioLabLoop",
	"AudioLabAutoPlay", "AudioLabSpatial", "AudioLabVolume", "AudioLabMode" }

local function optionsFromAttributes(instance)
	return {
		Midi = instance:GetAttribute("AudioLabMidi"), SoundFont = instance:GetAttribute("AudioLabSoundFont"),
		Clip = instance:GetAttribute("AudioLabClip"), File = instance:GetAttribute("AudioLabFile"),
		Loop = instance:GetAttribute("AudioLabLoop") == true,
		AutoPlay = (not instance:GetAttribute("AudioLabSynced")) and instance:GetAttribute("AudioLabAutoPlay") or false,
		Spatial = instance:GetAttribute("AudioLabSpatial"), Volume = instance:GetAttribute("AudioLabVolume"),
		Mode = instance:GetAttribute("AudioLabMode"),
	}
end

function Attach.bindTag(tag)
	tag = tag or "AudioLab"
	local conns = {}
	local attrConns = {}
	local bindGen = setmetatable({}, { __mode = "k" })
	local function bind(instance)
		-- a clip that has to be downloaded first (a video import's sound) loads before anything is replaced; if the
		-- attributes changed meanwhile, the newer bind does the work
		local gen = (bindGen[instance] or 0) + 1
		bindGen[instance] = gen
		local clip = instance:GetAttribute("AudioLabClip") or instance:GetAttribute("AudioLabFile")
		if type(clip) == "string" and not instance:GetAttribute("AudioLabMidi") then
			pcall(Assets.clip, clip)
			if bindGen[instance] ~= gen or not instance.Parent then
				return
			end
		end
		local ok, err = pcall(Attach.attach, instance, optionsFromAttributes(instance))
		if not ok then
			warn(("[AudioLab] %s: %s"):format(instance:GetFullName(), tostring(err)))
		elseif instance:GetAttribute("AudioLabSynced") then
			Attach.startSync(Attach.get(instance))
		end
		if not attrConns[instance] then
			local list = {}
			for _, a in ipairs(ATTRS) do
				table.insert(list, instance:GetAttributeChangedSignal(a):Connect(function()
					local h = Attach.get(instance)
					if a == "AudioLabVolume" and h and not h.destroyed then
						h:setVolume(instance:GetAttribute("AudioLabVolume") or (h.kind == "midi" and 0.5 or 1)) -- no restart
					else
						task.defer(bind, instance)
					end
				end))
			end
			table.insert(list, instance:GetAttributeChangedSignal("AudioLabSeq"):Connect(function()
				local h = Attach.get(instance)
				if h and h._reconcile then
					task.defer(h._reconcile)
				end
			end))
			attrConns[instance] = list
		end
	end
	local function unbind(instance)
		Attach.detach(instance)
		for _, c in ipairs(attrConns[instance] or {}) do
			c:Disconnect()
		end
		attrConns[instance] = nil
	end
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		task.spawn(bind, inst)
	end
	table.insert(conns, CollectionService:GetInstanceAddedSignal(tag):Connect(bind))
	table.insert(conns, CollectionService:GetInstanceRemovedSignal(tag):Connect(unbind))
	return {
		Disconnect = function()
			for _, c in ipairs(conns) do
				c:Disconnect()
			end
			for inst in pairs(attrConns) do
				unbind(inst)
			end
		end,
	}
end

return Attach
