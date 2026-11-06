--!native
--!optimize 2
-- Base64 (RFC 4648) for storing binary files and encoded clips as text in ModuleScripts.

local Base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC = table.create(64)
local DEC = table.create(256, -1)
for i = 1, 64 do
	local c = string.byte(ALPHABET, i)
	ENC[i - 1] = c
	DEC[c + 1] = i - 1
end

-- input: buffer or string. Returns string.
function Base64.encode(input)
	local src = type(input) == "string" and buffer.fromstring(input) or input
	local n = buffer.len(src)
	local outLen = math.ceil(n / 3) * 4
	local out = buffer.create(outLen)
	local o = 0
	local i = 0
	while i + 2 < n do
		local v = buffer.readu8(src, i) * 65536 + buffer.readu8(src, i + 1) * 256 + buffer.readu8(src, i + 2)
		buffer.writeu8(out, o, ENC[bit32.rshift(v, 18)])
		buffer.writeu8(out, o + 1, ENC[bit32.band(bit32.rshift(v, 12), 63)])
		buffer.writeu8(out, o + 2, ENC[bit32.band(bit32.rshift(v, 6), 63)])
		buffer.writeu8(out, o + 3, ENC[bit32.band(v, 63)])
		i += 3
		o += 4
	end
	local rest = n - i
	if rest > 0 then
		local v = buffer.readu8(src, i) * 65536 + (rest == 2 and buffer.readu8(src, i + 1) * 256 or 0)
		buffer.writeu8(out, o, ENC[bit32.rshift(v, 18)])
		buffer.writeu8(out, o + 1, ENC[bit32.band(bit32.rshift(v, 12), 63)])
		buffer.writeu8(out, o + 2, rest == 2 and ENC[bit32.band(bit32.rshift(v, 6), 63)] or 61)
		buffer.writeu8(out, o + 3, 61)
	end
	return buffer.tostring(out)
end

-- Ignores whitespace. Returns buffer.
function Base64.decode(text)
	text = string.gsub(text, "[%s]", "")
	local src = buffer.fromstring(text)
	local n = buffer.len(src)
	assert(n % 4 == 0, "Base64 input length must be a multiple of 4")
	local pad = 0
	if n > 0 and buffer.readu8(src, n - 1) == 61 then
		pad += 1
		if buffer.readu8(src, n - 2) == 61 then
			pad += 1
		end
	end
	local out = buffer.create(n // 4 * 3 - pad)
	local outLen = buffer.len(out)
	local o = 0
	for i = 0, n - 1, 4 do
		local a = DEC[buffer.readu8(src, i) + 1]
		local b = DEC[buffer.readu8(src, i + 1) + 1]
		local c3 = buffer.readu8(src, i + 2)
		local d4 = buffer.readu8(src, i + 3)
		local c = c3 == 61 and 0 or DEC[c3 + 1]
		local d = d4 == 61 and 0 or DEC[d4 + 1]
		if a < 0 or b < 0 or c < 0 or d < 0 then
			error("invalid Base64 character near position " .. i)
		end
		local v = a * 262144 + b * 4096 + c * 64 + d
		buffer.writeu8(out, o, bit32.rshift(v, 16))
		if o + 1 < outLen then
			buffer.writeu8(out, o + 1, bit32.band(bit32.rshift(v, 8), 255))
		end
		if o + 2 < outLen then
			buffer.writeu8(out, o + 2, bit32.band(v, 255))
		end
		o += 3
	end
	return out
end

return Base64
