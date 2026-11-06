--!optimize 2
-- Growable binary writer backed by a Luau buffer. Mirrors ByteReader's methods.

local ByteWriter = {}
ByteWriter.__index = ByteWriter

function ByteWriter.new(capacity)
	return setmetatable({ buf = buffer.create(math.max(16, capacity or 256)), pos = 0 }, ByteWriter)
end

function ByteWriter:reserve(n)
	local need = self.pos + n
	local cap = buffer.len(self.buf)
	if need <= cap then
		return
	end
	while cap < need do
		cap *= 2
	end
	local nb = buffer.create(cap)
	buffer.copy(nb, 0, self.buf, 0, self.pos)
	self.buf = nb
end

function ByteWriter:tell()
	return self.pos
end

-- Overwrite a little-endian u32 at an earlier offset (chunk size back-patching).
function ByteWriter:patchU32(at, v)
	buffer.writeu32(self.buf, at, v)
end

function ByteWriter:patchU32be(at, v)
	buffer.writeu32(self.buf, at, bit32.byteswap(v))
end

function ByteWriter:u8(v)
	self:reserve(1)
	buffer.writeu8(self.buf, self.pos, v)
	self.pos += 1
end

function ByteWriter:i8(v)
	self:reserve(1)
	buffer.writei8(self.buf, self.pos, v)
	self.pos += 1
end

function ByteWriter:u16(v)
	self:reserve(2)
	buffer.writeu16(self.buf, self.pos, v)
	self.pos += 2
end

function ByteWriter:i16(v)
	self:reserve(2)
	buffer.writei16(self.buf, self.pos, v)
	self.pos += 2
end

function ByteWriter:u24(v)
	self:u8(v % 256)
	self:u8(math.floor(v / 256) % 256)
	self:u8(math.floor(v / 65536) % 256)
end

function ByteWriter:i24(v)
	if v < 0 then
		v += 16777216
	end
	self:u24(v)
end

function ByteWriter:u32(v)
	self:reserve(4)
	buffer.writeu32(self.buf, self.pos, v)
	self.pos += 4
end

function ByteWriter:i32(v)
	self:reserve(4)
	buffer.writei32(self.buf, self.pos, v)
	self.pos += 4
end

function ByteWriter:f32(v)
	self:reserve(4)
	buffer.writef32(self.buf, self.pos, v)
	self.pos += 4
end

function ByteWriter:f64(v)
	self:reserve(8)
	buffer.writef64(self.buf, self.pos, v)
	self.pos += 8
end

function ByteWriter:u16be(v)
	self:u8(math.floor(v / 256) % 256)
	self:u8(v % 256)
end

function ByteWriter:i16be(v)
	if v < 0 then
		v += 65536
	end
	self:u16be(v)
end

function ByteWriter:i24be(v)
	if v < 0 then
		v += 16777216
	end
	self:u8(math.floor(v / 65536) % 256)
	self:u8(math.floor(v / 256) % 256)
	self:u8(v % 256)
end

function ByteWriter:u32be(v)
	self:reserve(4)
	buffer.writeu32(self.buf, self.pos, bit32.byteswap(v))
	self.pos += 4
end

function ByteWriter:i32be(v)
	if v < 0 then
		v += 4294967296
	end
	self:u32be(v)
end

function ByteWriter:f32be(v)
	local tmp = buffer.create(4)
	buffer.writef32(tmp, 0, v)
	self:u32be(buffer.readu32(tmp, 0))
end

-- 80-bit IEEE 754 extended, big-endian (AIFF COMM sample rate).
function ByteWriter:f80be(v)
	if v == 0 then
		self:u16be(0)
		self:u32be(0)
		self:u32be(0)
		return
	end
	local sign = 0
	if v < 0 then
		sign = 0x8000
		v = -v
	end
	local e = math.floor(math.log(v, 2))
	-- guard against log rounding
	if 2 ^ e > v then
		e -= 1
	elseif 2 ^ (e + 1) <= v then
		e += 1
	end
	local scaled = v / 2 ^ e * 2 ^ 31 -- [2^31, 2^32)
	local hi = math.floor(scaled)
	local lo = math.floor((scaled - hi) * 4294967296)
	self:u16be(sign + e + 16383)
	self:u32be(hi)
	self:u32be(lo)
end

function ByteWriter:str(s)
	self:reserve(#s)
	buffer.writestring(self.buf, self.pos, s)
	self.pos += #s
end

-- Fixed-size field, NUL padded.
function ByteWriter:fixedStr(s, n)
	s = string.sub(s, 1, n)
	self:str(s)
	self:zeros(n - #s)
end

function ByteWriter:zeros(n)
	self:reserve(n)
	buffer.fill(self.buf, self.pos, 0, n)
	self.pos += n
end

function ByteWriter:bytes(b, offset, count)
	offset = offset or 0
	count = count or (buffer.len(b) - offset)
	self:reserve(count)
	buffer.copy(self.buf, self.pos, b, offset, count)
	self.pos += count
end

function ByteWriter:varlen(v)
	assert(v >= 0 and v <= 0x0FFFFFFF, "varlen out of range")
	local groups = { v % 128 }
	v = math.floor(v / 128)
	while v > 0 do
		table.insert(groups, 1, v % 128 + 128)
		v = math.floor(v / 128)
	end
	for _, g in ipairs(groups) do
		self:u8(g)
	end
end

function ByteWriter:toBuffer()
	local out = buffer.create(self.pos)
	buffer.copy(out, 0, self.buf, 0, self.pos)
	return out
end

function ByteWriter:toString()
	return buffer.readstring(self.buf, 0, self.pos)
end

return ByteWriter
