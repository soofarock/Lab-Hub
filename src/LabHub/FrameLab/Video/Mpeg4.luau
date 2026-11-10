--!native
--!optimize 2
-- FrameLab MPEG-4 Part 2 video decoder (ISO/IEC 14496-2 Simple and Advanced Simple profile: Xvid, DivX 4/5/6, FFmpeg's
-- "mpeg4") in pure Luau. I, P, B and S (global motion) pictures, 4 motion vectors per macroblock, quarter-sample
-- motion, H.263 and MPEG quantisation, AC/DC prediction, video packets, interlaced (field) DCT and field motion, packed
-- B frames. Not read: static sprites, data partitioning, shapes and scalability (all rare outside test streams).
-- The pixels are FFmpeg's: its "simple" IDCT, or the Xvid IDCT for Xvid streams, and its workarounds for old Xvid and
-- DivX encoders (known from the stream's user data, or from the AVI FourCC when there is none).
--
--   local dec = Mpeg4.new(config, fourcc)   config: the VOL header bytes (an MP4 / MKV track's setup), optional;
--       fourcc: the AVI stream's FourCC ("XVID", "DIVX", ...), optional
--   local pic = dec:decodeSample(buf, pos, size)
--       one VOP (any VOL / GOV / user data headers before it may come along) -> { Y, U, V, ys, cs, yo, co } in decode
--       order; nil when the VOP is "not coded" (the picture before it stays); errors on damaged data or a missing
--       reference picture
--   dec.width, dec.height, dec.pictType (1 I, 2 P, 3 B, 4 S), dec.fps (from the VOL, or nil)
--
--   local p = Mpeg4.parser(config)      splits a stream into VOPs and times them (for AVI, where frames have no times
--   p:vops(buf, pos, size) -> { { pos, size, type, coded, time } ... }   (packed AVI frames hold two VOPs; time in
--       seconds from the stream's start, display order)

local Mpeg4 = {}
Mpeg4.__index = Mpeg4

local band, bor, bxor, lshift, rshift, bswap = bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift, bit32.byteswap
local readu8, writeu8, readu32, writeu32 = buffer.readu8, buffer.writeu8, buffer.readu32, buffer.writeu32

---------------------------------------------------------------------------------------------------------------------------
-- tables

local ZIGZAG = {
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}
local ALT_H = {
	0, 1, 2, 3, 8, 9, 16, 17, 10, 11, 4, 5, 6, 7, 15, 14, 13, 12, 19, 18, 24, 25, 32, 33, 26, 27, 20, 21, 22, 23, 28, 29,
	30, 31, 34, 35, 40, 41, 48, 49, 42, 43, 36, 37, 38, 39, 44, 45, 46, 47, 50, 51, 56, 57, 58, 59, 52, 53, 54, 55, 60, 61, 62, 63,
}
local ALT_V = {
	0, 8, 16, 24, 1, 9, 2, 10, 17, 25, 32, 40, 48, 56, 57, 49, 41, 33, 26, 18, 3, 11, 4, 12, 19, 27, 34, 42, 50, 58, 35, 43,
	51, 59, 20, 28, 5, 13, 6, 14, 21, 29, 36, 44, 52, 60, 37, 45, 53, 61, 22, 30, 7, 15, 23, 31, 38, 46, 54, 62, 39, 47, 55, 63,
}
local DEFAULT_INTRA = {
	8, 17, 18, 19, 21, 23, 25, 27, 17, 18, 19, 21, 23, 25, 27, 28, 20, 21, 22, 23, 24, 26, 28, 30, 21, 22, 23, 24, 26, 28, 30, 32,
	22, 23, 24, 26, 28, 30, 32, 35, 23, 24, 26, 28, 30, 32, 35, 38, 25, 26, 28, 30, 32, 35, 38, 41, 27, 28, 30, 32, 35, 38, 41, 45,
}
local DEFAULT_INTER = {
	16, 17, 18, 19, 20, 21, 22, 23, 17, 18, 19, 20, 21, 22, 23, 24, 18, 19, 20, 21, 22, 23, 24, 25, 19, 20, 21, 22, 23, 24, 26, 27,
	20, 21, 22, 23, 25, 26, 27, 28, 21, 22, 23, 24, 26, 27, 28, 30, 22, 23, 24, 26, 27, 28, 30, 31, 23, 24, 25, 27, 28, 30, 31, 33,
}
local Y_DC_SCALE = { [0] = 0, 8, 8, 8, 8, 10, 12, 14, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 34, 36, 38, 40, 42, 44, 46 }
local C_DC_SCALE = { [0] = 0, 8, 8, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18, 19, 20, 21, 22, 23, 24, 25 }
local DC_THRESHOLD = { [0] = 99, 13, 15, 17, 19, 21, 23, 0 }
local QUANT_DELTA = { [0] = -1, -2, 1, 2 }

-- VLC lookup: a buffer of 2^bits u32 entries, value * 32 + code length (0: no such code)
local function vlc(bits, codes)
	local t = buffer.create(4 * 2 ^ bits)
	for _, c in ipairs(codes) do
		local code, len, value = c[1], c[2], c[3]
		local shift = bits - len
		local first = code * 2 ^ shift
		for k = first, first + 2 ^ shift - 1 do
			writeu32(t, 4 * k, value * 32 + len)
		end
	end
	return t
end

local function pairsTable(t, offset)
	local codes = {}
	for i = 1, #t // 2 do
		codes[i] = { t[2 * i - 1], t[2 * i], i - 1 + (offset or 0) }
	end
	return codes
end

local DC_LUM = vlc(11, pairsTable({ 3, 3, 3, 2, 2, 2, 2, 3, 1, 3, 1, 4, 1, 5, 1, 6, 1, 7, 1, 8, 1, 9, 1, 10, 1, 11 }))
local DC_CHROM = vlc(12, pairsTable({ 3, 2, 2, 2, 1, 2, 1, 3, 1, 4, 1, 5, 1, 6, 1, 7, 1, 8, 1, 9, 1, 10, 1, 11, 1, 12 }))
local MCBPC_INTRA = vlc(9, pairsTable({ 1, 1, 1, 3, 2, 3, 3, 3, 1, 4, 1, 6, 2, 6, 3, 6, 1, 9 }))
local MCBPC_INTER
do
	local code = { 1, 3, 2, 5, 3, 4, 3, 3, 3, 7, 6, 5, 4, 4, 3, 2, 2, 5, 4, 5, 1, 0, 0, 0, 2, 12, 14, 15 }
	local bits = { 1, 4, 4, 6, 5, 8, 8, 7, 3, 7, 7, 9, 6, 9, 9, 9, 3, 7, 7, 8, 9, 0, 0, 0, 11, 13, 13, 13 }
	local codes = {}
	for i = 1, 28 do
		if bits[i] > 0 then
			table.insert(codes, { code[i], bits[i], i - 1 })
		end
	end
	MCBPC_INTER = vlc(13, codes)
end
local CBPY = vlc(6, pairsTable({ 3, 4, 5, 5, 4, 5, 9, 4, 3, 5, 7, 4, 2, 6, 11, 4, 2, 5, 3, 6, 5, 4, 10, 4, 4, 4, 8, 4, 6, 4, 3, 2 }))
local MVTAB = vlc(12, pairsTable({
	1, 1, 1, 2, 1, 3, 1, 4, 3, 6, 5, 7, 4, 7, 3, 7, 11, 9, 10, 9, 9, 9, 17, 10, 16, 10, 15, 10, 14, 10, 13, 10, 12, 10, 11, 10,
	10, 10, 9, 10, 8, 10, 7, 10, 6, 10, 5, 10, 4, 10, 7, 11, 6, 11, 5, 11, 4, 11, 3, 11, 2, 11, 3, 12, 2, 12,
}))
local MBTYPE_B = vlc(4, pairsTable({ 1, 1, 1, 2, 1, 3, 1, 4 }))

-- DCT coefficient tables: value = level + 64 * run + 4096 * last; 0 = escape
local RL_INTRA, RL_INTER, MAXLEVEL_INTRA, MAXRUN_INTRA, MAXLEVEL_INTER, MAXRUN_INTER
do
	local function build(codes, runs, levels, lastFrom)
		local list = {}
		local maxLevel = { [0] = {}, [1] = {} }
		local maxRun = { [0] = {}, [1] = {} }
		for i = 1, #runs do
			local last = (i - 1) >= lastFrom and 1 or 0
			local run, level = runs[i], levels[i]
			list[i] = { codes[2 * i - 1], codes[2 * i], level + 64 * run + 4096 * last }
			maxLevel[last][run] = math.max(maxLevel[last][run] or 0, level)
			maxRun[last][level] = math.max(maxRun[last][level] or 0, run)
		end
		table.insert(list, { codes[2 * #runs + 1], codes[2 * #runs + 2], 0 })
		return vlc(12, list), maxLevel, maxRun
	end
	local intraCodes = {
		0x2, 2, 0x6, 3, 0xf, 4, 0xd, 5, 0xc, 5, 0x15, 6, 0x13, 6, 0x12, 6, 0x17, 7, 0x1f, 8, 0x1e, 8, 0x1d, 8, 0x25, 9, 0x24, 9,
		0x23, 9, 0x21, 9, 0x21, 10, 0x20, 10, 0xf, 10, 0xe, 10, 0x7, 11, 0x6, 11, 0x20, 11, 0x21, 11, 0x50, 12, 0x51, 12, 0x52, 12,
		0xe, 4, 0x14, 6, 0x16, 7, 0x1c, 8, 0x20, 9, 0x1f, 9, 0xd, 10, 0x22, 11, 0x53, 12, 0x55, 12, 0xb, 5, 0x15, 7, 0x1e, 9,
		0xc, 10, 0x56, 12, 0x11, 6, 0x1b, 8, 0x1d, 9, 0xb, 10, 0x10, 6, 0x22, 9, 0xa, 10, 0xd, 6, 0x1c, 9, 0x8, 10, 0x12, 7,
		0x1b, 9, 0x54, 12, 0x14, 7, 0x1a, 9, 0x57, 12, 0x19, 8, 0x9, 10, 0x18, 8, 0x23, 11, 0x17, 8, 0x19, 9, 0x18, 9, 0x7, 10,
		0x58, 12, 0x7, 4, 0xc, 6, 0x16, 8, 0x17, 9, 0x6, 10, 0x5, 11, 0x4, 11, 0x59, 12, 0xf, 6, 0x16, 9, 0x5, 10, 0xe, 6,
		0x4, 10, 0x11, 7, 0x24, 11, 0x10, 7, 0x25, 11, 0x13, 7, 0x5a, 12, 0x15, 8, 0x5b, 12, 0x14, 8, 0x13, 8, 0x1a, 8,
		0x15, 9, 0x14, 9, 0x13, 9, 0x12, 9, 0x11, 9, 0x26, 11, 0x27, 11, 0x5c, 12, 0x5d, 12, 0x5e, 12, 0x5f, 12, 0x3, 7,
	}
	local intraLevel = {
		1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 1, 2, 3, 4, 5,
		6, 7, 8, 9, 10, 1, 2, 3, 4, 5, 1, 2, 3, 4, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 1, 2, 1, 1,
		1, 1, 1, 1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1,
		1, 1, 1, 1, 1, 1,
	}
	local intraRun = {
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1,
		1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 7, 7, 7, 8, 8, 9, 9, 10, 11,
		12, 13, 14, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 14,
		15, 16, 17, 18, 19, 20,
	}
	local interCodes = {
		0x2, 2, 0xf, 4, 0x15, 6, 0x17, 7, 0x1f, 8, 0x25, 9, 0x24, 9, 0x21, 10, 0x20, 10, 0x7, 11, 0x6, 11, 0x20, 11, 0x6, 3,
		0x14, 6, 0x1e, 8, 0xf, 10, 0x21, 11, 0x50, 12, 0xe, 4, 0x1d, 8, 0xe, 10, 0x51, 12, 0xd, 5, 0x23, 9, 0xd, 10, 0xc, 5,
		0x22, 9, 0x52, 12, 0xb, 5, 0xc, 10, 0x53, 12, 0x13, 6, 0xb, 10, 0x54, 12, 0x12, 6, 0xa, 10, 0x11, 6, 0x9, 10, 0x10, 6,
		0x8, 10, 0x16, 7, 0x55, 12, 0x15, 7, 0x14, 7, 0x1c, 8, 0x1b, 8, 0x21, 9, 0x20, 9, 0x1f, 9, 0x1e, 9, 0x1d, 9, 0x1c, 9,
		0x1b, 9, 0x1a, 9, 0x22, 11, 0x23, 11, 0x56, 12, 0x57, 12, 0x7, 4, 0x19, 9, 0x5, 11, 0xf, 6, 0x4, 11, 0xe, 6, 0xd, 6,
		0xc, 6, 0x13, 7, 0x12, 7, 0x11, 7, 0x10, 7, 0x1a, 8, 0x19, 8, 0x18, 8, 0x17, 8, 0x16, 8, 0x15, 8, 0x14, 8, 0x13, 8,
		0x18, 9, 0x17, 9, 0x16, 9, 0x15, 9, 0x14, 9, 0x13, 9, 0x12, 9, 0x11, 9, 0x7, 10, 0x6, 10, 0x5, 10, 0x4, 10, 0x24, 11,
		0x25, 11, 0x26, 11, 0x27, 11, 0x58, 12, 0x59, 12, 0x5a, 12, 0x5b, 12, 0x5c, 12, 0x5d, 12, 0x5e, 12, 0x5f, 12, 0x3, 7,
	}
	local interLevel = {
		1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1,
		2, 3, 1, 2, 1, 2, 1, 2, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 3, 1, 2, 1,
		1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
		1, 1, 1, 1, 1, 1,
	}
	local interRun = {
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6,
		6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 0, 0, 0, 1, 1, 2,
		3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
		35, 36, 37, 38, 39, 40,
	}
	RL_INTRA, MAXLEVEL_INTRA, MAXRUN_INTRA = build(intraCodes, intraRun, intraLevel, 67)
	RL_INTER, MAXLEVEL_INTER, MAXRUN_INTER = build(interCodes, interRun, interLevel, 58)
end

---------------------------------------------------------------------------------------------------------------------------
-- bits (the sample is copied to S, with zero bytes after it)

local S = buffer.create(65536)
local SLEN = 0

local function peek(bp: number): number
	return lshift(bswap(readu32(S, rshift(bp, 3))), band(bp, 7))
end

local function getBits(bp: number, n: number): (number, number)
	if n == 0 then
		return 0, bp
	end
	return rshift(lshift(bswap(readu32(S, rshift(bp, 3))), band(bp, 7)), 32 - n), bp + n
end

local function getVlc(bp: number, t: buffer, bits: number): (number, number)
	local e = readu32(t, 4 * rshift(peek(bp), 32 - bits))
	local len = band(e, 31)
	if len == 0 then
		return -1, bp
	end
	return rshift(e, 5), bp + len
end

-- a signed value of n bits as sent for DC differences
local function getXbits(bp: number, n: number): (number, number)
	local v
	v, bp = getBits(bp, n)
	if v < 2 ^ (n - 1) then
		v -= 2 ^ n - 1
	end
	return v, bp
end

---------------------------------------------------------------------------------------------------------------------------
-- inverse DCT

local blk = table.create(64, 0)
local W1, W2, W3, W4, W5, W6, W7 = 22725, 21407, 19266, 16383, 12873, 8867, 4520

-- FFmpeg's simple IDCT: rows, then columns
local function simpleIdct(b, dst: buffer, off: number, stride: number, add: boolean)
	for r = 0, 7 do
		local o = r * 8 + 1
		local r0, r1, r2, r3, r4, r5, r6, r7 = b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4], b[o + 5], b[o + 6], b[o + 7]
		if r1 == 0 and r2 == 0 and r3 == 0 and r4 == 0 and r5 == 0 and r6 == 0 and r7 == 0 then
			if r0 ~= 0 then
				local v = r0 * 8
				b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4], b[o + 5], b[o + 6], b[o + 7] = v, v, v, v, v, v, v, v
			end
		else
			local a0 = W4 * r0 + 1024
			local a1, a2, a3 = a0, a0, a0
			a0 += W2 * r2
			a1 += W6 * r2
			a2 -= W6 * r2
			a3 -= W2 * r2
			local b0 = W1 * r1 + W3 * r3
			local b1 = W3 * r1 - W7 * r3
			local b2 = W5 * r1 - W1 * r3
			local b3 = W7 * r1 - W5 * r3
			a0 += W4 * r4 + W6 * r6
			a1 += -W4 * r4 - W2 * r6
			a2 += -W4 * r4 + W2 * r6
			a3 += W4 * r4 - W6 * r6
			b0 += W5 * r5 + W7 * r7
			b1 += -W1 * r5 - W5 * r7
			b2 += W7 * r5 + W3 * r7
			b3 += W3 * r5 - W1 * r7
			b[o] = (a0 + b0) // 2048
			b[o + 7] = (a0 - b0) // 2048
			b[o + 1] = (a1 + b1) // 2048
			b[o + 6] = (a1 - b1) // 2048
			b[o + 2] = (a2 + b2) // 2048
			b[o + 5] = (a2 - b2) // 2048
			b[o + 3] = (a3 + b3) // 2048
			b[o + 4] = (a3 - b3) // 2048
		end
	end
	for c = 1, 8 do
		local c0, c1, c2, c3, c4, c5, c6, c7 = b[c], b[c + 8], b[c + 16], b[c + 24], b[c + 32], b[c + 40], b[c + 48], b[c + 56]
		local a0 = W4 * (c0 + 32)
		local a1, a2, a3 = a0, a0, a0
		a0 += W2 * c2
		a1 += W6 * c2
		a2 -= W6 * c2
		a3 -= W2 * c2
		local b0 = W1 * c1 + W3 * c3
		local b1 = W3 * c1 - W7 * c3
		local b2 = W5 * c1 - W1 * c3
		local b3 = W7 * c1 - W5 * c3
		a0 += W4 * c4 + W6 * c6
		a1 += -W4 * c4 - W2 * c6
		a2 += -W4 * c4 + W2 * c6
		a3 += W4 * c4 - W6 * c6
		b0 += W5 * c5 + W7 * c7
		b1 += -W1 * c5 - W5 * c7
		b2 += W7 * c5 + W3 * c7
		b3 += W3 * c5 - W1 * c7
		local v0, v1, v2, v3 = (a0 + b0) // 1048576, (a1 + b1) // 1048576, (a2 + b2) // 1048576, (a3 + b3) // 1048576
		local v4, v5, v6, v7 = (a3 - b3) // 1048576, (a2 - b2) // 1048576, (a1 - b1) // 1048576, (a0 - b0) // 1048576
		local p = off + c - 1
		if add then
			writeu8(dst, p, math.clamp(readu8(dst, p) + v0, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v1, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v2, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v3, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v4, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v5, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v6, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v7, 0, 255))
		else
			writeu8(dst, p, math.clamp(v0, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v1, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v2, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v3, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v4, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v5, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v6, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v7, 0, 255))
		end
	end
end

-- Xvid's IDCT (as FFmpeg runs it for Xvid streams): rows with per-row tables and rounding, then columns in 16-bit
-- fixed point
local XTAB = {
	{ 22725, 21407, 19266, 16384, 12873, 8867, 4520 },
	{ 31521, 29692, 26722, 22725, 17855, 12299, 6270 },
	{ 29692, 27969, 25172, 21407, 16819, 11585, 5906 },
	{ 26722, 25172, 22654, 19266, 15137, 10426, 5315 },
}
local XROW_TAB = { XTAB[1], XTAB[2], XTAB[3], XTAB[4], XTAB[1], XTAB[4], XTAB[3], XTAB[2] }
local XROW_RND = { 65536, 3597, 2260, 1203, 0, 120, 512, 512 }
local TAN1, TAN2, TAN3, SQRT2 = 0x32EC, 0x6A0A, 0xAB0E, 0x5A82

local function xvidIdct(b, dst: buffer, off: number, stride: number, add: boolean)
	for r = 0, 7 do
		local o = r * 8 + 1
		local t = XROW_TAB[r + 1]
		local rnd = XROW_RND[r + 1]
		local c1, c2, c3, c4, c5, c6, c7 = t[1], t[2], t[3], t[4], t[5], t[6], t[7]
		local i0, i1, i2, i3, i4, i5, i6, i7 = b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4], b[o + 5], b[o + 6], b[o + 7]
		local left = i1 ~= 0 or i2 ~= 0 or i3 ~= 0
		local right = i5 ~= 0 or i6 ~= 0 or i7 ~= 0
		if not right and i4 == 0 then
			local k = c4 * i0 + rnd
			if left then
				local a0, a1, a2, a3 = k + c2 * i2, k + c6 * i2, k - c6 * i2, k - c2 * i2
				local b0 = c1 * i1 + c3 * i3
				local b1 = c3 * i1 - c7 * i3
				local b2 = c5 * i1 - c1 * i3
				local b3 = c7 * i1 - c5 * i3
				b[o], b[o + 1], b[o + 2], b[o + 3] = (a0 + b0) // 2048, (a1 + b1) // 2048, (a2 + b2) // 2048, (a3 + b3) // 2048
				b[o + 4], b[o + 5], b[o + 6], b[o + 7] = (a3 - b3) // 2048, (a2 - b2) // 2048, (a1 - b1) // 2048, (a0 - b0) // 2048
			else
				local a0 = k // 2048
				if a0 ~= 0 then
					b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4], b[o + 5], b[o + 6], b[o + 7] = a0, a0, a0, a0, a0, a0, a0, a0
				end
			end
		elseif not left and not right then
			local a0 = (rnd + c4 * (i0 + i4)) // 2048
			local a1 = (rnd + c4 * (i0 - i4)) // 2048
			b[o], b[o + 3], b[o + 4], b[o + 7] = a0, a0, a0, a0
			b[o + 1], b[o + 2], b[o + 5], b[o + 6] = a1, a1, a1, a1
		else
			local k = c4 * i0 + rnd
			local a0 = k + c2 * i2 + c4 * i4 + c6 * i6
			local a1 = k + c6 * i2 - c4 * i4 - c2 * i6
			local a2 = k - c6 * i2 - c4 * i4 + c2 * i6
			local a3 = k - c2 * i2 + c4 * i4 - c6 * i6
			local b0 = c1 * i1 + c3 * i3 + c5 * i5 + c7 * i7
			local b1 = c3 * i1 - c7 * i3 - c1 * i5 - c5 * i7
			local b2 = c5 * i1 - c1 * i3 + c7 * i5 + c3 * i7
			local b3 = c7 * i1 - c5 * i3 + c3 * i5 - c1 * i7
			b[o], b[o + 1], b[o + 2], b[o + 3] = (a0 + b0) // 2048, (a1 + b1) // 2048, (a2 + b2) // 2048, (a3 + b3) // 2048
			b[o + 4], b[o + 5], b[o + 6], b[o + 7] = (a3 - b3) // 2048, (a2 - b2) // 2048, (a1 - b1) // 2048, (a0 - b0) // 2048
		end
	end
	for c = 1, 8 do
		-- odd
		local x4, x5, x6, x7 = b[c + 56], b[c + 40], b[c + 24], b[c + 8]
		local m0 = (TAN1 * x4) // 65536 + x7
		local m1 = (TAN1 * x7) // 65536 - x4
		local m2 = (TAN3 * x5) // 65536 + x6
		local m3 = (TAN3 * x6) // 65536 - x5
		local m7 = m0 + m2
		local m4 = m1 - m3
		m0 -= m2
		m1 += m3
		local m6 = 2 * ((SQRT2 * (m0 + m1)) // 65536)
		local m5 = 2 * ((SQRT2 * (m0 - m1)) // 65536)
		-- even
		local y1, y2 = b[c + 16], b[c + 48]
		local e3 = (TAN2 * y2) // 65536 + y1
		local e2 = (TAN2 * y1) // 65536 - y2
		local e0 = b[c] + b[c + 32]
		local e1 = b[c] - b[c + 32]
		local t0 = e0 + e3
		e3 = e0 - e3
		local v0, v7 = (t0 + m7) // 64, (t0 - m7) // 64
		local v3, v4 = (e3 + m4) // 64, (e3 - m4) // 64
		local t1 = e1 + e2
		e2 = e1 - e2
		local v1, v6 = (t1 + m6) // 64, (t1 - m6) // 64
		local v2, v5 = (e2 + m5) // 64, (e2 - m5) // 64
		local p = off + c - 1
		if add then
			writeu8(dst, p, math.clamp(readu8(dst, p) + v0, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v1, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v2, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v3, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v4, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v5, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v6, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(readu8(dst, p) + v7, 0, 255))
		else
			writeu8(dst, p, math.clamp(v0, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v1, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v2, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v3, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v4, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v5, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v6, 0, 255))
			p += stride
			writeu8(dst, p, math.clamp(v7, 0, 255))
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------
-- motion compensation

local EDGE = buffer.create(24 * 24)

-- the (w + 1) x (h + 1) samples from (sx, sy) of a plane (rows from base, stride apart, rw x rh): the plane itself
-- when they are inside it, else a copy with the edge samples repeated
local function source(ref: buffer, base: number, stride: number, rw: number, rh: number, sx: number, sy: number, w: number,
	h: number): (buffer, number, number)
	if sx >= 0 and sy >= 0 and sx + w + 1 <= rw and sy + h + 1 <= rh then
		return ref, base + sy * stride + sx, stride
	end
	for y = 0, h do
		local row = base + math.clamp(sy + y, 0, rh - 1) * stride
		for x = 0, w do
			writeu8(EDGE, y * 24 + x, readu8(ref, row + math.clamp(sx + x, 0, rw - 1)))
		end
	end
	return EDGE, 0, 24
end

-- the same from one field (sel 0 top, 1 bottom) of a frame plane (stride, rw x rh frame rows), at field row sy:
-- outside the picture, rows repeat as the frame's edge rows (of either field), as FFmpeg's edge emulation does
local function sourceField(ref: buffer, stride: number, rw: number, rh: number, sel: number, sx: number, sy: number, w: number,
	h: number): (buffer, number, number)
	if sx >= 0 and sy >= 0 and sx + w + 1 <= rw and 2 * (sy + h) + sel < rh then
		return ref, sel * stride + sy * 2 * stride + sx, 2 * stride
	end
	for y = 0, h do
		local row = math.clamp(2 * (sy + y) + sel, 0, rh - 1) * stride
		for x = 0, w do
			writeu8(EDGE, y * 24 + x, readu8(ref, row + math.clamp(sx + x, 0, rw - 1)))
		end
	end
	return EDGE, 0, 24
end

-- half-sample prediction of a w x h block (hx / hy: half a sample right / down): rnd false = the "no rounding" filter
-- (P pictures with rounding_type 1); avg: averaged with what is in dst
local function hpel(dst: buffer, dOff: number, dStride: number, src: buffer, sOff: number, sStride: number, hx: number,
	hy: number, w: number, h: number, rnd: boolean, avg: boolean)
	local r1 = rnd and 1 or 0
	local r2 = rnd and 2 or 1
	for _ = 1, h do
		for x = 0, w - 1 do
			local p
			if hx == 0 and hy == 0 then
				p = readu8(src, sOff + x)
			elseif hy == 0 then
				p = (readu8(src, sOff + x) + readu8(src, sOff + x + 1) + r1) // 2
			elseif hx == 0 then
				p = (readu8(src, sOff + x) + readu8(src, sOff + sStride + x) + r1) // 2
			else
				p = (readu8(src, sOff + x) + readu8(src, sOff + x + 1) + readu8(src, sOff + sStride + x)
					+ readu8(src, sOff + sStride + x + 1) + r2) // 4
			end
			if avg then
				p = (readu8(dst, dOff + x) + p + 1) // 2
			end
			writeu8(dst, dOff + x, p)
		end
		dOff += dStride
		sOff += sStride
	end
end

-- quarter-sample luma prediction (MPEG-4's 8-tap filter, mirrored at the block's edges), as FFmpeg's qpel functions
local QA = table.create(17 * 17, 0) -- the (n + 1) x (n + 1) source samples
local QH = table.create(17 * 17, 0)
local QV = table.create(17 * 17, 0)
local QO = table.create(17 * 17, 0)

-- horizontal lowpass of rows 0..rows-1 of src (n + 1 wide, row stride 17) into out (n wide, stride 17): a sliding
-- window of the 8 taps, mirrored at the block's ends
local function hLow(src, out, n: number, rows: number, rnd: boolean)
	local r = rnd and 16 or 15
	for y = 0, rows - 1 do
		local o = y * 17 + 1
		local s0, s1, s2 = src[o + 2], src[o + 1], src[o]
		local s3, s4, s5, s6 = src[o], src[o + 1], src[o + 2], src[o + 3]
		for x = 0, n - 1 do
			local k = x + 4
			if k > n then
				k = 2 * n + 1 - k
			end
			local s7 = src[o + k]
			out[o + x] = math.clamp(((s3 + s4) * 20 - (s2 + s5) * 6 + (s1 + s6) * 3 - (s0 + s7) + r) // 32, 0, 255)
			s0, s1, s2, s3, s4, s5, s6 = s1, s2, s3, s4, s5, s6, s7
		end
	end
end
-- vertical lowpass of src (n + 1 rows) into out (n rows)
local function vLow(src, out, n: number, rnd: boolean)
	local r = rnd and 16 or 15
	for x = 1, n do
		local s0, s1, s2 = src[34 + x], src[17 + x], src[x]
		local s3, s4, s5, s6 = src[x], src[17 + x], src[34 + x], src[51 + x]
		for y = 0, n - 1 do
			local k = y + 4
			if k > n then
				k = 2 * n + 1 - k
			end
			local s7 = src[k * 17 + x]
			out[y * 17 + x] = math.clamp(((s3 + s4) * 20 - (s2 + s5) * 6 + (s1 + s6) * 3 - (s0 + s7) + r) // 32, 0, 255)
			s0, s1, s2, s3, s4, s5, s6 = s1, s2, s3, s4, s5, s6, s7
		end
	end
end
-- out = average of a (offset ao) and b (offset bo), rows x n
local function l2(out, oo, a, ao, b, bo, n: number, rows: number, rnd: boolean)
	local r = rnd and 1 or 0
	for y = 0, rows - 1 do
		local base = y * 17 + 1
		for x = 0, n - 1 do
			out[oo + base + x] = (a[ao + base + x] + b[bo + base + x] + r) // 2
		end
	end
end

local function qpel(dst: buffer, dOff: number, dStride: number, src: buffer, sOff: number, sStride: number, qx: number,
	qy: number, n: number, rnd: boolean, avg: boolean)
	-- the source block
	for y = 0, n do
		local row = sOff + y * sStride
		local o = y * 17 + 1
		for x = 0, n do
			QA[o + x] = readu8(src, row + x)
		end
	end
	local res, ro = QA, 0 -- the result (offset in rows of 17)
	if qx == 0 and qy == 0 then
		res = QA
	elseif qy == 0 then
		hLow(QA, QH, n, n, rnd)
		if qx == 2 then
			res = QH
		else
			l2(QO, 0, QA, qx == 3 and 1 or 0, QH, 0, n, n, rnd)
			res = QO
		end
	elseif qx == 0 then
		vLow(QA, QV, n, rnd)
		if qy == 2 then
			res = QV
		else
			l2(QO, 0, QA, qy == 3 and 17 or 0, QV, 0, n, n, rnd)
			res = QO
		end
	else
		hLow(QA, QH, n, n + 1, rnd)
		if qx ~= 2 then
			-- the horizontal quarter position first
			l2(QH, 0, QH, 0, QA, qx == 3 and 1 or 0, n, n + 1, rnd)
		end
		if qy == 2 then
			vLow(QH, QO, n, rnd)
			res = QO
		else
			vLow(QH, QV, n, rnd)
			l2(QO, 0, QH, qy == 3 and 17 or 0, QV, 0, n, n, rnd)
			res = QO
		end
	end
	for y = 0, n - 1 do
		local o = y * 17 + 1 + ro
		for x = 0, n - 1 do
			local p = res[o + x]
			if avg then
				p = (readu8(dst, dOff + x) + p + 1) // 2
			end
			writeu8(dst, dOff + x, p)
		end
		dOff += dStride
	end
end

local CHROMA_ROUND = { [0] = 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1 }
local function roundChroma(x: number): number
	return CHROMA_ROUND[band(x, 15)] + x // 8
end
local XVID_FOURCC = { XVID = true, XVIX = true, RMP4 = true, ZMP4 = true, SIPP = true }
local QPEL_RTAB = { [0] = 0, 0, 1, 1, 0, 0, 0, 1 }
local function divTrunc(a: number, b: number): number
	local q = a / b
	if q >= 0 then
		return math.floor(q)
	end
	return -math.floor(-q)
end
-- (x >> 1) | (x & 1), for negative x too
local function orHalf(x: number): number
	local f = x // 2
	if x % 2 == 1 and f % 2 == 0 then
		f += 1
	end
	return f
end

---------------------------------------------------------------------------------------------------------------------------
-- global motion compensation (S-VOPs with GMC): warping points to an affine map, as FFmpeg computes it

-- C's integer division (towards zero) for b > 0
local function cdiv(a: number, b: number): number
	if a >= 0 then
		return a // b
	end
	return -((-a) // b)
end
local function cRoundedDiv(a: number, b: number): number
	if a > 0 then
		return cdiv(a + b // 2, b)
	end
	return cdiv(a - b // 2, b)
end

-- dmv_length VLC, then the signed value
local function readTrajectoryValue(bp: number): (number, number)
	local w = peek(bp)
	local top3 = rshift(w, 29)
	local len
	if top3 < 2 then
		len, bp = 0, bp + 2
	elseif top3 < 7 then
		len, bp = top3 - 1, bp + 3
	else
		local n = 0
		while n < 9 and band(lshift(w, 3 + n), 0x80000000) ~= 0 do
			n += 1
		end
		len, bp = 6 + n, bp + 4 + n
	end
	if len == 0 then
		return 0, bp
	end
	return getXbits(bp, len)
end

local function readSpriteTrajectory(st, bp: number, width: number, height: number)
	local divx413 = st.xvid < 0 and st.divx == 500 and st.divxBuild == 413
	local pts = st.warpPoints
	local d = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }
	for i = 1, pts do
		local x, y
		x, bp = readTrajectoryValue(bp)
		if not divx413 then
			bp += 1 -- marker
		end
		y, bp = readTrajectoryValue(bp)
		bp += 1 -- marker
		d[i][1], d[i][2] = x, y
	end
	local acc = st.warpAccuracy
	local a = lshift(2, acc)
	local rho = 3 - acc
	local r = 16 // a
	local w, h = width, height
	local alpha, beta = 1, 0
	while 2 ^ alpha < w do
		alpha += 1
	end
	while 2 ^ beta < h do
		beta += 1
	end
	local w2, h2 = 2 ^ alpha, 2 ^ beta
	local vop = { { 0, 0 }, { w, 0 }, { 0, h }, { w, h } }
	local sref = { {}, {}, {} }
	if divx413 then
		sref[1][1] = a * vop[1][1] + d[1][1]
		sref[1][2] = a * vop[1][2] + d[1][2]
		sref[2][1] = a * vop[2][1] + d[1][1] + d[2][1]
		sref[2][2] = a * vop[2][2] + d[1][2] + d[2][2]
		sref[3][1] = a * vop[3][1] + d[1][1] + d[3][1]
		sref[3][2] = a * vop[3][2] + d[1][2] + d[3][2]
	else
		local ha = a // 2
		sref[1][1] = ha * (2 * vop[1][1] + d[1][1])
		sref[1][2] = ha * (2 * vop[1][2] + d[1][2])
		sref[2][1] = ha * (2 * vop[2][1] + d[1][1] + d[2][1])
		sref[2][2] = ha * (2 * vop[2][2] + d[1][2] + d[2][2])
		sref[3][1] = ha * (2 * vop[3][1] + d[1][1] + d[3][1])
		sref[3][2] = ha * (2 * vop[3][2] + d[1][2] + d[3][2])
	end
	local vr00 = 16 * (vop[1][1] + w2)
		+ cRoundedDiv((w - w2) * (r * sref[1][1] - 16 * vop[1][1]) + w2 * (r * sref[2][1] - 16 * vop[2][1]), w)
	local vr01 = 16 * vop[1][2]
		+ cRoundedDiv((w - w2) * (r * sref[1][2] - 16 * vop[1][2]) + w2 * (r * sref[2][2] - 16 * vop[2][2]), w)
	local vr10 = 16 * vop[1][1]
		+ cRoundedDiv((h - h2) * (r * sref[1][1] - 16 * vop[1][1]) + h2 * (r * sref[3][1] - 16 * vop[3][1]), h)
	local vr11 = 16 * (vop[1][2] + h2)
		+ cRoundedDiv((h - h2) * (r * sref[1][2] - 16 * vop[1][2]) + h2 * (r * sref[3][2] - 16 * vop[3][2]), h)
	local o00, o01, o10, o11 -- offset[luma/chroma][x/y]
	local d00, d01, d10, d11 -- delta[x/y][along x/along y]
	local sh0, sh1
	if pts == 0 then
		o00, o01, o10, o11 = 0, 0, 0, 0
		d00, d01, d10, d11 = a, 0, 0, a
		sh0, sh1 = 0, 0
	elseif pts == 1 then
		o00 = sref[1][1] - a * vop[1][1]
		o01 = sref[1][2] - a * vop[1][2]
		o10 = orHalf(sref[1][1]) - a * (vop[1][1] // 2)
		o11 = orHalf(sref[1][2]) - a * (vop[1][2] // 2)
		d00, d01, d10, d11 = a, 0, 0, a
		sh0, sh1 = 0, 0
	elseif pts == 2 then
		local p = alpha + rho
		o00 = sref[1][1] * 2 ^ p + (-r * sref[1][1] + vr00) * (-vop[1][1]) + (r * sref[1][2] - vr01) * (-vop[1][2]) + 2 ^ (p - 1)
		o01 = sref[1][2] * 2 ^ p + (-r * sref[1][2] + vr01) * (-vop[1][1]) + (-r * sref[1][1] + vr00) * (-vop[1][2]) + 2 ^ (p - 1)
		o10 = (-r * sref[1][1] + vr00) * (-2 * vop[1][1] + 1) + (r * sref[1][2] - vr01) * (-2 * vop[1][2] + 1)
			+ 2 * w2 * r * sref[1][1] - 16 * w2 + 2 ^ (p + 1)
		o11 = (-r * sref[1][2] + vr01) * (-2 * vop[1][1] + 1) + (-r * sref[1][1] + vr00) * (-2 * vop[1][2] + 1)
			+ 2 * w2 * r * sref[1][2] - 16 * w2 + 2 ^ (p + 1)
		d00 = -r * sref[1][1] + vr00
		d01 = r * sref[1][2] - vr01
		d10 = -r * sref[1][2] + vr01
		d11 = -r * sref[1][1] + vr00
		sh0, sh1 = p, p + 2
	else
		local minab = math.min(alpha, beta)
		local w3, h3 = w2 // 2 ^ minab, h2 // 2 ^ minab
		local p = alpha + beta + rho - minab
		o00 = sref[1][1] * 2 ^ p + (-r * sref[1][1] + vr00) * h3 * (-vop[1][1]) + (-r * sref[1][1] + vr10) * w3 * (-vop[1][2])
			+ 2 ^ (p - 1)
		o01 = sref[1][2] * 2 ^ p + (-r * sref[1][2] + vr01) * h3 * (-vop[1][1]) + (-r * sref[1][2] + vr11) * w3 * (-vop[1][2])
			+ 2 ^ (p - 1)
		o10 = (-r * sref[1][1] + vr00) * h3 * (-2 * vop[1][1] + 1) + (-r * sref[1][1] + vr10) * w3 * (-2 * vop[1][2] + 1)
			+ 2 * w2 * h3 * r * sref[1][1] - 16 * w2 * h3 + 2 ^ (p + 1)
		o11 = (-r * sref[1][2] + vr01) * h3 * (-2 * vop[1][1] + 1) + (-r * sref[1][2] + vr11) * w3 * (-2 * vop[1][2] + 1)
			+ 2 * w2 * h3 * r * sref[1][2] - 16 * w2 * h3 + 2 ^ (p + 1)
		d00 = (-r * sref[1][1] + vr00) * h3
		d01 = (-r * sref[1][1] + vr10) * w3
		d10 = (-r * sref[1][2] + vr01) * h3
		d11 = (-r * sref[1][2] + vr11) * w3
		sh0, sh1 = p, p + 2
	end
	local g = { acc = acc, points = pts }
	if d00 == a * 2 ^ sh0 and d01 == 0 and d10 == 0 and d11 == a * 2 ^ sh0 then
		-- a translation
		g.o00, g.o01 = o00 // 2 ^ sh0, o01 // 2 ^ sh0
		g.o10, g.o11 = o10 // 2 ^ sh1, o11 // 2 ^ sh1
		g.d00, g.d01, g.d10, g.d11 = a, 0, 0, a
		g.shift = 0
		g.points = 1
	else
		local shy, shc = 16 - sh0, 16 - sh1
		local lim = 2147483647
		if shy < 0 or shc < 0 then
			error("MPEG-4 video: a global motion warp is out of range", 0)
		end
		g.o00, g.o01 = o00 * 2 ^ shy, o01 * 2 ^ shy
		g.o10, g.o11 = o10 * 2 ^ shc, o11 * 2 ^ shc
		g.d00, g.d01, g.d10, g.d11 = d00 * 2 ^ shy, d01 * 2 ^ shy, d10 * 2 ^ shy, d11 * 2 ^ shy
		for _, v in ipairs({ g.o00, g.o01, g.o10, g.o11, g.d00, g.d01, g.d10, g.d11 }) do
			if math.abs(v) >= lim then
				error("MPEG-4 video: a global motion warp is out of range", 0)
			end
		end
		g.shift = 16
	end
	return g, bp
end

-- one block from a bilinear interpolation at 1/16 sample (translational GMC)
local function gmc1Block(dst: buffer, dO: number, ds: number, ref: buffer, rs: number, ew: number, eh: number, sx: number,
	sy: number, fx: number, fy: number, w: number, h: number, rounder: number)
	local A, B, C, D = (16 - fx) * (16 - fy), fx * (16 - fy), (16 - fx) * fy, fx * fy
	if sx >= 0 and sy >= 0 and sx + w < ew and sy + h < eh then
		local s = sy * rs + sx
		for y = 0, h - 1 do
			local s0, s1 = s, s + rs
			local o = dO + y * ds
			local a0, c0 = readu8(ref, s0), readu8(ref, s1)
			for x = 1, w do
				local a1, c1 = readu8(ref, s0 + x), readu8(ref, s1 + x)
				writeu8(dst, o + x - 1, rshift(A * a0 + B * a1 + C * c0 + D * c1 + rounder, 8))
				a0, c0 = a1, c1
			end
			s += rs
		end
	else
		for y = 0, h - 1 do
			local r0 = math.clamp(sy + y, 0, eh - 1) * rs
			local r1 = math.clamp(sy + y + 1, 0, eh - 1) * rs
			local o = dO + y * ds
			for x = 0, w - 1 do
				local x0, x1 = math.clamp(sx + x, 0, ew - 1), math.clamp(sx + x + 1, 0, ew - 1)
				writeu8(dst, o + x, rshift(A * readu8(ref, r0 + x0) + B * readu8(ref, r0 + x1) + C * readu8(ref, r1 + x0)
					+ D * readu8(ref, r1 + x1) + rounder, 8))
			end
		end
	end
end

-- FFmpeg's ff_gmc_c: an 8-wide column of h rows along the affine map
local function gmcBlock(dst: buffer, dO: number, ds: number, ref: buffer, rs: number, ox: number, oy: number, dxx: number,
	dxy: number, dyx: number, dyy: number, shift: number, r: number, width: number, height: number, h: number)
	local s = 2 ^ shift
	local s2 = 2 ^ (2 * shift)
	width -= 1
	height -= 1
	for y = 0, h - 1 do
		local vx, vy = ox, oy
		local o = dO + y * ds
		for x = 0, 7 do
			local srcX, srcY = vx // 65536, vy // 65536
			local fx, fy = srcX % s, srcY % s
			srcX, srcY = srcX // s, srcY // s
			local v
			if srcX >= 0 and srcX < width then
				if srcY >= 0 and srcY < height then
					local i = srcX + srcY * rs
					v = ((readu8(ref, i) * (s - fx) + readu8(ref, i + 1) * fx) * (s - fy)
						+ (readu8(ref, i + rs) * (s - fx) + readu8(ref, i + rs + 1) * fx) * fy + r) // s2
				else
					local i = srcX + math.clamp(srcY, 0, height) * rs
					v = ((readu8(ref, i) * (s - fx) + readu8(ref, i + 1) * fx) * s + r) // s2
				end
			else
				if srcY >= 0 and srcY < height then
					local i = math.clamp(srcX, 0, width) + srcY * rs
					v = ((readu8(ref, i) * (s - fy) + readu8(ref, i + rs) * fy) * s + r) // s2
				else
					v = readu8(ref, math.clamp(srcX, 0, width) + math.clamp(srcY, 0, height) * rs)
				end
			end
			writeu8(dst, o + x, v)
			vx += dxx
			vy += dyx
		end
		ox += dxy
		oy += dyy
	end
end

---------------------------------------------------------------------------------------------------------------------------
-- headers

local function newStreamState()
	return { timeRes = 0, timeBits = 1, fixedRate = 0, width = 0, height = 0, interlaced = false, sprite = 0, quantPrec = 5,
		mpegQuant = false, qpel = false, resync = false, partitioned = false, newPred = false, reducedRes = false,
		scalability = false, intraQ = table.clone(DEFAULT_INTRA), interQ = table.clone(DEFAULT_INTER), voType = 0,
		lowDelay = false, haveVol = false, tFrame = 0, timeBase = 0, lastTimeBase = 0, time = 0, lastNonBTime = 0, ppTime = 0,
		xvid = -1, divx = -1, divxBuild = -1, packed = false, aspect = 1, parW = 1, parH = 1 }
end

local PIXEL_ASPECT = { [1] = { 1, 1 }, [2] = { 12, 11 }, [3] = { 10, 11 }, [4] = { 16, 11 }, [5] = { 40, 33 } }

-- VOL header at bit position bp (after the start code)
local function readVol(st, bp)
	local v, verId
	bp += 1 -- random accessible
	st.voType, bp = getBits(bp, 8)
	v, bp = getBits(bp, 1)
	if v == 1 then
		verId, bp = getBits(bp, 4)
		bp += 3
	else
		verId = 1
	end
	local ar
	ar, bp = getBits(bp, 4)
	if ar == 15 then
		st.parW, bp = getBits(bp, 8)
		st.parH, bp = getBits(bp, 8)
	elseif PIXEL_ASPECT[ar] then
		st.parW, st.parH = PIXEL_ASPECT[ar][1], PIXEL_ASPECT[ar][2]
	end
	v, bp = getBits(bp, 1)
	st.volControl = v == 1
	if v == 1 then -- vol control parameters
		local chroma, ld
		chroma, bp = getBits(bp, 2)
		ld, bp = getBits(bp, 1)
		st.lowDelay = ld == 1
		v, bp = getBits(bp, 1)
		if v == 1 then
			bp += 15 + 1 + 15 + 1 + 15 + 1 + 3 + 11 + 1 + 15 + 1
		end
		if chroma ~= 1 then
			error("MPEG-4 video: only 4:2:0 colour is read", 0)
		end
	else
		st.lowDelay = st.voType == 1 or st.voType == 17
	end
	local shape
	shape, bp = getBits(bp, 2)
	if shape ~= 0 then
		error("MPEG-4 video: shaped (non-rectangular) video isn't supported", 0)
	end
	bp += 1 -- marker
	st.timeRes, bp = getBits(bp, 16)
	if st.timeRes == 0 then
		error("MPEG-4 video: the VOL header has no time resolution", 0)
	end
	local bits = 1
	while 2 ^ bits < st.timeRes do
		bits += 1
	end
	st.timeBits = math.max(1, bits)
	bp += 1
	v, bp = getBits(bp, 1)
	if v == 1 then
		st.fixedRate, bp = getBits(bp, st.timeBits)
	else
		st.fixedRate = 0
	end
	bp += 1
	st.width, bp = getBits(bp, 13)
	bp += 1
	st.height, bp = getBits(bp, 13)
	bp += 1
	v, bp = getBits(bp, 1)
	st.interlaced = v == 1
	bp += 1 -- obmc_disable
	if verId == 1 then
		st.sprite, bp = getBits(bp, 1)
	else
		st.sprite, bp = getBits(bp, 2)
	end
	if st.sprite == 1 or st.sprite == 2 then
		if st.sprite == 1 then
			bp += 13 + 1 + 13 + 1 + 13 + 1 + 13 + 1
		end
		st.warpPoints, bp = getBits(bp, 6)
		st.warpAccuracy, bp = getBits(bp, 2)
		bp += 1 -- brightness change
		if st.sprite == 1 then
			bp += 1
		end
	end
	v, bp = getBits(bp, 1)
	if v == 1 then -- not 8 bit
		st.quantPrec, bp = getBits(bp, 4)
		local bpp
		bpp, bp = getBits(bp, 4)
		if bpp ~= 8 then
			error("MPEG-4 video: only 8-bit video is read", 0)
		end
		if st.quantPrec < 3 or st.quantPrec > 9 then
			st.quantPrec = 5
		end
	else
		st.quantPrec = 5
	end
	v, bp = getBits(bp, 1)
	st.mpegQuant = v == 1
	if st.mpegQuant then
		st.intraQ, st.interQ = table.clone(DEFAULT_INTRA), table.clone(DEFAULT_INTER)
		for _, which in ipairs({ "intraQ", "interQ" }) do
			v, bp = getBits(bp, 1)
			if v == 1 then
				local m = st[which]
				local last = 0
				local i = 1
				while i <= 64 do
					local q
					q, bp = getBits(bp, 8)
					if q == 0 then
						break
					end
					last = q
					m[ZIGZAG[i] + 1] = q
					i += 1
				end
				while i <= 64 do
					m[ZIGZAG[i] + 1] = last
					i += 1
				end
			end
		end
	end
	if verId ~= 1 then
		v, bp = getBits(bp, 1)
		st.qpel = v == 1
	else
		st.qpel = false
	end
	v, bp = getBits(bp, 1)
	if v == 0 then
		error("MPEG-4 video: complexity estimation headers aren't supported", 0)
	end
	v, bp = getBits(bp, 1)
	st.resync = v == 0
	v, bp = getBits(bp, 1)
	st.partitioned = v == 1
	if st.partitioned then
		v, bp = getBits(bp, 1) -- reversible VLC
	end
	if verId ~= 1 then
		v, bp = getBits(bp, 1)
		st.newPred = v == 1
		if st.newPred then
			bp += 3
		end
		v, bp = getBits(bp, 1)
		st.reducedRes = v == 1
	end
	v, bp = getBits(bp, 1)
	st.scalability = v == 1
	st.haveVol = true
	st.tFrame = 0
	return bp
end

-- user data: the encoder's name and build (FFmpeg works around old encoders' habits; here: Xvid's IDCT, DivX's
-- direct-mode block size)
local function readUserData(st, p0, stop)
	local chars = {}
	for p = p0, math.min(stop, p0 + 255) - 1 do
		local c = readu8(S, p)
		if c == 0 then
			break
		end
		table.insert(chars, string.char(c))
	end
	local text = table.concat(chars)
	local ver, build, last = string.match(text, "^DivX(%d+)Build(%d+)(.?)")
	if not ver then
		ver, build, last = string.match(text, "^DivX(%d+)b(%d+)(.?)")
	end
	if ver then
		st.divx = tonumber(ver)
		st.divxBuild = tonumber(build)
		st.packed = last == "p"
	end
	local xb = string.match(text, "^XviD(%d+)")
	if xb then
		st.xvid = tonumber(xb)
	end
	if string.match(text, "^FFmpe") or string.match(text, "^Lavc%d") or text == "ffmpeg" then
		st.lavc = true
	end
end

-- VOP header up to vop_coded: type, coded, time (seconds), bit position after it
local function readVopTime(st, bp)
	local t
	t, bp = getBits(bp, 2)
	local ptype = t + 1
	local incr = 0
	while true do
		local b
		b, bp = getBits(bp, 1)
		if b == 0 then
			break
		end
		incr += 1
	end
	bp += 1
	local ti
	ti, bp = getBits(bp, st.timeBits)
	bp += 1
	local coded
	coded, bp = getBits(bp, 1)
	local time
	if ptype ~= 3 then
		st.lastTimeBase = st.timeBase
		st.timeBase += incr
		time = st.timeBase * st.timeRes + ti
		st.ppTime = time - st.lastNonBTime
		st.lastNonBTime = time
	else
		time = (st.lastTimeBase + incr) * st.timeRes + ti
		st.pbTime = st.ppTime - (st.lastNonBTime - time)
		-- field times (interlaced direct mode), in units of the first B picture's distance
		if st.tFrame == 0 then
			st.tFrame = st.pbTime
		end
		if st.tFrame == 0 then
			st.tFrame = 1
		end
		local function rdiv(a, b)
			if a >= 0 then
				return (a + b // 2) // b
			end
			return -((-a + b // 2) // b)
		end
		local base = rdiv(st.lastNonBTime - st.ppTime, st.tFrame)
		st.ppFieldTime = (rdiv(st.lastNonBTime, st.tFrame) - base) * 2
		st.pbFieldTime = (rdiv(time, st.tFrame) - base) * 2
		if st.ppFieldTime <= st.pbFieldTime or st.pbFieldTime <= 1 then
			st.pbFieldTime, st.ppFieldTime = 2, 4
		end
	end
	return ptype, coded == 1, time, bp
end

---------------------------------------------------------------------------------------------------------------------------
-- the parser (VOP boundaries and times)

local Parser = {}
Parser.__index = Parser

function Mpeg4.parser(config)
	local self = setmetatable({ st = newStreamState() }, Parser)
	if config and buffer.len(config) > 0 then
		self:vops(config, 0, buffer.len(config))
	end
	return self
end

-- start codes 00 00 01 xx in S[from, size)
local function nextCode(from, size)
	local q = from
	while q + 3 < size do
		local b2 = readu8(S, q + 2)
		if b2 > 1 then
			q += 3
		elseif b2 == 1 and readu8(S, q + 1) == 0 and readu8(S, q) == 0 then
			return q
		else
			q += 1
		end
	end
	return nil
end

local function loadSample(buf, pos, size)
	if buffer.len(S) < size + 16 then
		S = buffer.create(size + 65536)
	end
	buffer.copy(S, 0, buf, pos, size)
	buffer.fill(S, size, 0, 16)
	SLEN = size
end

-- headers in S[0, size): VOL / GOV / user data read into st; returns the VOPs { pos, type, coded, time, bp }
local function scanHeaders(st, size)
	local list = {}
	local p = nextCode(0, size)
	local headerStart = 0
	while p do
		local code = readu8(S, p + 3)
		local nxt = nextCode(p + 4, size)
		if code >= 0x20 and code <= 0x2F then
			readVol(st, (p + 4) * 8)
		elseif code == 0xB2 then
			readUserData(st, p + 4, nxt or size)
		elseif code == 0xB3 then
			local h, m, s
			local bp = (p + 4) * 8
			h, bp = getBits(bp, 5)
			m, bp = getBits(bp, 6)
			bp += 1
			s, bp = getBits(bp, 6)
			st.timeBase = s + 60 * (m + 60 * h)
		elseif code == 0xB6 then
			if not st.haveVol then
				error("MPEG-4 video: a picture comes before the VOL header", 0)
			end
			local ptype, coded, time, bp = readVopTime(st, (p + 4) * 8)
			table.insert(list, { start = headerStart, pos = p, type = ptype, coded = coded, time = time, bp = bp })
			headerStart = nxt or size
		end
		p = nxt
	end
	return list
end

function Parser:vops(buf, pos, size)
	loadSample(buf, pos, size)
	local st = self.st
	local list = scanHeaders(st, size)
	local out = {}
	for i, v in ipairs(list) do
		local stop = list[i + 1] and list[i + 1].start or size
		table.insert(out, { pos = pos + v.start, size = stop - v.start, type = v.type, coded = v.coded,
			time = v.time / math.max(st.timeRes, 1) })
	end
	return out
end

---------------------------------------------------------------------------------------------------------------------------
-- the decoder

function Mpeg4.new(config, fourcc: string?)
	local self = setmetatable({}, Mpeg4)
	self.st = newStreamState()
	self.st.fourcc = fourcc
	self.width, self.height = 0, 0
	self.frames = {}
	if config and buffer.len(config) > 0 then
		loadSample(config, 0, buffer.len(config))
		scanHeaders(self.st, buffer.len(config))
	end
	return self
end

function Mpeg4:reset()
	self.last, self.next = nil, nil
end

function Mpeg4:allocate()
	local st = self.st
	local mbw, mbh = (st.width + 15) // 16, (st.height + 15) // 16
	self.width, self.height = st.width, st.height
	self.mbw, self.mbh = mbw, mbh
	if mbw == self.allocW and mbh == self.allocH then
		return
	end
	self.allocW, self.allocH = mbw, mbh
	local W, H = mbw * 16, mbh * 16
	self.frames = {}
	for i = 1, 3 do
		local Y, U, V = buffer.create(W * H), buffer.create(W * H // 4), buffer.create(W * H // 4)
		buffer.fill(U, 0, 128)
		buffer.fill(V, 0, 128)
		self.frames[i] = {
			Y = Y, U = U, V = V, ys = W, cs = W // 2, yo = 0, co = 0,
			-- per 8x8 luma block: the forward motion vector (for later B pictures' direct mode)
			mvx = table.create(4 * mbw * mbh, 0), mvy = table.create(4 * mbw * mbh, 0),
			-- per macroblock: 0 coded 16x16 (or intra), 1 4MV, 2 skipped, 3 field motion
			mbKind = table.create(mbw * mbh, 0),
			-- field vectors (interlaced direct mode): per macroblock, per field, and the field each came from
			fmvx = table.create(2 * mbw * mbh, 0), fmvy = table.create(2 * mbw * mbh, 0), fsel = table.create(2 * mbw * mbh, 0),
		}
	end
	-- prediction state of the picture being decoded
	self.dcY = table.create(4 * mbw * mbh, 1024)
	self.dcU = table.create(mbw * mbh, 1024)
	self.dcV = table.create(mbw * mbh, 1024)
	self.acY = table.create(16 * 4 * mbw * mbh, 0)
	self.acU = table.create(16 * mbw * mbh, 0)
	self.acV = table.create(16 * mbw * mbh, 0)
	self.mbQ = table.create(mbw * mbh, 0)
	self:reset()
end

-- decode one VOP
function Mpeg4:decodeSample(buf: buffer, pos: number, size: number)
	loadSample(buf, pos, size)
	local st = self.st
	local list = scanHeaders(st, size)
	local result = nil
	for _, v in ipairs(list) do
		self.pictType = v.type
		if v.coded then
			result = self:decodeVop(v)
		elseif v.type ~= 3 then
			-- a "not coded" I / P picture: the reference stays as it is
			result = nil
		end
	end
	return result
end

function Mpeg4:decodeVop(v)
	local st = self.st
	if st.partitioned then
		error("MPEG-4 video: data-partitioned video isn't supported", 0)
	end
	if st.newPred or st.reducedRes or st.scalability then
		error("MPEG-4 video: NEWPRED, reduced resolution and scalable video aren't supported", 0)
	end
	local ptype = v.type
	if ptype == 4 and st.sprite ~= 2 then
		error("MPEG-4 video: sprite pictures aren't supported", 0)
	end
	self:allocate()
	local bp = v.bp
	local noRounding = false
	if ptype == 2 or ptype == 4 then
		local r
		r, bp = getBits(bp, 1)
		noRounding = r == 1
	end
	local dcThr
	dcThr, bp = getBits(bp, 3)
	local intraDcThreshold = DC_THRESHOLD[dcThr]
	local altScan = false
	local tff = true
	if st.interlaced then
		local a, b
		a, bp = getBits(bp, 1)
		b, bp = getBits(bp, 1)
		tff, altScan = a == 1, b == 1
	end
	local gmc
	if ptype == 4 then
		gmc, bp = readSpriteTrajectory(st, bp, st.width, st.height)
	end
	local qscale
	qscale, bp = getBits(bp, st.quantPrec)
	if qscale == 0 then
		error("MPEG-4 video: a picture has quantiser 0", 0)
	end
	local fcode, bcode = 1, 1
	if ptype ~= 1 then
		fcode, bp = getBits(bp, 3)
		if fcode == 0 then
			error("MPEG-4 video: a picture has f_code 0", 0)
		end
	end
	if ptype == 3 then
		bcode, bp = getBits(bp, 3)
		if bcode == 0 then
			error("MPEG-4 video: a picture has b_code 0", 0)
		end
	end

	-- references
	local free
	for _, f in ipairs(self.frames) do
		if f ~= self.last and f ~= self.next then
			free = f
			break
		end
	end
	local last, nxt = self.last, self.next
	if ptype == 3 then
		if not last or not nxt then
			error("MPEG-4 video: a B picture's reference picture is missing", 0)
		end
	else
		if ptype ~= 1 and not nxt then
			error("MPEG-4 video: a P picture's reference picture is missing", 0)
		end
		self.last, self.next = nxt, free
		last = nxt
	end
	local cur = free
	local ppTime, pbTime = st.ppTime, st.pbTime or 0
	if ptype == 3 and (ppTime <= pbTime or ppTime <= ppTime - pbTime or ppTime <= 0) then
		error("MPEG-4 video: a B picture's times are out of order", 0)
	end

	local mbw, mbh = self.mbw, self.mbh
	local W, H = mbw * 16, mbh * 16
	local Y, U, V = cur.Y, cur.U, cur.V
	local ys, cs = cur.ys, cur.cs
	local qpelMode = st.qpel
	local mpegQuant = st.mpegQuant
	local intraQ, interQ = st.intraQ, st.interQ
	local interlaced = st.interlaced
	local dcY, dcU, dcV, acY, acU, acV, mbQ = self.dcY, self.dcU, self.dcV, self.acY, self.acU, self.acV, self.mbQ
	local bw = 2 * mbw
	local mvx, mvy, mbKind = cur.mvx, cur.mvy, cur.mbKind
	local b = blk
	-- old encoders' habits, as FFmpeg works around them (an untagged stream's encoder from the AVI FourCC)
	local xvid, divx, divxBuild = st.xvid, st.xvid >= 0 and -1 or st.divx, st.divxBuild
	if xvid < 0 and divx < 0 and not st.lavc then
		if XVID_FOURCC[st.fourcc or ""] then
			xvid = 0
		elseif st.fourcc == "DIVX" and st.voType == 0 and not st.volControl then
			divx = 400 -- DivX 4
		end
	end
	local idct = xvid >= 0 and xvidIdct or simpleIdct
	local EW, EH = W, H -- (motion vectors reach past the picture by repeating these edges)
	if (xvid >= 0 and xvid <= 12) or (divx >= 0 and divx < 500) then
		EW, EH = st.width, st.height
	end
	local qpelChroma = 0
	if divx > 502 and divxBuild < 1814 then
		qpelChroma = 2
	elseif (divx >= 500 and divxBuild < 1814) or (xvid >= 0 and xvid <= 1) then
		qpelChroma = 1
	end
	local hpelFieldChroma = divx >= 0
	local dcNoClip = xvid >= 0 and xvid <= 32
	local mbNumBits = 1
	while 2 ^ mbNumBits < mbw * mbh do
		mbNumBits += 1
	end
	local prefixLen = 16
	if ptype == 2 or ptype == 4 then
		prefixLen = fcode + 15
	elseif ptype == 3 then
		prefixLen = math.max(fcode, bcode, 2) + 15
	end

	-- prediction state
	for i = 1, 4 * mbw * mbh do
		dcY[i] = 1024
	end
	for i = 1, mbw * mbh do
		dcU[i], dcV[i] = 1024, 1024
	end
	for i = 1, 64 * mbw * mbh do
		acY[i] = 0
	end
	for i = 1, 16 * mbw * mbh do
		acU[i], acV[i] = 0, 0
	end

	local mbx, mby = 0, 0
	local count = 0 -- macroblocks done (the current one's index)
	local sliceStart = 0 -- index of the first macroblock of the current video packet
	local firstSliceLine = true
	local resyncX, resyncY = 0, 0
	-- B picture vector predictors
	local pfx, pfy, pbx, pby = 0, 0, 0, 0
	local pffx, pffy = { 0, 0 }, { 0, 0 } -- (field: forward per field)
	local pbfx, pbfy = { 0, 0 }, { 0, 0 }

	-- motion vector difference (h263 style) added to pred, wrapped into the f_code range
	local function motion(pred: number, fc: number): number
		local code
		code, bp = getVlc(bp, MVTAB, 12)
		if code < 0 then
			error("MPEG-4 video: a motion vector is damaged", 0)
		end
		if code == 0 then
			return pred
		end
		local sign
		sign, bp = getBits(bp, 1)
		local shift = fc - 1
		local val = code
		if shift > 0 then
			local r
			r, bp = getBits(bp, shift)
			val = (val - 1) * 2 ^ shift + r + 1
		end
		if sign == 1 then
			val = -val
		end
		val += pred
		local m = 2 ^ (5 + fc)
		return (val + m // 2) % m - m // 2
	end

	local function median(a, b2, c)
		return math.max(math.min(a, b2), math.min(math.max(a, b2), c))
	end

	-- forward vector prediction for block n (0-3) of macroblock (mbx, mby)
	local function predMv(n: number): (number, number)
		local bx, by = 2 * mbx + band(n, 1), 2 * mby + rshift(n, 1)
		local function at(x, y)
			if x < 0 or x >= bw or y < 0 then
				return 0, 0
			end
			local i = y * bw + x + 1
			return mvx[i], mvy[i]
		end
		local ax, ay = at(bx - 1, by)
		local off = n == 0 and 2 or (n == 3 and -1 or 1)
		if firstSliceLine and n < 3 then
			if n == 0 then
				if mbx == resyncX then
					return 0, 0
				elseif mbx + 1 == resyncX then
					local cx, cy = at(bx + off, by - 1)
					if mbx == 0 then
						return cx, cy
					end
					return median(ax, 0, cx), median(ay, 0, cy)
				end
				return ax, ay
			elseif n == 1 then
				if mbx + 1 == resyncX then
					local cx, cy = at(bx + off, by - 1)
					return median(ax, 0, cx), median(ay, 0, cy)
				end
				return ax, ay
			else
				local bx2, by2 = at(bx, by - 1)
				local cx, cy = at(bx + off, by - 1)
				if mbx == resyncX then
					ax, ay = 0, 0
				end
				return median(ax, bx2, cx), median(ay, by2, cy)
			end
		end
		local bx2, by2 = at(bx, by - 1)
		local cx, cy = at(bx + off, by - 1)
		return median(ax, bx2, cx), median(ay, by2, cy)
	end

	local function setMv(n, x, y2)
		local i = (2 * mby + rshift(n, 1)) * bw + 2 * mbx + band(n, 1) + 1
		mvx[i], mvy[i] = x, y2
	end
	local function setMv4(x, y2)
		local i = 2 * mby * bw + 2 * mbx + 1
		mvx[i], mvy[i], mvx[i + 1], mvy[i + 1] = x, y2, x, y2
		mvx[i + bw], mvy[i + bw], mvx[i + bw + 1], mvy[i + bw + 1] = x, y2, x, y2
	end

	-- prediction of the macroblock from ref (one direction): kind 0 16x16 (mv[1]), 1 four 8x8 (mv[1..4]), 3 field
	-- (mv[1] top, mv[2] bottom, sel: the reference field of each)
	local MX, MY = table.create(4, 0), table.create(4, 0)
	local FS = table.create(2, 0)
	-- global motion: the average vector of a macroblock (component n: 0 x, 1 y), clipped to the f_code range
	local function amv(n: number): number
		local len = lshift(1, fcode + 4)
		local a = gmc.acc
		local q = qpelMode and 1 or 0
		local sum
		local function rshiftRound(x, k)
			local h = 2 ^ k // 2
			if x > 0 then
				return (x + h) // 2 ^ k
			end
			return (x + h - 1) // 2 ^ k
		end
		if gmc.points == 1 then
			local off = n == 0 and gmc.o00 or gmc.o01
			if st.xvid < 0 and st.divx == 500 and st.divxBuild == 413 and a >= q then
				sum = cdiv(off, 2 ^ (a - q))
			else
				sum = rshiftRound(off * 2 ^ q, a)
			end
		else
			local dx, dy
			if n == 0 then
				dx, dy = gmc.d00 - 2 ^ (gmc.shift + a + 1), gmc.d01
			else
				dx, dy = gmc.d10, gmc.d11 - 2 ^ (gmc.shift + a + 1)
			end
			local mbv = (n == 0 and gmc.o00 or gmc.o01) + dx * mbx * 16 + dy * mby * 16
			local sc = 2 ^ gmc.shift
			sum = 0
			for y = 0, 15 do
				local v = mbv + dy * y
				for _ = 0, 15 do
					sum += v // sc
					v += dx
				end
			end
			sum = rshiftRound(sum, a + 8 - q)
		end
		return math.clamp(sum, -len, len - 1)
	end

	-- a macroblock predicted by the global motion
	local function gmcPredict()
		local refY, refU, refV = last.Y, last.U, last.V
		local lumaO = mby * 16 * ys + mbx * 16
		local chromaO = mby * 8 * cs + mbx * 8
		local acc = gmc.acc
		local nr = noRounding and 1 or 0
		if gmc.points == 1 then
			local w, h = st.width, st.height
			local mx, my = gmc.o00, gmc.o01
			local sx = math.clamp(mbx * 16 + mx // 2 ^ (acc + 1), -16, w)
			local sy = math.clamp(mby * 16 + my // 2 ^ (acc + 1), -16, h)
			mx *= 2 ^ (3 - acc)
			my *= 2 ^ (3 - acc)
			if sx == w then
				mx = 0
			end
			if sy == h then
				my = 0
			end
			gmc1Block(Y, lumaO, ys, refY, ys, EW, EH, sx, sy, band(mx, 15), band(my, 15), 16, 16, 128 - nr)
			mx, my = gmc.o10, gmc.o11
			sx = math.clamp(mbx * 8 + mx // 2 ^ (acc + 1), -8, w // 2)
			sy = math.clamp(mby * 8 + my // 2 ^ (acc + 1), -8, h // 2)
			mx *= 2 ^ (3 - acc)
			my *= 2 ^ (3 - acc)
			if sx == w // 2 then
				mx = 0
			end
			if sy == h // 2 then
				my = 0
			end
			gmc1Block(U, chromaO, cs, refU, cs, EW // 2, EH // 2, sx, sy, band(mx, 15), band(my, 15), 8, 8, 128 - nr)
			gmc1Block(V, chromaO, cs, refV, cs, EW // 2, EH // 2, sx, sy, band(mx, 15), band(my, 15), 8, 8, 128 - nr)
		else
			local d00, d01, d10, d11 = gmc.d00, gmc.d01, gmc.d10, gmc.d11
			local shift = acc + 1
			local r = 2 ^ (2 * acc + 1) - nr
			local ox = gmc.o00 + d00 * mbx * 16 + d01 * mby * 16
			local oy = gmc.o01 + d10 * mbx * 16 + d11 * mby * 16
			gmcBlock(Y, lumaO, ys, refY, ys, ox, oy, d00, d01, d10, d11, shift, r, EW, EH, 16)
			gmcBlock(Y, lumaO + 8, ys, refY, ys, ox + d00 * 8, oy + d10 * 8, d00, d01, d10, d11, shift, r, EW, EH, 16)
			ox = gmc.o10 + d00 * mbx * 8 + d01 * mby * 8
			oy = gmc.o11 + d10 * mbx * 8 + d11 * mby * 8
			local cw, ch = (EW + 1) // 2, (EH + 1) // 2
			gmcBlock(U, chromaO, cs, refU, cs, ox, oy, d00, d01, d10, d11, shift, r, cw, ch, 8)
			gmcBlock(V, chromaO, cs, refV, cs, ox, oy, d00, d01, d10, d11, shift, r, cw, ch, 8)
		end
	end

	local function predict(ref, kind: number, rnd: boolean, avg: boolean)
		local lumaO = mby * 16 * ys + mbx * 16
		local chromaO = mby * 8 * cs + mbx * 8
		local refY, refU, refV = ref.Y, ref.U, ref.V
		local cw, ch = EW // 2, EH // 2
		if kind == 0 then
			local mx, my = MX[1], MY[1]
			local cx, cy, hx, hy
			if qpelMode then
				local src, so, ss = source(refY, 0, ys, EW, EH, mbx * 16 + mx // 4, mby * 16 + my // 4, 16, 16)
				qpel(Y, lumaO, ys, src, so, ss, mx % 4, my % 4, 16, rnd, avg)
				-- (chroma: a quarter of the vector, its odd bits kept)
				local tx, ty
				if qpelChroma == 2 then
					tx, ty = mx // 2 + QPEL_RTAB[band(mx, 7)], my // 2 + QPEL_RTAB[band(my, 7)]
				elseif qpelChroma == 1 then
					tx, ty = orHalf(mx), orHalf(my)
				else
					tx, ty = divTrunc(mx, 2), divTrunc(my, 2)
				end
				tx, ty = orHalf(tx), orHalf(ty)
				hx, hy = band(tx, 1), band(ty, 1)
				cx, cy = mbx * 8 + tx // 2, mby * 8 + ty // 2
			else
				local sx, sy = mbx * 16 + mx // 2, mby * 16 + my // 2
				local src, so, ss = source(refY, 0, ys, EW, EH, sx, sy, 16, 16)
				hpel(Y, lumaO, ys, src, so, ss, band(mx, 1), band(my, 1), 16, 16, rnd, avg)
				-- (chroma: half the luma vector, rounded up to half samples)
				hx = bor(band(mx, 1), rshift(band(mx, 2), 1))
				hy = bor(band(my, 1), rshift(band(my, 2), 1))
				cx, cy = sx // 2, sy // 2
			end
			local src, so, ss = source(refU, 0, cs, cw, ch, cx, cy, 8, 8)
			hpel(U, chromaO, cs, src, so, ss, hx, hy, 8, 8, rnd, avg)
			src, so, ss = source(refV, 0, cs, cw, ch, cx, cy, 8, 8)
			hpel(V, chromaO, cs, src, so, ss, hx, hy, 8, 8, rnd, avg)
		elseif kind == 1 then
			local sumx, sumy = 0, 0
			for i = 0, 3 do
				local mx, my = MX[i + 1], MY[i + 1]
				local dO = lumaO + band(i, 1) * 8 + rshift(i, 1) * 8 * ys
				local bx0, by0 = mbx * 16 + band(i, 1) * 8, mby * 16 + rshift(i, 1) * 8
				if qpelMode then
					local src, so, ss = source(refY, 0, ys, EW, EH, bx0 + mx // 4, by0 + my // 4, 8, 8)
					qpel(Y, dO, ys, src, so, ss, mx % 4, my % 4, 8, rnd, avg)
					sumx += divTrunc(mx, 2)
					sumy += divTrunc(my, 2)
				else
					local src, so, ss = source(refY, 0, ys, EW, EH, bx0 + mx // 2, by0 + my // 2, 8, 8)
					hpel(Y, dO, ys, src, so, ss, band(mx, 1), band(my, 1), 8, 8, rnd, avg)
					sumx += mx
					sumy += my
				end
			end
			-- (chroma: one vector from the four, with H.263's rounding)
			local cx, cy = roundChroma(sumx), roundChroma(sumy)
			local src, so, ss = source(refU, 0, cs, cw, ch, mbx * 8 + cx // 2, mby * 8 + cy // 2, 8, 8)
			hpel(U, chromaO, cs, src, so, ss, band(cx, 1), band(cy, 1), 8, 8, rnd, avg)
			src, so, ss = source(refV, 0, cs, cw, ch, mbx * 8 + cx // 2, mby * 8 + cy // 2, 8, 8)
			hpel(V, chromaO, cs, src, so, ss, band(cx, 1), band(cy, 1), 8, 8, rnd, avg)
		else
			-- field prediction: each field of the macroblock from a field of ref (vertical vectors in field units)
			for f = 0, 1 do
				local mx, my = MX[f + 1], MY[f + 1]
				local sel = FS[f + 1]
				local dO = lumaO + f * ys
				local cx, cy, hx, hy
				if qpelMode then
					-- (16 x 8: two 8 x 8 quarter-sample blocks)
					local src, so, ss = sourceField(refY, ys, EW, EH, sel, mbx * 16 + mx // 4, mby * 8 + my // 4, 8, 8)
					qpel(Y, dO, 2 * ys, src, so, ss, mx % 4, my % 4, 8, rnd, avg)
					src, so, ss = sourceField(refY, ys, EW, EH, sel, mbx * 16 + 8 + mx // 4, mby * 8 + my // 4, 8, 8)
					qpel(Y, dO + 8, 2 * ys, src, so, ss, mx % 4, my % 4, 8, rnd, avg)
					local tx, ty = orHalf(divTrunc(mx, 2)), orHalf(my // 2)
					hx, hy = band(tx, 1), band(ty, 1)
					cx, cy = mbx * 8 + tx // 2, mby * 4 + ty // 2
				else
					local sx, sy = mbx * 16 + mx // 2, mby * 8 + my // 2
					local src, so, ss = sourceField(refY, ys, EW, EH, sel, sx, sy, 16, 8)
					hpel(Y, dO, 2 * ys, src, so, ss, band(mx, 1), band(my, 1), 16, 8, rnd, avg)
					if hpelFieldChroma then
						-- (DivX: the chroma vector is the luma one halved with its odd bit kept)
						local tx, ty = orHalf(mx), my // 2
						hx, hy = band(tx, 1), band(ty, 1)
						cx, cy = mbx * 8 + tx // 2, mby * 4 + ty // 2
					else
						hx = bor(band(mx, 1), rshift(band(mx, 2), 1))
						hy = bor(band(my, 1), rshift(band(my, 2), 1))
						cx, cy = sx // 2, sy // 2
					end
				end
				local src, so, ss = sourceField(refU, cs, cw, ch, sel, cx, cy, 8, 4)
				hpel(U, chromaO + f * cs, 2 * cs, src, so, ss, hx, hy, 8, 4, rnd, avg)
				src, so, ss = sourceField(refV, cs, cw, ch, sel, cx, cy, 8, 4)
				hpel(V, chromaO + f * cs, 2 * cs, src, so, ss, hx, hy, 8, 4, rnd, avg)
			end
		end
	end

	-- one block's coefficients into b (raster order); returns the last scan index (-1: none)
	local function readCoefs(i: number, intra: boolean, scan, qmul: number, qadd: number): number
		local tab = intra and RL_INTRA or RL_INTER
		local maxLevel = intra and MAXLEVEL_INTRA or MAXLEVEL_INTER
		local maxRun = intra and MAXRUN_INTRA or MAXRUN_INTER
		while true do
			local w = peek(bp)
			local e = readu32(tab, 4 * rshift(w, 20))
			local len = band(e, 31)
			if len == 0 then
				error("MPEG-4 video: a DCT coefficient is damaged", 0)
			end
			local v = rshift(e, 5)
			local level, run, last
			if v ~= 0 then
				level, run, last = band(v, 63), band(rshift(v, 6), 63), rshift(v, 12)
				local neg = band(lshift(w, len), 0x80000000) ~= 0
				bp += len + 1
				if qmul ~= 1 or qadd ~= 0 then
					level = level * qmul + qadd
				end
				if neg then
					level = -level
				end
			else
				bp += len
				local mode
				mode, bp = getBits(bp, 1)
				if mode == 0 then
					-- first escape: level beyond the table's for this run
					local e2
					e2, bp = getVlc(bp, tab, 12)
					if e2 <= 0 then
						error("MPEG-4 video: a DCT escape is damaged", 0)
					end
					level, run, last = band(e2, 63), band(rshift(e2, 6), 63), rshift(e2, 12)
					level += maxLevel[last][run]
					local s
					s, bp = getBits(bp, 1)
					level = level * qmul + qadd
					if s == 1 then
						level = -level
					end
				else
					mode, bp = getBits(bp, 1)
					if mode == 0 then
						-- second escape: run beyond the table's for this level
						local e2
						e2, bp = getVlc(bp, tab, 12)
						if e2 <= 0 then
							error("MPEG-4 video: a DCT escape is damaged", 0)
						end
						level, run, last = band(e2, 63), band(rshift(e2, 6), 63), rshift(e2, 12)
						run += maxRun[last][level] + 1
						local s
						s, bp = getBits(bp, 1)
						level = level * qmul + qadd
						if s == 1 then
							level = -level
						end
					else
						-- third escape: last, run, a 12-bit level
						last, bp = getBits(bp, 1)
						run, bp = getBits(bp, 6)
						bp += 1
						level, bp = getBits(bp, 12)
						if level >= 2048 then
							level -= 4096
						end
						bp += 1
						if level > 0 then
							level = level * qmul + qadd
						else
							level = level * qmul - qadd
						end
						level = math.clamp(level, -2048, 2047)
					end
				end
			end
			i += run + 1
			if i > 63 then
				error("MPEG-4 video: a block has too many coefficients", 0)
			end
			b[scan[i + 1] + 1] = level
			if last == 1 then
				return i
			end
		end
	end

	-- an intra block n (0-5): DC, AC (coded or not), predictions, dequantisation, IDCT into the picture
	local function intraBlock(n: number, coded: boolean, acPred: boolean, useDcVlc: boolean, dctType: number, qs: number)
		local isLuma = n < 4
		local scale = isLuma and Y_DC_SCALE[qs] or C_DC_SCALE[qs]
		-- DC prediction (B C / A X): from the left or the top, by which gradient is smaller
		local da, db, dc
		local mbi = mby * mbw + mbx
		local function avail(x, y)
			return x >= 0 and y >= 0 and x < mbw and y * mbw + x >= sliceStart
		end
		local dcArr, acArr, idx, leftIdx, topIdx, leftMb, topMb
		if isLuma then
			local bx, by = 2 * mbx + band(n, 1), 2 * mby + rshift(n, 1)
			idx = by * bw + bx + 1
			local lx, ty = (bx - 1) // 2, (by - 1) // 2
			local leftOk = avail(lx, by // 2)
			local topOk = avail(bx // 2, ty)
			local tlOk = avail(lx, ty)
			dcArr, acArr = dcY, acY
			da = leftOk and dcY[idx - 1] or 1024
			dc = topOk and dcY[idx - bw] or 1024
			db = tlOk and dcY[idx - bw - 1] or 1024
			if leftOk then
				leftIdx, leftMb = idx - 1, (by // 2) * mbw + lx
			end
			if topOk then
				topIdx, topMb = idx - bw, ty * mbw + bx // 2
			end
		else
			idx = mbi + 1
			local leftOk = avail(mbx - 1, mby)
			local topOk = avail(mbx, mby - 1)
			local tlOk = avail(mbx - 1, mby - 1)
			dcArr = n == 4 and dcU or dcV
			acArr = n == 4 and acU or acV
			da = leftOk and dcArr[idx - 1] or 1024
			dc = topOk and dcArr[idx - mbw] or 1024
			db = tlOk and dcArr[idx - mbw - 1] or 1024
			if leftOk then
				leftIdx, leftMb = idx - 1, mbi - 1
			end
			if topOk then
				topIdx, topMb = idx - mbw, mbi - mbw
			end
		end
		local pred, dirTop
		if math.abs(da - db) < math.abs(db - dc) then
			pred, dirTop = dc, true
		else
			pred, dirTop = da, false
		end
		local scan = ZIGZAG
		if acPred then
			scan = dirTop and (altScan and ALT_V or ALT_H) or ALT_V
		elseif altScan then
			scan = ALT_V
		end
		local i = -1
		if useDcVlc then
			local size
			if isLuma then
				size, bp = getVlc(bp, DC_LUM, 11)
			else
				size, bp = getVlc(bp, DC_CHROM, 12)
			end
			if size < 0 then
				error("MPEG-4 video: a DC coefficient is damaged", 0)
			end
			local diff = 0
			if size > 0 then
				diff, bp = getXbits(bp, size)
				if size > 8 then
					bp += 1 -- marker
				end
			end
			b[1] = diff
			i = 0
		end
		if coded then
			i = readCoefs(i, true, scan, 1, 0)
		end
		-- the DC: prediction (in the quantised domain) added
		local level = b[1] + (pred + scale // 2) // scale
		b[1] = level
		local stored = level * scale
		if stored < 0 then
			stored = 0
		elseif stored > 2047 and not dcNoClip then
			stored = 2047
		end
		dcArr[idx] = stored
		-- AC prediction: the first column from the left block, or the first row from the top block (rescaled when that
		-- macroblock's quantiser differs)
		local ac0 = (idx - 1) * 16
		if acPred then
			if dirTop then
				if topIdx then
					local o = (topIdx - 1) * 16
					local q2 = mbQ[topMb + 1]
					local same = q2 == qs or (isLuma and rshift(n, 1) == 1)
					for k = 1, 7 do
						local v2 = acArr[o + 8 + k + 1]
						if not same then
							v2 = v2 * q2
							v2 = (v2 >= 0 and (v2 + qs // 2) or (v2 - qs // 2))
							v2 = divTrunc(v2, qs)
						end
						b[k + 1] += v2
					end
				end
			else
				if leftIdx then
					local o = (leftIdx - 1) * 16
					local q2 = mbQ[leftMb + 1]
					local same = q2 == qs or (isLuma and band(n, 1) == 1)
					for k = 1, 7 do
						local v2 = acArr[o + k + 1]
						if not same then
							v2 = v2 * q2
							v2 = (v2 >= 0 and (v2 + qs // 2) or (v2 - qs // 2))
							v2 = divTrunc(v2, qs)
						end
						b[k * 8 + 1] += v2
					end
				end
			end
		end
		for k = 1, 7 do
			acArr[ac0 + k + 1] = b[k * 8 + 1]
			acArr[ac0 + 8 + k + 1] = b[k + 1]
		end
		-- dequantisation
		b[1] = level * scale
		if mpegQuant then
			-- (no mismatch control on intra blocks, as FFmpeg and Xvid decode them)
			local q2 = qs * 2
			for k = 2, 64 do
				local l = b[k]
				if l ~= 0 then
					if l < 0 then
						b[k] = -((-l * q2 * intraQ[k]) // 16)
					else
						b[k] = (l * q2 * intraQ[k]) // 16
					end
				end
			end
		else
			local qmul, qadd = qs * 2, bor(qs - 1, 1)
			for k = 2, 64 do
				local l = b[k]
				if l ~= 0 then
					if l < 0 then
						b[k] = l * qmul - qadd
					else
						b[k] = l * qmul + qadd
					end
				end
			end
		end
		local dst, off, stride
		if isLuma then
			dst = Y
			local base = mby * 16 * ys + mbx * 16
			if dctType == 1 then
				off, stride = base + band(n, 1) * 8 + rshift(n, 1) * ys, 2 * ys
			else
				off, stride = base + band(n, 1) * 8 + rshift(n, 1) * 8 * ys, ys
			end
		else
			dst = n == 4 and U or V
			off, stride = mby * 8 * cs + mbx * 8, cs
		end
		idct(b, dst, off, stride, false)
		for k = 1, 64 do
			b[k] = 0
		end
		return i
	end

	-- an inter block's residual added to the prediction
	local function interBlock(n: number, dctType: number, qs: number)
		local scan = altScan and ALT_V or ZIGZAG
		if mpegQuant then
			readCoefs(-1, false, scan, 1, 0)
			local q2 = qs * 2
			local sum = -1
			for k = 1, 64 do
				local l = b[k]
				if l ~= 0 then
					if l < 0 then
						l = -(((-2 * l + 1) * q2 * interQ[k]) // 32)
					else
						l = ((2 * l + 1) * q2 * interQ[k]) // 32
					end
					b[k] = l
					sum += l
				end
			end
			if sum % 2 == 1 then
				local v2 = b[64]
				b[64] = v2 % 2 == 0 and v2 + 1 or v2 - 1
			end
		else
			readCoefs(-1, false, scan, qs * 2, bor(qs - 1, 1))
		end
		local dst, off, stride
		if n < 4 then
			dst = Y
			local base = mby * 16 * ys + mbx * 16
			if dctType == 1 then
				off, stride = base + band(n, 1) * 8 + rshift(n, 1) * ys, 2 * ys
			else
				off, stride = base + band(n, 1) * 8 + rshift(n, 1) * 8 * ys, ys
			end
		else
			dst = n == 4 and U or V
			off, stride = mby * 8 * cs + mbx * 8, cs
		end
		idct(b, dst, off, stride, true)
		for k = 1, 64 do
			b[k] = 0
		end
	end

	-- a macroblock that isn't intra: its DC / AC predictors reset
	local function clearIntra()
		local i = 2 * mby * bw + 2 * mbx + 1
		dcY[i], dcY[i + 1], dcY[i + bw], dcY[i + bw + 1] = 1024, 1024, 1024, 1024
		for _, j in ipairs({ i, i + 1, i + bw, i + bw + 1 }) do
			local o = (j - 1) * 16
			for k = 1, 16 do
				acY[o + k] = 0
			end
		end
		local c = mby * mbw + mbx + 1
		dcU[c], dcV[c] = 1024, 1024
		for k = 1, 16 do
			acU[(c - 1) * 16 + k] = 0
			acV[(c - 1) * 16 + k] = 0
		end
	end

	-- is a resync marker (a new video packet) next? Returns true and reads its header if so
	local function resyncNext(): boolean
		if not st.resync then
			return false
		end
		-- stuffing to the byte boundary: a 0 then 1s
		local k = 8 - band(bp, 7)
		local stuff = rshift(peek(bp), 32 - k)
		if stuff ~= 2 ^ (k - 1) - 1 then
			return false
		end
		local p = bp + k
		local zeros = 0
		while zeros < 32 and rshift(peek(p + zeros), 31) == 0 do
			zeros += 1
		end
		if zeros ~= prefixLen then
			return false
		end
		local q0 = p + zeros + 1
		local mbNum = getBits(q0, mbNumBits)
		if mbNum >= mbw * mbh then
			error("MPEG-4 video: a video packet starts past the picture", 0)
		end
		-- (in a B picture, macroblocks skipped with the next picture's take no bits: the marker comes before them)
		if mbNum > count and ptype == 3 and nxt.mbKind[count + 1] == 2 then
			return false
		end
		bp = q0 + mbNumBits
		local q
		q, bp = getBits(bp, st.quantPrec)
		if q > 0 then
			qscale = q
		end
		local hec
		hec, bp = getBits(bp, 1)
		if hec == 1 then
			while true do
				local one
				one, bp = getBits(bp, 1)
				if one == 0 then
					break
				end
			end
			bp += 1 + st.timeBits + 1 + 2 + 3
			if gmc then
				local _
				_, bp = readSpriteTrajectory(st, bp, st.width, st.height)
			end
			if ptype ~= 1 then
				bp += 3
			end
			if ptype == 3 then
				bp += 3
			end
		end
		mbx, mby = mbNum % mbw, mbNum // mbw
		sliceStart = mbNum
		resyncX, resyncY = mbx, mby
		firstSliceLine = true
		pfx, pfy, pbx, pby = 0, 0, 0, 0
		return true
	end

	local timePP, timePB = ppTime, pbTime
	local nmbs = mbw * mbh
	while count < nmbs do
		local mbi = mby * mbw + mbx
		if mbx == resyncX and mby == resyncY + 1 then
			firstSliceLine = false
		end
		local intra = false
		local skipped = false
		if ptype ~= 3 then
			local cbpc
			local notCoded = false
			if ptype ~= 1 then
				repeat
					local nc
					nc, bp = getBits(bp, 1)
					if nc == 1 then
						notCoded = true
						break
					end
					cbpc, bp = getVlc(bp, MCBPC_INTER, 13)
					if cbpc < 0 then
						error("MPEG-4 video: a macroblock type is damaged", 0)
					end
				until cbpc ~= 20
			else
				repeat
					cbpc, bp = getVlc(bp, MCBPC_INTRA, 9)
					if cbpc < 0 then
						error("MPEG-4 video: a macroblock type is damaged", 0)
					end
				until cbpc ~= 8
				cbpc += 4 -- (as the inter table's intra entries)
				if cbpc >= 8 then
					cbpc += 4 -- intra + quantiser: 12..15
				end
			end
			if notCoded and gmc then
				-- (skipped in an S-VOP: global motion, its average vector kept for predictions)
				mbKind[mbi + 1] = 0
				setMv4(amv(0), amv(1))
				gmcPredict()
				clearIntra()
				mbQ[mbi + 1] = qscale
			elseif notCoded then
				skipped = true
				mbKind[mbi + 1] = 2
				setMv4(0, 0)
				MX[1], MY[1] = 0, 0
				predict(last, 0, not noRounding, false)
				clearIntra()
				mbQ[mbi + 1] = qscale
			else
				local dquant = band(cbpc, 8) ~= 0
				intra = band(cbpc, 4) ~= 0
				if intra then
					local acp
					acp, bp = getBits(bp, 1)
					local cbpy
					cbpy, bp = getVlc(bp, CBPY, 6)
					if cbpy < 0 then
						error("MPEG-4 video: a coded block pattern is damaged", 0)
					end
					local cbp = band(cbpc, 3) + cbpy * 4
					local useDcVlc = qscale < intraDcThreshold
					if dquant then
						local d
						d, bp = getBits(bp, 2)
						qscale = math.clamp(qscale + QUANT_DELTA[d], 1, 31)
					end
					local dctType = 0
					if interlaced then
						dctType, bp = getBits(bp, 1)
					end
					mbQ[mbi + 1] = qscale
					for n = 0, 5 do
						intraBlock(n, band(cbp, lshift(1, 5 - n)) ~= 0, acp == 1, useDcVlc, dctType, qscale)
					end
					mbKind[mbi + 1] = 0
					setMv4(0, 0)
				else
					local mcsel = 0
					if gmc and band(cbpc, 16) == 0 then
						mcsel, bp = getBits(bp, 1)
					end
					local cbpy
					cbpy, bp = getVlc(bp, CBPY, 6)
					if cbpy < 0 then
						error("MPEG-4 video: a coded block pattern is damaged", 0)
					end
					cbpy = bxor(cbpy, 15)
					local cbp = band(cbpc, 3) + cbpy * 4
					if dquant then
						local d
						d, bp = getBits(bp, 2)
						qscale = math.clamp(qscale + QUANT_DELTA[d], 1, 31)
					end
					local dctType = 0
					if interlaced and cbp ~= 0 then
						dctType, bp = getBits(bp, 1)
					end
					mbQ[mbi + 1] = qscale
					local kind = 0
					if mcsel == 1 then
						kind = -1
						setMv4(amv(0), amv(1))
					elseif band(cbpc, 16) == 0 then
						local field = 0
						if interlaced then
							field, bp = getBits(bp, 1)
						end
						if field == 1 then
							kind = 3
							FS[1], bp = getBits(bp, 1)
							FS[2], bp = getBits(bp, 1)
							local px, py = predMv(0)
							for f = 1, 2 do
								MX[f] = motion(px, fcode)
								MY[f] = motion(divTrunc(py, 2), fcode)
							end
							-- the macroblock's vector for later predictions: the fields' average
							local ax = MX[1] + MX[2]
							local ay = MY[1] + MY[2]
							setMv4(orHalf(ax), ay)
							local fi = 2 * mbi + 1
							cur.fmvx[fi], cur.fmvy[fi], cur.fsel[fi] = MX[1], MY[1], FS[1]
							cur.fmvx[fi + 1], cur.fmvy[fi + 1], cur.fsel[fi + 1] = MX[2], MY[2], FS[2]
						else
							local px, py = predMv(0)
							MX[1] = motion(px, fcode)
							MY[1] = motion(py, fcode)
							setMv4(MX[1], MY[1])
						end
					else
						kind = 1
						for n = 0, 3 do
							local px, py = predMv(n)
							MX[n + 1] = motion(px, fcode)
							MY[n + 1] = motion(py, fcode)
							setMv(n, MX[n + 1], MY[n + 1])
						end
					end
					if kind < 0 then
						mbKind[mbi + 1] = 0
						gmcPredict()
					else
						mbKind[mbi + 1] = kind
						predict(last, kind, not noRounding, false)
					end
					for n = 0, 5 do
						if band(cbp, lshift(1, 5 - n)) ~= 0 then
							interBlock(n, dctType, qscale)
						end
					end
					clearIntra()
				end
			end
		else
			-- B picture
			if mbx == 0 then
				pfx, pfy, pbx, pby = 0, 0, 0, 0
				pffx[1], pffx[2], pffy[1], pffy[2] = 0, 0, 0, 0
				pbfx[1], pbfx[2], pbfy[1], pbfy[2] = 0, 0, 0, 0
			end
			mbQ[mbi + 1] = qscale
			if nxt.mbKind[mbi + 1] == 2 then
				-- the co-located macroblock was skipped in the next picture: this one is too (forward, no motion)
				MX[1], MY[1] = 0, 0
				predict(last, 0, true, false)
			else
				local modb1
				modb1, bp = getBits(bp, 1)
				local mbt, cbp = 0, 0
				if modb1 == 0 then
					local modb2
					modb2, bp = getBits(bp, 1)
					mbt, bp = getVlc(bp, MBTYPE_B, 4)
					if mbt < 0 then
						error("MPEG-4 video: a B macroblock type is damaged", 0)
					end
					if modb2 == 0 then
						cbp, bp = getBits(bp, 6)
					end
					if mbt ~= 0 and cbp ~= 0 then
						local dq
						dq, bp = getBits(bp, 1)
						if dq == 1 then
							local s
							s, bp = getBits(bp, 1)
							qscale = math.clamp(qscale + s * 4 - 2, 1, 31)
							mbQ[mbi + 1] = qscale
						end
					end
				end
				local dctType = 0
				local field = false
				local fsF, fsB = { 0, 0 }, { 0, 0 }
				if interlaced then
					if cbp ~= 0 then
						dctType, bp = getBits(bp, 1)
					end
					if mbt ~= 0 then
						local f
						f, bp = getBits(bp, 1)
						field = f == 1
						if field then
							if mbt == 1 or mbt == 3 then
								fsF[1], bp = getBits(bp, 1)
								fsF[2], bp = getBits(bp, 1)
							end
							if mbt == 1 or mbt == 2 then
								fsB[1], bp = getBits(bp, 1)
								fsB[2], bp = getBits(bp, 1)
							end
						end
					end
				end
				if mbt == 0 then
					-- direct: the next picture's co-located vectors, scaled by time, plus a delta
					local dx, dy = 0, 0
					if modb1 == 0 then
						dx = motion(0, 1)
						dy = motion(0, 1)
					end
					local colKind = nxt.mbKind[mbi + 1]
					local FX, FY, BX, BY = table.create(4, 0), table.create(4, 0), table.create(4, 0), table.create(4, 0)
					local function one(k, px2, py2)
						FX[k] = divTrunc(px2 * timePB, timePP) + dx
						BX[k] = dx ~= 0 and (FX[k] - px2) or divTrunc(px2 * (timePB - timePP), timePP)
						FY[k] = divTrunc(py2 * timePB, timePP) + dy
						BY[k] = dy ~= 0 and (FY[k] - py2) or divTrunc(py2 * (timePB - timePP), timePP)
					end
					local kind
					if colKind == 3 then
						-- the co-located macroblock had field vectors: each field scaled by its own time distance
						local fi = 2 * mbi + 1
						local ppF, pbF = st.ppFieldTime, st.pbFieldTime
						local SELF = { 0, 0 }
						for f = 0, 1 do
							local sel = nxt.fsel[fi + f]
							local tpp, tpb
							if tff then
								tpp, tpb = ppF - sel + f, pbF - sel + f
							else
								tpp, tpb = ppF + sel - f, pbF + sel - f
							end
							local px2, py2 = nxt.fmvx[fi + f], nxt.fmvy[fi + f]
							FX[f + 1] = divTrunc(px2 * tpb, tpp) + dx
							FY[f + 1] = divTrunc(py2 * tpb, tpp) + dy
							BX[f + 1] = dx ~= 0 and (FX[f + 1] - px2) or divTrunc(px2 * (tpb - tpp), tpp)
							BY[f + 1] = dy ~= 0 and (FY[f + 1] - py2) or divTrunc(py2 * (tpb - tpp), tpp)
							SELF[f + 1] = sel
						end
						MX[1], MY[1], MX[2], MY[2] = FX[1], FY[1], FX[2], FY[2]
						FS[1], FS[2] = SELF[1], SELF[2]
						predict(last, 3, true, false)
						MX[1], MY[1], MX[2], MY[2] = BX[1], BY[1], BX[2], BY[2]
						FS[1], FS[2] = 0, 1
						predict(nxt, 3, true, true)
						kind = -1
					elseif colKind == 1 then
						kind = 1
						for n = 0, 3 do
							local i = (2 * mby + rshift(n, 1)) * bw + 2 * mbx + band(n, 1) + 1
							one(n + 1, nxt.mvx[i], nxt.mvy[i])
						end
					else
						local i = 2 * mby * bw + 2 * mbx + 1
						one(1, nxt.mvx[i], nxt.mvy[i])
						for k = 2, 4 do
							FX[k], FY[k], BX[k], BY[k] = FX[1], FY[1], BX[1], BY[1]
						end
						kind = qpelMode and 1 or 0
					end
					if kind >= 0 then
						for k = 1, 4 do
							MX[k], MY[k] = FX[k], FY[k]
						end
						predict(last, kind, true, false)
						for k = 1, 4 do
							MX[k], MY[k] = BX[k], BY[k]
						end
						predict(nxt, kind, true, true)
					end
				else
					local fwd = mbt == 1 or mbt == 3
					local bwd = mbt == 1 or mbt == 2
					if not field then
						local fx, fy, bx2, by2
						if fwd then
							fx = motion(pfx, fcode)
							fy = motion(pfy, fcode)
							pfx, pfy = fx, fy
							pffx[2], pffy[2] = fx, fy
						end
						if bwd then
							bx2 = motion(pbx, bcode)
							by2 = motion(pby, bcode)
							pbx, pby = bx2, by2
							pbfx[2], pbfy[2] = bx2, by2
						end
						if fwd then
							MX[1], MY[1] = fx, fy
							predict(last, 0, true, false)
						end
						if bwd then
							MX[1], MY[1] = bx2, by2
							predict(nxt, 0, true, fwd)
						end
					else
						local F = { {}, {} }
						local Bv = { {}, {} }
						if fwd then
							for f = 1, 2 do
								F[f][1] = motion(f == 1 and pfx or pffx[2], fcode)
								F[f][2] = motion(divTrunc(f == 1 and pfy or pffy[2], 2), fcode)
							end
							pfx, pfy = F[1][1], F[1][2] * 2
							pffx[2], pffy[2] = F[2][1], F[2][2] * 2
						end
						if bwd then
							for f = 1, 2 do
								Bv[f][1] = motion(f == 1 and pbx or pbfx[2], bcode)
								Bv[f][2] = motion(divTrunc(f == 1 and pby or pbfy[2], 2), bcode)
							end
							pbx, pby = Bv[1][1], Bv[1][2] * 2
							pbfx[2], pbfy[2] = Bv[2][1], Bv[2][2] * 2
						end
						if fwd then
							MX[1], MY[1], MX[2], MY[2] = F[1][1], F[1][2], F[2][1], F[2][2]
							FS[1], FS[2] = fsF[1], fsF[2]
							predict(last, 3, true, false)
						end
						if bwd then
							MX[1], MY[1], MX[2], MY[2] = Bv[1][1], Bv[1][2], Bv[2][1], Bv[2][2]
							FS[1], FS[2] = fsB[1], fsB[2]
							predict(nxt, 3, true, fwd)
						end
					end
				end
				for n = 0, 5 do
					if band(cbp, lshift(1, 5 - n)) ~= 0 then
						interBlock(n, dctType, qscale)
					end
				end
			end
		end

		count += 1
		mbx += 1
		if mbx >= mbw then
			mbx = 0
			mby += 1
		end
		if count < nmbs and resyncNext() then
			count = mby * mbw + mbx
		end
	end
	self.pictType = ptype
	return cur
end

return Mpeg4
