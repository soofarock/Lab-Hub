--!optimize 2
-- Bounds-checked binary reader over a Luau buffer.
-- Little-endian reads by default (RIFF, WAV, SF2); *be variants for big-endian (MIDI, AIFF).
-- Every read checks the remaining range and raises a descriptive error instead of
-- returning garbage, so malformed files fail closed.

local ByteReader = {}
ByteReader.__index = ByteReader

local function fail(self, what)
	error(("%s at offset %d (range %d..%d)"):format(what, self.pos, self.base, self.limit), 3)
end

-- source: buffer or string. offset/length (bytes) restrict the readable window.
function ByteReader.new(source, offset, length)
	local buf = source
	if type(source) == "string" then
		buf = buffer.fromstring(source)
	end
	assert(typeof(buf) == "buffer", "ByteReader.new expects a buffer or string")
	local total = buffer.len(buf)
	offset = offset or 0
	length = length or (total - offset)
	assert(offset >= 0 and length >= 0 and offset + length <= total, "ByteReader window is outside the buffer")
	return setmetatable({ buf = buf, base = offset, limit = offset + length, pos = offset }, ByteReader)
end

function ByteReader:tell()
	return self.pos - self.base
end

function ByteReader:size()
	return self.limit - self.base
end

function ByteReader:remaining()
	return self.limit - self.pos
end

function ByteReader:seek(relative)
	if relative < 0 or relative > self.limit - self.base then
		fail(self, "seek outside range")
	end
	self.pos = self.base + relative
end

function ByteReader:need(n, what)
	if n < 0 or self.pos + n > self.limit then
		fail(self, ("truncated %s (need %d bytes, have %d)"):format(what or "data", n, self.limit - self.pos))
	end
end

function ByteReader:skip(n)
	self:need(n, "skip")
	self.pos += n
end

-- Returns a new reader over the next n bytes and advances past them.
function ByteReader:sub(n)
	self:need(n, "sub-range")
	local r = ByteReader.new(self.buf, self.pos, n)
	self.pos += n
	return r
end

-- Absolute buffer offset of the cursor (for bulk buffer.read* loops).
function ByteReader:absolute()
	return self.pos
end

-- Little-endian --------------------------------------------------------------

function ByteReader:u8()
	self:need(1, "u8")
	local v = buffer.readu8(self.buf, self.pos)
	self.pos += 1
	return v
end

function ByteReader:i8()
	self:need(1, "i8")
	local v = buffer.readi8(self.buf, self.pos)
	self.pos += 1
	return v
end

function ByteReader:u16()
	self:need(2, "u16")
	local v = buffer.readu16(self.buf, self.pos)
	self.pos += 2
	return v
end

function ByteReader:i16()
	self:need(2, "i16")
	local v = buffer.readi16(self.buf, self.pos)
	self.pos += 2
	return v
end

function ByteReader:u24()
	self:need(3, "u24")
	local b = self.buf
	local p = self.pos
	local v = buffer.readu8(b, p) + buffer.readu8(b, p + 1) * 256 + buffer.readu8(b, p + 2) * 65536
	self.pos += 3
	return v
end

function ByteReader:u32()
	self:need(4, "u32")
	local v = buffer.readu32(self.buf, self.pos)
	self.pos += 4
	return v
end

function ByteReader:i32()
	self:need(4, "i32")
	local v = buffer.readi32(self.buf, self.pos)
	self.pos += 4
	return v
end

function ByteReader:f32()
	self:need(4, "f32")
	local v = buffer.readf32(self.buf, self.pos)
	self.pos += 4
	return v
end

function ByteReader:f64()
	self:need(8, "f64")
	local v = buffer.readf64(self.buf, self.pos)
	self.pos += 8
	return v
end

-- Big-endian -----------------------------------------------------------------

function ByteReader:u16be()
	self:need(2, "u16be")
	local b = self.buf
	local p = self.pos
	self.pos += 2
	return buffer.readu8(b, p) * 256 + buffer.readu8(b, p + 1)
end

function ByteReader:i16be()
	local v = self:u16be()
	return v >= 32768 and v - 65536 or v
end

function ByteReader:u24be()
	self:need(3, "u24be")
	local b = self.buf
	local p = self.pos
	self.pos += 3
	return buffer.readu8(b, p) * 65536 + buffer.readu8(b, p + 1) * 256 + buffer.readu8(b, p + 2)
end

function ByteReader:u32be()
	self:need(4, "u32be")
	local v = bit32.byteswap(buffer.readu32(self.buf, self.pos))
	self.pos += 4
	return v
end

function ByteReader:i32be()
	local v = self:u32be()
	return v >= 2147483648 and v - 4294967296 or v
end

-- 80-bit IEEE 754 extended (AIFF sample rate).
function ByteReader:f80be()
	local se = self:u16be()
	local hi = self:u32be()
	local lo = self:u32be()
	if se == 0 and hi == 0 and lo == 0 then
		return 0
	end
	local sign = (se >= 32768) and -1 or 1
	local exponent = bit32.band(se, 0x7FFF)
	if exponent == 0x7FFF then
		return sign * math.huge
	end
	local mantissa = hi * 4294967296 + lo
	return sign * mantissa * 2 ^ (exponent - 16383 - 63)
end

-- Strings / variable-length --------------------------------------------------

function ByteReader:str(n)
	self:need(n, "string")
	local s = buffer.readstring(self.buf, self.pos, n)
	self.pos += n
	return s
end

-- Fixed-size field, truncated at the first NUL (SF2 names).
function ByteReader:cstr(n)
	local s = self:str(n)
	local z = string.find(s, "\0", 1, true)
	return z and string.sub(s, 1, z - 1) or s
end

-- MIDI variable-length quantity (max 4 bytes).
function ByteReader:varlen()
	local value = 0
	for _ = 1, 4 do
		local b = self:u8()
		value = value * 128 + bit32.band(b, 0x7F)
		if b < 0x80 then
			return value
		end
	end
	fail(self, "variable-length quantity longer than 4 bytes")
	return value
end

return ByteReader
