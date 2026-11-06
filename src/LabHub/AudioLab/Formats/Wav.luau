--!native
--!optimize 2
-- WAV (RIFF/WAVE) decoder and encoder.
-- Decodes: PCM 8 (unsigned) / 16 / 24 / 32-bit, IEEE float 32 / 64, A-law, mu-law,
-- and WAVE_FORMAT_EXTENSIBLE wrapping any of those. Reads 'smpl' loop points.
-- Result: { signal = Signal, format = {...}, loops = {{start, finish}}, chunks = {...} }

local AudioLab = script:FindFirstAncestor("AudioLab")
local Iff = require(AudioLab.Formats.Iff)
local Signal = require(AudioLab.DSP.Signal)
local ByteWriter = require(AudioLab.Util.ByteWriter)

local Wav = {}

local TAG_PCM = 1
local TAG_FLOAT = 3
local TAG_ALAW = 6
local TAG_MULAW = 7
local TAG_EXTENSIBLE = 0xFFFE
local MAX_FRAMES = 50_000_000

local function alawToLinear(a)
	a = bit32.bxor(a, 0x55)
	local t = bit32.lshift(bit32.band(a, 0x0F), 4)
	local seg = bit32.rshift(bit32.band(a, 0x70), 4)
	if seg == 0 then
		t += 8
	elseif seg == 1 then
		t += 0x108
	else
		t = bit32.lshift(t + 0x108, seg - 1)
	end
	return (bit32.band(a, 0x80) ~= 0) and t or -t
end

local function mulawToLinear(u)
	u = bit32.bnot(u) % 256
	local t = bit32.lshift(bit32.band(u, 0x0F), 3) + 0x84
	t = bit32.lshift(t, bit32.rshift(bit32.band(u, 0x70), 4))
	return (bit32.band(u, 0x80) ~= 0) and (0x84 - t) or (t - 0x84)
end

local ALAW = table.create(256)
local MULAW = table.create(256)
for i = 0, 255 do
	ALAW[i + 1] = alawToLinear(i) / 32768
	MULAW[i + 1] = mulawToLinear(i) / 32768
end

local function parseFmt(chunk)
	local r = Iff.reader(chunk)
	local f = {}
	f.tag = r:u16()
	f.channels = r:u16()
	f.sampleRate = r:u32()
	f.byteRate = r:u32()
	f.blockAlign = r:u16()
	f.bitsPerSample = r:remaining() >= 2 and r:u16() or 8
	if f.tag == TAG_EXTENSIBLE and r:remaining() >= 24 then
		local cbSize = r:u16()
		if cbSize >= 22 then
			f.validBits = r:u16()
			f.channelMask = r:u32()
			f.subTag = r:u16() -- first two bytes of the SubFormat GUID
		end
	end
	f.codec = (f.tag == TAG_EXTENSIBLE) and (f.subTag or TAG_PCM) or f.tag
	if f.channels < 1 or f.channels > 32 then
		error("WAV channel count out of range: " .. f.channels)
	end
	if f.sampleRate < 1 or f.sampleRate > 768000 then
		error("WAV sample rate out of range: " .. f.sampleRate)
	end
	return f
end

local function parseSmpl(chunk)
	local r = Iff.reader(chunk)
	if r:remaining() < 36 then
		return {}
	end
	r:skip(12) -- manufacturer, product, sample period
	local unityNote = r:u32()
	r:skip(16) -- pitch fraction, SMPTE format/offset
	local count = r:u32()
	r:skip(4) -- sampler data size
	local loops = {}
	for _ = 1, math.min(count, 64) do
		if r:remaining() < 24 then
			break
		end
		r:skip(4) -- cue id
		local kind = r:u32()
		local start = r:u32()
		local finish = r:u32()
		r:skip(8) -- fraction, play count
		table.insert(loops, { kind = kind, start = start, finish = finish })
	end
	return loops, unityNote
end

-- bytes: buffer or string.
function Wav.decode(bytes)
	local form, chunks = Iff.open(bytes)
	if form ~= "WAVE" then
		error("RIFF form is " .. form .. ", expected WAVE")
	end
	local fmtChunk = Iff.find(chunks, "fmt ")
	local dataChunk = Iff.find(chunks, "data")
	if not fmtChunk then
		error("WAV has no fmt chunk")
	end
	if not dataChunk then
		error("WAV has no data chunk")
	end
	local fmt = parseFmt(fmtChunk)
	local codec, bits, ch = fmt.codec, fmt.bitsPerSample, fmt.channels
	local bytesPerSample
	if codec == TAG_PCM then
		if bits ~= 8 and bits ~= 16 and bits ~= 24 and bits ~= 32 then
			error("unsupported PCM bit depth " .. bits)
		end
		bytesPerSample = bits // 8
	elseif codec == TAG_FLOAT then
		if bits ~= 32 and bits ~= 64 then
			error("unsupported float bit depth " .. bits)
		end
		bytesPerSample = bits // 8
	elseif codec == TAG_ALAW or codec == TAG_MULAW then
		bytesPerSample = 1
	else
		error(("unsupported WAV codec 0x%04X (only PCM, float, A-law and mu-law)"):format(codec))
	end

	local stride = math.max(fmt.blockAlign, bytesPerSample * ch)
	local frames = dataChunk.size // stride
	if frames > MAX_FRAMES then
		error("WAV exceeds the frame safety limit")
	end
	local signal = Signal.new(fmt.sampleRate, ch, frames)
	local src = dataChunk.body.buf
	local base = dataChunk.body.base

	for c = 1, ch do
		local dst = signal.data[c]
		local off = base + (c - 1) * bytesPerSample
		if codec == TAG_PCM and bits == 16 then
			for i = 0, frames - 1 do
				buffer.writef32(dst, i * 4, buffer.readi16(src, off + i * stride) / 32768)
			end
		elseif codec == TAG_PCM and bits == 8 then
			for i = 0, frames - 1 do
				buffer.writef32(dst, i * 4, (buffer.readu8(src, off + i * stride) - 128) / 128)
			end
		elseif codec == TAG_PCM and bits == 24 then
			for i = 0, frames - 1 do
				local p = off + i * stride
				local v = buffer.readu8(src, p) + buffer.readu8(src, p + 1) * 256 + buffer.readi8(src, p + 2) * 65536
				buffer.writef32(dst, i * 4, v / 8388608)
			end
		elseif codec == TAG_PCM and bits == 32 then
			for i = 0, frames - 1 do
				buffer.writef32(dst, i * 4, buffer.readi32(src, off + i * stride) / 2147483648)
			end
		elseif codec == TAG_FLOAT and bits == 32 then
			for i = 0, frames - 1 do
				buffer.writef32(dst, i * 4, buffer.readf32(src, off + i * stride))
			end
		elseif codec == TAG_FLOAT and bits == 64 then
			for i = 0, frames - 1 do
				buffer.writef32(dst, i * 4, buffer.readf64(src, off + i * stride))
			end
		else
			local tableLookup = (codec == TAG_ALAW) and ALAW or MULAW
			for i = 0, frames - 1 do
				buffer.writef32(dst, i * 4, tableLookup[buffer.readu8(src, off + i * stride) + 1])
			end
		end
	end

	local loops, unityNote = {}, nil
	local smpl = Iff.find(chunks, "smpl")
	if smpl then
		loops, unityNote = parseSmpl(smpl)
	end
	return { signal = signal, format = fmt, loops = loops, unityNote = unityNote, chunks = chunks }
end

-- signal -> buffer. options.bits: 8 | 16 | 24 | 32 (PCM) ; options.float = true for 32-bit float.
function Wav.encode(signal, options)
	options = options or {}
	local isFloat = options.float == true
	local bits = isFloat and 32 or (options.bits or 16)
	local bps = bits // 8
	local ch = signal.channels
	local n = signal.length
	local dataSize = n * ch * bps
	local w = ByteWriter.new(44 + dataSize + 1)
	w:str("RIFF")
	w:u32(36 + dataSize + (dataSize % 2))
	w:str("WAVE")
	w:str("fmt ")
	w:u32(16)
	w:u16(isFloat and TAG_FLOAT or TAG_PCM)
	w:u16(ch)
	w:u32(signal.sampleRate)
	w:u32(signal.sampleRate * ch * bps)
	w:u16(ch * bps)
	w:u16(bits)
	w:str("data")
	w:u32(dataSize)
	w:reserve(dataSize)
	local out, p = w.buf, w.pos
	for i = 0, n - 1 do
		for c = 1, ch do
			local v = buffer.readf32(signal.data[c], i * 4)
			if isFloat then
				buffer.writef32(out, p, v)
			else
				v = math.clamp(v, -1, 1)
				if bits == 16 then
					buffer.writei16(out, p, math.clamp(math.round(v * 32768), -32768, 32767))
				elseif bits == 8 then
					buffer.writeu8(out, p, math.clamp(math.round(v * 128) + 128, 0, 255))
				elseif bits == 24 then
					local s = math.clamp(math.round(v * 8388608), -8388608, 8388607)
					if s < 0 then
						s += 16777216
					end
					buffer.writeu8(out, p, s % 256)
					buffer.writeu8(out, p + 1, (s // 256) % 256)
					buffer.writeu8(out, p + 2, s // 65536)
				else
					buffer.writei32(out, p, math.clamp(math.round(v * 2147483648), -2147483648, 2147483647))
				end
			end
			p += bps
		end
	end
	w.pos = p
	if dataSize % 2 == 1 then
		w:u8(0)
	end
	return w:toBuffer()
end

return Wav
