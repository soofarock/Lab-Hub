-- AudioLab: binary audio formats, FFT, and a parametric codec that rebuilds
-- sounds from a fixed bank of uploaded waveform loops.
-- (part of LabHub: keep it inside the LabHub module in ReplicatedStorage)
--   Util/     ByteReader, ByteWriter, Base64
--   Formats/  Iff (RIFF/IFF chunks), Wav, Aiff, Mp3 (MPEG Layer III decoder), Midi, Sf2, etc.
--   DSP/      Signal (PCM container), FFT (FFT, windows, STFT)
--   Codec/    WaveBank (waveform + noise asset spec), Analyzer, Format, Encoder, Partials (clip codec v3)
--   Synth/    Renderer (renders a clip to PCM / WAV), OscillatorPool, Player,
--             Instruments (GM presets, drum kit, SF2 analysis), MidiSynth (MIDI player)
--   Tools/    Importer (file import into Data/), Assets (shared decode-once cache),
--             Baker (analyse SoundFonts in Studio into Data/Banks)
--   Synth/Attach  audio attached to instances (registry, tag binder, 3D AudioEmitter output)
--   Synth/Tracks  track manager: AudioLab.play returns a track; playing list, pause/resume/stop/delete, fades,
--                 crossfade/switch, playlist with next/previous/shuffle/repeat (see the block above `lib.play`)
--   Data/     Imported files and encoded clips (base64 ModuleScripts)
--
--   Runtime/  Server (sync + Studio import servers) and Client (tagged-instance player, music player UI) modules,
--             started by AudioLab:init() (LabHub.start calls it)
--
-- Usage: local AudioLab = require(ReplicatedStorage.LabHub.AudioLab); AudioLab.Wav.decode(bytes)

local cache = {}
local paths = {
	ByteReader = {"Util", "ByteReader"}, ByteWriter = {"Util", "ByteWriter"}, Base64 = {"Util", "Base64"},
	Iff = {"Formats", "Iff"}, Wav = {"Formats", "Wav"}, Aiff = {"Formats", "Aiff"},
	Midi = {"Formats", "Midi"}, Sf2 = {"Formats", "Sf2"}, Mp3 = {"Formats", "Mp3"},
	Signal = {"DSP", "Signal"}, FFT = {"DSP", "FFT"},
	WaveBank = {"Codec", "WaveBank"}, Analyzer = {"Codec", "Analyzer"},
	Format = {"Codec", "Format"}, Encoder = {"Codec", "Encoder"}, Partials = {"Codec", "Partials"},
	Renderer = {"Synth", "Renderer"}, OscillatorPool = {"Synth", "OscillatorPool"}, Player = {"Synth", "Player"},
	Instruments = {"Synth", "Instruments"}, MidiSynth = {"Synth", "MidiSynth"},
	Importer = {"Tools", "Importer"}, Tests = {"Tests", "RunAll"},
	Assets = {"Tools", "Assets"}, Library = {"Tools", "Library"}, Baker = {"Tools", "Baker"}, Attach = {"Synth", "Attach"},
	Tracks = {"Synth", "Tracks"},
}

local lib = {}

-- AudioLab:init() (or AudioLab.init()): starts the runtime of this side once: on the server every module in
-- Runtime/Server (sync server, Studio import server), on a client every module in Runtime/Client (tagged-instance
-- player, music player UI). Each module returns function(AudioLab) and runs in its own thread.
-- LabHub.start() calls it.
local started = {}
function lib.init()
	local RunService = game:GetService("RunService")
	local side = RunService:IsServer() and "Server" or "Client"
	if started[side] then
		return lib
	end
	started[side] = true
	local folder = script:FindFirstChild("Runtime") and script.Runtime:FindFirstChild(side)
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("ModuleScript") then
				local ok, fn = pcall(require, m)
				if not ok then
					warn(("[AudioLab] %s failed to load: %s"):format(m:GetFullName(), tostring(fn)))
				elseif type(fn) == "function" then
					task.spawn(fn, lib)
				end
			end
		end
	end
	return lib
end

-- AudioLab.attach(instance, options) / AudioLab.get(instance) / AudioLab.detach(instance)
-- AudioLab.bindTag(tag)  -- see Synth/Attach
function lib.attach(instance, options)
	return lib.Attach.attach(instance, options)
end
function lib.get(instance)
	return lib.Attach.get(instance)
end
function lib.detach(instance)
	return lib.Attach.detach(instance)
end
function lib.bindTag(tag)
	return lib.Attach.bindTag(tag)
end

-- Track manager (Synth/Tracks): everything that plays is a track you can list, pause, fade, crossfade or delete.
--   local track = AudioLab.play(path, { Loop = false, Volume = 1, FadeIn = 0, StartTime = 0, SoundFont = "..." })
--       path: a Library id, a .mid/.wav/.aif/.mp3 in Data/Files (a .mid uses the .sf2 next to it, or options.SoundFont)
--       or a clip in Data/Clips. Returns a track: :pause() :resume() :stop() :delete() :seek(t) :setLoop(on)
--       :setVolume(v, fade) :fadeOut(seconds, "stop" | "pause" | "delete") :getTime() :getDuration() :getInfo(); .Ended
--   AudioLab.getAllPlayingTracks(), getAllTracks(), getTrack(id), getTracksInGroup(group)
--   AudioLab.pause / resume / stop / delete (target?)   -- a track, an id, a list, or nothing = all tracks
--   AudioLab.pauseAll / resumeAll / stopAll / deleteAll, AudioLab.fadeOut(target?, seconds, then?)
--   AudioLab.setLoop(target?, on), AudioLab.setMasterVolume(v, fade?), AudioLab.getMasterVolume()
--   AudioLab.crossfade(path, { Duration = 2 })   -- current tracks fade out while the new one fades in
--   AudioLab.switch(path, { FadeOut = 0.5 })     -- current tracks fade out, then the new one starts
--   AudioLab.setPlaylist({ path, ... }, { Repeat = "all" | "one" | "off", Shuffle, Crossfade, StartIndex })
--   AudioLab.next() / previous() / jump(i) / queue(path) / setRepeat(mode) / setShuffle(on) / setCrossfade(s)
--   AudioLab.getPlaylist(), getCurrentTrack(), stopPlaylist(fade?), clearPlaylist()
--   Events: AudioLab.TrackAdded, TrackStateChanged, TrackEnded, TrackRemoved, PlaylistChanged
for _, name in ipairs({
	"play", "create", "crossfade", "switch",
	"getAllPlayingTracks", "getAllTracks", "getTrack", "getTracksInGroup",
	"pause", "resume", "stop", "delete", "pauseAll", "resumeAll", "stopAll", "deleteAll", "fadeOut", "setLoop",
	"setMasterVolume", "getMasterVolume",
	"setPlaylist", "queue", "next", "previous", "jump", "setRepeat", "setShuffle", "setCrossfade",
	"getPlaylist", "getCurrentTrack", "stopPlaylist", "clearPlaylist",
}) do
	lib[name] = function(...)
		return lib.Tracks[name](...)
	end
end
-- AudioLab.warmUp(options?) -- yields: creates the voice players ahead of time, a few per frame, so the first song (and
-- every song switch) doesn't hitch. Call it once at start from a script that can wait: task.spawn(AudioLab.warmUp)
function lib.warmUp(options)
	return lib.OscillatorPool.warmUp(options)
end

-- AudioLab.preload(timeout?) -- starts loading every audio file of the active manifest (once per session; yields up to
-- `timeout` seconds if given) and returns true when all are ready. AudioLab.preloadStatus() -> { State, Total, Ready, ... }
function lib.preload(timeout)
	return lib.OscillatorPool.preload(timeout)
end

function lib.preloadStatus()
	return lib.OscillatorPool.preloadStatus()
end
local EVENTS = { TrackAdded = true, TrackStateChanged = true, TrackEnded = true, TrackRemoved = true, PlaylistChanged = true }

return setmetatable(lib, {
	__index = function(_, name)
		if EVENTS[name] then return lib.Tracks[name] end
		local cached = cache[name]
		if cached ~= nil then return cached end
		local path = paths[name]
		assert(path, "AudioLab has no module named " .. tostring(name))
		local mod = require(script:WaitForChild(path[1]):WaitForChild(path[2]))
		cache[name] = mod
		return mod
	end,
})
