--!native
--!optimize 2
-- FrameLab MPEG-1 / MPEG-2 video decoder (ISO/IEC 11172-2 and 13818-2: Main profile, 4:2:0, 8 bits per sample) in pure
-- Luau. Frame and field pictures, interlaced (field) prediction, dual prime, all scans, quantiser tables and VLC formats.
-- The inverse DCT gives the same pixels as FFmpeg's "simple" IDCT.
--
--   local dec = Mpeg2.new()
--   local pic = dec:decodeSample(buf, pos, size)
--       one coded frame (a frame picture, or both field pictures), with any sequence / GOP headers before it ->
--       { Y, U, V, ys, cs, yo, co } (4:2:0 planes, row strides ys / cs) in decode order, or nil when the sample holds
--       no picture; errors on damaged data or a picture whose reference is missing
--   dec.width, dec.height (the picture size), dec.bt709, dec.mpeg2 (false: MPEG-1), dec.fps,
--   dec.pictType (1 = I, 2 = P, 3 = B: the last picture decoded), dec.temporalRef
--   dec:reset()   forget the reference pictures (before decoding from another keyframe)

local Mpeg2 = {}
Mpeg2.__index = Mpeg2

local band, bor, bxor, lshift, rshift, bswap = bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift, bit32.byteswap
local readu8, writeu8, readu32, writeu32 = buffer.readu8, buffer.writeu8, buffer.readu32, buffer.writeu32

-- scan orders (scan index -> raster position)
local ZIGZAG = {
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}
local ALTERNATE = {
	0, 8, 16, 24, 1, 9, 2, 10, 17, 25, 32, 40, 48, 56, 57, 49, 41, 33, 26, 18, 3, 11, 4, 12, 19, 27, 34, 42, 50, 58, 35, 43,
	51, 59, 20, 28, 5, 13, 6, 14, 21, 29, 36, 44, 52, 60, 37, 45, 53, 61, 22, 30, 7, 15, 23, 31, 38, 46, 54, 62, 39, 47, 55, 63,
}
-- default quantiser matrices (raster order)
local DEFAULT_INTRA = {
	8, 16, 19, 22, 26, 27, 29, 34, 16, 16, 22, 24, 27, 29, 34, 37, 19, 22, 26, 27, 29, 34, 34, 38, 22, 22, 26, 27, 29, 34, 37, 40,
	22, 26, 27, 29, 32, 35, 40, 48, 26, 27, 29, 32, 35, 40, 48, 58, 26, 27, 29, 34, 38, 46, 56, 69, 27, 29, 35, 38, 46, 56, 69, 83,
}
local NON_LINEAR_Q = {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 18, 20, 22, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96, 104, 112,
}
local FRAME_RATES = { 24000 / 1001, 24, 25, 30000 / 1001, 30, 50, 60000 / 1001, 60 }

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

local DC_LUMA, DC_CHROMA
do
	local lc = { 0x4, 0x0, 0x1, 0x5, 0x6, 0xe, 0x1e, 0x3e, 0x7e, 0xfe, 0x1fe, 0x1ff }
	local lb = { 3, 2, 2, 3, 3, 4, 5, 6, 7, 8, 9, 9 }
	local cc = { 0x0, 0x1, 0x2, 0x6, 0xe, 0x1e, 0x3e, 0x7e, 0xfe, 0x1fe, 0x3fe, 0x3ff }
	local cb = { 2, 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10 }
	local a, b = {}, {}
	for i = 1, 12 do
		a[i] = { lc[i], lb[i], i - 1 }
		b[i] = { cc[i], cb[i], i - 1 }
	end
	DC_LUMA, DC_CHROMA = vlc(10, a), vlc(10, b)
end

-- DCT coefficients (tables B.14 and B.15): value = run + 64 * level; 62 = end of block, 63 = escape
local COEF_B14, COEF_B15
do
	local B14 = {
		0x3, 2, 0x4, 4, 0x5, 5, 0x6, 7, 0x26, 8, 0x21, 8, 0xa, 10, 0x1d, 12, 0x18, 12, 0x13, 12, 0x10, 12, 0x1a, 13, 0x19, 13, 0x18, 13,
		0x17, 13, 0x1f, 14, 0x1e, 14, 0x1d, 14, 0x1c, 14, 0x1b, 14, 0x1a, 14, 0x19, 14, 0x18, 14, 0x17, 14, 0x16, 14, 0x15, 14, 0x14, 14,
		0x13, 14, 0x12, 14, 0x11, 14, 0x10, 14, 0x18, 15, 0x17, 15, 0x16, 15, 0x15, 15, 0x14, 15, 0x13, 15, 0x12, 15, 0x11, 15, 0x10, 15,
		0x3, 3, 0x6, 6, 0x25, 8, 0xc, 10, 0x1b, 12, 0x16, 13, 0x15, 13, 0x1f, 15, 0x1e, 15, 0x1d, 15, 0x1c, 15, 0x1b, 15, 0x1a, 15,
		0x19, 15, 0x13, 16, 0x12, 16, 0x11, 16, 0x10, 16, 0x5, 4, 0x4, 7, 0xb, 10, 0x14, 12, 0x14, 13, 0x7, 5, 0x24, 8, 0x1c, 12,
		0x13, 13, 0x6, 5, 0xf, 10, 0x12, 12, 0x7, 6, 0x9, 10, 0x12, 13, 0x5, 6, 0x1e, 12, 0x14, 16, 0x4, 6, 0x15, 12, 0x7, 7, 0x11, 12,
		0x5, 7, 0x11, 13, 0x27, 8, 0x10, 13, 0x23, 8, 0x1a, 16, 0x22, 8, 0x19, 16, 0x20, 8, 0x18, 16, 0xe, 10, 0x17, 16, 0xd, 10, 0x16, 16,
		0x8, 10, 0x15, 16, 0x1f, 12, 0x1a, 12, 0x19, 12, 0x17, 12, 0x16, 12, 0x1f, 13, 0x1e, 13, 0x1d, 13, 0x1c, 13, 0x1b, 13, 0x1f, 16,
		0x1e, 16, 0x1d, 16, 0x1c, 16, 0x1b, 16, 0x1, 6, 0x2, 2,
	}
	local B15 = {
		0x02, 2, 0x06, 3, 0x07, 4, 0x1c, 5, 0x1d, 5, 0x05, 6, 0x04, 6, 0x7b, 7, 0x7c, 7, 0x23, 8, 0x22, 8, 0xfa, 8, 0xfb, 8, 0xfe, 8,
		0xff, 8, 0x1f, 14, 0x1e, 14, 0x1d, 14, 0x1c, 14, 0x1b, 14, 0x1a, 14, 0x19, 14, 0x18, 14, 0x17, 14, 0x16, 14, 0x15, 14, 0x14, 14,
		0x13, 14, 0x12, 14, 0x11, 14, 0x10, 14, 0x18, 15, 0x17, 15, 0x16, 15, 0x15, 15, 0x14, 15, 0x13, 15, 0x12, 15, 0x11, 15, 0x10, 15,
		0x02, 3, 0x06, 5, 0x79, 7, 0x27, 8, 0x20, 8, 0x16, 13, 0x15, 13, 0x1f, 15, 0x1e, 15, 0x1d, 15, 0x1c, 15, 0x1b, 15, 0x1a, 15,
		0x19, 15, 0x13, 16, 0x12, 16, 0x11, 16, 0x10, 16, 0x05, 5, 0x07, 7, 0xfc, 8, 0x0c, 10, 0x14, 13, 0x07, 5, 0x26, 8, 0x1c, 12,
		0x13, 13, 0x06, 6, 0xfd, 8, 0x12, 12, 0x07, 6, 0x04, 9, 0x12, 13, 0x06, 7, 0x1e, 12, 0x14, 16, 0x04, 7, 0x15, 12, 0x05, 7, 0x11, 12,
		0x78, 7, 0x11, 13, 0x7a, 7, 0x10, 13, 0x21, 8, 0x1a, 16, 0x25, 8, 0x19, 16, 0x24, 8, 0x18, 16, 0x05, 9, 0x17, 16, 0x07, 9, 0x16, 16,
		0x0d, 10, 0x15, 16, 0x1f, 12, 0x1a, 12, 0x19, 12, 0x17, 12, 0x16, 12, 0x1f, 13, 0x1e, 13, 0x1d, 13, 0x1c, 13, 0x1b, 13, 0x1f, 16,
		0x1e, 16, 0x1d, 16, 0x1c, 16, 0x1b, 16, 0x01, 6, 0x06, 4,
	}
	local LEVEL = {
		1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
		33, 34, 35, 36, 37, 38, 39, 40, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 1, 2, 3, 4, 5, 1,
		2, 3, 4, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2,
		1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
	}
	local RUN = {
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3,
		3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
		17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
	}
	local function build(t)
		local codes = {}
		for i = 1, #LEVEL do
			codes[i] = { t[2 * i - 1], t[2 * i], RUN[i] + 64 * LEVEL[i] }
		end
		table.insert(codes, { t[2 * #LEVEL + 1], t[2 * #LEVEL + 2], 63 })
		table.insert(codes, { t[2 * #LEVEL + 3], t[2 * #LEVEL + 4], 62 })
		return vlc(16, codes)
	end
	COEF_B14, COEF_B15 = build(B14), build(B15)
end

-- macroblock_address_increment (value: increment - 1; 33 escape, 34 stuffing, 35 end of slice)
local MB_INCR
do
	local t = {
		0x1, 1, 0x3, 3, 0x2, 3, 0x3, 4, 0x2, 4, 0x3, 5, 0x2, 5, 0x7, 7, 0x6, 7, 0xb, 8, 0xa, 8, 0x9, 8, 0x8, 8, 0x7, 8, 0x6, 8,
		0x17, 10, 0x16, 10, 0x15, 10, 0x14, 10, 0x13, 10, 0x12, 10, 0x23, 11, 0x22, 11, 0x21, 11, 0x20, 11, 0x1f, 11, 0x1e, 11,
		0x1d, 11, 0x1c, 11, 0x1b, 11, 0x1a, 11, 0x19, 11, 0x18, 11, 0x8, 11, 0xf, 11, 0x0, 8,
	}
	local codes = {}
	for i = 1, #t // 2 do
		codes[i] = { t[2 * i - 1], t[2 * i], i - 1 }
	end
	MB_INCR = vlc(11, codes)
end

-- macroblock_type: 1 intra, 2 coded pattern, 4 backward, 8 forward, 16 quantiser
local MB_FLAG_INTRA, MB_FLAG_PAT, MB_FLAG_BACK, MB_FLAG_FOR, MB_FLAG_QUANT = 1, 2, 4, 8, 16
local MBTYPE_P = vlc(6, {
	{ 3, 5, 0x01 }, { 1, 2, 0x02 }, { 1, 3, 0x08 }, { 1, 1, 0x0A }, { 1, 6, 0x11 }, { 1, 5, 0x12 }, { 2, 5, 0x1A },
})
local MBTYPE_B = vlc(6, {
	{ 3, 5, 0x01 }, { 2, 3, 0x04 }, { 3, 3, 0x06 }, { 2, 4, 0x08 }, { 3, 4, 0x0A }, { 2, 2, 0x0C }, { 3, 2, 0x0E },
	{ 1, 6, 0x11 }, { 2, 6, 0x16 }, { 3, 6, 0x1A }, { 2, 5, 0x1E },
})

local CBP
do
	local t = {
		0x1, 9, 0xb, 5, 0x9, 5, 0xd, 6, 0xd, 4, 0x17, 7, 0x13, 7, 0x1f, 8, 0xc, 4, 0x16, 7, 0x12, 7, 0x1e, 8, 0x13, 5, 0x1b, 8, 0x17, 8,
		0x13, 8, 0xb, 4, 0x15, 7, 0x11, 7, 0x1d, 8, 0x11, 5, 0x19, 8, 0x15, 8, 0x11, 8, 0xf, 6, 0xf, 8, 0xd, 8, 0x3, 9, 0xf, 5, 0xb, 8,
		0x7, 8, 0x7, 9, 0xa, 4, 0x14, 7, 0x10, 7, 0x1c, 8, 0xe, 6, 0xe, 8, 0xc, 8, 0x2, 9, 0x10, 5, 0x18, 8, 0x14, 8, 0x10, 8, 0xe, 5,
		0xa, 8, 0x6, 8, 0x6, 9, 0x12, 5, 0x1a, 8, 0x16, 8, 0x12, 8, 0xd, 5, 0x9, 8, 0x5, 8, 0x5, 9, 0xc, 5, 0x8, 8, 0x4, 8, 0x4, 9,
		0x7, 3, 0xa, 5, 0x8, 5, 0xc, 6,
	}
	local codes = {}
	for i = 1, 64 do
		codes[i] = { t[2 * i - 1], t[2 * i], i - 1 }
	end
	CBP = vlc(9, codes)
end

local MOTION
do
	local t = { 0x1, 1, 0x1, 2, 0x1, 3, 0x1, 4, 0x3, 6, 0x5, 7, 0x4, 7, 0x3, 7, 0xb, 9, 0xa, 9, 0x9, 9, 0x11, 10, 0x10, 10, 0xf, 10,
		0xe, 10, 0xd, 10, 0xc, 10 }
	local codes = {}
	for i = 1, 17 do
		codes[i] = { t[2 * i - 1], t[2 * i], i - 1 }
	end
	MOTION = vlc(10, codes)
end

---------------------------------------------------------------------------------------------------------------------------
-- bits: the picture's data is copied to S (with zero bytes after it), read from bit position bp

local S = buffer.create(65536)

-- the next 32 bits at bp (the first 25 always valid)
local function peek(bp: number): number
	return lshift(bswap(readu32(S, rshift(bp, 3))), band(bp, 7))
end

local function getBits(bp: number, n: number): (number, number)
	return rshift(lshift(bswap(readu32(S, rshift(bp, 3))), band(bp, 7)), 32 - n), bp + n
end

-- a VLC from table t (bits wide): value, new position; value -1 if no code matches
local function getVlc(bp: number, t: buffer, bits: number): (number, number)
	local e = readu32(t, 4 * rshift(peek(bp), 32 - bits))
	local len = band(e, 31)
	if len == 0 then
		return -1, bp
	end
	return rshift(e, 5), bp + len
end

---------------------------------------------------------------------------------------------------------------------------
-- inverse DCT (FFmpeg's simple IDCT, 8-bit: rows, then columns written to the picture)

local W1, W2, W3, W4, W5, W6, W7 = 22725, 21407, 19266, 16383, 12873, 8867, 4520

local blk = table.create(64, 0) -- the block being decoded (raster order, 1-based)

-- rows (rowMask: bit r set when row r has a coefficient)
local function idctRows(b, rowMask: number)
	for r = 0, 7 do
		if band(rowMask, lshift(1, r)) ~= 0 then
			local o = r * 8 + 1
			local r0, r1, r2, r3, r4, r5, r6, r7 = b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4], b[o + 5], b[o + 6], b[o + 7]
			if r1 == 0 and r2 == 0 and r3 == 0 and r4 == 0 and r5 == 0 and r6 == 0 and r7 == 0 then
				local v = r0 * 8
				b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4], b[o + 5], b[o + 6], b[o + 7] = v, v, v, v, v, v, v, v
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
	end
end

-- columns -> picture: add = false writes the block, true adds it to the prediction there
local function idctCols(b, rowMask: number, dst: buffer, off: number, stride: number, add: boolean)
	if rowMask == 1 then
		-- (only the first row: each column is flat)
		for c = 1, 8 do
			local v = (W4 * (b[c] + 32)) // 1048576
			local p = off + c - 1
			if add then
				for _ = 1, 8 do
					writeu8(dst, p, math.clamp(readu8(dst, p) + v, 0, 255))
					p += stride
				end
			else
				local x = math.clamp(v, 0, 255)
				for _ = 1, 8 do
					writeu8(dst, p, x)
					p += stride
				end
			end
		end
		return
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
		local p = off + c - 1
		local v0, v1, v2, v3 = (a0 + b0) // 1048576, (a1 + b1) // 1048576, (a2 + b2) // 1048576, (a3 + b3) // 1048576
		local v4, v5, v6, v7 = (a3 - b3) // 1048576, (a2 - b2) // 1048576, (a1 - b1) // 1048576, (a0 - b0) // 1048576
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
-- motion compensation: a w x h block from a reference plane (rows from rBase, rStride apart, rh of them, rw wide) at
-- whole-sample position (sx, sy) plus half a sample right (hx = 1) / down (hy = 1); written to dst, or averaged with
-- what is there (avg)

local EDGE = buffer.create(17 * 17)

local function mc(dst: buffer, dOff: number, dStride: number, ref: buffer, rBase: number, rStride: number, rw: number,
	rh: number, sx: number, sy: number, hx: number, hy: number, w: number, h: number, avg: boolean)
	local src, sStride
	if sx >= 0 and sy >= 0 and sx + w + hx <= rw and sy + h + hy <= rh then
		src, sStride = rBase + sy * rStride + sx, rStride
	else
		-- (outside the picture: its edge samples repeat)
		for y = 0, h + hy - 1 do
			local ry = math.clamp(sy + y, 0, rh - 1)
			local row = rBase + ry * rStride
			for x = 0, w + hx - 1 do
				writeu8(EDGE, y * 17 + x, readu8(ref, row + math.clamp(sx + x, 0, rw - 1)))
			end
		end
		ref, src, sStride = EDGE, 0, 17
	end
	local words = w // 4
	if hx == 0 and hy == 0 then
		if avg then
			for _ = 1, h do
				for k = 0, words - 1 do
					local a, b = readu32(dst, dOff + 4 * k), readu32(ref, src + 4 * k)
					writeu32(dst, dOff + 4 * k, bor(a, b) - rshift(band(bxor(a, b), 0xFEFEFEFE), 1))
				end
				dOff += dStride
				src += sStride
			end
		else
			for _ = 1, h do
				buffer.copy(dst, dOff, ref, src, w)
				dOff += dStride
				src += sStride
			end
		end
	elseif hy == 0 or hx == 0 then
		local s2 = hx == 1 and 1 or sStride
		for _ = 1, h do
			for k = 0, words - 1 do
				local a, b = readu32(ref, src + 4 * k), readu32(ref, src + s2 + 4 * k)
				local p = bor(a, b) - rshift(band(bxor(a, b), 0xFEFEFEFE), 1)
				if avg then
					local d = readu32(dst, dOff + 4 * k)
					p = bor(d, p) - rshift(band(bxor(d, p), 0xFEFEFEFE), 1)
				end
				writeu32(dst, dOff + 4 * k, p)
			end
			dOff += dStride
			src += sStride
		end
	else
		for _ = 1, h do
			local a, c = readu8(ref, src), readu8(ref, src + sStride)
			for x = 0, w - 1 do
				local b, d = readu8(ref, src + x + 1), readu8(ref, src + sStride + x + 1)
				local p = (a + b + c + d + 2) // 4
				if avg then
					p = (readu8(dst, dOff + x) + p + 1) // 2
				end
				writeu8(dst, dOff + x, p)
				a, c = b, d
			end
			dOff += dStride
			src += sStride
		end
	end
end

-- chroma vectors: half the luma one, towards zero
local function halfTowardZero(v: number): number
	if v < 0 then
		return -((-v) // 2)
	end
	return v // 2
end

---------------------------------------------------------------------------------------------------------------------------

function Mpeg2.new()
	local self = setmetatable({}, Mpeg2)
	self.width, self.height = 0, 0
	self.bt709 = false
	self.mpeg2 = false
	self.fps = 25
	self.intraQ = table.clone(DEFAULT_INTRA)
	self.interQ = table.create(64, 16)
	self.chromaIntraQ = table.clone(DEFAULT_INTRA)
	self.chromaInterQ = table.create(64, 16)
	self.progressiveSeq = true
	self.frames = {}
	return self
end

function Mpeg2:reset()
	self.last, self.next, self.cur = nil, nil, nil
	self.secondField = false
end

-- planes for a w x h sequence: coded size in whole macroblocks (an interlaced MPEG-2 sequence: whole pairs of rows)
function Mpeg2:allocate()
	local mbw = (self.width + 15) // 16
	local mbh = (self.height + 15) // 16
	if self.mpeg2 and not self.progressiveSeq then
		mbh = 2 * ((self.height + 31) // 32)
	end
	self.mbw, self.mbh = mbw, mbh
	if mbw == self.allocW and mbh == self.allocH then
		return
	end
	self.allocW, self.allocH = mbw, mbh
	local W, H = mbw * 16, mbh * 16
	self.frames = {}
	for i = 1, 3 do
		local Y, U, V = buffer.create(W * H), buffer.create(W * H // 4), buffer.create(W * H // 4)
		buffer.fill(Y, 0, 0)
		buffer.fill(U, 0, 128)
		buffer.fill(V, 0, 128)
		self.frames[i] = { Y = Y, U = U, V = V, ys = W, cs = W // 2, yo = 0, co = 0 }
	end
	self:reset()
end

local function loadMatrix(bp, into1, into2, intra)
	for i = 1, 64 do
		local v
		v, bp = getBits(bp, 8)
		if v == 0 then
			error("MPEG video: a quantiser matrix is damaged", 0)
		end
		if intra and i == 1 then
			v = 8
		end
		local j = ZIGZAG[i] + 1
		into1[j] = v
		if into2 then
			into2[j] = v
		end
	end
	return bp
end

function Mpeg2:sequenceHeader(bp)
	local w, h, aspect, rate
	w, bp = getBits(bp, 12)
	h, bp = getBits(bp, 12)
	aspect, bp = getBits(bp, 4)
	rate, bp = getBits(bp, 4)
	bp += 18 + 1 + 10 + 1 -- (bit rate, marker, VBV buffer size, constrained parameters)
	if w == 0 or h == 0 then
		error("MPEG video: the sequence header has no picture size", 0)
	end
	self.aspect = aspect
	self.fps = FRAME_RATES[rate] or 25
	self.rateCode = rate
	local load
	load, bp = getBits(bp, 1)
	if load == 1 then
		bp = loadMatrix(bp, self.intraQ, self.chromaIntraQ, true)
	else
		for i = 1, 64 do
			self.intraQ[i], self.chromaIntraQ[i] = DEFAULT_INTRA[i], DEFAULT_INTRA[i]
		end
	end
	load, bp = getBits(bp, 1)
	if load == 1 then
		bp = loadMatrix(bp, self.interQ, self.chromaInterQ)
	else
		for i = 1, 64 do
			self.interQ[i], self.chromaInterQ[i] = 16, 16
		end
	end
	if self.width ~= w or self.height ~= h then
		self.width, self.height = w, h
	end
	-- (MPEG-1 until a sequence extension says otherwise)
	self.mpeg2 = false
	self.progressiveSeq = true
	self.bt709 = false
	self.seenSequence = true
end

function Mpeg2:extension(bp)
	local id
	id, bp = getBits(bp, 4)
	if id == 1 then -- sequence extension
		local prog, chroma, hx, vx
		bp += 8
		prog, bp = getBits(bp, 1)
		chroma, bp = getBits(bp, 2)
		hx, bp = getBits(bp, 2)
		vx, bp = getBits(bp, 2)
		bp += 12 + 1 + 8 + 1
		local en, ed
		en, bp = getBits(bp, 2)
		ed, bp = getBits(bp, 5)
		if chroma == 2 or chroma == 3 then
			error(("MPEG video: the picture is %s colour, which FrameLab can't read (4:2:0 works)"):format(chroma == 2 and "4:2:2" or "4:4:4"), 0)
		end
		self.mpeg2 = true
		self.progressiveSeq = prog == 1
		local w, h = band(self.width, 0xFFF) + hx * 4096, band(self.height, 0xFFF) + vx * 4096
		self.width, self.height = w, h
		local base = FRAME_RATES[self.rateCode or 3] or 25
		self.fps = base * (en + 1) / (ed + 1)
		-- (high-definition pictures default to BT.709 colour, others to BT.601)
		self.bt709 = self.height > 576
	elseif id == 2 then -- sequence display extension
		local desc
		bp += 3
		desc, bp = getBits(bp, 1)
		if desc == 1 then
			local matrix
			bp += 16
			matrix, bp = getBits(bp, 8)
			if matrix == 1 then
				self.bt709 = true
			elseif matrix == 4 or matrix == 5 or matrix == 6 then
				self.bt709 = false
			end
		end
	elseif id == 3 then -- quantiser matrix extension
		local load
		load, bp = getBits(bp, 1)
		if load == 1 then
			bp = loadMatrix(bp, self.chromaIntraQ, self.intraQ, true)
		end
		load, bp = getBits(bp, 1)
		if load == 1 then
			bp = loadMatrix(bp, self.chromaInterQ, self.interQ)
		end
		load, bp = getBits(bp, 1)
		if load == 1 then
			bp = loadMatrix(bp, self.chromaIntraQ, nil, true)
		end
		load, bp = getBits(bp, 1)
		if load == 1 then
			bp = loadMatrix(bp, self.chromaInterQ, nil)
		end
	elseif id == 8 then -- picture coding extension
		local p = self.pic
		if not p then
			return
		end
		local f = table.create(4, 0)
		for i = 1, 4 do
			f[i], bp = getBits(bp, 4)
			if f[i] == 0 then
				f[i] = 1
			end
		end
		p.fcode = f
		p.fullPel = { 0, 0 }
		local v
		v, bp = getBits(bp, 14)
		p.dcPrec = rshift(v, 12)
		p.structure = band(rshift(v, 10), 3)
		p.tff = band(rshift(v, 9), 1) == 1
		p.framePredDct = band(rshift(v, 8), 1) == 1
		p.concealment = band(rshift(v, 7), 1) == 1
		p.qScaleType = band(rshift(v, 6), 1) == 1
		p.intraVlc = band(rshift(v, 5), 1) == 1
		p.altScan = band(rshift(v, 4), 1) == 1
		p.rff = band(rshift(v, 3), 1) == 1
		p.progressiveFrame = band(v, 1) == 1
		if p.structure == 0 then
			error("MPEG video: a picture has no structure", 0)
		end
	end
end

function Mpeg2:pictureHeader(bp)
	local tr, t
	tr, bp = getBits(bp, 10)
	t, bp = getBits(bp, 3)
	bp += 16
	if t < 1 or t > 3 then
		error(("MPEG video: picture type %d isn't supported"):format(t), 0)
	end
	-- (MPEG-1 values; an MPEG-2 picture coding extension replaces them)
	local p = { type = t, tr = tr, fcode = { 1, 1, 1, 1 }, fullPel = { 0, 0 }, dcPrec = 0, structure = 3, tff = true,
		framePredDct = true, concealment = false, qScaleType = false, intraVlc = false, altScan = false, rff = false,
		progressiveFrame = true }
	if t >= 2 then
		local fp, fc
		fp, bp = getBits(bp, 1)
		fc, bp = getBits(bp, 3)
		fc = math.max(fc, 1)
		p.fullPel[1], p.fcode[1], p.fcode[2] = fp, fc, fc
	end
	if t == 3 then
		local fp, fc
		fp, bp = getBits(bp, 1)
		fc, bp = getBits(bp, 3)
		fc = math.max(fc, 1)
		p.fullPel[2], p.fcode[3], p.fcode[4] = fp, fc, fc
	end
	self.pic = p
	self.picStarted = false
end

-- the reference pictures and the buffer for a new frame (at its first slice)
function Mpeg2:startPicture()
	local p = self.pic
	self.picStarted = true
	self:allocate()
	local field = p.structure ~= 3
	if field and self.secondField and self.cur and self.cur.firstStructure ~= p.structure then
		-- the second field of the frame begun by the first
		p.second = true
		self.secondField = false
		return
	end
	p.second = false
	self.secondField = field
	local free
	for _, f in ipairs(self.frames) do
		if f ~= self.last and f ~= self.next then
			free = f
			break
		end
	end
	if p.type ~= 3 then
		self.last = self.next
		self.next = free
	end
	self.cur = free
	free.firstStructure = p.structure
	free.type = p.type
end

---------------------------------------------------------------------------------------------------------------------------
-- slices

-- the motion vector difference added to pred (fcode: its range), wrapped into range
local function motionDelta(bp: number, fcode: number, pred: number): (number, number)
	local code
	code, bp = getVlc(bp, MOTION, 10)
	if code < 0 then
		error("MPEG video: a motion vector is damaged", 0)
	end
	if code == 0 then
		return pred, bp
	end
	local sign
	sign, bp = getBits(bp, 1)
	local shift = fcode - 1
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
	local m = 2 ^ (5 + shift)
	return (val + m // 2) % m - m // 2, bp
end

local function getDmv(bp: number): (number, number)
	local b
	b, bp = getBits(bp, 1)
	if b == 0 then
		return 0, bp
	end
	b, bp = getBits(bp, 1)
	return 1 - 2 * b, bp
end

-- one slice; mbRow: its first macroblock row (of the field, in a field picture)
function Mpeg2:decodeSlice(bp: number, mbRow: number)
	local p = self.pic
	local mpeg2 = self.mpeg2
	local cur, last, nxt = self.cur, self.last, self.next
	local ptype = p.type
	if (ptype == 2 and not last and not (p.second and p.structure ~= 3)) or (ptype == 3 and (not last or not nxt)) then
		error("MPEG video: a picture's reference picture is missing", 0)
	end
	if ptype == 2 and not last then
		-- (the second field of a key frame, predicted from its first field only)
		last = cur
	end
	local mbw = self.mbw
	local fieldPic = p.structure ~= 3
	local parity = p.structure == 2 and 1 or 0
	local mbRows = fieldPic and self.mbh // 2 or self.mbh
	local Y, U, V = cur.Y, cur.U, cur.V
	local ys, cs = cur.ys, cur.cs
	local W, H = mbw * 16, self.mbh * 16
	local pS, pCS = ys, cs
	local pBase, cBase = 0, 0
	if fieldPic then
		pS, pCS = 2 * ys, 2 * cs
		pBase, cBase = parity * ys, parity * cs
	end
	local second = p.second
	local fcode = p.fcode
	local fullPel = p.fullPel
	local dcPrec = p.dcPrec
	local framePredDct = p.framePredDct
	local concealment = p.concealment
	local qScaleType = p.qScaleType
	local scan = p.altScan and ALTERNATE or ZIGZAG
	local intraTab = p.intraVlc and COEF_B15 or COEF_B14
	local intraQ, interQ, cIntraQ, cInterQ = self.intraQ, self.interQ, self.chromaIntraQ, self.chromaInterQ
	local tff = p.tff
	local b = blk

	if mpeg2 and self.mbh > 175 then
		local ext
		ext, bp = getBits(bp, 3)
		mbRow += ext * 128
	end
	local mbx, mby = 0, mbRow
	if mby >= mbRows then
		error("MPEG video: a slice starts below the picture", 0)
	end
	local q
	q, bp = getBits(bp, 5)
	local qscale = qScaleType and NON_LINEAR_Q[q + 1] or q * 2
	if qscale == 0 then
		error("MPEG video: a slice has quantiser 0", 0)
	end
	-- (extra slice information)
	while true do
		local more
		more, bp = getBits(bp, 1)
		if more == 0 then
			break
		end
		bp += 8
	end
	-- the first macroblock's column
	while true do
		local code
		code, bp = getVlc(bp, MB_INCR, 11)
		if code < 0 then
			error("MPEG video: a slice's first macroblock address is damaged", 0)
		elseif code == 33 then
			mbx += 33
		elseif code < 33 then
			mbx += code
			break
		end
	end
	if mbx >= mbw then
		error("MPEG video: a slice starts past the picture's right edge", 0)
	end

	local dcReset = 128 * 2 ^ dcPrec
	local dcY, dcU, dcV = dcReset, dcReset, dcReset
	-- motion vector predictors pmv[dir * 4 + r * 2 + comp + 1], vectors mv[dir * 8 + k * 2 + comp + 1], field selects
	local pmv = table.create(8, 0)
	local mv = table.create(16, 0)
	local fsel = table.create(4, 0)
	local mvDir = 0 -- 1 forward, 2 backward, 3 both
	local mvType = 0 -- 0 frame (16x16), 1 field, 2 16x8, 3 dual prime
	local prevIntra = false
	local skipRun = 0

	-- the prediction of the current macroblock from one direction (dir 0 forward, 1 backward)
	local function predict(dir: number, avg: boolean)
		local ref = dir == 0 and last or nxt
		local lumaO = pBase + mby * 16 * pS + mbx * 16
		local chromaO = cBase + mby * 8 * pCS + mbx * 8
		local o = dir * 8
		-- one vector: ref frame f, its field fsl (-1: the frame), at luma row ly (of that frame / field), h rows high
		local function one(f, fsl: number, ly: number, h: number, mx: number, my: number, dY: number, dYS: number, dC: number,
			dCS: number, a: boolean)
			local rB, rS, rH, cB, cS, cH = 0, ys, H, 0, cs, H // 2
			if fsl >= 0 then
				rB, rS, rH, cB, cS, cH = fsl * ys, 2 * ys, H // 2, fsl * cs, 2 * cs, H // 4
			end
			mc(Y, dY, dYS, f.Y, rB, rS, W, rH, mbx * 16 + mx // 2, ly + my // 2, mx % 2, my % 2, 16, h, a)
			local cx, cy = halfTowardZero(mx), halfTowardZero(my)
			local cxp, cyp = mbx * 8 + cx // 2, ly // 2 + cy // 2
			mc(U, dC, dCS, f.U, cB, cS, W // 2, cH, cxp, cyp, cx % 2, cy % 2, 8, h // 2, a)
			mc(V, dC, dCS, f.V, cB, cS, W // 2, cH, cxp, cyp, cx % 2, cy % 2, 8, h // 2, a)
		end
		if not fieldPic then
			if mvType == 0 then
				one(ref, -1, mby * 16, 16, mv[o + 1], mv[o + 2], lumaO, ys, chromaO, cs, avg)
			elseif mvType == 1 then
				one(ref, fsel[dir * 2 + 1], mby * 8, 8, mv[o + 1], mv[o + 2], lumaO, 2 * ys, chromaO, 2 * cs, avg)
				one(ref, fsel[dir * 2 + 2], mby * 8, 8, mv[o + 3], mv[o + 4], lumaO + ys, 2 * ys, chromaO + cs, 2 * cs, avg)
			else -- dual prime
				one(ref, 0, mby * 8, 8, mv[o + 1], mv[o + 2], lumaO, 2 * ys, chromaO, 2 * cs, false)
				one(ref, 1, mby * 8, 8, mv[o + 3], mv[o + 4], lumaO + ys, 2 * ys, chromaO + cs, 2 * cs, false)
				one(ref, 1, mby * 8, 8, mv[o + 5], mv[o + 6], lumaO, 2 * ys, chromaO, 2 * cs, true)
				one(ref, 0, mby * 8, 8, mv[o + 7], mv[o + 8], lumaO + ys, 2 * ys, chromaO + cs, 2 * cs, true)
			end
		else
			if mvType == 1 then
				local sel = fsel[dir * 2 + 1]
				local f = ref
				if sel ~= parity and ptype ~= 3 and second then
					f = cur
				end
				one(f, sel, mby * 16, 16, mv[o + 1], mv[o + 2], lumaO, pS, chromaO, pCS, avg)
			elseif mvType == 2 then
				for i = 0, 1 do
					local sel = fsel[dir * 2 + i + 1]
					local f = ref
					if sel ~= parity and ptype ~= 3 and second then
						f = cur
					end
					one(f, sel, mby * 16 + 8 * i, 8, mv[o + 2 * i + 1], mv[o + 2 * i + 2], lumaO + 8 * i * pS, pS,
						chromaO + 4 * i * pCS, pCS, avg)
				end
			else -- dual prime
				one(ref, parity, mby * 16, 16, mv[o + 1], mv[o + 2], lumaO, pS, chromaO, pCS, false)
				one(second and cur or ref, 1 - parity, mby * 16, 16, mv[o + 5], mv[o + 6], lumaO, pS, chromaO, pCS, true)
			end
		end
	end

	-- one coded block (n: 0-3 luma, 4 Cb, 5 Cr) of an intra (true) or a predicted macroblock, added to / written at the picture
	local function block(n: number, intra: boolean, dctType: number)
		local rowMask = 0
		local sum = 0 -- (for MPEG-2 mismatch control: the coefficients' sum's parity)
		local filled = 0
		local i
		local quant
		if intra then
			-- DC
			local size
			if n < 4 then
				size, bp = getVlc(bp, DC_LUMA, 10)
				quant = intraQ
			else
				size, bp = getVlc(bp, DC_CHROMA, 10)
				quant = cIntraQ
			end
			if size < 0 then
				error("MPEG video: a DC coefficient is damaged", 0)
			end
			local diff = 0
			if size > 0 then
				diff, bp = getBits(bp, size)
				if diff < 2 ^ (size - 1) then
					diff -= 2 ^ size - 1
				end
			end
			local dc
			if n < 4 then
				dcY += diff
				dc = dcY
			elseif n == 4 then
				dcU += diff
				dc = dcU
			else
				dcV += diff
				dc = dcV
			end
			if not mpeg2 then
				quant = intraQ
				b[1] = dc * quant[1]
			else
				b[1] = dc * 2 ^ (3 - dcPrec)
			end
			sum = b[1]
			if b[1] ~= 0 then
				rowMask = 1
			end
			filled = 1
			i = 0
		else
			quant = (n < 4 or not mpeg2) and interQ or cInterQ
			i = -1
			-- (the first coefficient: "1s" is run 0, level 1)
			local w = peek(bp)
			if w >= 0x80000000 then
				local level = (3 * qscale * quant[1]) // 32
				if not mpeg2 then
					level = bor(level - 1, 1)
				end
				if band(w, 0x40000000) ~= 0 then
					level = -level
				end
				b[1] = level
				sum = level
				rowMask = 1
				filled = 1
				i = 0
				bp += 2
			end
		end
		local tab = (intra and mpeg2) and intraTab or COEF_B14
		while true do
			local w = peek(bp)
			local e = readu32(tab, 4 * rshift(w, 16))
			local len = band(e, 31)
			local v = rshift(e, 5)
			if len == 0 then
				error("MPEG video: a DCT coefficient is damaged", 0)
			end
			if v == 62 then
				bp += len
				break
			end
			local level, run
			if v ~= 63 then
				run, level = band(v, 63), rshift(v, 6)
				local neg = band(lshift(w, len), 0x80000000) ~= 0
				bp += len + 1
				i += run + 1
				if i > 63 then
					error("MPEG video: a block has too many coefficients", 0)
				end
				local j = scan[i + 1]
				if intra then
					level = (level * qscale * quant[j + 1]) // 16
				else
					level = ((2 * level + 1) * qscale * quant[j + 1]) // 32
				end
				if not mpeg2 then
					level = bor(level - 1, 1)
				end
				if neg then
					level = -level
				end
				b[j + 1] = level
				sum += level
				rowMask = bor(rowMask, lshift(1, rshift(j, 3)))
				filled += 1
			else
				-- escape: a run, then the level in 12 bits (MPEG-2) or 8 / 16 bits (MPEG-1)
				bp += len
				run, bp = getBits(bp, 6)
				if mpeg2 then
					level, bp = getBits(bp, 12)
					if level >= 2048 then
						level -= 4096
					end
				else
					level, bp = getBits(bp, 8)
					if level == 128 then
						level, bp = getBits(bp, 8)
						level -= 256
					elseif level == 0 then
						level, bp = getBits(bp, 8)
					elseif level > 128 then
						level -= 256
					end
				end
				i += run + 1
				if i > 63 then
					error("MPEG video: a block has too many coefficients", 0)
				end
				local j = scan[i + 1]
				local neg = level < 0
				if neg then
					level = -level
				end
				if intra then
					level = (level * qscale * quant[j + 1]) // 16
				else
					level = ((2 * level + 1) * qscale * quant[j + 1]) // 32
				end
				if not mpeg2 then
					level = bor(level - 1, 1)
				end
				if neg then
					level = -level
				end
				b[j + 1] = level
				sum += level
				rowMask = bor(rowMask, lshift(1, rshift(j, 3)))
				filled += 1
			end
		end
		if mpeg2 and sum % 2 == 0 then
			-- (mismatch control: the last coefficient's lowest bit flips when the sum is even)
			local v = b[64]
			b[64] = v % 2 == 0 and v + 1 or v - 1
			rowMask = bor(rowMask, 0x80)
		end
		if rowMask == 0 then
			if intra then
				-- (all zero: an intra block is flat 0 then)
				rowMask = 1
			else
				return
			end
		end
		-- where it goes
		local dst, off, stride
		if n < 4 then
			dst = Y
			local base = pBase + mby * 16 * pS + mbx * 16
			if dctType == 1 then
				off = base + band(n, 1) * 8 + rshift(n, 1) * ys
				stride = 2 * ys
			else
				off = base + band(n, 1) * 8 + rshift(n, 1) * 8 * pS
				stride = pS
			end
		else
			dst = n == 4 and U or V
			off = cBase + mby * 8 * pCS + mbx * 8
			stride = pCS
		end
		idctRows(b, rowMask)
		idctCols(b, rowMask, dst, off, stride, not intra)
		for k = 1, 64 do
			b[k] = 0
		end
	end

	while true do
		if skipRun > 0 then
			-- a skipped macroblock
			skipRun -= 1
			if ptype == 3 then
				if prevIntra then
					error("MPEG video: a skipped macroblock follows an intra one in a B picture", 0)
				end
				mv[1], mv[2], mv[9], mv[10] = pmv[1], pmv[2], pmv[5], pmv[6]
			else
				mvDir = 1
				mv[1], mv[2] = 0, 0
				for k = 1, 4 do
					pmv[k] = 0
				end
			end
			fsel[1], fsel[3] = parity, parity
			mvType = fieldPic and 1 or 0
			dcY, dcU, dcV = dcReset, dcReset, dcReset
			if band(mvDir, 1) ~= 0 then
				predict(0, false)
			end
			if band(mvDir, 2) ~= 0 then
				predict(1, mvDir == 3)
			end
		else
			-- macroblock_type
			local mbType
			if ptype == 1 then
				local bit
				bit, bp = getBits(bp, 1)
				if bit == 1 then
					mbType = MB_FLAG_INTRA
				else
					bit, bp = getBits(bp, 1)
					if bit == 0 then
						error("MPEG video: a macroblock type is damaged", 0)
					end
					mbType = MB_FLAG_INTRA + MB_FLAG_QUANT
				end
			else
				mbType, bp = getVlc(bp, ptype == 2 and MBTYPE_P or MBTYPE_B, 6)
				if mbType < 0 then
					error("MPEG video: a macroblock type is damaged", 0)
				end
			end
			local dctType = 0
			if band(mbType, MB_FLAG_INTRA) ~= 0 then
				if not fieldPic and not framePredDct then
					dctType, bp = getBits(bp, 1)
				end
				if band(mbType, MB_FLAG_QUANT) ~= 0 then
					q, bp = getBits(bp, 5)
					qscale = qScaleType and NON_LINEAR_Q[q + 1] or q * 2
				end
				if concealment then
					if fieldPic then
						bp += 1
					end
					local vx, vy
					vx, bp = motionDelta(bp, fcode[1], pmv[1])
					vy, bp = motionDelta(bp, fcode[2], pmv[2])
					pmv[1], pmv[3], pmv[2], pmv[4] = vx, vx, vy, vy
					bp += 1 -- (marker)
				else
					for k = 1, 8 do
						pmv[k] = 0
					end
				end
				prevIntra = true
				for n = 0, 5 do
					block(n, true, dctType)
				end
			else
				prevIntra = false
				dcY, dcU, dcV = dcReset, dcReset, dcReset
				if band(mbType, MB_FLAG_FOR + MB_FLAG_BACK) == 0 then
					-- (a P macroblock without motion: no vector, from the same place)
					mvDir = 1
					if not fieldPic then
						if not framePredDct then
							dctType, bp = getBits(bp, 1)
						end
						mvType = 0
					else
						mvType = 1
						fsel[1] = parity
					end
					if band(mbType, MB_FLAG_QUANT) ~= 0 then
						q, bp = getBits(bp, 5)
						qscale = qScaleType and NON_LINEAR_Q[q + 1] or q * 2
					end
					for k = 1, 4 do
						pmv[k] = 0
					end
					mv[1], mv[2] = 0, 0
				else
					local motionType = 2 -- (frame: 2; field pictures: 1 field, 2 16x8, 3 dual prime)
					if fieldPic or not framePredDct then
						motionType, bp = getBits(bp, 2)
						if not fieldPic and band(mbType, MB_FLAG_PAT) ~= 0 then
							dctType, bp = getBits(bp, 1)
						end
					end
					if band(mbType, MB_FLAG_QUANT) ~= 0 then
						q, bp = getBits(bp, 5)
						qscale = qScaleType and NON_LINEAR_Q[q + 1] or q * 2
					end
					mvDir = (band(mbType, MB_FLAG_FOR) ~= 0 and 1 or 0) + (band(mbType, MB_FLAG_BACK) ~= 0 and 2 or 0)
					if motionType == 0 then
						error("MPEG video: a macroblock's motion type is damaged", 0)
					end
					for dir = 0, 1 do
						if band(mvDir, dir + 1) ~= 0 then
							local fx, fy = fcode[dir * 2 + 1], fcode[dir * 2 + 2]
							local o, po = dir * 8, dir * 4
							if motionType == 2 and not fieldPic then
								-- frame prediction
								mvType = 0
								local vx, vy
								vx, bp = motionDelta(bp, fx, pmv[po + 1])
								vy, bp = motionDelta(bp, fy, pmv[po + 2])
								pmv[po + 1], pmv[po + 3], pmv[po + 2], pmv[po + 4] = vx, vx, vy, vy
								if fullPel[dir + 1] == 1 then
									vx, vy = vx * 2, vy * 2
								end
								mv[o + 1], mv[o + 2] = vx, vy
							elseif motionType == 2 then
								-- 16x8 (field pictures)
								mvType = 2
								for r = 0, 1 do
									fsel[dir * 2 + r + 1], bp = getBits(bp, 1)
									local vx, vy
									vx, bp = motionDelta(bp, fx, pmv[po + 2 * r + 1])
									vy, bp = motionDelta(bp, fy, pmv[po + 2 * r + 2])
									pmv[po + 2 * r + 1], pmv[po + 2 * r + 2] = vx, vy
									mv[o + 2 * r + 1], mv[o + 2 * r + 2] = vx, vy
								end
							elseif motionType == 1 then
								mvType = 1
								if not fieldPic then
									-- field prediction in a frame picture: one vector per field (vertical in field units)
									for r = 0, 1 do
										fsel[dir * 2 + r + 1], bp = getBits(bp, 1)
										local vx, vy
										vx, bp = motionDelta(bp, fx, pmv[po + 2 * r + 1])
										vy, bp = motionDelta(bp, fy, pmv[po + 2 * r + 2] // 2)
										pmv[po + 2 * r + 1], pmv[po + 2 * r + 2] = vx, vy * 2
										mv[o + 2 * r + 1], mv[o + 2 * r + 2] = vx, vy
									end
								else
									fsel[dir * 2 + 1], bp = getBits(bp, 1)
									local vx, vy
									vx, bp = motionDelta(bp, fx, pmv[po + 1])
									vy, bp = motionDelta(bp, fy, pmv[po + 2])
									pmv[po + 1], pmv[po + 3], pmv[po + 2], pmv[po + 4] = vx, vx, vy, vy
									mv[o + 1], mv[o + 2] = vx, vy
								end
							else
								-- dual prime
								if self.progressiveSeq then
									error("MPEG video: dual prime in a progressive sequence", 0)
								end
								mvType = 3
								local myShift = fieldPic and 1 or 2
								local vx, vy, dmx, dmy
								vx, bp = motionDelta(bp, fx, pmv[po + 1])
								pmv[po + 1], pmv[po + 3] = vx, vx
								dmx, bp = getDmv(bp)
								vy, bp = motionDelta(bp, fy, pmv[po + 2] // myShift)
								dmy, bp = getDmv(bp)
								pmv[po + 2], pmv[po + 4] = vy * myShift, vy * myShift
								mv[o + 1], mv[o + 2], mv[o + 3], mv[o + 4] = vx, vy, vx, vy
								local function sc(v, m)
									return (v * m + (v > 0 and 1 or 0)) // 2
								end
								if not fieldPic then
									local m = tff and 1 or 3
									mv[o + 5] = sc(vx, m) + dmx
									mv[o + 6] = sc(vy, m) + dmy - 1
									m = 4 - m
									mv[o + 7] = sc(vx, m) + dmx
									mv[o + 8] = sc(vy, m) + dmy + 1
								else
									mv[o + 5] = sc(vx, 1) + dmx
									mv[o + 6] = sc(vy, 1) + dmy + (parity == 0 and -1 or 1)
								end
							end
						end
					end
				end
				if band(mvDir, 1) ~= 0 then
					predict(0, false)
				end
				if band(mvDir, 2) ~= 0 then
					predict(1, mvDir == 3)
				end
				if band(mbType, MB_FLAG_PAT) ~= 0 then
					local cbp
					cbp, bp = getVlc(bp, CBP, 9)
					if cbp <= 0 then
						error("MPEG video: a coded block pattern is damaged", 0)
					end
					for n = 0, 5 do
						if band(cbp, lshift(1, 5 - n)) ~= 0 then
							block(n, false, dctType)
						end
					end
				end
			end
			skipRun = -1
		end

		-- next macroblock
		mbx += 1
		if mbx >= mbw then
			mbx = 0
			mby += 1
			if mby >= mbRows then
				return
			end
		end
		if skipRun == -1 then
			skipRun = 0
			while true do
				local code
				code, bp = getVlc(bp, MB_INCR, 11)
				if code < 0 then
					error("MPEG video: a macroblock address is damaged", 0)
				elseif code == 33 then
					skipRun += 33
				elseif code == 35 then
					-- end of the slice
					return
				elseif code < 33 then
					skipRun += code
					break
				end
			end
			if skipRun > 0 and ptype == 1 then
				error("MPEG video: a skipped macroblock in an I picture", 0)
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------

function Mpeg2:decodeSample(buf: buffer, pos: number, size: number)
	if buffer.len(S) < size + 16 then
		S = buffer.create(size + 65536)
	end
	buffer.copy(S, 0, buf, pos, size)
	buffer.fill(S, size, 0, 16)
	local done = nil
	local p = 0
	-- start codes 00 00 01 xx
	local function nextCode(from)
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
	local function finish()
		local pic = self.pic
		if pic and self.picStarted then
			self.pictType = pic.type
			self.temporalRef = pic.tr
			if not self.secondField then
				done = self.cur
			end
		end
		self.pic = nil
	end
	p = nextCode(0)
	while p do
		local code = readu8(S, p + 3)
		local bp = (p + 4) * 8
		if code == 0xB3 then
			finish()
			self:sequenceHeader(bp)
		elseif code == 0xB5 then
			self:extension(bp)
		elseif code == 0x00 then
			finish()
			if not self.seenSequence then
				error("MPEG video: a picture comes before any sequence header", 0)
			end
			self:pictureHeader(bp)
		elseif code >= 0x01 and code <= 0xAF then
			if self.pic then
				if not self.picStarted then
					self:startPicture()
				end
				self:decodeSlice(bp, code - 1)
			end
		elseif code == 0xB7 or code == 0xB8 then
			finish()
		end
		p = nextCode(p + 4)
	end
	finish()
	return done
end

return Mpeg2
