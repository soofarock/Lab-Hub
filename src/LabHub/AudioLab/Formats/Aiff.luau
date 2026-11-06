--!native
--!optimize 2
-- AIFF / AIFF-C decoder and encoder (IFF FORM, big-endian).
-- Decodes: AIFF PCM 8/16/24/32-bit (signed, big-endian); AIFF-C compression types
-- NONE, twos (BE PCM), sowt (LE PCM), fl32/FL32, fl64/FL64, raw (8-bit unsigned).
-- Result: { signal = Signal, format = {...}, chunks = {...} }

local AudioLab = script:FindFirstAncestor("AudioLab")
local Iff = require(AudioLab.Formats.Iff)
local Signal = require(AudioLab.DSP.Signal)
local ByteWriter = require(AudioLab.Util.ByteWriter)

local Aiff = {}

local function readU(src, p, nBytes, little)
	-- unsigned integer of nBytes at p
	local v = 0
	if little then
		for k = nBytes - 1, 0, -1 do
			v = v * 256 + buffer.readu8(src, p + k)
		end
	else
		for k = 0, nBytes - 1 do
			v = v * 256 + buffer.readu8(src, p + k)
		end
	end
	return v
end

function Aiff.decode(bytes)
	local form, chunks, bigEndian = Iff.open(bytes)
	if not bigEndian or (form ~= "AIFF" and form ~= "AIFC") then
		error("expected FORM AIFF or AIFC, found " .. tostring(form))
	end
	local comm = Iff.find(chunks, "COMM")
	local ssnd = Iff.find(chunks, "SSND")
	if not comm then
		error("AIFF has no COMM chunk")
	end

	local r = Iff.reader(comm)
	local fmt = {}
	fmt.channels = r:i16be()
	fmt.frames = r:u32be()
	fmt.bitsPerSample = r:i16be()
	fmt.sampleRate = r:f80be()
	fmt.compression = "NONE"
	if form == "AIFC" and r:remaining() >= 4 then
		fmt.compression = r:str(4)
	end
	if fmt.channels < 1 or fmt.channels > 32 then
		error("AIFF channel count out of range: " .. fmt.channels)
	end
	if not (fmt.sampleRate > 0 and fmt.sampleRate < 1e6) then
		error("AIFF sample rate out of range")
	end

	local comp = fmt.compression
	local kind, bytesPerSample, little
	if comp == "NONE" or comp == "twos" then
		kind, little = "int", false
		bytesPerSample = math.ceil(fmt.bitsPerSample / 8)
	elseif comp == "sowt" then
		kind, little = "int", true
		bytesPerSample = math.ceil(fmt.bitsPerSample / 8)
	elseif comp == "raw " then
		kind, bytesPerSample = "u8", 1
	elseif comp == "fl32" or comp == "FL32" then
		kind, bytesPerSample = "f32", 4
	elseif comp == "fl64" or comp == "FL64" then
		kind, bytesPerSample = "f64", 8
	else
		error("unsupported AIFF-C compression " .. comp)
	end
	if kind == "int" and (bytesPerSample < 1 or bytesPerSample > 4) then
		error("unsupported AIFF bit depth " .. fmt.bitsPerSample)
	end

	local ch = fmt.channels
	local stride = bytesPerSample * ch
	local frames, src, dataStart = 0, nil, 0
	if ssnd then
		local sr = Iff.reader(ssnd)
		local offset = sr:u32be()
		sr:skip(4) -- block size
		sr:skip(math.min(offset, sr:remaining()))
		frames = math.min(fmt.frames, sr:remaining() // stride)
		src = sr.buf
		dataStart = sr:absolute()
	end

	local signal = Signal.new(fmt.sampleRate, ch, frames)
	local scale = 1 / 2 ^ (bytesPerSample * 8 - 1)
	local full = 2 ^ (bytesPerSample * 8)
	local half = full / 2
	local tmp = buffer.create(8)
	for c = 1, ch do
		local dst = signal.data[c]
		local off = dataStart + (c - 1) * bytesPerSample
		for i = 0, frames - 1 do
			local p = off + i * stride
			local v
			if kind == "int" then
				local u = readU(src, p, bytesPerSample, little)
				if u >= half then
					u -= full
				end
				v = u * scale
			elseif kind == "u8" then
				v = (buffer.readu8(src, p) - 128) / 128
			elseif kind == "f32" then
				buffer.writeu32(tmp, 0, bit32.byteswap(buffer.readu32(src, p)))
				v = buffer.readf32(tmp, 0)
			else
				for k = 0, 7 do
					buffer.writeu8(tmp, k, buffer.readu8(src, p + 7 - k))
				end
				v = buffer.readf64(tmp, 0)
			end
			buffer.writef32(dst, i * 4, v)
		end
	end
	return { signal = signal, format = fmt, chunks = chunks }
end

-- signal -> buffer. options.compression: nil/"NONE" (AIFF, BE PCM), "sowt" (AIFF-C LE PCM),
-- "fl32" (AIFF-C float). options.bits for PCM: 8/16/24 (default 16).
function Aiff.encode(signal, options)
	options = options or {}
	local comp = options.compression or "NONE"
	local isC = comp ~= "NONE"
	local bits = (comp == "fl32") and 32 or (options.bits or 16)
	local bps = bits // 8
	local ch, n = signal.channels, signal.length
	local dataSize = n * ch * bps
	local w = ByteWriter.new(64 + dataSize)
	w:str("FORM")
	local sizeAt = w:tell()
	w:u32be(0)
	w:str(isC and "AIFC" or "AIFF")
	if isC then
		w:str("FVER")
		w:u32be(4)
		w:u32be(0xA2805140)
	end
	w:str("COMM")
	w:u32be(isC and 24 or 18)
	w:i16be(ch)
	w:u32be(n)
	w:i16be(bits)
	w:f80be(signal.sampleRate)
	if isC then
		w:str(comp)
		w:u8(0)
		w:u8(0) -- empty pascal string + pad
	end
	w:str("SSND")
	w:u32be(8 + dataSize)
	w:u32be(0)
	w:u32be(0)
	for i = 0, n - 1 do
		for c = 1, ch do
			local v = buffer.readf32(signal.data[c], i * 4)
			if comp == "fl32" then
				w:f32be(v)
			else
				v = math.clamp(v, -1, 1)
				local maxv = 2 ^ (bits - 1)
				local s = math.clamp(math.round(v * maxv), -maxv, maxv - 1)
				if comp == "sowt" then
					if bits == 16 then
						w:i16(s)
					elseif bits == 8 then
						w:i8(s)
					else
						w:i24(s)
					end
				else
					if bits == 16 then
						w:i16be(s)
					elseif bits == 8 then
						w:i8(s)
					else
						w:i24be(s)
					end
				end
			end
		end
	end
	if dataSize % 2 == 1 then
		w:u8(0)
	end
	w:patchU32be(sizeAt, w:tell() - 8)
	return w:toBuffer()
end

return Aiff
