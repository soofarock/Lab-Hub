-- Started by AudioLab:init() on the client, run once in its own thread.
return function(AudioLab)
-- Plays AudioLab audio for every instance tagged "AudioLab", configured by attributes:
--   AudioLabMidi = "MySong/music.mid", AudioLabSoundFont = "MySong/instruments.sf2",
--   AudioLabClip = "sfx/splash" (or AudioLabFile = "...wav"),
--   AudioLabLoop = true, AudioLabVolume = 0.5, AudioLabAutoPlay = true, AudioLabSpatial = true
-- Other scripts can reach the running audio with AudioLab.get(instance).
local AudioLab = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("AudioLab"))
-- Get ready in the background so the first song and every song switch start without a hitch: create the voice players
-- ahead of time (a few per frame) and decode each song's MIDI and baked SoundFont once (one file per frame).
-- Make sure the audio files are loading (ReplicatedFirst.AudioLabPreload usually started them at join).
task.spawn(AudioLab.preload)
task.spawn(function()
	AudioLab.warmUp({ PerSine = 160, PerBundle = 6, PerNoise = 2, PerFrame = 4 }) -- one sine file: 160 players of it
	local ok, tracks = pcall(AudioLab.Library.list)
	if not ok then
		return
	end
	for _, t in ipairs(tracks) do
		if t.kind == "midi" then
			pcall(AudioLab.Assets.midi, t.midi)
			task.wait()
			if t.soundFont then
				pcall(AudioLab.Assets.bank, t.soundFont)
				task.wait()
			end
		end
	end
end)

AudioLab.bindTag("AudioLab")

end
