-- Track library for players and menus.
--
--   Library.list() -> { { id, title, folder, kind = "midi" | "clip", midi?, soundFont?, clip? } }
--       MIDI files are paired with the SoundFont (.sf2, baked bank preferred) in the same folder;
--       WAV/AIFF/MP3 files and stored clips are "clip" tracks. Test folders are skipped.
--   local c = Library.open(track, { Parent, Volume, Loop })   -- one controller for both kinds:
--       c:play(), c:pause(), c:resume(), c:stop(), c:seek(t), c:getTime(), c:getDuration(),
--       c:isPlaying(), c:setVolume(v), c:setLoop(bool), c.Ended, c:destroy()
--       MIDI only: c.channels() -> { [ch] = { notes, program, name, pan } }, c:setMute(ch, on),
--       c:setSolo(ch, on), c:activity(ch) -> 0..1, c.loopStart / c.loopEnd
--   While any controller plays (on a client), SoundService attribute AudioLabLocalMusic = true: synced world audio (TVs,
--   speakers) steps aside on this client so the player's own music gets the players (see Synth.Attach).

local AudioLab = script:FindFirstAncestor("AudioLab")
local Importer = require(AudioLab.Tools.Importer)
local Assets = require(AudioLab.Tools.Assets)
local MidiSynth = require(AudioLab.Synth.MidiSynth)
local Player = require(AudioLab.Synth.Player)

local Library = {}
local SKIP = { tests = true, selftest = true }

local function split(path)
	local folder, name = string.match(path, "^(.*)/([^/]+)$")
	return folder or "", name or path
end

function Library.list()
	local tracks = {}
	local files = Importer.list()
	local soundFonts = {}
	for _, path in ipairs(files) do
		local folder = split(path)
		if string.lower(string.match(path, "%.(%w+)$") or "") == "sf2" then
			soundFonts[folder] = soundFonts[folder] or path
		end
	end
	local clipsSeen = {}
	for _, path in ipairs(files) do
		local folder, name = split(path)
		local top = string.match(path, "^([^/]+)/") or ""
		if not SKIP[top] then
			local ext = string.lower(string.match(name, "%.(%w+)$") or "")
			local base = string.gsub(name, "%.%w+$", "")
			if ext == "mid" or ext == "midi" then
				table.insert(tracks, {
					id = path, kind = "midi", midi = path, soundFont = soundFonts[folder], folder = folder,
					title = (folder ~= "" and (folder .. " - ") or "") .. base,
				})
			elseif ext == "wav" or ext == "aif" or ext == "aiff" or ext == "aifc" or ext == "mp3" or ext == "flac" or ext == "ogg" or ext == "oga" then
				local clipPath = string.gsub(path, "%.%w+$", "")
				clipsSeen[clipPath] = true
				table.insert(tracks, { id = path, kind = "clip", clip = path, folder = folder, title = (folder ~= "" and (folder .. " - ") or "") .. base })
			end
		end
	end
	for _, path in ipairs(Importer.listClips()) do
		local top = string.match(path, "^([^/]+)/") or ""
		if not clipsSeen[path] and not SKIP[top] then
			local folder, name = split(path)
			table.insert(tracks, { id = "clip:" .. path, kind = "clip", clip = path, folder = folder, title = (folder ~= "" and (folder .. " - ") or "") .. name })
		end
	end
	table.sort(tracks, function(a, b)
		if a.kind ~= b.kind then
			return a.kind == "midi"
		end
		return a.title < b.title
	end)
	return tracks
end

local Controller = {}
Controller.__index = Controller

-- which controllers are playing: the player's own music, so world audio steps aside (Synth.Attach)
local playingSet = setmetatable({}, { __mode = "k" })
local function markPlaying(c, on)
	playingSet[c] = on and true or nil
	if not game:GetService("RunService"):IsClient() then
		return
	end
	local any = next(playingSet) ~= nil
	local SoundService = game:GetService("SoundService")
	if (SoundService:GetAttribute("AudioLabLocalMusic") == true) ~= any then
		SoundService:SetAttribute("AudioLabLocalMusic", any or nil)
	end
end

-- every controller playing on this client paused at once (watching a video: the player's own music steps aside) ->
-- the list paused, for Library.resumeAll(list), which resumes only those still paused (not ones stopped or restarted
-- by hand in between)
function Library.pauseAll()
	local paused = {}
	for c in pairs(playingSet) do
		if pcall(c.pause, c) then
			table.insert(paused, c)
		end
	end
	return paused
end
function Library.resumeAll(list)
	for _, c in ipairs(list or {}) do
		local ok, isPaused = pcall(c.isPaused, c)
		if ok and isPaused then
			pcall(c.resume, c)
		end
	end
end

function Library.open(track, options)
	options = options or {}
	local c = setmetatable({ track = track, loop = options.Loop == true }, Controller)
	if track.kind == "midi" then
		local midi = Assets.midi(track.midi)
		local inst = track.soundFont and Assets.instruments(track.soundFont) or {}
		c.midi = midi
		c.engine = MidiSynth.new({
			Parent = options.Parent, MasterGain = options.Volume or 1, Bank = inst.Bank, SoundFont = inst.SoundFont,
			Name = "AudioLabMusic_" .. tostring(track.title),
		})
		c.loopStart, c.loopEnd = MidiSynth.findLoop(midi)
		-- per channel summary: note count, first program, track name
		local info = {}
		for _, n in ipairs(midi.notes) do
			local ch = info[n.channel] or { notes = 0, program = n.program }
			ch.notes += 1
			info[n.channel] = ch
		end
		for _, tr in ipairs(midi.tracks) do
			for _, ev in ipairs(tr.events) do
				if ev.channel and info[ev.channel] then
					info[ev.channel].name = info[ev.channel].name or tr.name
					break
				end
			end
		end
		c._channels = info
	else
		local clip = Assets.clip(track.clip)
		c.engine = Player.new(clip, { Parent = options.Parent, MasterGain = options.Volume or 1, Name = "AudioLabMusic_" .. tostring(track.title) })
	end
	c.Ended = c.engine.Ended
	c.Ended:Connect(function()
		if not c.engine.playing then
			markPlaying(c, false)
		end
	end)
	return c
end

function Controller:play(startTime)
	markPlaying(self, true)
	if self.midi then
		self.engine:play(self.midi, { Loop = self.loop, StartTime = startTime })
	else
		self.engine:play({ Loop = self.loop, StartTime = startTime })
	end
end

function Controller:pause()
	self.engine:pause()
	markPlaying(self, false)
end

function Controller:resume()
	markPlaying(self, true)
	if self.engine.paused then
		self.engine:resume()
	elseif not self.engine.playing then
		self:play(self:getTime())
	end
end

function Controller:stop()
	markPlaying(self, false)
	self.engine:stop()
	self.engine.paused = false
	if self.engine.seek then
		self.engine:seek(0)
	end
end

function Controller:seek(t)
	local wasPlaying = self.engine.playing
	if self.midi then
		self.engine:seek(t)
	else
		self.engine:seek(t)
	end
	if not wasPlaying and not self.engine.paused then
		-- stopped: remember the position for the next play
		self.engine.time = t
	end
end

function Controller:getTime()
	return self.engine:getTime()
end

function Controller:getDuration()
	return self.engine:getDuration()
end

function Controller:isPlaying()
	return self.engine.playing == true
end

function Controller:isPaused()
	return self.engine.paused == true
end

function Controller:setVolume(v)
	if self.midi then
		self.engine.masterGain = v
	else
		self.engine.pool:setMasterGain(v)
	end
end

function Controller:setLoop(on)
	self.loop = on
	self.engine.loop = on
end

function Controller:channels()
	return self._channels or {}
end

function Controller:setMute(ch, on)
	if self.midi then
		self.engine:setMute(ch, on)
	end
end

function Controller:setSolo(ch, on)
	if self.midi then
		self.engine:setSolo(ch, on)
	end
end

function Controller:activity(ch)
	return self.midi and (self.engine.activity[ch] or 0) or 0
end

function Controller:destroy(gradual)
	markPlaying(self, false)
	self.engine:destroy(gradual)
end

return Library
