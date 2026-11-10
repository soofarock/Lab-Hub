-- Tracks: manager for everything that plays through AudioLab (MIDI + SoundFont songs, WAV/AIFF/MP3 clips).
-- Reached through the main module: AudioLab.play, AudioLab.getAllPlayingTracks, AudioLab.crossfade, ...
--
-- Tracks
--   local track = AudioLab.play(path, options)   -- starts it and returns a handle
--       path: a Library id ("MySong/music.mid", "clip:imports/MyClip"), a file in Data/Files
--             (.mid + SoundFont, .wav/.aif/.mp3), a clip in Data/Clips, or an entry of Library.list()
--       options: Loop (default false), Volume (1), FadeIn (seconds), StartTime, SoundFont (path of an .sf2),
--                Name, Group (any string), AutoDelete (default true: a track that reaches its end is deleted),
--                Parent, Paused (create it paused: call track:play() later)
--   AudioLab.getAllPlayingTracks() -> { track, ... }   -- playing right now (not paused, stopped, pending)
--   AudioLab.getAllTracks() -> { track, ... }          -- every track that has not been deleted
--   AudioLab.getTrack(id), AudioLab.getTracksInGroup(group)
--   AudioLab.pause(target?), resume(target?), stop(target?), delete(target?)   -- target: a track, an id, a list of
--       either, or nothing for every track. stop() keeps the track (play it again with track:play());
--       delete() stops it and frees its players. AudioLab.pauseAll / resumeAll / stopAll / deleteAll are the same.
--   AudioLab.fadeOut(target?, seconds, then?)           -- then: "stop" (default), "pause", "delete"
--   AudioLab.setLoop(target?, on)                       -- loop on / off for tracks that are already playing
--   AudioLab.setMasterVolume(v, fadeSeconds?), AudioLab.getMasterVolume()
--
--   track:play(startTime?, fadeIn?), :pause(), :resume(), :stop(), :delete() (also :destroy()),
--   track:seek(t), :getTime(), :getDuration(), :isPlaying(), :isPaused(), :getState(),
--   track:setLoop(on), :getLoop(), :setVolume(v, fadeSeconds?), :getVolume(), :fadeTo(v, seconds, onDone?),
--   track:fadeIn(seconds), :fadeOut(seconds, then?, onDone?), :getInfo(),
--   MIDI tracks also: :setMute(ch, on), :setSolo(ch, on), :channels(), :activity(ch)
--   track.Ended (fires when it reaches its end), track.id, track.name, track.kind ("midi" | "clip"), track.group
--   states: "pending" (waiting for a switch), "playing", "paused", "stopped", "ended", "deleted"
--
-- Transitions
--   AudioLab.crossfade(path, { Duration = 2, From = track?, Keep = false, ...play options })
--       the tracks that are playing (or From) fade out and are deleted (Keep: stopped) while the new one fades in
--   AudioLab.switch(path, { FadeOut = 0.5, FadeIn = 0.25, ... })    -- fade the current tracks out, then start the new one
--
-- Playlist (one at a time)
--   AudioLab.setPlaylist({ path, ... }, { Repeat = "all" | "one" | "off", Shuffle = false, Crossfade = 0,
--                                         StartIndex = 1, Play = true, Volume = 1 })
--   AudioLab.queue(path), AudioLab.next(opts?), AudioLab.previous(opts?), AudioLab.jump(indexOrPath, opts?)
--   AudioLab.setRepeat(mode), AudioLab.setShuffle(on), AudioLab.setCrossfade(seconds)
--   AudioLab.getPlaylist() -> { items, index, repeat, shuffle, crossfade, current }, AudioLab.getCurrentTrack()
--   AudioLab.stopPlaylist(fadeSeconds?), AudioLab.clearPlaylist()
--   With Crossfade > 0 the next song starts that many seconds before the current one ends; with 0 it follows it.
--
-- Events: AudioLab.TrackAdded(track), TrackStateChanged(track, new, old), TrackEnded(track), TrackRemoved(track),
--         PlaylistChanged(track)

local RunService = game:GetService("RunService")
local AudioLab = script:FindFirstAncestor("AudioLab")

local Tracks = {}
local Track = {}
Track.__index = Track

local registry = {} -- id -> track
local list = {} -- tracks, oldest first
local nextId = 0
local master = 1
local masterFade = nil
local connection = nil
local autoUpdate = true

local function newEvent()
	local e = Instance.new("BindableEvent")
	return e
end
local evAdded, evState, evEnded, evRemoved, evPlaylist = newEvent(), newEvent(), newEvent(), newEvent(), newEvent()
Tracks.TrackAdded = evAdded.Event
Tracks.TrackStateChanged = evState.Event
Tracks.TrackEnded = evEnded.Event
Tracks.TrackRemoved = evRemoved.Event
Tracks.PlaylistChanged = evPlaylist.Event

local playlist = {
	items = {}, -- { path, options }
	order = {}, -- play order: indices into items
	pos = 0, -- position in order of the current item
	current = nil,
	repeatMode = "all",
	shuffle = false,
	crossfade = 0,
	volume = 1,
}

-- fade curves: rising 0 -> 1 over p in 0..1. "power" keeps the summed power of a crossfade constant.
local function rise(kind, p)
	p = math.clamp(p, 0, 1)
	if kind == "linear" then
		return p
	elseif kind == "power" then
		return math.sin(p * math.pi / 2)
	end
	return p * p * (3 - 2 * p)
end

local function fadeValue(f, p)
	if f.to >= f.from then
		return f.from + (f.to - f.from) * rise(f.curve, p)
	end
	return f.to + (f.from - f.to) * rise(f.curve, 1 - p)
end

-- Opening ----------------------------------------------------------------------------------

local function resolve(path, options)
	local Library = require(AudioLab.Tools.Library)
	if type(path) == "table" then
		return path
	end
	for _, t in ipairs(Library.list()) do
		if t.id == path or t.title == path or t.midi == path or t.clip == path or t.id == "clip:" .. path then
			local entry = table.clone(t)
			if options.SoundFont and entry.kind == "midi" then
				entry.soundFont = options.SoundFont
			end
			return entry
		end
	end
	local ext = string.lower(string.match(path, "%.(%w+)$") or "")
	if ext == "mid" or ext == "midi" then
		local soundFont = options.SoundFont
		if not soundFont then
			local folder = string.match(path, "^(.*)/[^/]+$") or ""
			for _, f in ipairs(require(AudioLab.Tools.Importer).list()) do
				if string.lower(string.match(f, "%.(%w+)$") or "") == "sf2" and (string.match(f, "^(.*)/[^/]+$") or "") == folder then
					soundFont = f
					break
				end
			end
		end
		return { id = path, kind = "midi", midi = path, soundFont = soundFont, title = path }
	elseif ext == "" or ext == "wav" or ext == "aif" or ext == "aiff" or ext == "aifc" or ext == "mp3" or ext == "mp2" or ext == "ac3" or ext == "flac" or ext == "ogg" or ext == "oga" then
		return { id = path, kind = "clip", clip = path, title = path }
	end
	error("AudioLab: unsupported track type ." .. ext .. " (" .. tostring(path) .. ")")
end

-- returns a Library controller and the resolved entry (replaceable for tests: Tracks._open)
function Tracks._open(path, options, gain)
	local entry = resolve(path, options)
	local controller = require(AudioLab.Tools.Library).open(entry, {
		Parent = options.Parent, Volume = gain, Loop = options.Loop == true,
	})
	return controller, entry
end

-- Update loop --------------------------------------------------------------------------------

local function ensureConnection()
	if autoUpdate and not connection then
		connection = RunService.Heartbeat:Connect(function(dt)
			Tracks.update(dt)
		end)
	end
end

function Tracks.setAutoUpdate(on)
	autoUpdate = on
	if not on and connection then
		connection:Disconnect()
		connection = nil
	elseif on and (#list > 0 or masterFade or playlist.current) then
		ensureConnection()
	end
end

function Track:_gain()
	return self.volume * self.fadeGain * master
end

function Track:_applyVolume(force)
	local g = self:_gain()
	if force or g ~= self._applied then
		self._applied = g
		self.controller:setVolume(g)
	end
end

function Track:_setState(state)
	local old = self.state
	if old == state then
		return
	end
	self.state = state
	evState:Fire(self, state, old)
end

function Track:_finishFade(f)
	self.fadeGain = f.to
	self._fade = nil
	self:_applyVolume()
	if f.to == 0 then
		self.fadingOut = false
		local action = f.thenDo
		if action == "delete" then
			self:delete()
		elseif action == "stop" then
			self:stop()
		elseif action == "pause" then
			self:pause()
		end
	end
	if f.onDone then
		f.onDone(self)
	end
end

-- Tracks ---------------------------------------------------------------------------------------

function Tracks.create(path, options)
	options = options or {}
	nextId += 1
	local track = setmetatable({
		id = nextId,
		path = path,
		volume = options.Volume or options.MasterGain or 1,
		fadeGain = 1,
		loop = options.Loop == true,
		autoDelete = options.AutoDelete ~= false,
		group = options.Group,
		state = "stopped",
		fadingOut = false,
	}, Track)
	track.fadeGain = (options.FadeIn and options.FadeIn > 0) and 0 or 1
	local controller, entry = Tracks._open(path, options, track:_gain())
	track.controller = controller
	track.entry = entry
	track.kind = entry.kind
	track.name = options.Name or entry.title or tostring(path)
	track._applied = track:_gain()
	track._endedEvent = newEvent()
	track.Ended = track._endedEvent.Event
	track._endConn = controller.Ended:Connect(function()
		Tracks._onEnded(track)
	end)
	registry[track.id] = track
	table.insert(list, track)
	evAdded:Fire(track)
	ensureConnection()
	return track
end

function Tracks.play(path, options)
	options = options or {}
	local track = Tracks.create(path, options)
	if options.Paused then
		return track
	end
	track:play(options.StartTime, options.FadeIn)
	return track
end

function Track:play(startTime, fadeIn)
	assert(self.state ~= "deleted", "AudioLab: the track was deleted")
	if fadeIn and fadeIn > 0 then
		self.fadeGain = 0
		self._fade = { from = 0, to = 1, elapsed = 0, dur = fadeIn, curve = "power" }
		self.fadingOut = false
	elseif not self._fade then
		self.fadeGain = 1
		self.fadingOut = false
	end
	self._advanced = nil
	self:_applyVolume(true)
	self.controller:setLoop(self.loop)
	self.controller:play(startTime or 0)
	self:_setState("playing")
	ensureConnection()
end

function Track:pause()
	if self.state == "playing" then
		self.controller:pause()
		self:_setState("paused")
	end
end

function Track:resume()
	if self.state == "paused" then
		self.controller:resume()
		self:_setState("playing")
		if self.fadeGain == 0 and not self._fade then
			self:fadeIn(0.25)
		end
	elseif self.state == "stopped" or self.state == "ended" then
		self:play(0)
	end
end

function Track:stop()
	if self.state == "deleted" or self.state == "stopped" then
		return
	end
	self._fade, self._vfade = nil, nil
	self.fadingOut = false
	self.fadeGain = 1
	self.controller:stop()
	self:_applyVolume()
	self:_setState("stopped")
end

function Track:delete()
	if self.state == "deleted" then
		return
	end
	self._fade, self._vfade = nil, nil
	if self._endConn then
		self._endConn:Disconnect()
		self._endConn = nil
	end
	pcall(function()
		self.controller:destroy(true) -- players are freed a few milliseconds per frame (no hitch)
	end)
	registry[self.id] = nil
	local i = table.find(list, self)
	if i then
		table.remove(list, i)
	end
	self:_setState("deleted")
	evRemoved:Fire(self)
	self._endedEvent:Destroy()
end
Track.destroy = Track.delete

function Track:seek(t)
	self.controller:seek(t)
end

function Track:getTime()
	return self.controller:getTime()
end

function Track:getDuration()
	return self.controller:getDuration()
end

function Track:getState()
	return self.state
end

function Track:isPlaying()
	return self.state == "playing"
end

function Track:isPaused()
	return self.state == "paused"
end

function Track:setLoop(on)
	self.loop = on == true
	self.controller:setLoop(self.loop)
end

function Track:getLoop()
	return self.loop
end

function Track:setVolume(v, fadeSeconds)
	if fadeSeconds and fadeSeconds > 0 then
		self._vfade = { from = self.volume, to = v, elapsed = 0, dur = fadeSeconds, curve = "smooth" }
	else
		self._vfade = nil
		self.volume = v
		self:_applyVolume()
	end
end

function Track:getVolume()
	return self.volume
end

function Track:fadeTo(v, seconds, onDone)
	self:setVolume(v, seconds)
	if onDone then
		if self._vfade then
			self._vfade.onDone = onDone
		else
			onDone(self)
		end
	end
end

function Track:fadeIn(seconds, onDone)
	self.fadingOut = false
	if seconds <= 0 then
		self._fade = nil
		self.fadeGain = 1
		self:_applyVolume()
		if onDone then
			onDone(self)
		end
		return
	end
	self._fade = { from = self.fadeGain, to = 1, elapsed = 0, dur = seconds, curve = "power", onDone = onDone }
end

-- fade to silence, then "stop" (default), "pause", "delete" or "none"
function Track:fadeOut(seconds, thenDo, onDone)
	thenDo = thenDo or "stop"
	self.fadingOut = true
	local f = { from = self.fadeGain, to = 0, elapsed = 0, dur = seconds, curve = "power", thenDo = thenDo, onDone = onDone }
	if seconds <= 0 then
		self:_finishFade(f)
		return
	end
	self._fade = f
end

function Track:getInfo()
	return {
		id = self.id, name = self.name, kind = self.kind, state = self.state, group = self.group,
		time = self.state ~= "deleted" and self:getTime() or 0,
		duration = self.state ~= "deleted" and self:getDuration() or 0,
		volume = self.volume, gain = self:_gain(), loop = self.loop,
	}
end

function Track:setMute(ch, on)
	self.controller:setMute(ch, on)
end

function Track:setSolo(ch, on)
	self.controller:setSolo(ch, on)
end

function Track:channels()
	return self.controller:channels()
end

function Track:activity(ch)
	return self.controller:activity(ch)
end

-- a track reached its end by itself
function Tracks._onEnded(track)
	if track.state == "deleted" then
		return
	end
	track:_setState("ended")
	evEnded:Fire(track)
	track._endedEvent:Fire()
	local wasCurrent = playlist.current == track
	local advanced = track._advanced
	if track.autoDelete then
		track:delete()
	end
	if wasCurrent then
		playlist.current = nil
		if not advanced and Tracks.hasNext() then
			Tracks.next({ Crossfade = 0 })
		end
	end
end

-- Queries and bulk control -----------------------------------------------------------------

local function targets(target)
	local out = {}
	if target == nil then
		for _, t in ipairs(list) do
			table.insert(out, t)
		end
	elseif type(target) == "table" and target.controller then
		table.insert(out, target)
	elseif type(target) == "table" then
		for _, x in ipairs(target) do
			for _, t in ipairs(targets(x)) do
				table.insert(out, t)
			end
		end
	else
		local t = registry[target]
		if t then
			table.insert(out, t)
		end
	end
	return out
end

function Tracks.getAllTracks()
	return targets(nil)
end

function Tracks.getAllPlayingTracks()
	local out = {}
	for _, t in ipairs(list) do
		if t.state == "playing" then
			table.insert(out, t)
		end
	end
	return out
end

function Tracks.getTrack(id)
	return registry[id]
end

function Tracks.getTracksInGroup(group)
	local out = {}
	for _, t in ipairs(list) do
		if t.group == group then
			table.insert(out, t)
		end
	end
	return out
end

function Tracks.pause(target)
	for _, t in ipairs(targets(target)) do
		t:pause()
	end
end

function Tracks.resume(target)
	for _, t in ipairs(targets(target)) do
		t:resume()
	end
end

function Tracks.stop(target)
	for _, t in ipairs(targets(target)) do
		t:stop()
	end
end

function Tracks.delete(target)
	for _, t in ipairs(targets(target)) do
		t:delete()
	end
end

function Tracks.fadeOut(target, seconds, thenDo)
	for _, t in ipairs(targets(target)) do
		t:fadeOut(seconds, thenDo)
	end
end

function Tracks.setLoop(target, on)
	if type(target) == "boolean" then
		target, on = nil, target
	end
	for _, t in ipairs(targets(target)) do
		t:setLoop(on)
	end
end

Tracks.pauseAll, Tracks.resumeAll, Tracks.stopAll, Tracks.deleteAll = Tracks.pause, Tracks.resume, Tracks.stop, Tracks.delete

function Tracks.setMasterVolume(v, fadeSeconds)
	if fadeSeconds and fadeSeconds > 0 then
		masterFade = { from = master, to = v, elapsed = 0, dur = fadeSeconds, curve = "smooth" }
		ensureConnection()
	else
		masterFade = nil
		master = v
		for _, t in ipairs(list) do
			t:_applyVolume()
		end
	end
end

function Tracks.getMasterVolume()
	return master
end

-- Transitions ------------------------------------------------------------------------------------

local function fadable(options)
	local out = {}
	local from = options.From and targets(options.From) or Tracks.getAllPlayingTracks()
	for _, t in ipairs(from) do
		if not t.fadingOut then
			table.insert(out, t)
		end
	end
	return out
end

function Tracks.crossfade(path, options)
	options = options or {}
	local d = options.Duration or 2
	local from = fadable(options)
	local new = Tracks.create(path, options) -- opened first: loading time doesn't eat into the fade
	for _, t in ipairs(from) do
		t:fadeOut(d, options.Keep and "stop" or "delete")
	end
	if options.Paused then
		return new
	end
	new:play(options.StartTime, d)
	return new
end

function Tracks.switch(path, options)
	options = options or {}
	local fadeOut = options.FadeOut or 0.5
	local from = fadable(options)
	local new = Tracks.create(path, options)
	new:_setState("pending")
	local remaining = #from
	local function start()
		if new.state == "pending" then
			new:play(options.StartTime, options.FadeIn or 0.25)
		end
	end
	if remaining == 0 then
		start()
	elseif fadeOut <= 0 then
		for _, t in ipairs(from) do
			if options.Keep then
				t:stop()
			else
				t:delete()
			end
		end
		start()
	else
		for _, t in ipairs(from) do
			t:fadeOut(fadeOut, options.Keep and "stop" or "delete", function()
				remaining -= 1
				if remaining == 0 then
					start()
				end
			end)
		end
	end
	return new
end

-- Playlist -----------------------------------------------------------------------------------------

local function normalize(item)
	if type(item) == "table" and item.path then
		return { path = item.path, options = item }
	end
	return { path = item, options = {} }
end

local function rebuildOrder(firstIndex)
	local n = #playlist.items
	local order = table.create(n)
	for i = 1, n do
		order[i] = i
	end
	if playlist.shuffle then
		for i = n, 2, -1 do
			local j = math.random(i)
			order[i], order[j] = order[j], order[i]
		end
		if firstIndex then
			local at = table.find(order, firstIndex)
			if at and at ~= 1 then
				order[at], order[1] = order[1], order[at]
			end
		end
	end
	playlist.order = order
	playlist.pos = firstIndex and table.find(order, firstIndex) or 0
end

local function currentItemIndex()
	return playlist.order[playlist.pos]
end

local function startItem(pos, transition)
	playlist.pos = pos
	local item = playlist.items[playlist.order[pos]]
	local o = table.clone(item.options)
	o.Loop = playlist.repeatMode == "one"
	o.Volume = o.Volume or playlist.volume
	o.Group = "playlist"
	local old = playlist.current
	local new
	if transition > 0 and old and old.state == "playing" then
		o.Duration = transition
		o.From = old
		new = Tracks.crossfade(item.path, o)
	else
		if old then
			old:delete()
		end
		new = Tracks.play(item.path, o)
	end
	playlist.current = new
	evPlaylist:Fire(new)
	return new
end

function Tracks.hasNext()
	local n = #playlist.order
	if n == 0 then
		return false
	end
	return playlist.repeatMode ~= "off" or playlist.pos < n
end

function Tracks.setPlaylist(items, options)
	options = options or {}
	playlist.items = {}
	for _, it in ipairs(items) do
		table.insert(playlist.items, normalize(it))
	end
	playlist.repeatMode = options.Repeat or playlist.repeatMode
	if options.Shuffle ~= nil then
		playlist.shuffle = options.Shuffle
	end
	playlist.crossfade = options.Crossfade or playlist.crossfade
	playlist.volume = options.Volume or playlist.volume
	local first = math.clamp(options.StartIndex or 1, 1, math.max(#playlist.items, 1))
	rebuildOrder(#playlist.items > 0 and first or nil)
	if options.Play ~= false and #playlist.items > 0 then
		return startItem(playlist.pos, options.Transition or 0)
	end
	evPlaylist:Fire(playlist.current)
	return nil
end

function Tracks.queue(path, atFront)
	local item = normalize(path)
	if atFront then
		table.insert(playlist.items, 1, item)
		for i, v in ipairs(playlist.order) do
			playlist.order[i] = v + 1
		end
		table.insert(playlist.order, math.max(playlist.pos, 0) + 1, 1)
	else
		table.insert(playlist.items, item)
		table.insert(playlist.order, #playlist.items)
	end
	evPlaylist:Fire(playlist.current)
end

function Tracks.next(options)
	options = options or {}
	local n = #playlist.order
	if n == 0 then
		return nil
	end
	local pos = playlist.pos + 1
	if pos > n then
		if playlist.repeatMode == "off" then
			Tracks.stopPlaylist(options.Crossfade or playlist.crossfade)
			return nil
		end
		if playlist.shuffle then
			rebuildOrder(nil)
		end
		pos = 1
	end
	return startItem(pos, options.Crossfade or playlist.crossfade)
end

function Tracks.previous(options)
	options = options or {}
	local n = #playlist.order
	if n == 0 then
		return nil
	end
	local cur = playlist.current
	if cur and cur.state ~= "deleted" and cur:getTime() > 3 then
		cur:seek(0)
		return cur
	end
	local pos = playlist.pos - 1
	if pos < 1 then
		pos = (playlist.repeatMode == "off") and 1 or n
	end
	return startItem(pos, options.Crossfade or playlist.crossfade)
end

function Tracks.jump(target, options)
	options = options or {}
	local index = target
	if type(target) == "string" then
		index = nil
		for i, it in ipairs(playlist.items) do
			if it.path == target then
				index = i
				break
			end
		end
	end
	local pos = index and table.find(playlist.order, index)
	if not pos then
		return nil
	end
	return startItem(pos, options.Crossfade or playlist.crossfade)
end

function Tracks.setRepeat(mode)
	assert(mode == "off" or mode == "all" or mode == "one", 'AudioLab.setRepeat: "off", "all" or "one"')
	playlist.repeatMode = mode
	local cur = playlist.current
	if cur and cur.state ~= "deleted" then
		cur:setLoop(mode == "one")
	end
end

function Tracks.setShuffle(on)
	if playlist.shuffle == (on == true) then
		return
	end
	playlist.shuffle = on == true
	rebuildOrder(currentItemIndex())
end

function Tracks.setCrossfade(seconds)
	playlist.crossfade = math.max(seconds, 0)
end

function Tracks.getCurrentTrack()
	local cur = playlist.current
	if cur and cur.state ~= "deleted" then
		return cur
	end
	return nil
end

function Tracks.getPlaylist()
	local paths = {}
	for i, it in ipairs(playlist.items) do
		paths[i] = it.path
	end
	return {
		items = paths, index = currentItemIndex(), position = playlist.pos, order = table.clone(playlist.order),
		["repeat"] = playlist.repeatMode, shuffle = playlist.shuffle, crossfade = playlist.crossfade,
		current = Tracks.getCurrentTrack(),
	}
end

function Tracks.stopPlaylist(fadeSeconds)
	local cur = playlist.current
	playlist.current = nil
	playlist.pos = 0
	if cur and cur.state ~= "deleted" then
		if fadeSeconds and fadeSeconds > 0 then
			cur._advanced = true
			cur:fadeOut(fadeSeconds, "delete")
		else
			cur:delete()
		end
	end
	evPlaylist:Fire(nil)
end

function Tracks.clearPlaylist()
	Tracks.stopPlaylist(0)
	playlist.items, playlist.order = {}, {}
end

-- Frame step: fades, master volume, playlist advance. Runs on Heartbeat; tests call it with Tracks.setAutoUpdate(false).
function Tracks.update(dt)
	if masterFade then
		local f = masterFade
		f.elapsed += dt
		local p = math.min(f.elapsed / f.dur, 1)
		master = fadeValue(f, p)
		for _, t in ipairs(list) do
			t:_applyVolume()
		end
		if p >= 1 then
			masterFade = nil
		end
	end
	for _, t in ipairs(table.clone(list)) do
		local vf = t._vfade
		if vf then
			vf.elapsed += dt
			local p = math.min(vf.elapsed / vf.dur, 1)
			t.volume = fadeValue(vf, p)
			t:_applyVolume()
			if p >= 1 then
				t._vfade = nil
				if vf.onDone then
					vf.onDone(t)
				end
			end
		end
		local f = t._fade
		if f and t.state ~= "deleted" then
			-- fades run on the track's own clock while it plays; a paused track holds its level
			if t.state ~= "paused" then
				f.elapsed += dt
			end
			local p = math.min(f.elapsed / f.dur, 1)
			t.fadeGain = fadeValue(f, p)
			t:_applyVolume()
			if p >= 1 then
				t:_finishFade(f)
			end
		end
	end
	-- the next song starts Crossfade seconds before the current one ends
	local cur = playlist.current
	if cur and cur.state == "playing" and not cur.loop and not cur._advanced and playlist.crossfade > 0 and Tracks.hasNext() then
		local remaining = cur:getDuration() - cur:getTime()
		if remaining > 0 and remaining <= playlist.crossfade then
			cur._advanced = true
			Tracks.next({ Crossfade = math.max(remaining, 0.05) })
		end
	end
	if #list == 0 and not masterFade and not playlist.current and connection then
		connection:Disconnect()
		connection = nil
	end
end

Tracks.Track = Track

return Tracks
