-- High-level entry point: audio file or Signal -> packed RBAC clip.
--
--   local bytes, stats = Encoder.encode(signalOrDecoded, options)   -- options: Analyzer.Defaults keys
--   local bytes, stats = Encoder.encodeFile(audioBytes, options)   -- detects WAV / AIFF / FLAC / OGG (Vorbis, Opus) / AC-3 /
--                                                                     MP3 / MP2 / AAC (raw ADTS .aac) / M4A, MP4, MOV
--   Encoder.decodeAudio(bytes, { MaxSeconds? }) -> { signal, format }  (MP3 decoding yields when it can)
--   Encoder.decodeMp4Audio(bytes, track, { MaxSeconds? }) -> { signal, format }   -- track: a parsed MP4's or WebM's
--                                                                     sound (FrameLab.Formats.Mp4 / Webm .audio): AAC, MP3,
--                                                                     Opus, Vorbis, FLAC or AC-3; or an MPEG
--                                                                     stream's (FrameLab.Formats.Mpg .audio: MP2 / MP3, AC-3, AAC or PCM)
--   Encoder.toBase64(bytes) / Encoder.fromBase64(text)
--   Encoder.preload()   loads the Opus decoder now (code running in parallel can't load it when it gets there)

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
local Ac3 = require(AudioLab.Formats.Ac3)

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

local opusLoaded
function Encoder.preload()
	local m = AudioLab.Formats:FindFirstChild("Opus")
	if m and not opusLoaded then
		opusLoaded = require(m)
	end
end

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

-- WebM / Matroska Vorbis (its three setup packets and the frames) -> an Ogg Vorbis stream for Formats.Ogg
local function vorbisOgg(headers, buf, frames)
	local packets = {}
	for _, h in ipairs(headers) do
		table.insert(packets, { h, 0, buffer.len(h) })
	end
	for _, s in ipairs(frames) do
		table.insert(packets, { buf, s.pos, s.size })
	end
	local total = 0
	for _, p in ipairs(packets) do
		total += p[3] + p[3] // 255 + 1
	end
	local out = buffer.create(total + (total // 255 + 2) * 27 + 64)
	local o = 0
	local seq = 0
	local pi, done = 1, 0 -- the packet being written, and how much of it is
	-- pages of up to 255 lacing values; a packet may run on into the next page
	while pi <= #packets do
		local laces, chunks = {}, {}
		local continued = done > 0
		while pi <= #packets and #laces < 255 do
			local p = packets[pi]
			local left = p[3] - done
			while #laces < 255 do
				local n = math.min(left, 255)
				table.insert(laces, n)
				table.insert(chunks, { p[1], p[2] + done, n })
				done += n
				left -= n
				if n < 255 then
					break
				end
			end
			if left == 0 and laces[#laces] < 255 then
				pi += 1
				done = 0
			elseif left == 0 and #laces < 255 then
				-- (a packet of a multiple of 255 bytes ends with a 0 lace)
				table.insert(laces, 0)
				pi += 1
				done = 0
			else
				break
			end
		end
		buffer.writestring(out, o, "OggS")
		buffer.writeu8(out, o + 4, 0)
		buffer.writeu8(out, o + 5, (seq == 0 and 2 or 0) + (continued and 1 or 0))
		buffer.writeu32(out, o + 6, 0xFFFFFFFF)
		buffer.writeu32(out, o + 10, 0xFFFFFFFF)
		buffer.writeu32(out, o + 14, 1)
		buffer.writeu32(out, o + 18, seq)
		buffer.writeu32(out, o + 22, 0)
		buffer.writeu8(out, o + 26, #laces)
		for i, l in ipairs(laces) do
			buffer.writeu8(out, o + 26 + i, l)
		end
		o += 27 + #laces
		for _, c in ipairs(chunks) do
			buffer.copy(out, o, c[1], c[2], c[3])
			o += c[3]
		end
		seq += 1
	end
	local r = buffer.create(o)
	buffer.copy(r, 0, out, 0, o)
	return r
end

-- an MPEG stream's sound (FrameLab.Formats.Mpg): its elementary stream
local function decodeStream(track, options, yield)
	local data, codec = track.data, track.codec
	if codec == "mpga" then
		local signal = Mp3.decode(data, { Yield = yield, MaxSeconds = options.MaxSeconds })
		return { signal = signal, format = "mpeg audio" }
	elseif codec == "ac-3" then
		local result = Ac3.decode(data, { Yield = yield, MaxSeconds = options.MaxSeconds })
		return { signal = result.signal, format = "ac3" }
	elseif codec == "aac" then
		local cfg, frames = Aac.parseAdts(data)
		return { signal = Aac.decodeFrames(cfg, data, frames, { Yield = yield, MaxSeconds = options.MaxSeconds }), format = "aac" }
	elseif codec == "lpcm" then
		-- (DVD PCM: big-endian samples, channels interleaved)
		if (track.bits or 16) ~= 16 then
			error(("the sound is %d-bit DVD PCM, which AudioLab can't read (16-bit works)"):format(track.bits), 0)
		end
		local ch, rate = track.channels or 2, track.sampleRate or 48000
		local frames = buffer.len(data) // (2 * ch)
		if options.MaxSeconds then
			frames = math.min(frames, math.floor(options.MaxSeconds * rate))
		end
		local out = {}
		for c = 1, ch do
			local b = buffer.create(frames * 4)
			local p = 2 * (c - 1)
			for i = 0, frames - 1 do
				local v = buffer.readu8(data, p) * 256 + buffer.readu8(data, p + 1)
				if v >= 32768 then
					v -= 65536
				end
				buffer.writef32(b, i * 4, v / 32768)
				p += 2 * ch
			end
			out[c] = b
			if yield then
				yield()
			end
		end
		return { signal = { sampleRate = rate, channels = ch, length = frames, data = out }, format = "pcm" }
	end
	error(("the sound is %s, which AudioLab can't read from this video"):format(tostring(codec)), 0)
end

-- the sound moved to start `start` seconds after the video's first frame (a negative start: its beginning is cut)
local function shiftStart(decoded, start)
	local sig = decoded.signal
	local shift = math.clamp(math.floor((start or 0) * sig.sampleRate + 0.5), -sig.length, sig.sampleRate * 10)
	if shift == 0 then
		return decoded
	end
	local len = sig.length + shift
	local data = {}
	for c = 1, sig.channels do
		local nb = buffer.create(len * 4)
		if shift > 0 then
			buffer.copy(nb, shift * 4, sig.data[c], 0, sig.length * 4)
		elseif len > 0 then
			buffer.copy(nb, 0, sig.data[c], -shift * 4, len * 4)
		end
		data[c] = nb
	end
	local out = table.clone(sig)
	out.length, out.data = len, data
	return { signal = out, format = decoded.format }
end

function Encoder.decodeMp4Audio(bytes, track, options)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	options = options or {}
	local yield = smartYield()
	if track and track.data then
		return shiftStart(decodeStream(track, options, yield), track.start)
	end
	local frames = {}
	for _, s in ipairs(track and track.samples or {}) do
		if s.cut then
			break -- the download stopped early: keep what arrived
		end
		table.insert(frames, s)
	end
	if #frames == 0 then
		error("the video's sound track has no frames", 0)
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
	if codec == "vorbis" then
		if not track.vorbisHeaders or #track.vorbisHeaders < 3 then
			error("the Vorbis sound's setup is missing", 0)
		end
		local result = Ogg.decode(vorbisOgg(track.vorbisHeaders, buf, frames), { Yield = yield, MaxSeconds = options.MaxSeconds })
		return { signal = result.signal, format = "vorbis" }
	end
	if codec == "Opus" then
		local m = AudioLab.Formats:FindFirstChild("Opus")
		if not m then
			error("the sound is Opus, and the Opus decoder (AudioLab.Formats.Opus) is missing", 0)
		end
		local Opus = opusLoaded or require(m)
		local cfg = track.dOps and Opus.readDops(track.dOps, 0, buffer.len(track.dOps))
			or { channels = track.channels or 2, preSkip = 312, gainDb = 0, mapping = 0, streams = 1 }
		if cfg.channels > 2 or cfg.streams > 1 then
			error("the sound is surround Opus (more than 2 channels), which AudioLab can't read; mono and stereo work", 0)
		end
		local packets = table.create(#frames)
		for i, s in ipairs(frames) do
			packets[i] = { buf, s.pos, s.size }
		end
		-- the edit list states the decoder delay; the setup box's pre-skip when there is none
		local skip = track.skip or cfg.preSkip
		local signal = Opus.decodePackets(packets, cfg.channels, skip, { Yield = yield, MaxSeconds = options.MaxSeconds }, cfg.gainDb)
		return { signal = signal, format = "opus" }
	end
	if codec == "ac-3" then
		local result = Ac3.decodeFrames(buf, frames, { Yield = yield, MaxSeconds = options.MaxSeconds })
		return { signal = result.signal, format = "ac3" }
	end
	if codec == "fLaC" then
		-- a FLAC stream: its header (MKV: "fLaC" and the metadata blocks; MP4: the dfLa box's metadata blocks), then the
		-- frames
		local head, hs, hl
		if track.flacHeader and buffer.len(track.flacHeader) > 4 then
			head, hs, hl = track.flacHeader, 0, buffer.len(track.flacHeader)
		elseif track.dfLa and buffer.len(track.dfLa) > 4 then
			head, hs, hl = track.dfLa, 4, buffer.len(track.dfLa) - 4
		else
			error("the FLAC sound's setup is missing", 0)
		end
		local magic = hs == 4 and 4 or 0
		local total = magic + hl
		for _, s in ipairs(frames) do
			total += s.size
		end
		local stream = buffer.create(total)
		local o = 0
		if magic == 4 then
			buffer.writestring(stream, 0, "fLaC")
			o = 4
		end
		buffer.copy(stream, o, head, hs, hl)
		o += hl
		for _, s in ipairs(frames) do
			buffer.copy(stream, o, buf, s.pos, s.size)
			o += s.size
		end
		local result = Flac.decode(stream, { Yield = yield, MaxSeconds = options.MaxSeconds })
		return { signal = result.signal, format = "flac" }
	end
	if codec ~= "mp4a" or not (track.esds and track.esds.asc) then
		local names = { ["ec-3"] = "E-AC-3 (Dolby Digital Plus)", alac = "ALAC", sowt = "PCM", twos = "PCM", lpcm = "PCM",
			samr = "AMR", A_EAC3 = "E-AC-3 (Dolby Digital Plus)", A_DTS = "DTS", A_TRUEHD = "Dolby TrueHD", A_ALAC = "ALAC" }
		error(("the sound is %s, which AudioLab can't read from a video (AAC, MP3, Opus, Vorbis, FLAC and AC-3 work)"):format(names[codec] or ("%q"):format(codec)), 0)
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
	elseif Ac3.isAc3(buf) then
		return Ac3.decode(buf, { Yield = yield, MaxSeconds = options and options.MaxSeconds })
	elseif Aac.isAdts(buf) then -- (before MP3: both start with an FF sync byte)
		local cfg, frames = Aac.parseAdts(buf)
		return { signal = Aac.decodeFrames(cfg, buf, frames, { Yield = yield, MaxSeconds = options and options.MaxSeconds }), format = "aac" }
	elseif buffer.readstring(buf, 4, 4) == "ftyp" or (not isMp3(buf) and mp4Demuxer().isMp4(buf)) then
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
