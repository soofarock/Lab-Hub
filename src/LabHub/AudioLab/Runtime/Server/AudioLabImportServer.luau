-- Started by AudioLab:init() on the server, run once in its own thread.
return function(AudioLab)
-- AudioLab import server. STUDIO ONLY: in a live game this script does nothing and the remotes
-- are never created.
--
-- Remotes (created here, in ReplicatedStorage.AudioLabRemotes):
--   ImportRequest (client -> server): { kind = "music", name, midiUrl, soundFontUrl? }
--                                     { kind = "sfx",   name, url }   -- WAV, AIFF, MP3, AAC or M4A
--   ImportStatus  (server -> client): { id, state = "progress" | "done" | "error", message, track? }
--
-- Downloads with HttpService (Game Settings > Security > Allow HTTP Requests must be on), checks each
-- file's type from its header bytes, stores it under Data/Files/imports/..., bakes SoundFonts into
-- Data/Banks and encodes sound effects into Data/Clips. Play-mode changes are not saved to the place.

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AudioLab = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("AudioLab"))

local MAX_BYTES = 24 * 1024 * 1024
-- MP3s are decoded natively in Luau (AudioLab.Mp3, a minimp3 port); no helper is needed.
local MAX_SFX_SECONDS = 360
local MAX_PENDING_PER_PLAYER = 2

local remotes = Instance.new("Folder")
remotes.Name = "AudioLabRemotes"
local request = Instance.new("RemoteEvent")
request.Name = "ImportRequest"
request.Parent = remotes
local status = Instance.new("RemoteEvent")
status.Name = "ImportStatus"
status.Parent = remotes
remotes.Parent = ReplicatedStorage

local pending = {}

local function detect(bytes)
	if #bytes < 12 then
		return nil
	end
	local m4 = string.sub(bytes, 1, 4)
	local form = string.sub(bytes, 9, 12)
	if m4 == "RIFF" and form == "WAVE" then
		return "wav"
	elseif m4 == "RIFF" and form == "sfbk" then
		return "sf2"
	elseif m4 == "RIFF" and form == "RMID" then
		return "mid"
	elseif m4 == "MThd" then
		return "mid"
	elseif m4 == "FORM" and (form == "AIFF" or form == "AIFC") then
		return "aiff"
	elseif string.sub(bytes, 5, 8) == "ftyp" then
		return "m4a"
	elseif string.sub(bytes, 1, 3) == "ID3" then
		return "mp3"
	else
		local b1, b2 = string.byte(bytes, 1, 2)
		if b1 == 0xFF and b2 and bit32.band(b2, 0xF6) == 0xF0 then
			return "aac" -- ADTS
		elseif b1 == 0xFF and b2 and bit32.band(b2, 0xE0) == 0xE0 then
			return "mp3"
		end
	end
	return nil
end

local function cleanName(s, fallback)
	s = tostring(s or "")
	s = string.gsub(s, "[^%w%-_ ]", "")
	s = string.gsub(s, "^%s+", "")
	s = string.gsub(s, "%s+$", "")
	if s == "" then
		s = fallback
	end
	return string.sub(s, 1, 40)
end

local function validUrl(u)
	return type(u) == "string" and #u < 2048 and (string.match(u, "^https?://[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]+$") ~= nil)
end

local function fetch(url)
	if not HttpService.HttpEnabled then
		error("HTTP requests are off: Game Settings > Security > Allow HTTP Requests", 0)
	end
	local ok, response = pcall(HttpService.RequestAsync, HttpService, { Url = url, Method = "GET" })
	if not ok then
		error("download failed: " .. tostring(response), 0)
	end
	if not response.Success then
		error(("download failed: HTTP %d %s"):format(response.StatusCode, response.StatusMessage or ""), 0)
	end
	local body = response.Body
	if #body == 0 then
		error("download returned no data", 0)
	end
	if #body > MAX_BYTES then
		error(("file too large (%.1f MB, limit %d MB)"):format(#body / 1048576, MAX_BYTES // 1048576), 0)
	end
	return body
end

-- the FrameLab data manager lists AudioLab imports too (FrameLab.Server.onAudioImported, when FrameLab is in the place)
local function record(info)
	pcall(function()
		local FL = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("FrameLab")
		if FL then
			local FrameLab = require(FL)
			if FrameLab.Server and FrameLab.Server.onAudioImported then
				FrameLab.Server.onAudioImported(info)
			end
		end
	end)
end

local function send(player, id, state, message, track)
	status:FireClient(player, { id = id, state = state, message = message, track = track })
end

local function importSfx(player, id, data)
	local name = cleanName(data.name, "sound")
	send(player, id, "progress", "Downloading sound...")
	local bytes = fetch(data.url)
	local kind = detect(bytes)
	if kind ~= "wav" and kind ~= "aiff" and kind ~= "mp3" and kind ~= "aac" and kind ~= "m4a" then
		error("not a WAV, AIFF, MP3, AAC or M4A file (checked its header bytes)", 0)
	end
	send(player, id, "progress", ("Downloaded %.0f KB, decoding %s%s..."):format(#bytes / 1024, string.upper(kind),
		kind == "mp3" and " (decoded natively)" or ""))
	local t0 = os.clock()
	local decoded = AudioLab.Encoder.decodeAudio(bytes, { MaxSeconds = MAX_SFX_SECONDS + 1 })
	local signal = decoded.signal
	local seconds = signal.length / signal.sampleRate
	if seconds > MAX_SFX_SECONDS then
		error(("sound is longer than %d minutes; sound effects are limited to that"):format(MAX_SFX_SECONDS // 60), 0)
	end
	send(player, id, "progress", ("Decoded %.1f s of audio (%d Hz, %d ch) in %.1f s. Encoding the clip..."):format(
		seconds, signal.sampleRate, signal.channels, os.clock() - t0))
	local clip, stats = AudioLab.Encoder.encode(decoded)
	-- keep only the encoded clip (a few hundred KB): the source file can be many megabytes, and
	-- everything stored here has to replicate to the client before the player can list it
	local trackId = "clip:imports/" .. name
	send(player, id, "progress", ("Encoded in %.1f s. Saving the clip..."):format(os.clock() - t0))
	AudioLab.Importer.storeClip("imports/" .. name, clip, { SourceRate = signal.sampleRate, Seconds = stats.seconds })
	record({ kind = "sound", name = name, path = "imports/" .. name, url = data.url, seconds = stats.seconds, bytes = stats.bytes,
		detail = ("%s, %d Hz, %d ch"):format(string.upper(kind), signal.sampleRate, signal.channels), player = player })
	return { kind = "clip", id = trackId, title = "imports - " .. name, seconds = stats.seconds }, ("Imported %s: %.1f s, %d Hz, %d channel(s), clip %.1f KB"):format(name, stats.seconds, signal.sampleRate, signal.channels, stats.bytes / 1024)
end

local function importMusic(player, id, data)
	local name = cleanName(data.name, "song")
	local folder = "imports/" .. name
	send(player, id, "progress", "Downloading MIDI...")
	local midiBytes = fetch(data.midiUrl)
	if detect(midiBytes) ~= "mid" then
		error("the MIDI URL didn't return a MIDI file (checked its header bytes)", 0)
	end
	local midi = AudioLab.Midi.decode(midiBytes) -- validates
	AudioLab.Importer.store(folder .. "/" .. name .. ".mid", midiBytes)
	local note = ("MIDI: %d notes, %s"):format(#midi.notes, string.format("%d:%02d", midi.duration // 60, math.floor(midi.duration % 60)))
	if data.soundFontUrl and data.soundFontUrl ~= "" then
		send(player, id, "progress", note .. ". Downloading SoundFont...")
		local sfBytes = fetch(data.soundFontUrl)
		if detect(sfBytes) ~= "sf2" then
			error("the SoundFont URL didn't return an SF2 file (checked its header bytes)", 0)
		end
		local sfPath = folder .. "/" .. name .. ".sf2"
		AudioLab.Importer.store(sfPath, sfBytes)
		send(player, id, "progress", ("SoundFont %.0f KB downloaded. Analysing instruments..."):format(#sfBytes / 1024))
		local _, stats = AudioLab.Baker.bakeSoundFont(sfPath)
		note ..= (", SoundFont baked: %d presets, %d samples"):format(stats.presets, stats.samples)
	else
		note ..= ", General MIDI instruments"
	end
	record({ kind = "music", name = name, path = folder, url = data.midiUrl, soundFontUrl = data.soundFontUrl, seconds = midi.duration,
		bytes = #midiBytes, detail = ("MIDI, %d notes%s"):format(#midi.notes, (data.soundFontUrl and data.soundFontUrl ~= "") and ", SoundFont" or ""),
		player = player })
	return { kind = "midi", id = folder .. "/" .. name .. ".mid", title = folder .. " - " .. name }, "Imported " .. name .. " (" .. note .. ")"
end

request.OnServerEvent:Connect(function(player, data)
	if type(data) ~= "table" then
		return
	end
	local id = tostring(data.id or "")
	pending[player] = pending[player] or 0
	if pending[player] >= MAX_PENDING_PER_PLAYER then
		send(player, id, "error", "Already importing; wait for the current import to finish")
		return
	end
	if data.kind == "sfx" and not validUrl(data.url) then
		send(player, id, "error", "That doesn't look like an http(s) URL")
		return
	elseif data.kind == "music" and (not validUrl(data.midiUrl) or (data.soundFontUrl and data.soundFontUrl ~= "" and not validUrl(data.soundFontUrl))) then
		send(player, id, "error", "That doesn't look like an http(s) URL")
		return
	elseif data.kind ~= "sfx" and data.kind ~= "music" then
		return
	end
	pending[player] += 1
	task.spawn(function()
		local ok, track, message = pcall(data.kind == "sfx" and importSfx or importMusic, player, id, data)
		pending[player] = math.max(0, (pending[player] or 1) - 1)
		if ok then
			send(player, id, "done", message, track)
		else
			send(player, id, "error", tostring(track))
		end
	end)
end)

game:GetService("Players").PlayerRemoving:Connect(function(p)
	pending[p] = nil
end)

end
