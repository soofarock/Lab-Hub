--!native
--!optimize 2
-- DEFLATE (RFC 1951) and zlib (RFC 1950) decompression. Roblox's EncodingService only does zstd, and PNG
-- (and WebP lossless's sibling formats) store their pixels deflated.
--
--   local out, len = Inflate.zlib(buf, pos?, sizeHint?)    -- zlib stream starting at byte pos (0-based)
--   local out, len, endPos = Inflate.raw(buf, pos?, sizeHint?)
-- `out` is a buffer whose first `len` bytes are the data (it may be longer).

local Inflate = {}

local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
	4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- canonical Huffman lookup: index = the next maxLen bits (LSB first), value = symbol * 16 + code length
local function buildTable(lengths, n)
	local maxLen = 0
	local count = table.create(16, 0)
	for i = 0, n - 1 do
		local l = lengths[i]
		if l > 0 then
			count[l] += 1
			if l > maxLen then
				maxLen = l
			end
		end
	end
	if maxLen == 0 then
		return nil, 0
	end
	local nextCode = table.create(16, 0)
	local code = 0
	for bits = 1, maxLen do
		code = (code + (bits > 1 and count[bits - 1] or 0)) * 2
		nextCode[bits] = code
	end
	local size = lshift(1, maxLen)
	local tbl = table.create(size, 0)
	for sym = 0, n - 1 do
		local l = lengths[sym]
		if l > 0 then
			local c = nextCode[l]
			nextCode[l] = c + 1
			-- reverse the l-bit code (deflate sends Huffman codes MSB first inside an LSB-first stream)
			local r = 0
			for _ = 1, l do
				r = r * 2 + band(c, 1)
				c = rshift(c, 1)
			end
			local v = sym * 16 + l
			local step = lshift(1, l)
			for idx = r, size - 1, step do
				tbl[idx + 1] = v
			end
		end
	end
	return tbl, maxLen
end

local FIXED_LIT, FIXED_LIT_BITS, FIXED_DIST, FIXED_DIST_BITS
do
	local l = {}
	for i = 0, 143 do
		l[i] = 8
	end
	for i = 144, 255 do
		l[i] = 9
	end
	for i = 256, 279 do
		l[i] = 7
	end
	for i = 280, 287 do
		l[i] = 8
	end
	FIXED_LIT, FIXED_LIT_BITS = buildTable(l, 288)
	local d = {}
	for i = 0, 29 do
		d[i] = 5
	end
	FIXED_DIST, FIXED_DIST_BITS = buildTable(d, 30)
end

function Inflate.raw(src, pos, sizeHint)
	pos = pos or 0
	local srcLen = buffer.len(src)
	local cap = math.max(sizeHint or 0, srcLen * 4, 1024)
	local out = buffer.create(cap)
	local n = 0 -- bytes written
	local bitbuf, bitcnt = 0, 0

	local function need(k)
		while bitcnt < k do
			local byte = 0
			if pos < srcLen then
				byte = buffer.readu8(src, pos)
			elseif pos > srcLen + 4 then
				error("Inflate: unexpected end of data")
			end
			pos += 1
			bitbuf = bor(bitbuf, lshift(byte, bitcnt))
			bitcnt += 8
		end
	end
	local function bits(k)
		if k == 0 then
			return 0
		end
		need(k)
		local v = band(bitbuf, lshift(1, k) - 1)
		bitbuf = rshift(bitbuf, k)
		bitcnt -= k
		return v
	end
	local function decode(tbl, maxLen)
		need(maxLen)
		local v = tbl[band(bitbuf, lshift(1, maxLen) - 1) + 1]
		local l = band(v, 15)
		if l == 0 then
			error("Inflate: bad Huffman code")
		end
		bitbuf = rshift(bitbuf, l)
		bitcnt -= l
		return rshift(v, 4)
	end
	local function grow(extra)
		if n + extra > cap then
			while n + extra > cap do
				cap *= 2
			end
			local nb = buffer.create(cap)
			buffer.copy(nb, 0, out, 0, n)
			out = nb
		end
	end

	local final = 0
	repeat
		final = bits(1)
		local btype = bits(2)
		if btype == 0 then
			-- stored block: skip to a byte boundary (any whole bytes left in the bit buffer are data)
			local drop = bitcnt % 8
			bitbuf = rshift(bitbuf, drop)
			bitcnt -= drop
			while bitcnt > 0 do -- give back whole buffered bytes
				pos -= 1
				bitcnt -= 8
			end
			bitbuf, bitcnt = 0, 0
			local len = buffer.readu16(src, pos)
			pos += 4
			grow(len)
			buffer.copy(out, n, src, pos, len)
			pos += len
			n += len
		elseif btype == 1 or btype == 2 then
			local lit, litBits, dist, distBits
			if btype == 1 then
				lit, litBits, dist, distBits = FIXED_LIT, FIXED_LIT_BITS, FIXED_DIST, FIXED_DIST_BITS
			else
				local hlit = bits(5) + 257
				local hdist = bits(5) + 1
				local hclen = bits(4) + 4
				local cl = {}
				for i = 0, 18 do
					cl[i] = 0
				end
				for i = 1, hclen do
					cl[CL_ORDER[i]] = bits(3)
				end
				local clt, clBits = buildTable(cl, 19)
				local lens = {}
				local i = 0
				while i < hlit + hdist do
					local sym = decode(clt, clBits)
					if sym < 16 then
						lens[i] = sym
						i += 1
					else
						local rep, val
						if sym == 16 then
							if i == 0 then
								error("Inflate: repeat with no previous length")
							end
							val, rep = lens[i - 1], 3 + bits(2)
						elseif sym == 17 then
							val, rep = 0, 3 + bits(3)
						else
							val, rep = 0, 11 + bits(7)
						end
						for _ = 1, rep do
							lens[i] = val
							i += 1
						end
					end
				end
				local ll, dl = {}, {}
				for k = 0, hlit - 1 do
					ll[k] = lens[k]
				end
				for k = 0, hdist - 1 do
					dl[k] = lens[hlit + k]
				end
				lit, litBits = buildTable(ll, hlit)
				dist, distBits = buildTable(dl, hdist)
			end
			while true do
				local sym = decode(lit, litBits)
				if sym < 256 then
					if n >= cap then
						grow(1)
					end
					buffer.writeu8(out, n, sym)
					n += 1
				elseif sym == 256 then
					break
				else
					local li = sym - 256
					local len = LEN_BASE[li] + bits(LEN_EXTRA[li])
					if not dist then
						error("Inflate: distance code with no distance table")
					end
					local di = decode(dist, distBits) + 1
					local d = DIST_BASE[di] + bits(DIST_EXTRA[di])
					if d > n then
						error("Inflate: distance too far back")
					end
					grow(len)
					local from = n - d
					if d >= len then
						buffer.copy(out, n, out, from, len)
					else
						for k = 0, len - 1 do
							buffer.writeu8(out, n + k, buffer.readu8(out, from + k))
						end
					end
					n += len
				end
			end
		else
			error("Inflate: invalid block type")
		end
	until final == 1
	-- unused whole bytes in the bit buffer belong to what follows the stream
	pos -= bitcnt // 8
	return out, n, pos
end

function Inflate.zlib(src, pos, sizeHint)
	pos = pos or 0
	local cmf, flg = buffer.readu8(src, pos), buffer.readu8(src, pos + 1)
	if band(cmf, 15) ~= 8 or (cmf * 256 + flg) % 31 ~= 0 then
		error("Inflate: not a zlib stream")
	end
	if band(flg, 32) ~= 0 then
		error("Inflate: zlib preset dictionaries are not supported")
	end
	local out, n, endPos = Inflate.raw(src, pos + 2, sizeHint)
	return out, n, endPos + 4 -- adler32 follows
end

return Inflate
