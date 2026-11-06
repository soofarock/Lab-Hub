--!native
--!optimize 2
-- Binary clip format ("RBAC" v1), little-endian.
--
-- Header (24 bytes):
--   0  "RBAC"            magic
--   4  u8  version        1
--   5  u8  fps            control frames per second
--   6  u8  slots          voice slots per frame
--   7  u8  bands          noise bands per frame
--   8  u32 frameCount
--   12 u32 sourceRate     sample rate of the analysed source
--   16 u32 sourceLength   samples in the analysed source
--   20 u8  bankVersion    WaveBank.Version the clip was encoded against
--   21 u8[3] reserved
-- Frame (slots*4 + bands bytes):
--   per slot: u8 wave (0 = silent, else WaveBank.Waves index), u16 pitch (MIDI note * 256),
--             u8 volume (log scale, see volToByte)
--   per band: u8 volume (same log scale)

local Format = {}

Format.Magic = "RBAC"
Format.Version = 1
Format.HeaderSize = 24
local DB_MIN, DB_MAX = -72, 12

-- Linear gain -> byte: 0 = silence, 1..255 spans -72 dB .. +12 dB.
function Format.volToByte(v)
	if v <= 0 then
		return 0
	end
	local db = 20 * math.log10(v)
	if db < DB_MIN then
		return 0
	end
	db = math.min(db, DB_MAX)
	return 1 + math.floor((db - DB_MIN) / (DB_MAX - DB_MIN) * 254 + 0.5)
end

local BYTE_TO_VOL = table.create(256)
BYTE_TO_VOL[1] = 0
for b = 1, 255 do
	BYTE_TO_VOL[b + 1] = 10 ^ ((DB_MIN + (b - 1) * (DB_MAX - DB_MIN) / 254) / 20)
end

function Format.byteToVol(b)
	return BYTE_TO_VOL[b + 1]
end

function Format.freqToMidi(f)
	return 69 + 12 * math.log(f / 440, 2)
end

function Format.midiToFreq(m)
	return 440 * 2 ^ ((m - 69) / 12)
end

function Format.frameBytes(slots, bands)
	return slots * 4 + bands
end

-- clip = { fps, slots, bands, sourceRate, sourceLength, bankVersion,
--          frames = { { voices = {[slot] = {wave, freq, volume}}, bands = {vol...} } } }
function Format.pack(clip)
	local slots, bands = clip.slots, clip.bands
	local frameCount = #clip.frames
	local fb = Format.frameBytes(slots, bands)
	local buf = buffer.create(Format.HeaderSize + frameCount * fb)
	buffer.writestring(buf, 0, Format.Magic)
	buffer.writeu8(buf, 4, Format.Version)
	buffer.writeu8(buf, 5, clip.fps)
	buffer.writeu8(buf, 6, slots)
	buffer.writeu8(buf, 7, bands)
	buffer.writeu32(buf, 8, frameCount)
	buffer.writeu32(buf, 12, clip.sourceRate or 0)
	buffer.writeu32(buf, 16, clip.sourceLength or 0)
	buffer.writeu8(buf, 20, clip.bankVersion or 0)
	local p = Format.HeaderSize
	for _, frame in ipairs(clip.frames) do
		for s = 1, slots do
			local v = frame.voices[s]
			local volByte = v and Format.volToByte(v.volume) or 0
			if v and volByte > 0 then
				buffer.writeu8(buf, p, v.wave)
				buffer.writeu16(buf, p + 1, math.clamp(math.floor(Format.freqToMidi(v.freq) * 256 + 0.5), 0, 65535))
				buffer.writeu8(buf, p + 3, volByte)
			else
				buffer.writeu32(buf, p, 0)
			end
			p += 4
		end
		for b = 1, bands do
			buffer.writeu8(buf, p, Format.volToByte(frame.bands[b] or 0))
			p += 1
		end
	end
	return buf
end

-- Parse a packed clip (buffer or string). Frames stay packed; use Format.readFrame.
function Format.unpack(bytes)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local len = buffer.len(buf)
	if len < Format.HeaderSize or buffer.readstring(buf, 0, 4) ~= Format.Magic then
		error("not an RBAC clip")
	end
	local version = buffer.readu8(buf, 4)
	if version ~= Format.Version then
		error("unsupported RBAC version " .. version)
	end
	local clip = {
		buf = buf, version = version,
		fps = buffer.readu8(buf, 5), slots = buffer.readu8(buf, 6), bands = buffer.readu8(buf, 7),
		frameCount = buffer.readu32(buf, 8), sourceRate = buffer.readu32(buf, 12),
		sourceLength = buffer.readu32(buf, 16), bankVersion = buffer.readu8(buf, 20),
	}
	clip.frameSize = Format.frameBytes(clip.slots, clip.bands)
	if Format.HeaderSize + clip.frameCount * clip.frameSize > len then
		error("RBAC clip is truncated")
	end
	if clip.fps == 0 then
		error("RBAC clip has fps 0")
	end
	clip.duration = clip.frameCount / clip.fps
	return clip
end

-- Decode frame (0-based) into out = { waves = {}, pitches = {} (MIDI), volumes = {}, bands = {} }.
-- Indices past the end read as silence.
function Format.readFrame(clip, index, out)
	out = out or { waves = {}, pitches = {}, volumes = {}, bands = {} }
	local waves, pitches, volumes, bands = out.waves, out.pitches, out.volumes, out.bands
	if index < 0 or index >= clip.frameCount then
		for s = 1, clip.slots do
			waves[s], pitches[s], volumes[s] = 0, 0, 0
		end
		for b = 1, clip.bands do
			bands[b] = 0
		end
		return out
	end
	local buf = clip.buf
	local p = Format.HeaderSize + index * clip.frameSize
	for s = 1, clip.slots do
		waves[s] = buffer.readu8(buf, p)
		pitches[s] = buffer.readu16(buf, p + 1) / 256
		volumes[s] = BYTE_TO_VOL[buffer.readu8(buf, p + 3) + 1]
		p += 4
	end
	for b = 1, clip.bands do
		bands[b] = BYTE_TO_VOL[buffer.readu8(buf, p) + 1]
		p += 1
	end
	return out
end

return Format
