--!native
--!optimize 2
-- Opus range decoder (RFC 6716 section 4.1): the entropy decoder that CELT and SILK both read their symbols with.
-- Ported from libopus celt/entdec.c and entcode.c (BSD-3-Clause, see the notice in the Opus module).
--
--   local ec = Entropy.new(buf, offset, length)   -- a frame's bytes inside a buffer
--   ec:decode(ft) / ec:update(fl, fh, ft)          -- a symbol from a frequency table of total ft
--   ec:decodeBin(bits), ec:bitLogp(logp), ec:icdf(table, ftb, base?), ec:uint(ft), ec:bits(n)
--   ec:tell() (bits used, rounded up), ec:tellFrac() (in 1/8 bits)

local Entropy = {}
Entropy.__index = Entropy

local CODE_TOP = 2147483648 -- 2^31
local CODE_BOT = 8388608 -- 2^23
local CODE_MASK = 2147483648 -- values are kept below CODE_TOP

-- floor(log2(v)) + 1; 0 for 0
local function ilog(v)
	if v <= 0 then
		return 0
	end
	return 32 - bit32.countlz(v)
end
Entropy.ilog = ilog

local function readByte(self)
	local o = self.offs
	if o < self.storage then
		self.offs = o + 1
		return buffer.readu8(self.buf, self.base + o)
	end
	return 0
end

local function readByteFromEnd(self)
	local e = self.endOffs
	if e < self.storage then
		e += 1
		self.endOffs = e
		return buffer.readu8(self.buf, self.base + self.storage - e)
	end
	return 0
end

local function normalize(self)
	while self.rng <= CODE_BOT do
		self.nbitsTotal += 8
		self.rng *= 256
		local sym = self.rem
		self.rem = readByte(self)
		sym = (sym * 256 + self.rem) // 2
		self.val = (self.val * 256 + (255 - sym % 256)) % CODE_MASK
	end
end

function Entropy.new(buf, offset, length)
	local self = setmetatable({
		buf = buf, base = offset or 0, storage = length or (buffer.len(buf) - (offset or 0)),
		endOffs = 0, endWindow = 0, nendBits = 0,
		nbitsTotal = 33 - 24, -- EC_CODE_BITS + 1 - ((EC_CODE_BITS - EC_CODE_EXTRA) / EC_SYM_BITS) * EC_SYM_BITS
		offs = 0, rng = 128, val = 0, ext = 0, rem = 0, error = 0,
	}, Entropy)
	self.rem = readByte(self)
	self.val = self.rng - 1 - (self.rem // 2)
	normalize(self)
	return self
end

function Entropy:decode(ft)
	self.ext = self.rng // ft
	local s = self.val // self.ext
	return ft - math.min(s + 1, ft)
end

function Entropy:decodeBin(bits)
	self.ext = self.rng // (2 ^ bits)
	local s = self.val // self.ext
	local t = 2 ^ bits
	return t - math.min(s + 1, t)
end

function Entropy:update(fl, fh, ft)
	local s = self.ext * (ft - fh)
	self.val -= s
	if fl > 0 then
		self.rng = self.ext * (fh - fl)
	else
		self.rng -= s
	end
	normalize(self)
end

-- a bit that is 1 with probability 1 / 2^logp
function Entropy:bitLogp(logp)
	local r, d = self.rng, self.val
	local s = r // (2 ^ logp)
	local ret = d < s
	if not ret then
		self.val = d - s
		self.rng = r - s
	else
		self.rng = s
	end
	normalize(self)
	return ret and 1 or 0
end

-- a symbol from an "inverse CDF" table (values start at icdf[base], 1-based Luau array; base defaults to 1)
function Entropy:icdf(icdf, ftb, base)
	base = base or 1
	local s, d = self.rng, self.val
	local r = s // (2 ^ ftb)
	local ret = -1
	local t
	repeat
		t = s
		ret += 1
		s = r * icdf[base + ret]
	until d >= s
	self.val = d - s
	self.rng = t - s
	normalize(self)
	return ret
end

function Entropy:bits(n)
	if n == 0 then
		return 0
	end
	local window, available = self.endWindow, self.nendBits
	if available < n then
		repeat
			window += readByteFromEnd(self) * (2 ^ available)
			available += 8
		until available > 24
	end
	local p = 2 ^ n
	local ret = window % p
	window = window // p
	available -= n
	self.endWindow = window
	self.nendBits = available
	self.nbitsTotal += n
	return ret
end

function Entropy:uint(ft)
	ft -= 1
	local ftb = ilog(ft)
	if ftb > 8 then
		ftb -= 8
		local ft1 = ft // (2 ^ ftb) + 1
		local s = self:decode(ft1)
		self:update(s, s + 1, ft1)
		local t = s * (2 ^ ftb) + self:bits(ftb)
		if t <= ft then
			return t
		end
		self.error = 1
		return ft
	end
	ft += 1
	local s = self:decode(ft)
	self:update(s, s + 1, ft)
	return s
end

function Entropy:tell()
	return self.nbitsTotal - ilog(self.rng)
end

local CORRECTION = { 35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535 }
function Entropy:tellFrac()
	local nbits = self.nbitsTotal * 8
	local l = ilog(self.rng)
	local r = self.rng // (2 ^ (l - 16))
	local b = (r // 4096) - 8
	if r > CORRECTION[b + 1] then
		b += 1
	end
	l = l * 8 + b
	return nbits - l
end

return Entropy
