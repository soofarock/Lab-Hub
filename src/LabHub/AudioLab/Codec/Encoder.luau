-- High-level entry point: audio file or Signal -> packed RBAC clip.
--
--   local bytes, stats = Encoder.encode(signalOrDecoded, options)   -- options: Analyzer.Defaults keys
--   local bytes, stats = Encoder.encodeFile(audioBytes, options)   -- detects WAV / AIFF / FLAC / OGG (Vorbis) / MP3 /
--                                                                     AAC (raw ADTS .aac, or M4A / MP4)
--   Encoder.decodeAudio(bytes, { MaxSeconds? }) -> { signal, format }  (MP3 decoding yields when it can)
--   Encoder.decodeMp4Audio(bytes, track, { MaxSeconds? }) -> { signal, format }   -- track: a parsed MP4's sound
--                                                                     (FrameLab.Formats.Mp4 .audio): AAC or MP3
--   Encoder.toBase64(bytes) / Encoder.fromBase64(text)

local AudioLab = script:FindFirstAncestor("AudioLab")
local Analyzer = require(AudioLab.Codec.Analyzer)
local Format = require(AudioLab.Codec.Format)
local Base64 = require(AudioLab.Util.Base64)
local Wav = require(AudioLab.Formats.Wav)
local Aiff = require(AudioLab.Formats.Aiff)
local Mp3 = require(AudioLab.Formats.Mp3)
local Flac = require(AudioLab.Formats.Flac)
local Ogg = require(AudioLab.Formats.Ogg)
local Partials = require(AudioLab.Codec.Partials)
local Aac = require(AudioLab.Formats.Aac)

-- the MP4 reader: AudioLab's own if it has one, else FrameLab's
local function mp4Demuxer()
	local own = AudioLab.Formats:FindFirstChild("Mp4")
	local fl = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):FindFirstChild("FrameLab")
	local m = own or (fl and fl:FindFirstChild("Formats") and fl.Formats:FindFirstChild("Mp4"))
	if not m then
		error("M4A / MP4 sound needs FrameLab (its MP4 reader) in this place", 0)
	end
	return require(m)
end

-- MP3: ID3v2 tag or an MPEG audio frame sync at the start
local function isMp3(buf)
	if buffer.readstring(buf, 0, 3) == "ID3" then
		return true
	end
	return buffer.readu8(buf, 0) == 0xFF and bit32.band(buffer.readu8(buf, 1), 0xE0) == 0xE0
end

local Encoder = {}
Encoder.isMp3 = isMp3

-- a yield for long jobs (decoding, encoding): waits a frame only after ~12 ms of work since the last wait. (A task.wait
-- every chunk cost a whole frame each time: an imported video's sound spent most of its time waiting.)
local function smartYield()
	if not coroutine.isyieldable() then
		return nil
	end
	local last = os.clock()
	return function()
		if os.clock() - last > 0.012 then
			task.wait()
			last = os.clock()
		end
	end
end

function Encoder.decodeMp4Audio(bytes, track, options)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	options = options or {}
	local yield = smartYield()
	local frames = {}
	for _, s in ipairs(track and track.samples or {}) do
		if s.cut then
			break -- the download stopped early: keep what arrived
		end
		table.insert(frames, s)
	end
	if #frames == 0 then
		error("the MP4 has no sound frames", 0)
	end
	local codec = track.codec or "?"
	local oti = track.esds and track.esds.oti
	if codec == ".mp3" or oti == 0x69 or oti == 0x6B then
		-- MP3 frames stand alone: joined, they are an MP3 file
		local total = 0
		for _, s in ipairs(frames) do
			total += s.size
		end
		local mp3 = buffer.create(total)
		local o = 0
		for _, s in ipairs(frames) do
			buffer.copy(mp3, o, buf, s.pos, s.size)
			o += s.size
		end
		local signal = Mp3.decode(mp3, { Yield = yield, MaxSeconds = options.MaxSeconds })
		return { signal = signal, format = "mp3" }
	end
	if codec ~= "mp4a" or not (track.esds and track.esds.asc) then
		local names = { ["ac-3"] = "AC-3 (Dolby Digital)", ["ec-3"] = "E-AC-3 (Dolby Digital Plus)", Opus = "Opus", alac = "ALAC",
			fLaC = "FLAC", sowt = "PCM", twos = "PCM", lpcm = "PCM", samr = "AMR" }
		error(("the sound is %s, which AudioLab can't read from an MP4 (AAC and MP3 work)"):format(names[codec] or ("%q"):format(codec)), 0)
	end
	local cfg = Aac.parseConfig(track.esds.asc)
	-- the encoder delay is in the track's rate; HE-AAC is decoded at its core rate (half)
	local skip = track.skip or 0
	if track.sampleRate and track.sampleRate > 0 and math.abs(track.sampleRate - cfg.sampleRate) > 1 then
		skip = math.floor(skip * cfg.sampleRate / track.sampleRate + 0.5)
	end
	local signal = Aac.decodeFrames(cfg, buf, frames, { Skip = skip, MaxSeconds = options.MaxSeconds, Yield = yield })
	return { signal = signal, format = cfg.sbr and "aac-he" or "aac" }
end

function Encoder.decodeAudio(bytes, options)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if buffer.len(buf) < 12 then
		error("audio file too small")
	end
	local magic = buffer.readstring(buf, 0, 4)
	local yield = smartYield()
	if magic == "RIFF" then
		return Wav.decode(buf)
	elseif magic == "FORM" then
		return Aiff.decode(buf)
	elseif Flac.isFlac(buf) then -- (before MP3: a FLAC file may start with an ID3 tag too)
		return Flac.decode(buf, { Yield = yield, MaxSeconds = options and options.MaxSeconds })
	elseif magic == "OggS" then
		return Ogg.decode(buf, { Yield = yield, MaxSeconds = options and options.MaxSeconds })
	elseif Aac.isAdts(buf) then -- (before MP3: both start with an FF sync byte)
		local cfg, frames = Aac.parseAdts(buf)
		return { signal = Aac.decodeFrames(cfg, buf, frames, { Yield = yield, MaxSeconds = options and options.MaxSeconds }), format = "aac" }
	elseif buffer.readstring(buf, 4, 4) == "ftyp" then
		local m = mp4Demuxer().parse(buf)
		if not m.audio then
			error("this MP4 has no sound", 0)
		end
		return Encoder.decodeMp4Audio(buf, m.audio, options)
	elseif isMp3(buf) then
		local signal = Mp3.decode(buf, {
			Yield = smartYield(),
			MaxSeconds = options and options.MaxSeconds,
		})
		return { signal = signal, format = "mp3", bitrate = signal.bitrate }
	end
	error(("unrecognised audio file (magic %q)"):format(magic))
end

-- short sound effects (TEXTURE_MAX_SECONDS or less) are encoded as RBA4 (Codec.Texture: generic tone shapes, clicks
-- and noise grains, each started at an exact time) once its generic files are uploaded (Codec.Manifests.Files:
-- every file of Codec.Texture.LAYOUT.allFiles); options.Texture = true / false forces it on / off.
-- recordings are encoded as RBA3 (Codec.Partials: tracked sines + high noise); options.Legacy = true
-- uses the old RBAC analyzer (8 waveform voices + octave noise)
local TEXTURE_MAX_SECONDS = 4
local function textureReady()
	local ok, files = pcall(require, AudioLab.Codec.Manifests.Files)
	local okT, Texture = pcall(require, AudioLab.Codec.Texture)
	if not ok or type(files) ~= "table" or not okT then
		return false
	end
	for _, name in ipairs(Texture.LAYOUT.allFiles) do
		if name ~= "tex_loop" and (files[name] or "") == "" then
			return false
		end
	end
	return true
end
Encoder.textureReady = textureReady

function Encoder.encode(input, options)
	local signal = input.signal or input
	local useTexture = options and options.Texture
	if useTexture == nil then
		useTexture = not (options and options.Legacy) and signal.length / signal.sampleRate <= TEXTURE_MAX_SECONDS
			and textureReady()
	end
	if useTexture then
		local Texture = require(AudioLab.Codec.Texture)
		local o = {
			Yield = (options and options.Yield) or smartYield(),
			Progress = options and options.Progress,
		}
		local bytes, stats = Texture.encode(signal, o)
		stats.sourceBytes = signal.length * 2
		stats.ratio = stats.sourceBytes / math.max(stats.bytes, 1)
		return bytes, stats
	end
	if not (options and options.Legacy) then
		local o = {}
		for k, v in pairs(options or {}) do
			o[k] = v
		end
		if o.Yield == nil and coroutine.isyieldable() then
			o.Yield = smartYield()
		end
		local bytes, stats = Partials.encode(signal, o)
		stats.sourceBytes = signal.length * 2
		stats.ratio = stats.sourceBytes / math.max(stats.bytes, 1)
		return bytes, stats
	end
	local t0 = os.clock()
	local clip, stats = Analyzer.analyze(signal, options)
	local bytes = Format.pack(clip)
	stats.seconds = signal.length / signal.sampleRate
	stats.encodeTime = os.clock() - t0
	stats.bytes = buffer.len(bytes)
	stats.sourceBytes = signal.length * 2 -- as mono 16-bit PCM at the source rate
	stats.ratio = stats.sourceBytes / math.max(stats.bytes, 1)
	stats.bytesPerSecond = stats.bytes / math.max(stats.seconds, 1e-9)
	return bytes, stats
end

function Encoder.encodeFile(fileBytes, options)
	return Encoder.encode(Encoder.decodeAudio(fileBytes), options)
end

Encoder.toBase64 = Base64.encode
Encoder.fromBase64 = Base64.decode

return Encoder
