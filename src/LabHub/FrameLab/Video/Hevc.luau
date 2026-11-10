--!native
--!optimize 2
-- FrameLab HEVC / H.265 video decoder in pure Luau: Main and Main 10 profiles (4:2:0, 8 or 10 bits; 10-bit pictures are
-- handed out as 8-bit planes). I, P and B slices, merge / AMVP motion with temporal prediction, weighted prediction,
-- the deblocking filter and SAO, tiles, wavefront rows (WPP), dependent slices, scaling lists, transform skip, PCM
-- and lossless blocks. Not read: 4:2:2 / 4:4:4 and the range / screen-content / multi-layer extensions.
--
--   local dec = Hevc.new(hvcC)                 hvcC: the hvcC box's payload (buffer: Formats.Mp4 / Webm), a table from
--                                               Hevc.parseConfig, or nil for Annex B input
--   local pic = dec:decodeSample(buf, pos, len)      one length-prefixed access unit -> the decoded picture or nil
--   local pic = dec:decodeAccessUnit(buf, pos, len)  the same for an Annex B access unit (MPEG-TS)
--   pic.Y, pic.U, pic.V (8-bit planes), pic.ys / pic.cs (strides), pic.yo / pic.co (offset of the coded picture's pixel
--   0,0; the shown picture starts at dec.cropX, dec.cropY)
--   dec.width, dec.height (cropped size), dec.cropX, dec.cropY, dec.fullRange, dec.bt709, dec.sarW, dec.sarH
--   The planes are valid until the next call. Pictures come out in decode order (the container has their times).
--   (A stream that starts at a CRA picture: the pictures after it in decoding order that lean on earlier ones are
--   skipped - nil.)
--   dec:reset()   forget the pictures decoded so far (the parameter sets stay): the next IRAP picture starts again
--   Hevc.parseConfig(hvcCBox: buffer, pos, size) -> hvcC table (from an MP4 'hvcC' box / MKV CodecPrivate)

local band, bor, rshift, lshift = bit32.band, bit32.bor, bit32.rshift, bit32.lshift
local byteswap = bit32.byteswap
local readu8, writeu8, readu16, writeu16, readu32 = buffer.readu8, buffer.writeu8, buffer.readu16, buffer.writeu16, buffer.readu32
local abs, min, max, clamp = math.abs, math.min, math.max, math.clamp

local Hevc = {}

local function fail(msg)
	error("HEVC: " .. msg, 0)
end

local lastYield = os.clock()
local function breathe()
	if task and os.clock() - lastYield > 0.05 then
		task.wait()
		lastYield = os.clock()
	end
end

------------------------------------------------------------------------------------------------------------------------
-- tables

-- CABAC context initial values (initType 0, 1, 2): one byte per context, numbered as the decoding below uses them
local CTX_INIT_HEX = "99c88b8d9d9a9a9a9a9a9a9a9ab89a9a9ab83f8b9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a998a8a6f8d5e8ab69a9a8b8b8b8b8b8b6e6e7c7d8c997d7f8c6d6f8f7f6f4f6c7b3f6e6e7c7d8c997d7f8c6d6f8f7f6f4f6c7b3f5bab868d6f6f7d6e6e5e7c6c7c6b7d8db3997d6b7d8db3997d6b7d8db3997d8c8bb6b69888988899888b6f888b6f8d6f8c5c898a8c988a8b994a955c8b6b7a988cb3a6b68ce37ac58a9988a798989a9a9a9a9a9a9a9a9a9a9a9a99b96b8b7e9ac5b9c99a9a9a959a8b9a9a9a988b6e7a5f4f3f1f1f999999998cc68cc6a84f7c8a5e996f956ba79a9a8b8b8b8b8b8b7d6e5e6e5f4f7d6f6e4e6e6f6f5f5e6c7b6c7d6e5e6e5f4f7d6f6e4e6e6f6f5f5e6c7b6c798c3d9a9b9a8b998b7b7b3f99a6b78c88999aa6b78c88999aa6b78c88999aaa997b7b6b796b79a797b78c97b78c8c8c9ac4c4a79a98a7b6b686958899798889a9c2a6a79aa789b66ba75b7a6ba79a9a9a9a9a9a9a9a9a9a9a9a99a06b8b7e9ac5b9c99a9a9a869a8b9a9ab7988b9a895f4f3f1f1f99999999a9c6a9c6a84fe0a77a996f955ca79a9a8b8b8b8b8b8b7d6e7c6e5f5e7d6f6f4f7d7e6f6f4f6c7b5d7d6e7c6e5f5e7d6f6f4f7d7e6f6f4f6c7b5d798c3d9aaa9a8b998b7b7b3f7ca6b78c88999aa6b78c88999aa6b78c88999aaa998a8a7a797a79a797b78c97b78c8c8c9ac4a7a79a98a7b6b68695889979887aa9d0a6a79a98a7b66ba75b6b6ba79a9a9a9a9a9a9a9a9a9a9a9a"
local NUM_CTX = 179
local CTX_INIT = table.create(3 * NUM_CTX, 0)
for i = 0, 3 * NUM_CTX - 1 do
	CTX_INIT[i + 1] = tonumber(string.sub(CTX_INIT_HEX, 2 * i + 1, 2 * i + 2), 16)
end

local LPS_TAB = { 128, 128, 128, 123, 116, 111, 105, 100, 95, 90, 85, 81, 77, 73, 69, 66, 62, 59, 56, 53, 51, 48, 46, 43, 41, 39, 37, 35, 33, 32, 30, 29, 27, 26, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 14, 13, 12, 12, 11, 11, 10, 10, 9, 9, 8, 8, 7, 7, 7, 6, 6, 6, 2, 176, 167, 158, 150, 142, 135, 128, 122, 116, 110, 104, 99, 94, 89, 85, 80, 76, 72, 69, 65, 62, 59, 56, 53, 50, 48, 45, 43, 41, 39, 37, 35, 33, 31, 30, 28, 27, 26, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 14, 13, 12, 12, 11, 11, 10, 9, 9, 9, 8, 8, 7, 7, 2, 208, 197, 187, 178, 169, 160, 152, 144, 137, 130, 123, 117, 111, 105, 100, 95, 90, 86, 81, 77, 73, 69, 66, 63, 59, 56, 54, 51, 48, 46, 43, 41, 39, 37, 35, 33, 32, 30, 29, 27, 26, 25, 23, 22, 21, 20, 19, 18, 17, 16, 15, 15, 14, 13, 12, 12, 11, 11, 10, 10, 9, 9, 8, 2, 240, 227, 216, 205, 195, 185, 175, 166, 158, 150, 142, 135, 128, 122, 116, 110, 104, 99, 94, 89, 85, 80, 76, 72, 69, 65, 62, 59, 56, 53, 50, 48, 45, 43, 41, 39, 37, 35, 33, 31, 30, 28, 27, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 14, 13, 12, 12, 11, 11, 10, 9, 2 }
local TRANS_LPS = { 0, 0, 1, 2, 2, 4, 4, 5, 6, 7, 8, 9, 9, 11, 11, 12, 13, 13, 15, 15, 16, 16, 18, 18, 19, 19, 21, 21, 22, 22, 23, 24, 24, 25, 26, 26, 27, 27, 28, 29, 29, 30, 30, 30, 31, 32, 32, 33, 33, 33, 34, 34, 35, 35, 35, 36, 36, 36, 37, 37, 37, 38, 38, 63 }

-- scans: positions (x + 8 * y within a block of up to 8 x 8) in scan order, 1-based arrays
local function diagScan(n)
	local out = {}
	local x, y = 0, 0
	while #out < n * n do
		while y >= 0 do
			if x < n and y < n then
				table.insert(out, { x, y })
			end
			y -= 1
			x += 1
		end
		y = x
		x = 0
	end
	return out
end
-- SCAN[kind][log2 size] = { xs, ys } (kind 0 diagonal, 1 horizontal, 2 vertical), sizes 1x1, 2x2, 4x4, 8x8
local SCAN_X, SCAN_Y = {}, {}
for kind = 0, 2 do
	SCAN_X[kind], SCAN_Y[kind] = {}, {}
	for lg = 0, 3 do
		local n = lshift(1, lg)
		local list
		if kind == 0 then
			list = diagScan(n)
		else
			list = {}
			for a = 0, n - 1 do
				for b = 0, n - 1 do
					if kind == 1 then
						table.insert(list, { b, a })
					else
						table.insert(list, { a, b })
					end
				end
			end
		end
		local xs, ys = table.create(n * n, 0), table.create(n * n, 0)
		for i, p in ipairs(list) do
			xs[i], ys[i] = p[1], p[2]
		end
		SCAN_X[kind][lg], SCAN_Y[kind][lg] = xs, ys
	end
end

-- context index of significant_coeff_flag within a 4x4 block (sigCtx for log2 size 2), raster position
local CTX_IDX_MAP_4x4 = { 0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 99 }

local INTRA_ANGLE = {}
for i, v in ipairs({ 32, 26, 21, 17, 13, 9, 5, 2, 0, -2, -5, -9, -13, -17, -21, -26, -32, -26, -21, -17, -13, -9, -5, -2,
	0, 2, 5, 9, 13, 17, 21, 26, 32 }) do
	INTRA_ANGLE[i + 1] = v
end
local INV_ANGLE = {}
for i, v in ipairs({ -4096, -1638, -910, -630, -482, -390, -315, -256, -315, -390, -482, -630, -910, -1638, -4096 }) do
	INV_ANGLE[i + 10] = v
end

local QPEL = { { -1, 4, -10, 58, 17, -5, 1, 0 }, { -1, 4, -11, 40, 40, -11, 4, -1 }, { 0, 1, -5, 17, 58, -10, 4, -1 } }
local EPEL = { { -2, 58, 10, -2 }, { -4, 54, 16, -2 }, { -6, 46, 28, -4 }, { -4, 36, 36, -4 }, { -4, 28, 46, -6 }, { -2, 16, 54, -4 },
	{ -2, 10, 58, -2 } }

local LEVEL_SCALE = { [0] = 40, 45, 51, 57, 64, 72 }
local QPC_TAB = {}
for i, v in ipairs({ 29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37 }) do
	QPC_TAB[i + 29] = v
end

local BETA_TAB = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24,
	26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64 }
local TC_TAB = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4,
	5, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 24 }

-- the 32-point DCT matrix (rows: basis functions)
local TM = {
	"64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64",
	"90 90 88 85 82 78 73 67 61 54 46 38 31 22 13 4 -4 -13 -22 -31 -38 -46 -54 -61 -67 -73 -78 -82 -85 -88 -90 -90",
	"90 87 80 70 57 43 25 9 -9 -25 -43 -57 -70 -80 -87 -90 -90 -87 -80 -70 -57 -43 -25 -9 9 25 43 57 70 80 87 90",
	"90 82 67 46 22 -4 -31 -54 -73 -85 -90 -88 -78 -61 -38 -13 13 38 61 78 88 90 85 73 54 31 4 -22 -46 -67 -82 -90",
	"89 75 50 18 -18 -50 -75 -89 -89 -75 -50 -18 18 50 75 89 89 75 50 18 -18 -50 -75 -89 -89 -75 -50 -18 18 50 75 89",
	"88 67 31 -13 -54 -82 -90 -78 -46 -4 38 73 90 85 61 22 -22 -61 -85 -90 -73 -38 4 46 78 90 82 54 13 -31 -67 -88",
	"87 57 9 -43 -80 -90 -70 -25 25 70 90 80 43 -9 -57 -87 -87 -57 -9 43 80 90 70 25 -25 -70 -90 -80 -43 9 57 87",
	"85 46 -13 -67 -90 -73 -22 38 82 88 54 -4 -61 -90 -78 -31 31 78 90 61 4 -54 -88 -82 -38 22 73 90 67 13 -46 -85",
	"83 36 -36 -83 -83 -36 36 83 83 36 -36 -83 -83 -36 36 83 83 36 -36 -83 -83 -36 36 83 83 36 -36 -83 -83 -36 36 83",
	"82 22 -54 -90 -61 13 78 85 31 -46 -90 -67 4 73 88 38 -38 -88 -73 -4 67 90 46 -31 -85 -78 -13 61 90 54 -22 -82",
	"80 9 -70 -87 -25 57 90 43 -43 -90 -57 25 87 70 -9 -80 -80 -9 70 87 25 -57 -90 -43 43 90 57 -25 -87 -70 9 80",
	"78 -4 -82 -73 13 85 67 -22 -88 -61 31 90 54 -38 -90 -46 46 90 38 -54 -90 -31 61 88 22 -67 -85 -13 73 82 4 -78",
	"75 -18 -89 -50 50 89 18 -75 -75 18 89 50 -50 -89 -18 75 75 -18 -89 -50 50 89 18 -75 -75 18 89 50 -50 -89 -18 75",
	"73 -31 -90 -22 78 67 -38 -90 -13 82 61 -46 -88 -4 85 54 -54 -85 4 88 46 -61 -82 13 90 38 -67 -78 22 90 31 -73",
	"70 -43 -87 9 90 25 -80 -57 57 80 -25 -90 -9 87 43 -70 -70 43 87 -9 -90 -25 80 57 -57 -80 25 90 9 -87 -43 70",
	"67 -54 -78 38 85 -22 -90 4 90 13 -88 -31 82 46 -73 -61 61 73 -46 -82 31 88 -13 -90 -4 90 22 -85 -38 78 54 -67",
	"64 -64 -64 64 64 -64 -64 64 64 -64 -64 64 64 -64 -64 64 64 -64 -64 64 64 -64 -64 64 64 -64 -64 64 64 -64 -64 64",
	"61 -73 -46 82 31 -88 -13 90 -4 -90 22 85 -38 -78 54 67 -67 -54 78 38 -85 -22 90 4 -90 13 88 -31 -82 46 73 -61",
	"57 -80 -25 90 -9 -87 43 70 -70 -43 87 9 -90 25 80 -57 -57 80 25 -90 9 87 -43 -70 70 43 -87 -9 90 -25 -80 57",
	"54 -85 -4 88 -46 -61 82 13 -90 38 67 -78 -22 90 -31 -73 73 31 -90 22 78 -67 -38 90 -13 -82 61 46 -88 4 85 -54",
	"50 -89 18 75 -75 -18 89 -50 -50 89 -18 -75 75 18 -89 50 50 -89 18 75 -75 -18 89 -50 -50 89 -18 -75 75 18 -89 50",
	"46 -90 38 54 -90 31 61 -88 22 67 -85 13 73 -82 4 78 -78 -4 82 -73 -13 85 -67 -22 88 -61 -31 90 -54 -38 90 -46",
	"43 -90 57 25 -87 70 9 -80 80 -9 -70 87 -25 -57 90 -43 -43 90 -57 -25 87 -70 -9 80 -80 9 70 -87 25 57 -90 43",
	"38 -88 73 -4 -67 90 -46 -31 85 -78 13 61 -90 54 22 -82 82 -22 -54 90 -61 -13 78 -85 31 46 -90 67 4 -73 88 -38",
	"36 -83 83 -36 -36 83 -83 36 36 -83 83 -36 -36 83 -83 36 36 -83 83 -36 -36 83 -83 36 36 -83 83 -36 -36 83 -83 36",
	"31 -78 90 -61 4 54 -88 82 -38 -22 73 -90 67 -13 -46 85 -85 46 13 -67 90 -73 22 38 -82 88 -54 -4 61 -90 78 -31",
	"25 -70 90 -80 43 9 -57 87 -87 57 -9 -43 80 -90 70 -25 -25 70 -90 80 -43 -9 57 -87 87 -57 9 43 -80 90 -70 25",
	"22 -61 85 -90 73 -38 -4 46 -78 90 -82 54 -13 -31 67 -88 88 -67 31 13 -54 82 -90 78 -46 4 38 -73 90 -85 61 -22",
	"18 -50 75 -89 89 -75 50 -18 -18 50 -75 89 -89 75 -50 18 18 -50 75 -89 89 -75 50 -18 -18 50 -75 89 -89 75 -50 18",
	"13 -38 61 -78 88 -90 85 -73 54 -31 4 22 -46 67 -82 90 -90 82 -67 46 -22 -4 31 -54 73 -85 90 -88 78 -61 38 -13",
	"9 -25 43 -57 70 -80 87 -90 90 -87 80 -70 57 -43 25 -9 -9 25 -43 57 -70 80 -87 90 -90 87 -80 70 -57 43 -25 9",
	"4 -13 22 -31 38 -46 54 -61 67 -73 78 -82 85 -88 90 -90 90 -90 88 -85 82 -78 73 -67 61 -54 46 -38 31 -22 13 -4",
}
-- MAT[n][k * n + j + 1]: basis k at sample j of the n-point transform
local MAT = {}
do
	local full = {}
	for k = 1, 32 do
		local row = {}
		for v in string.gmatch(TM[k], "%S+") do
			table.insert(row, tonumber(v))
		end
		full[k] = row
	end
	for _, n in ipairs({ 4, 8, 16, 32 }) do
		local m = table.create(n * n, 0)
		local step = 32 // n
		for k = 0, n - 1 do
			for j = 0, n - 1 do
				m[k * n + j + 1] = full[k * step + 1][j + 1]
			end
		end
		MAT[n] = m
	end
end

-- default scaling lists (8x8 intra / inter, up-right diagonal order)
local DEF_INTRA8 = { 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 16, 17, 16, 17, 18, 17, 18, 18, 17, 18, 21, 19, 20, 21, 20, 19, 21,
	24, 22, 22, 24, 24, 22, 22, 24, 25, 25, 27, 30, 27, 25, 25, 29, 31, 35, 35, 31, 29, 36, 41, 44, 41, 36, 47, 54, 54, 47, 65, 70, 65, 88,
	88, 115 }
local DEF_INTER8 = { 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20,
	24, 24, 24, 24, 24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 28, 28, 28, 28, 28, 28, 33, 33, 33, 33, 33, 41, 41, 41, 41, 54, 54, 54, 71,
	71, 91 }

------------------------------------------------------------------------------------------------------------------------
-- RBSP: one NAL unit's payload without emulation prevention bytes, read as bits

local RB = buffer.create(65536)
local RBLEN = 0
local BP = 0 -- bit position in RB

local function loadNal(buf: buffer, pos: number, size: number)
	if buffer.len(RB) < size + 16 then
		RB = buffer.create(size + 65536)
	end
	local o = 0
	local zeros = 0
	local stop = pos + size
	local p = pos
	while p < stop do
		local b = readu8(buf, p)
		if zeros >= 2 and b == 3 then
			zeros = 0
		else
			writeu8(RB, o, b)
			o += 1
			if b == 0 then
				zeros += 1
			else
				zeros = 0
			end
		end
		p += 1
	end
	buffer.fill(RB, o, 0, 16)
	RBLEN = o
	BP = 0
end

local function u(n: number): number
	if n == 0 then
		return 0
	end
	if n > 24 then
		local hi = u(n - 16)
		return hi * 65536 + u(16)
	end
	local w = byteswap(readu32(RB, rshift(BP, 3)))
	local v = rshift(lshift(w, band(BP, 7)), 32 - n)
	BP += n
	return v
end
local function u1(): number
	local v = band(rshift(readu8(RB, rshift(BP, 3)), 7 - band(BP, 7)), 1)
	BP += 1
	return v
end
local function ue(): number
	local z = 0
	while u1() == 0 do
		z += 1
		if z > 31 then
			fail("damaged data (a number is too long)")
		end
	end
	if z == 0 then
		return 0
	end
	return 2 ^ z - 1 + u(z)
end
local function se(): number
	local k = ue()
	if k % 2 == 1 then
		return (k + 1) // 2
	end
	return -(k // 2)
end

------------------------------------------------------------------------------------------------------------------------
-- parameter sets

local function profileTierLevel(maxSubLayersMinus1)
	local ptl = {}
	u(2) -- profile space
	u1() -- tier
	ptl.profile = u(5)
	local compat = u(32)
	ptl.compat = compat
	u(4) -- progressive, interlaced, non-packed, frame-only
	u(32)
	u(12) -- (the 43 reserved bits and the in-bld flag)
	u(8) -- level
	local subProfile, subLevel = {}, {}
	for i = 1, maxSubLayersMinus1 do
		subProfile[i] = u1()
		subLevel[i] = u1()
	end
	if maxSubLayersMinus1 > 0 then
		for _ = maxSubLayersMinus1, 7 do
			u(2)
		end
	end
	for i = 1, maxSubLayersMinus1 do
		if subProfile[i] == 1 then
			u(32)
			u(32)
			u(24)
		end
		if subLevel[i] == 1 then
			u(8)
		end
	end
	return ptl
end

local function scalingListData()
	-- sl[sizeId][matrixId] = coefficients in up-right diagonal order, dc[sizeId][matrixId]
	local sl, dc = {}, {}
	for sizeId = 0, 3 do
		sl[sizeId], dc[sizeId] = {}, {}
		local step = sizeId == 3 and 3 or 1
		for matrixId = 0, 5, step do
			local predModeFlag = u1()
			local n = min(64, lshift(1, 4 + lshift(sizeId, 1)))
			if predModeFlag == 0 then
				local delta = ue()
				if delta == 0 then
					-- the default list
					local def
					if sizeId == 0 then
						def = table.create(16, 16)
					else
						def = matrixId < 3 and DEF_INTRA8 or DEF_INTER8
					end
					sl[sizeId][matrixId] = table.clone(def)
					dc[sizeId][matrixId] = 16
				else
					local ref = matrixId - delta * (sizeId == 3 and 3 or 1)
					sl[sizeId][matrixId] = table.clone(sl[sizeId][ref])
					dc[sizeId][matrixId] = dc[sizeId][ref]
				end
			else
				local nextCoef = 8
				if sizeId > 1 then
					local d = se()
					nextCoef = d + 8
					dc[sizeId][matrixId] = nextCoef
				end
				local list = table.create(n, 0)
				for i = 1, n do
					local d = se()
					nextCoef = (nextCoef + d + 256) % 256
					list[i] = nextCoef
				end
				sl[sizeId][matrixId] = list
				if sizeId <= 1 then
					dc[sizeId][matrixId] = 16
				end
			end
		end
	end
	-- 32 x 32 chroma lists (4:2:0 never uses them; kept like the 16 x 16 ones for completeness)
	for matrixId = 1, 5 do
		if matrixId ~= 3 then
			sl[3][matrixId] = sl[2][matrixId]
			dc[3][matrixId] = dc[2][matrixId]
		end
	end
	return { sl = sl, dc = dc }
end

-- default lists as a scaling-list table
local DEFAULT_SL
do
	local sl, dc = {}, {}
	for sizeId = 0, 3 do
		sl[sizeId], dc[sizeId] = {}, {}
		for matrixId = 0, 5 do
			if sizeId == 0 then
				sl[sizeId][matrixId] = table.create(16, 16)
			else
				sl[sizeId][matrixId] = matrixId < 3 and DEF_INTRA8 or DEF_INTER8
			end
			dc[sizeId][matrixId] = 16
		end
	end
	DEFAULT_SL = { sl = sl, dc = dc }
end

-- the scaling factor arrays m[x + y * n] for a list (sizeId 0..3: 4x4 .. 32x32)
local function scalingFactors(list)
	local f = {}
	for sizeId = 0, 3 do
		f[sizeId] = {}
		local n = lshift(4, sizeId)
		for matrixId = 0, 5 do
			local coefs = list.sl[sizeId][matrixId]
			local m = table.create(n * n, 16)
			if coefs then
				local lg = sizeId == 0 and 2 or 3
				local xs, ys = SCAN_X[0][lg], SCAN_Y[0][lg]
				local rep = n // lshift(1, lg)
				for i = 1, #xs do
					local v = coefs[i]
					for dy = 0, rep - 1 do
						for dx = 0, rep - 1 do
							m[(ys[i] * rep + dy) * n + xs[i] * rep + dx + 1] = v
						end
					end
				end
				if sizeId >= 2 then
					m[1] = list.dc[sizeId][matrixId]
				end
			end
			f[sizeId][matrixId] = m
		end
	end
	return f
end

-- st_ref_pic_set(idx): { neg = { deltas }, negUsed, pos, posUsed }
local function stRefPicSet(sets, idx, numSets, inSlice)
	local predict = 0
	if idx ~= 0 then
		predict = u1()
	end
	local rps = { neg = {}, negUsed = {}, pos = {}, posUsed = {} }
	if predict == 1 then
		local deltaIdx = 1
		if inSlice then
			deltaIdx = ue() + 1
		end
		local ref = sets[idx - deltaIdx]
		if not ref then
			fail("damaged data (a reference picture set refers to a missing one)")
		end
		local sign = u1()
		local absDelta = ue() + 1
		local deltaRps = sign == 1 and -absDelta or absDelta
		local nRef = #ref.neg + #ref.pos
		local used, useDelta = {}, {}
		for j = 0, nRef do
			used[j] = u1()
			useDelta[j] = 1
			if used[j] == 0 then
				useDelta[j] = u1()
			end
		end
		local nNeg = #ref.neg
		for j = #ref.pos, 1, -1 do
			local d = ref.pos[j] + deltaRps
			if d < 0 and useDelta[nNeg + j - 1] == 1 then
				table.insert(rps.neg, d)
				table.insert(rps.negUsed, used[nNeg + j - 1])
			end
		end
		if deltaRps < 0 and useDelta[nRef] == 1 then
			table.insert(rps.neg, deltaRps)
			table.insert(rps.negUsed, used[nRef])
		end
		for j = 1, nNeg do
			local d = ref.neg[j] + deltaRps
			if d < 0 and useDelta[j - 1] == 1 then
				table.insert(rps.neg, d)
				table.insert(rps.negUsed, used[j - 1])
			end
		end
		for j = nNeg, 1, -1 do
			local d = ref.neg[j] + deltaRps
			if d > 0 and useDelta[j - 1] == 1 then
				table.insert(rps.pos, d)
				table.insert(rps.posUsed, used[j - 1])
			end
		end
		if deltaRps > 0 and useDelta[nRef] == 1 then
			table.insert(rps.pos, deltaRps)
			table.insert(rps.posUsed, used[nRef])
		end
		for j = 1, #ref.pos do
			local d = ref.pos[j] + deltaRps
			if d > 0 and useDelta[nNeg + j - 1] == 1 then
				table.insert(rps.pos, d)
				table.insert(rps.posUsed, used[nNeg + j - 1])
			end
		end
	else
		local nNeg, nPos = ue(), ue()
		if nNeg > 16 or nPos > 16 then
			fail("damaged data (too many reference pictures)")
		end
		local prev = 0
		for i = 1, nNeg do
			prev -= ue() + 1
			rps.neg[i] = prev
			rps.negUsed[i] = u1()
		end
		prev = 0
		for i = 1, nPos do
			prev += ue() + 1
			rps.pos[i] = prev
			rps.posUsed[i] = u1()
		end
	end
	return rps
end

local function hrdParameters(commonInf, maxSubLayersMinus1)
	local nalHrd, vclHrd, subPic = 0, 0, 0
	if commonInf then
		nalHrd = u1()
		vclHrd = u1()
		if nalHrd == 1 or vclHrd == 1 then
			subPic = u1()
			if subPic == 1 then
				u(8)
				u(5)
				u1()
				u(5)
			end
			u(4)
			u(4)
			if subPic == 1 then
				u(4)
			end
			u(5)
			u(5)
			u(5)
		end
	end
	for _ = 0, maxSubLayersMinus1 do
		local fixedGeneral = u1()
		local fixedCvs = 0
		if fixedGeneral == 0 then
			fixedCvs = u1()
		end
		local lowDelay = 0
		if fixedGeneral == 1 or fixedCvs == 1 then
			ue()
		else
			lowDelay = u1()
		end
		local cpbCnt = 1
		if lowDelay == 0 then
			cpbCnt = ue() + 1
		end
		for _ = 1, nalHrd + vclHrd do
			for _ = 1, cpbCnt do
				ue()
				ue()
				if subPic == 1 then
					ue()
					ue()
				end
				u1()
			end
		end
	end
end

local SAR = { { 1, 1 }, { 12, 11 }, { 10, 11 }, { 16, 11 }, { 40, 33 }, { 24, 11 }, { 20, 11 }, { 32, 11 }, { 80, 33 }, { 18, 11 },
	{ 15, 11 }, { 64, 33 }, { 160, 99 }, { 4, 3 }, { 3, 2 }, { 2, 1 } }

local function vui(sps)
	if u1() == 1 then
		local idc = u(8)
		if idc == 255 then
			sps.sarW, sps.sarH = u(16), u(16)
		elseif SAR[idc] then
			sps.sarW, sps.sarH = SAR[idc][1], SAR[idc][2]
		end
	end
	if u1() == 1 then
		u1()
	end
	if u1() == 1 then
		u(3)
		sps.fullRange = u1() == 1
		if u1() == 1 then
			u(8)
			u(8)
			local matrix = u(8)
			sps.bt709 = matrix == 1
		end
	end
	if u1() == 1 then
		ue()
		ue()
	end
	u1() -- neutral chroma
	u1() -- field seq
	u1() -- frame field info
	if u1() == 1 then -- default display window
		ue()
		ue()
		ue()
		ue()
	end
	if u1() == 1 then -- timing
		local units, scale = u(32), u(32)
		if units > 0 then
			sps.fps = scale / units
		end
		if u1() == 1 then
			ue()
		end
		if u1() == 1 then
			hrdParameters(true, sps.maxSubLayersMinus1)
		end
	end
	if u1() == 1 then -- bitstream restriction
		u1()
		u1()
		u1()
		ue()
		ue()
		ue()
		ue()
		ue()
	end
end

local function parseSps()
	local sps = { sarW = 1, sarH = 1, fullRange = false, bt709 = false }
	u(4) -- vps id
	sps.maxSubLayersMinus1 = u(3)
	u1()
	profileTierLevel(sps.maxSubLayersMinus1)
	sps.id = ue()
	if sps.id > 15 then
		fail("damaged data (bad SPS id)")
	end
	sps.chromaFormat = ue()
	if sps.chromaFormat ~= 1 then
		fail(("only 4:2:0 colour is read (this video is %s)"):format(({ [0] = "monochrome", "4:2:0", "4:2:2", "4:4:4" })[sps.chromaFormat] or "?"))
	end
	sps.width = ue()
	sps.height = ue()
	sps.cropL, sps.cropR, sps.cropT, sps.cropB = 0, 0, 0, 0
	if u1() == 1 then
		sps.cropL, sps.cropR, sps.cropT, sps.cropB = 2 * ue(), 2 * ue(), 2 * ue(), 2 * ue()
	end
	sps.bitDepth = ue() + 8
	sps.bitDepthC = ue() + 8
	if sps.bitDepth > 10 or sps.bitDepthC ~= sps.bitDepth then
		fail(("only 8 and 10-bit video is read (this is %d-bit)"):format(sps.bitDepth))
	end
	sps.log2MaxPocLsb = ue() + 4
	local orderingAll = u1()
	sps.maxDecPicBuffering = 1
	for i = orderingAll == 1 and 0 or sps.maxSubLayersMinus1, sps.maxSubLayersMinus1 do
		sps.maxDecPicBuffering = ue() + 1
		sps.numReorder = ue()
		ue()
	end
	sps.log2MinCb = ue() + 3
	sps.log2Ctb = sps.log2MinCb + ue()
	sps.log2MinTb = ue() + 2
	sps.log2MaxTb = sps.log2MinTb + ue()
	sps.maxTrDepthInter = ue()
	sps.maxTrDepthIntra = ue()
	if sps.log2Ctb > 6 or sps.log2Ctb < 4 or sps.log2MaxTb > 5 or sps.log2MaxTb > sps.log2Ctb then
		fail("damaged data (bad block sizes)")
	end
	sps.scalingListEnabled = u1() == 1
	if sps.scalingListEnabled then
		if u1() == 1 then
			sps.scalingList = scalingListData()
		else
			sps.scalingList = DEFAULT_SL
		end
	end
	sps.amp = u1() == 1
	sps.sao = u1() == 1
	sps.pcm = u1() == 1
	if sps.pcm then
		sps.pcmBitDepth = u(4) + 1
		sps.pcmBitDepthC = u(4) + 1
		sps.log2MinPcm = ue() + 3
		sps.log2MaxPcm = sps.log2MinPcm + ue()
		sps.pcmLoopFilterDisabled = u1() == 1
	end
	local numSets = ue()
	if numSets > 64 then
		fail("damaged data (too many reference picture sets)")
	end
	sps.stRps = {}
	for i = 0, numSets - 1 do
		sps.stRps[i] = stRefPicSet(sps.stRps, i, numSets, false)
	end
	sps.numStRps = numSets
	sps.longTermPresent = u1() == 1
	sps.ltPocLsb, sps.ltUsed = {}, {}
	sps.numLtSps = 0
	if sps.longTermPresent then
		sps.numLtSps = ue()
		for i = 0, sps.numLtSps - 1 do
			sps.ltPocLsb[i] = u(sps.log2MaxPocLsb)
			sps.ltUsed[i] = u1()
		end
	end
	sps.temporalMvp = u1() == 1
	sps.strongIntraSmoothing = u1() == 1
	if u1() == 1 then
		vui(sps)
	end
	if u1() == 1 then -- extensions
		local range = u1()
		u1() -- multilayer
		u1() -- 3d
		u1() -- scc
		u(4)
		if range == 1 then
			for _ = 1, 9 do
				if u1() == 1 then
					fail("the range extension (RExt) tools aren't supported")
				end
			end
		end
	end
	-- derived
	sps.ctbSize = lshift(1, sps.log2Ctb)
	sps.ctbW = (sps.width + sps.ctbSize - 1) // sps.ctbSize
	sps.ctbH = (sps.height + sps.ctbSize - 1) // sps.ctbSize
	sps.minCbW = sps.width // lshift(1, sps.log2MinCb)
	sps.minCbH = sps.height // lshift(1, sps.log2MinCb)
	if sps.scalingListEnabled then
		sps.scaling = scalingFactors(sps.scalingList)
	end
	return sps
end

local function parsePps()
	local pps = {}
	pps.id = ue()
	if pps.id > 63 then
		fail("damaged data (bad PPS id)")
	end
	pps.spsId = ue()
	pps.dependentSlices = u1() == 1
	pps.outputFlagPresent = u1() == 1
	pps.extraSliceHeaderBits = u(3)
	pps.signHiding = u1() == 1
	pps.cabacInitPresent = u1() == 1
	pps.numRefIdxL0 = ue() + 1
	pps.numRefIdxL1 = ue() + 1
	pps.initQp = 26 + se()
	pps.constrainedIntra = u1() == 1
	pps.transformSkip = u1() == 1
	pps.cuQpDelta = u1() == 1
	pps.diffCuQpDeltaDepth = 0
	if pps.cuQpDelta then
		pps.diffCuQpDeltaDepth = ue()
	end
	pps.cbQpOffset = se()
	pps.crQpOffset = se()
	pps.sliceChromaQpOffsets = u1() == 1
	pps.weightedPred = u1() == 1
	pps.weightedBipred = u1() == 1
	pps.transquantBypass = u1() == 1
	pps.tiles = u1() == 1
	pps.wpp = u1() == 1
	pps.tileCols, pps.tileRows = 1, 1
	pps.uniformSpacing = true
	pps.loopFilterAcrossTiles = true
	if pps.tiles then
		pps.tileCols = ue() + 1
		pps.tileRows = ue() + 1
		pps.uniformSpacing = u1() == 1
		if not pps.uniformSpacing then
			pps.colWidths, pps.rowHeights = {}, {}
			for i = 1, pps.tileCols - 1 do
				pps.colWidths[i] = ue() + 1
			end
			for i = 1, pps.tileRows - 1 do
				pps.rowHeights[i] = ue() + 1
			end
		end
		pps.loopFilterAcrossTiles = u1() == 1
	end
	pps.loopFilterAcrossSlices = u1() == 1
	pps.deblockOverride = false
	pps.deblockDisabled = false
	pps.betaOffset, pps.tcOffset = 0, 0
	if u1() == 1 then
		pps.deblockOverride = u1() == 1
		pps.deblockDisabled = u1() == 1
		if not pps.deblockDisabled then
			pps.betaOffset = 2 * se()
			pps.tcOffset = 2 * se()
		end
	end
	if u1() == 1 then
		pps.scalingList = scalingListData()
	end
	pps.listsModification = u1() == 1
	pps.log2ParMrgLevel = ue() + 2
	pps.sliceHeaderExtension = u1() == 1
	if u1() == 1 then
		local range = u1()
		u1()
		u1()
		u1()
		u(4)
		if range == 1 then
			if pps.transformSkip then
				ue() -- log2_max_transform_skip_block_size_minus2
			end
			if u1() == 1 then -- cross_component_prediction
				fail("the range extension (RExt) tools aren't supported")
			end
			if u1() == 1 then -- chroma_qp_offset_list
				fail("the range extension (RExt) tools aren't supported")
			end
			ue()
			ue()
		end
	end
	return pps
end

-- tile / scan conversion tables for a PPS with its SPS
local function setupPpsTables(pps, sps)
	if pps.tablesFor == sps then
		return
	end
	pps.tablesFor = sps
	local W, H = sps.ctbW, sps.ctbH
	local colBd, rowBd = { [0] = 0 }, { [0] = 0 }
	local colW, rowH = {}, {}
	for i = 0, pps.tileCols - 1 do
		if pps.uniformSpacing then
			colW[i] = ((i + 1) * W) // pps.tileCols - (i * W) // pps.tileCols
		elseif i < pps.tileCols - 1 then
			colW[i] = pps.colWidths[i + 1]
		else
			local used = 0
			for k = 1, pps.tileCols - 1 do
				used += pps.colWidths[k]
			end
			colW[i] = W - used
		end
		colBd[i + 1] = colBd[i] + colW[i]
	end
	for j = 0, pps.tileRows - 1 do
		if pps.uniformSpacing then
			rowH[j] = ((j + 1) * H) // pps.tileRows - (j * H) // pps.tileRows
		elseif j < pps.tileRows - 1 then
			rowH[j] = pps.rowHeights[j + 1]
		else
			local used = 0
			for k = 1, pps.tileRows - 1 do
				used += pps.rowHeights[k]
			end
			rowH[j] = H - used
		end
		rowBd[j + 1] = rowBd[j] + rowH[j]
	end
	if colBd[pps.tileCols] ~= W or rowBd[pps.tileRows] ~= H then
		fail("damaged data (bad tile sizes)")
	end
	local n = W * H
	local rsToTs, tsToRs, tileId = table.create(n, 0), table.create(n, 0), table.create(n, 0)
	for rs = 0, n - 1 do
		local tbX, tbY = rs % W, rs // W
		local tileX, tileY = 0, 0
		for i = 0, pps.tileCols - 1 do
			if tbX >= colBd[i] then
				tileX = i
			end
		end
		for j = 0, pps.tileRows - 1 do
			if tbY >= rowBd[j] then
				tileY = j
			end
		end
		local v = 0
		for i = 0, tileX - 1 do
			v += rowH[tileY] * colW[i]
		end
		for j = 0, tileY - 1 do
			v += W * rowH[j]
		end
		v += (tbY - rowBd[tileY]) * colW[tileX] + tbX - colBd[tileX]
		rsToTs[rs + 1] = v
		tsToRs[v + 1] = rs
	end
	for j = 0, pps.tileRows - 1 do
		for i = 0, pps.tileCols - 1 do
			local id = j * pps.tileCols + i
			for y = rowBd[j], rowBd[j + 1] - 1 do
				for x = colBd[i], colBd[i + 1] - 1 do
					tileId[y * W + x + 1] = id
				end
			end
		end
	end
	pps.rsToTs, pps.tsToRs, pps.tileId = rsToTs, tsToRs, tileId
	pps.colBd, pps.rowBd = colBd, rowBd
	if pps.scalingList then
		pps.scaling = scalingFactors(pps.scalingList)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- slice segment header


local function predWeightTable(sh, sps)
	local lumaDenom = ue()
	if lumaDenom > 7 then
		fail("damaged data (bad weight denominator)")
	end
	local chromaDenom = lumaDenom + se()
	if chromaDenom < 0 or chromaDenom > 7 then
		fail("damaged data (bad weight denominator)")
	end
	sh.lumaDenom, sh.chromaDenom = lumaDenom, chromaDenom
	local shiftY = sps.bitDepth - 8
	local lists = sh.type == 0 and 2 or 1
	sh.weights = {}
	for l = 0, lists - 1 do
		local n = l == 0 and sh.numRefIdx[0] or sh.numRefIdx[1]
		local lf, cf = {}, {}
		for i = 0, n - 1 do
			lf[i] = u1()
		end
		for i = 0, n - 1 do
			cf[i] = u1()
		end
		local w = {}
		for i = 0, n - 1 do
			-- { luma weight, luma offset, Cb weight, Cb offset, Cr weight, Cr offset }
			local e = { lshift(1, lumaDenom), 0, lshift(1, chromaDenom), 0, lshift(1, chromaDenom), 0 }
			if lf[i] == 1 then
				e[1] = lshift(1, lumaDenom) + se()
				e[2] = se() * lshift(1, shiftY)
			end
			if cf[i] == 1 then
				for j = 0, 1 do
					local cw = lshift(1, chromaDenom) + se()
					local dOff = se()
					local off = clamp(128 - (128 * cw) // lshift(1, chromaDenom) + dOff, -128, 127)
					e[3 + 2 * j] = cw
					e[4 + 2 * j] = off * lshift(1, shiftY)
				end
			end
			w[i] = e
		end
		sh.weights[l] = w
	end
end

-- the slice segment header of the NAL unit in RB (BP just after the 2-byte NAL header)
local function parseSliceHeader(dec, nalType)
	local sh = {}
	sh.first = u1() == 1
	if nalType >= 16 and nalType <= 23 then
		u1() -- no_output_of_prior_pics
	end
	sh.ppsId = ue()
	local pps = dec.ppsList[sh.ppsId]
	if not pps then
		fail("a slice refers to a missing picture parameter set")
	end
	local sps = dec.spsList[pps.spsId]
	if not sps then
		fail("a slice refers to a missing sequence parameter set")
	end
	sh.pps, sh.sps = pps, sps
	setupPpsTables(pps, sps)
	sh.dependent = false
	sh.address = 0
	if not sh.first then
		if pps.dependentSlices then
			sh.dependent = u1() == 1
		end
		local n = sps.ctbW * sps.ctbH
		local bits = 0
		while lshift(1, bits) < n do
			bits += 1
		end
		sh.address = u(bits)
		if sh.address >= n then
			fail("damaged data (bad slice address)")
		end
	end
	if sh.dependent then
		local prev = dec.lastIndependent
		if not prev then
			fail("a dependent slice comes without its slice")
		end
		-- (the rest of the header is the last independent slice's)
		for k, v in pairs(prev) do
			if sh[k] == nil then
				sh[k] = v
			end
		end
		sh.dependent = true
		sh.first = false
	else
		u(pps.extraSliceHeaderBits)
		sh.type = ue() -- 0 B, 1 P, 2 I
		if sh.type > 2 then
			fail("damaged data (bad slice type)")
		end
		if pps.outputFlagPresent then
			u1()
		end
		sh.pocLsb = 0
		sh.rps = nil
		sh.lt = {}
		sh.temporalMvp = false
		if nalType ~= 19 and nalType ~= 20 then
			sh.pocLsb = u(sps.log2MaxPocLsb)
			local fromSps = u1()
			if fromSps == 0 then
				sh.rps = stRefPicSet(sps.stRps, sps.numStRps, sps.numStRps, true)
			else
				local idx = 0
				if sps.numStRps > 1 then
					local bits = 0
					while lshift(1, bits) < sps.numStRps do
						bits += 1
					end
					idx = u(bits)
				end
				sh.rps = sps.stRps[idx]
				if not sh.rps then
					fail("damaged data (bad reference picture set index)")
				end
			end
			if sps.longTermPresent then
				local numLtSps = 0
				if sps.numLtSps > 0 then
					numLtSps = ue()
				end
				local numLtPics = ue()
				local prevMsb = 0
				for i = 0, numLtSps + numLtPics - 1 do
					local lt = {}
					if i < numLtSps then
						local idx = 0
						if sps.numLtSps > 1 then
							local bits = 0
							while lshift(1, bits) < sps.numLtSps do
								bits += 1
							end
							idx = u(bits)
						end
						lt.pocLsb = sps.ltPocLsb[idx]
						lt.used = sps.ltUsed[idx]
					else
						lt.pocLsb = u(sps.log2MaxPocLsb)
						lt.used = u1()
					end
					lt.msbPresent = u1() == 1
					local d = lt.msbPresent and ue() or 0
					-- (DeltaPocMsbCycleLt accumulates within each group)
					if i == 0 or i == numLtSps then
						lt.msbCycle = d
					else
						lt.msbCycle = d + prevMsb
					end
					prevMsb = lt.msbCycle
					sh.lt[i + 1] = lt
				end
			end
			if sps.temporalMvp then
				sh.temporalMvp = u1() == 1
			end
		end
		sh.saoLuma, sh.saoChroma = false, false
		if sps.sao then
			sh.saoLuma = u1() == 1
			sh.saoChroma = u1() == 1
		end
		sh.numRefIdx = { [0] = 0, 0 }
		sh.numPicTotalCurr = 0
		if sh.rps then
			for i = 1, #sh.rps.negUsed do
				sh.numPicTotalCurr += sh.rps.negUsed[i]
			end
			for i = 1, #sh.rps.posUsed do
				sh.numPicTotalCurr += sh.rps.posUsed[i]
			end
		end
		for _, lt in ipairs(sh.lt) do
			sh.numPicTotalCurr += lt.used
		end
		sh.mvdL1Zero = false
		sh.cabacInit = false
		sh.colFromL0 = true
		sh.colRefIdx = 0
		sh.maxMergeCand = 5
		sh.listEntries = { [0] = nil, nil }
		if sh.type ~= 2 then
			sh.numRefIdx[0] = pps.numRefIdxL0
			if sh.type == 0 then
				sh.numRefIdx[1] = pps.numRefIdxL1
			end
			if u1() == 1 then
				sh.numRefIdx[0] = ue() + 1
				if sh.type == 0 then
					sh.numRefIdx[1] = ue() + 1
				end
			end
			if sh.numRefIdx[0] > 16 or sh.numRefIdx[1] > 16 then
				fail("damaged data (too many reference pictures)")
			end
			if pps.listsModification and sh.numPicTotalCurr > 1 then
				local bits = 0
				while lshift(1, bits) < sh.numPicTotalCurr do
					bits += 1
				end
				for l = 0, sh.type == 0 and 1 or 0 do
					if u1() == 1 then
						local e = {}
						for i = 0, sh.numRefIdx[l] - 1 do
							e[i] = u(bits)
						end
						sh.listEntries[l] = e
					end
				end
			end
			if sh.type == 0 then
				sh.mvdL1Zero = u1() == 1
			end
			if pps.cabacInitPresent then
				sh.cabacInit = u1() == 1
			end
			if sh.temporalMvp then
				if sh.type == 0 then
					sh.colFromL0 = u1() == 1
				end
				if (sh.colFromL0 and sh.numRefIdx[0] > 1) or (not sh.colFromL0 and sh.numRefIdx[1] > 1) then
					sh.colRefIdx = ue()
				end
			end
			sh.weights = nil
			if (pps.weightedPred and sh.type == 1) or (pps.weightedBipred and sh.type == 0) then
				predWeightTable(sh, sps)
			end
			sh.maxMergeCand = 5 - ue()
			if sh.maxMergeCand < 1 or sh.maxMergeCand > 5 then
				fail("damaged data (bad merge candidate count)")
			end
		end
		sh.qp = pps.initQp + se()
		local qpBdOffset = 6 * (sps.bitDepth - 8)
		if sh.qp < -qpBdOffset or sh.qp > 51 then
			fail("damaged data (bad slice quantiser)")
		end
		sh.cbQpOffset, sh.crQpOffset = 0, 0
		if pps.sliceChromaQpOffsets then
			sh.cbQpOffset = se()
			sh.crQpOffset = se()
		end
		local override = false
		if pps.deblockOverride then
			override = u1() == 1
		end
		sh.deblockDisabled = pps.deblockDisabled
		sh.betaOffset, sh.tcOffset = pps.betaOffset, pps.tcOffset
		if override then
			sh.deblockDisabled = u1() == 1
			if not sh.deblockDisabled then
				sh.betaOffset = 2 * se()
				sh.tcOffset = 2 * se()
			end
		end
		sh.loopFilterAcrossSlices = pps.loopFilterAcrossSlices
		if pps.loopFilterAcrossSlices and (sh.saoLuma or sh.saoChroma or not sh.deblockDisabled) then
			sh.loopFilterAcrossSlices = u1() == 1
		end
	end
	sh.entryPoints = 0
	if pps.tiles or pps.wpp then
		sh.entryPoints = ue()
		if sh.entryPoints > 0 then
			local bits = ue() + 1
			if bits > 32 then
				fail("damaged data (bad entry point offsets)")
			end
			for _ = 1, sh.entryPoints do
				u(bits)
			end
		end
	end
	if pps.sliceHeaderExtension then
		local len = ue()
		BP += 8 * len
	end
	-- byte_alignment()
	if u1() ~= 1 then
		fail("damaged data (slice header alignment)")
	end
	BP = (BP + 7) // 8 * 8
	return sh
end

------------------------------------------------------------------------------------------------------------------------
-- CABAC arithmetic decoder (offset kept with `CB` extra low bits, like a window into the stream)

local CR, CV, CB, CP = 510, 0, 0, 0 -- range, value, extra bits, next byte
local CTX = table.create(NUM_CTX, 0) -- state * 2 + mps
local NORM9 = table.create(512, 0)
for r = 1, 511 do
	local s = 0
	while lshift(r, s) < 256 do
		s += 1
	end
	NORM9[r] = s
end
local LPS = LPS_TAB -- [q * 64 + state + 1]

local function cabacStart(bytePos)
	CP = bytePos
	CV = readu8(RB, CP) * 65536 + readu8(RB, CP + 1) * 256 + readu8(RB, CP + 2)
	CP += 3
	CB = 15
	CR = 510
end
local function decodeBin(ctx)
	local p = CTX[ctx + 1]
	local st = rshift(p, 1)
	local rl = LPS[(rshift(CR, 6) - 4) * 64 + st + 1]
	CR -= rl
	local big = lshift(CR, CB)
	local bin
	if CV >= big then
		CV -= big
		CR = rl
		bin = 1 - band(p, 1)
		if st == 0 then
			p = TRANS_LPS[1] * 2 + bin
		else
			p = TRANS_LPS[st + 1] * 2 + band(p, 1)
		end
	else
		bin = band(p, 1)
		if st < 62 then
			p += 2
		end
	end
	CTX[ctx + 1] = p
	if CR < 256 then
		local sh = NORM9[CR]
		CR = lshift(CR, sh)
		CB -= sh
		if CB < 0 then
			CV = CV * 16777216 + readu8(RB, CP) * 65536 + readu8(RB, CP + 1) * 256 + readu8(RB, CP + 2)
			CP += 3
			CB += 24
		end
	end
	return bin
end
local function decodeBypass()
	CB -= 1
	if CB < 0 then
		CV = CV * 16777216 + readu8(RB, CP) * 65536 + readu8(RB, CP + 1) * 256 + readu8(RB, CP + 2)
		CP += 3
		CB += 24
	end
	local big = lshift(CR, CB)
	if CV >= big then
		CV -= big
		return 1
	end
	return 0
end
local function decodeBypassBits(n)
	local v = 0
	for _ = 1, n do
		v = v * 2 + decodeBypass()
	end
	return v
end
local function decodeTerminate()
	CR -= 2
	local big = lshift(CR, CB)
	if CV >= big then
		return 1
	end
	if CR < 256 then
		local sh = NORM9[CR]
		CR = lshift(CR, sh)
		CB -= sh
		if CB < 0 then
			CV = CV * 16777216 + readu8(RB, CP) * 65536 + readu8(RB, CP + 1) * 256 + readu8(RB, CP + 2)
			CP += 3
			CB += 24
		end
	end
	return 0
end
-- the byte after the arithmetic decoder's data (after a terminating bin of 1)
local function cabacNextByte()
	return (CP * 8 - CB + 7) // 8
end
local function cabacInitContexts(sh)
	local initType = 0
	if sh.type == 1 then
		initType = sh.cabacInit and 2 or 1
	elseif sh.type == 0 then
		initType = sh.cabacInit and 1 or 2
	end
	local qp = clamp(sh.qp, 0, 51)
	local base = initType * NUM_CTX
	for i = 1, NUM_CTX do
		local v = CTX_INIT[base + i]
		local m = rshift(v, 4) * 5 - 45
		local n = lshift(band(v, 15), 3) - 16
		local pre = clamp((m * qp) // 16 + n, 1, 126)
		if pre <= 63 then
			CTX[i] = (63 - pre) * 2
		else
			CTX[i] = (pre - 64) * 2 + 1
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- picture state (module level: one picture is decoded at a time)

local S, P, SH -- sps, pps, slice header
local PIC -- the picture being decoded
local PY: buffer, PU: buffer, PV: buffer = buffer.create(0), buffer.create(0), buffer.create(0) -- 16-bit samples
local YS, CS = 0, 0 -- strides in samples
local PW, PH = 0, 0 -- size in 4 x 4 blocks
local BD, MAXV = 8, 255
local QP_BD = 0
-- per 4 x 4 block of the picture
local G_IPM = buffer.create(0) -- luma intra mode (1 = DC for others)
local G_CU = buffer.create(0) -- bit 0 intra, 1 skip, 2 not filtered (PCM / lossless), 3 lossless
local G_QP = buffer.create(0) -- QpY + 64
local G_EDGE = buffer.create(0) -- bit 0 transform edge left, 1 transform edge top, 2 prediction edge left, 3 prediction edge top, 4 coded luma
local G_DEPTH = buffer.create(0) -- coding tree depth
local G_ZS = buffer.create(0) -- z-scan order (u32)
local G_MVF = buffer.create(0) -- bit 0 L0 used, bit 1 L1 used
local G_MV = buffer.create(0) -- i16 x 4: L0 x, y, L1 x, y
local G_REF = buffer.create(0) -- i8 x 2
-- per CTB
local CTB_SLICE = {} -- SliceAddrRs of the slice that holds it (-1: not decoded)
local CTB_HDR = {} -- its slice header
local CTB_SAO = {} -- its SAO parameters

local function ensure(b: buffer, size: number): buffer
	if buffer.len(b) < size then
		return buffer.create(size)
	end
	return b
end

-- 4 x 4 block index of luma position
local function blk(x, y)
	return rshift(y, 2) * PW + rshift(x, 2)
end

-- is the luma position (xN, yN) available for the block at (xC, yC)? (6.4.1)
local CUR_SADDR = 0
local function avail(xC, yC, xN, yN): boolean
	if xN < 0 or yN < 0 or xN >= S.width or yN >= S.height then
		return false
	end
	local bn = rshift(yN, 2) * PW + rshift(xN, 2)
	local bc = rshift(yC, 2) * PW + rshift(xC, 2)
	if buffer.readu32(G_ZS, bn * 4) > buffer.readu32(G_ZS, bc * 4) then
		return false
	end
	local lg = S.log2Ctb
	local ctbN = rshift(yN, lg) * S.ctbW + rshift(xN, lg)
	if CTB_SLICE[ctbN + 1] ~= CUR_SADDR then
		return false
	end
	local ctbC = rshift(yC, lg) * S.ctbW + rshift(xC, lg)
	if P.tileId[ctbN + 1] ~= P.tileId[ctbC + 1] then
		return false
	end
	return true
end

------------------------------------------------------------------------------------------------------------------------
-- inverse transforms: COEF (n x n, raster, 1-based) -> RES

local COEF = table.create(1024, 0)
local RES = table.create(1024, 0)
local TMP = table.create(1024, 0)

local function clip16(v)
	if v < -32768 then
		return -32768
	elseif v > 32767 then
		return 32767
	end
	return v
end

-- one 1-D inverse transform of n points (generic: the 4-point DST)
local function inv1d(n, m, src, so, ss, dst, d0, ds, shift, lastK)
	local add = lshift(1, shift - 1)
	local div = lshift(1, shift)
	for j = 0, n - 1 do
		local sum = 0
		local idx = j + 1
		for k = 0, lastK do
			local c = src[so + k * ss]
			if c ~= 0 then
				sum += m[k * n + idx] * c
			end
		end
		dst[d0 + j * ds] = (sum + add) // div
	end
end

local DST = { 29, 55, 74, 84, 74, 74, 0, -74, 84, -29, -74, 55, 55, -84, 74, -29 }

-- the odd basis functions of the 8, 16 and 32-point transforms: ODD[s][j * s / 2 + i + 1] = basis 2i + 1 at sample j
local ODD = {}
for _, s in ipairs({ 8, 16, 32 }) do
	local m = MAT[s]
	local half = s // 2
	local t = table.create(half * half, 0)
	for j = 0, half - 1 do
		for i = 0, half - 1 do
			t[j * half + i + 1] = m[(2 * i + 1) * s + j + 1]
		end
	end
	ODD[s] = t
end
local EA = table.create(32, 0)
local EB = table.create(32, 0)
local CO = table.create(16, 0)

-- one 1-D inverse DCT of n points by even / odd decomposition: src[so + k * ss] (k <= lastK non-zero) -> dst[d0 + j * ds]
local function idct1d(n, src, so, ss, lastK, dst, d0, ds, add, div, clip)
	local q = n // 4
	local c0 = src[so]
	local c1 = q <= lastK and src[so + q * ss] or 0
	local c2 = 2 * q <= lastK and src[so + 2 * q * ss] or 0
	local c3 = 3 * q <= lastK and src[so + 3 * q * ss] or 0
	local e0, e1 = 64 * (c0 + c2), 64 * (c0 - c2)
	local o0, o1 = 83 * c1 + 36 * c3, 36 * c1 - 83 * c3
	local E, F = EA, EB
	E[1], E[2], E[3], E[4] = e0 + o0, e1 + o1, e1 - o1, e0 - o0
	local s = 8
	while s <= n do
		local step = n // s
		local half = s // 2
		-- the odd coefficients of this level that may be non-zero
		local cnt = 0
		local k = step
		while cnt < half and k <= lastK do
			cnt += 1
			CO[cnt] = src[so + k * ss]
			k += 2 * step
		end
		local od = ODD[s]
		for j = 0, half - 1 do
			local sum = 0
			local b = j * half
			for i = 1, cnt do
				sum += od[b + i] * CO[i]
			end
			local e = E[j + 1]
			F[j + 1] = e + sum
			F[s - j] = e - sum
		end
		E, F = F, E
		s *= 2
	end
	if clip then
		for j = 0, n - 1 do
			local v = (E[j + 1] + add) // div
			if v < -32768 then
				v = -32768
			elseif v > 32767 then
				v = 32767
			end
			dst[d0 + j * ds] = v
		end
	else
		for j = 0, n - 1 do
			dst[d0 + j * ds] = (E[j + 1] + add) // div
		end
	end
end

-- RES <- inverse transform of COEF (n x n); maxRow / maxCol: last non-zero row / column
local function inverseTransform(n, isDst, maxCol, maxRow)
	local bdShift = 20 - BD
	if isDst then
		for x = 0, maxCol do
			inv1d(n, DST, COEF, x + 1, n, TMP, x + 1, n, 7, maxRow)
			for y = 0, n - 1 do
				TMP[y * n + x + 1] = clip16(TMP[y * n + x + 1])
			end
		end
		for y = 0, n - 1 do
			inv1d(n, DST, TMP, y * n + 1, 1, RES, y * n + 1, 1, bdShift, maxCol)
		end
		return
	end
	if maxCol == 0 and maxRow == 0 then
		-- only the DC coefficient
		local v = clip16((COEF[1] * 64 + 64) // 128)
		local r = (v * 64 + lshift(1, bdShift - 1)) // lshift(1, bdShift)
		for i = 1, n * n do
			RES[i] = r
		end
		return
	end
	-- columns (first stage), then rows
	for x = 0, maxCol do
		idct1d(n, COEF, x + 1, n, maxRow, TMP, x + 1, n, 64, 128, true)
	end
	local add, div = lshift(1, bdShift - 1), lshift(1, bdShift)
	for y = 0, n - 1 do
		idct1d(n, TMP, y * n + 1, 1, maxCol, RES, y * n + 1, 1, add, div, false)
	end
end

-- add RES (n x n) to the plane, clipping
local function addResidual(plane: buffer, stride, x0, y0, n)
	local maxv = MAXV
	for y = 0, n - 1 do
		local o = 2 * ((y0 + y) * stride + x0)
		local r = y * n
		for x = 0, n - 1 do
			local v = readu16(plane, o) + RES[r + x + 1]
			if v < 0 then
				v = 0
			elseif v > maxv then
				v = maxv
			end
			writeu16(plane, o, v)
			o += 2
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- intra prediction

local REF = table.create(132, 0) -- p[-1][y]: REF[64 - y] ... corner REF[65] ... p[x][-1]: REF[66 + x]  (y, x in -1 .. 63)
local FREF = table.create(132, 0)
local REFA = table.create(200, 0) -- angular reference ref[x], index x + 100
local AV = table.create(132, false)

-- reference samples of the n x n block of plane cIdx at (x0, y0) (component samples) into REF, filtered by mode
local function intraPredict(cIdx, x0, y0, n, mode)
	local plane = cIdx == 0 and PY or (cIdx == 1 and PU or PV)
	local stride = cIdx == 0 and YS or CS
	local sc = cIdx == 0 and 0 or 1 -- (chroma: half the luma coordinates)
	local xL, yL = lshift(x0, sc), lshift(y0, sc)
	local unit = cIdx == 0 and 4 or 2 -- samples per 4 x 4 luma block
	local constrained = P.constrainedIntra
	local any = false
	-- availability per unit, then the samples: left column bottom-up (2n .. 1), corner, top row
	-- REF index: left y -> 65 - (y + 1) for y = 0 .. 2n - 1 (so REF[64] is p[-1][0]), corner 65, top x -> 66 + x
	local function fill(idxFn, count, xs, ys, dx, dy)
		for k = 0, count - 1, unit do
			local xs2, ys2 = xs + dx * k, ys + dy * k
			local ok = avail(xL, yL, lshift(xs2, sc), lshift(ys2, sc))
			if ok and constrained and band(readu8(G_CU, blk(lshift(xs2, sc), lshift(ys2, sc))), 1) == 0 then
				ok = false
			end
			for t = 0, min(unit, count - k) - 1 do
				local i = idxFn(k + t)
				AV[i] = ok
				if ok then
					REF[i] = readu16(plane, 2 * ((ys + dy * (k + t)) * stride + xs + dx * (k + t)))
					any = true
				end
			end
		end
	end
	fill(function(k)
		return 64 - k
	end, 2 * n, x0 - 1, y0, 0, 1)
	-- corner
	do
		local ok = avail(xL, yL, lshift(x0 - 1, sc), lshift(y0 - 1, sc))
		if ok and constrained and band(readu8(G_CU, blk(lshift(x0 - 1, sc), lshift(y0 - 1, sc))), 1) == 0 then
			ok = false
		end
		AV[65] = ok
		if ok then
			REF[65] = readu16(plane, 2 * ((y0 - 1) * stride + x0 - 1))
			any = true
		end
	end
	fill(function(k)
		return 66 + k
	end, 2 * n, x0, y0 - 1, 1, 0)
	local first = 65 - 2 * n -- p[-1][2n - 1]
	local last = 65 + 2 * n -- p[2n - 1][-1]
	if not any then
		local v = lshift(1, BD - 1)
		for i = first, last do
			REF[i] = v
		end
	else
		if not AV[first] then
			for i = first + 1, last do
				if AV[i] then
					REF[first] = REF[i]
					break
				end
			end
		end
		for i = first + 1, last do
			if not AV[i] then
				REF[i] = REF[i - 1]
			end
		end
	end
	-- filtering (luma only in 4:2:0)
	local ref = REF
	if cIdx == 0 and mode ~= 1 and n ~= 4 then
		local d = min(abs(mode - 26), abs(mode - 10))
		local thres = n == 8 and 7 or (n == 16 and 1 or 0)
		if d > thres then
			local strong = false
			if S.strongIntraSmoothing and n == 32 then
				local lim = lshift(1, BD - 5)
				local c = REF[65]
				if abs(c + REF[last] - 2 * REF[65 + n]) < lim and abs(c + REF[first] - 2 * REF[65 - n]) < lim then
					strong = true
				end
			end
			if strong then
				local c, l, t = REF[65], REF[first], REF[last]
				FREF[65] = c
				for i = 0, 62 do
					FREF[64 - i] = ((63 - i) * c + (i + 1) * l + 32) // 64
					FREF[66 + i] = ((63 - i) * c + (i + 1) * t + 32) // 64
				end
				FREF[first], FREF[last] = l, t
			else
				FREF[first], FREF[last] = REF[first], REF[last]
				for i = first + 1, last - 1 do
					FREF[i] = (REF[i - 1] + 2 * REF[i] + REF[i + 1] + 2) // 4
				end
			end
			ref = FREF
		end
	end
	-- prediction into the plane
	local maxv = MAXV
	if mode == 0 then
		-- planar
		local sh = 0
		while lshift(1, sh) < n do
			sh += 1
		end
		local tr, bl = ref[66 + n], ref[64 - n]
		for y = 0, n - 1 do
			local o = 2 * ((y0 + y) * stride + x0)
			local left = ref[64 - y]
			for x = 0, n - 1 do
				local v = ((n - 1 - x) * left + (x + 1) * tr + (n - 1 - y) * ref[66 + x] + (y + 1) * bl + n) // lshift(2, sh)
				writeu16(plane, o + 2 * x, v)
			end
		end
	elseif mode == 1 then
		-- DC
		local sum = n
		for i = 0, n - 1 do
			sum += ref[66 + i] + ref[64 - i]
		end
		local sh = 1
		while lshift(1, sh) < 2 * n do
			sh += 1
		end
		local dc = sum // lshift(1, sh)
		for y = 0, n - 1 do
			local o = 2 * ((y0 + y) * stride + x0)
			for x = 0, n - 1 do
				writeu16(plane, o + 2 * x, dc)
			end
		end
		if cIdx == 0 and n < 32 then
			writeu16(plane, 2 * (y0 * stride + x0), (ref[64] + 2 * dc + ref[66] + 2) // 4)
			for x = 1, n - 1 do
				writeu16(plane, 2 * (y0 * stride + x0 + x), (ref[66 + x] + 3 * dc + 2) // 4)
			end
			for y = 1, n - 1 do
				writeu16(plane, 2 * ((y0 + y) * stride + x0), (ref[64 - y] + 3 * dc + 2) // 4)
			end
		end
	else
		local angle = INTRA_ANGLE[mode]
		local R = REFA
		-- ref[x] at R[x + 100]
		if mode >= 18 then
			for x = 0, n do
				R[x + 100] = ref[65 + x]
			end
			if angle < 0 then
				local lo = (n * angle) // 32
				if lo < -1 then
					local inv = INV_ANGLE[mode]
					for x = lo, -1 do
						R[x + 100] = ref[65 - (((x * inv + 128) // 256))]
					end
				end
			else
				for x = n + 1, 2 * n do
					R[x + 100] = ref[65 + x]
				end
			end
			for y = 0, n - 1 do
				local pos = (y + 1) * angle
				local idx = pos // 32
				local fact = pos % 32
				local o = 2 * ((y0 + y) * stride + x0)
				if fact == 0 then
					for x = 0, n - 1 do
						writeu16(plane, o + 2 * x, R[x + idx + 101])
					end
				else
					for x = 0, n - 1 do
						writeu16(plane, o + 2 * x, ((32 - fact) * R[x + idx + 101] + fact * R[x + idx + 102] + 16) // 32)
					end
				end
			end
			if mode == 26 and cIdx == 0 and n < 32 then
				local c = ref[65]
				for y = 0, n - 1 do
					local v = ref[66] + (ref[64 - y] - c) // 2
					writeu16(plane, 2 * ((y0 + y) * stride + x0), v < 0 and 0 or (v > maxv and maxv or v))
				end
			end
		else
			for x = 0, n do
				R[x + 100] = ref[65 - x]
			end
			if angle < 0 then
				local lo = (n * angle) // 32
				if lo < -1 then
					local inv = INV_ANGLE[mode]
					for x = lo, -1 do
						R[x + 100] = ref[65 + ((x * inv + 128) // 256)]
					end
				end
			else
				for x = n + 1, 2 * n do
					R[x + 100] = ref[65 - x]
				end
			end
			for x = 0, n - 1 do
				local pos = (x + 1) * angle
				local idx = pos // 32
				local fact = pos % 32
				if fact == 0 then
					for y = 0, n - 1 do
						writeu16(plane, 2 * ((y0 + y) * stride + x0 + x), R[y + idx + 101])
					end
				else
					for y = 0, n - 1 do
						writeu16(plane, 2 * ((y0 + y) * stride + x0 + x), ((32 - fact) * R[y + idx + 101] + fact * R[y + idx + 102] + 16) // 32)
					end
				end
			end
			if mode == 10 and cIdx == 0 and n < 32 then
				local c = ref[65]
				for x = 0, n - 1 do
					local v = ref[64] + (ref[66 + x] - c) // 2
					writeu16(plane, 2 * (y0 * stride + x0 + x), v < 0 and 0 or (v > maxv and maxv or v))
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- residual coding (7.3.8.11) and the transform unit

local CSBF = table.create(64, 0) -- coded sub-block flags [xS + 8 * yS + 1]
local SIGPOS = table.create(16, 0)
local G1 = table.create(8, 0)
local NZ = table.create(1024, 0)

-- CU state
local cuIntra, cuBypass = false, false
local cuIntraMode = table.create(4, 1) -- luma modes of the (up to 4) prediction blocks
local cuChromaMode = 1
local qpY = 26
local qpYPred = 26
local lastQpY = 26
local isCuQpDeltaCoded = false
local cuQpDeltaVal = 0
local log2MinCuQpDelta = 6

-- chroma QP for cIdx 1 / 2
local function chromaQp(cIdx)
	local off = cIdx == 1 and (P.cbQpOffset + SH.cbQpOffset) or (P.crQpOffset + SH.crQpOffset)
	local qpi = clamp(qpY + off, -QP_BD, 57)
	local qpc
	if qpi < 30 then
		qpc = qpi
	elseif qpi > 43 then
		qpc = qpi - 6
	else
		qpc = QPC_TAB[qpi]
	end
	return qpc + QP_BD
end

local function residualCoding(x0, y0, log2Size, cIdx, predMode)
	-- (x0, y0): component sample position of the block
	local n = lshift(1, log2Size)
	local tsFlag = 0
	if P.transformSkip and log2Size == 2 and not cuBypass then
		tsFlag = decodeBin(47 + (cIdx > 0 and 1 or 0))
	end
	-- last significant position
	local ctxOff, ctxShift
	if cIdx == 0 then
		ctxOff = 3 * (log2Size - 2) + rshift(log2Size - 1, 2)
		ctxShift = rshift(log2Size + 1, 2)
	else
		ctxOff = 15
		ctxShift = log2Size - 2
	end
	local maxP = lshift(log2Size, 1) - 1
	local lx = 0
	while lx < maxP and decodeBin(53 + ctxOff + rshift(lx, ctxShift)) == 1 do
		lx += 1
	end
	local ly = 0
	while ly < maxP and decodeBin(71 + ctxOff + rshift(ly, ctxShift)) == 1 do
		ly += 1
	end
	if lx > 3 then
		local len = rshift(lx, 1) - 1
		lx = lshift(1, len) * (2 + band(lx, 1)) + decodeBypassBits(len)
	end
	if ly > 3 then
		local len = rshift(ly, 1) - 1
		ly = lshift(1, len) * (2 + band(ly, 1)) + decodeBypassBits(len)
	end
	-- scan order
	local scanIdx = 0
	if predMode >= 0 and (log2Size == 2 or (log2Size == 3 and cIdx == 0)) then
		if predMode >= 6 and predMode <= 14 then
			scanIdx = 2
		elseif predMode >= 22 and predMode <= 30 then
			scanIdx = 1
		end
	end
	if scanIdx == 2 then
		lx, ly = ly, lx
	end
	-- (COEF is all zeros between blocks: the positions set here are cleared at the end)
	local nn = n * n
	local nnz = 0
	local lgS = log2Size - 2 -- sub-blocks per side, log2
	local sbX, sbY = SCAN_X[scanIdx][lgS], SCAN_Y[scanIdx][lgS]
	local cX, cY = SCAN_X[scanIdx][2], SCAN_Y[scanIdx][2]
	-- the last sub-block and position in scan order
	local lastSub, lastPos = 0, 0
	do
		local xS, yS = rshift(lx, 2), rshift(ly, 2)
		for i = 1, #sbX do
			if sbX[i] == xS and sbY[i] == yS then
				lastSub = i - 1
				break
			end
		end
		local xp, yp = band(lx, 3), band(ly, 3)
		for i = 1, 16 do
			if cX[i] == xp and cY[i] == yp then
				lastPos = i - 1
				break
			end
		end
	end
	local sbW = lshift(1, lgS)
	for i = 1, 64 do
		CSBF[i] = 0
	end
	-- dequantisation
	local scale, shift, add = 0, 0, 0
	local mlist = nil
	local dcOnlyMax = 0
	if not cuBypass then
		local qp = cIdx == 0 and (qpY + QP_BD) or chromaQp(cIdx)
		shift = BD + log2Size - 5
		add = lshift(1, shift - 1)
		scale = LEVEL_SCALE[qp % 6] * lshift(1, qp // 6)
		if S.scalingListEnabled and not (tsFlag == 1 and log2Size > 2) then
			local fac = P.scaling or S.scaling
			mlist = fac[log2Size - 2][(cuIntra and 0 or 3) + cIdx]
		end
	end
	local greater1Ctx = 1
	local signHidingOn = P.signHiding and not cuBypass
	local maxRow, maxCol = 0, 0
	for i = lastSub, 0, -1 do
		local xS, yS = sbX[i + 1], sbY[i + 1]
		local inferSbDcSig = false
		local csbf
		if i < lastSub and i > 0 then
			local ctxCsbf = 0
			if xS < sbW - 1 then
				ctxCsbf += CSBF[xS + 2 + 8 * yS]
			end
			if yS < sbW - 1 then
				ctxCsbf += CSBF[xS + 1 + 8 * (yS + 1)]
			end
			csbf = decodeBin(89 + min(ctxCsbf, 1) + (cIdx > 0 and 2 or 0))
			inferSbDcSig = true
		else
			csbf = 1
		end
		CSBF[xS + 1 + 8 * yS] = csbf
		-- significant coefficients (positions in scan order within the sub-block)
		local nSig = 0
		local startN = 15
		if i == lastSub then
			startN = lastPos - 1
			SIGPOS[1] = lastPos
			nSig = 1
		end
		if csbf == 1 then
			local prevCsbf = 0
			if xS < sbW - 1 then
				prevCsbf += CSBF[xS + 2 + 8 * yS]
			end
			if yS < sbW - 1 then
				prevCsbf += 2 * CSBF[xS + 1 + 8 * (yS + 1)]
			end
			for nPos = startN, 0, -1 do
				local xP, yP = cX[nPos + 1], cY[nPos + 1]
				local sig
				if nPos == 0 and inferSbDcSig and nSig == 0 then
					sig = 1
				else
					local sigCtx
					local xC, yC = lshift(xS, 2) + xP, lshift(yS, 2) + yP
					if log2Size == 2 then
						sigCtx = CTX_IDX_MAP_4x4[lshift(yC, 2) + xC + 1]
					elseif xC + yC == 0 then
						sigCtx = 0
					else
						if prevCsbf == 0 then
							local s = xP + yP
							sigCtx = s == 0 and 2 or (s < 3 and 1 or 0)
						elseif prevCsbf == 1 then
							sigCtx = yP == 0 and 2 or (yP == 1 and 1 or 0)
						elseif prevCsbf == 2 then
							sigCtx = xP == 0 and 2 or (xP == 1 and 1 or 0)
						else
							sigCtx = 2
						end
						if cIdx == 0 then
							if xS + yS > 0 then
								sigCtx += 3
							end
							if log2Size == 3 then
								sigCtx += scanIdx == 0 and 9 or 15
							else
								sigCtx += 21
							end
						else
							if log2Size == 3 then
								sigCtx += 9
							else
								sigCtx += 12
							end
						end
					end
					sig = decodeBin(93 + (cIdx == 0 and sigCtx or 27 + sigCtx))
				end
				if sig == 1 then
					nSig += 1
					SIGPOS[nSig] = nPos
				end
			end
		end
		if nSig > 0 then
			-- levels
			local ctxSet = (i == 0 or cIdx > 0) and 0 or 2
			if i ~= lastSub and greater1Ctx == 0 then
				ctxSet += 1
			end
			greater1Ctx = 1
			local firstG1 = -1
			local numG1 = min(nSig, 8)
			for m = 1, numG1 do
				local inc = ctxSet * 4 + min(3, greater1Ctx) + (cIdx > 0 and 16 or 0)
				local f = decodeBin(137 + inc)
				G1[m] = f
				if f == 1 then
					greater1Ctx = 0
					if firstG1 < 0 then
						firstG1 = m
					end
				elseif greater1Ctx > 0 then
					greater1Ctx += 1
				end
			end
			local g2 = 0
			if firstG1 > 0 then
				g2 = decodeBin(161 + ctxSet + (cIdx > 0 and 4 or 0))
			end
			local lastSigPos, firstSigPos = SIGPOS[1], SIGPOS[nSig]
			local hidden = signHidingOn and (lastSigPos - firstSigPos > 3)
			local nSigns = hidden and nSig - 1 or nSig
			local signs = decodeBypassBits(nSigns)
			local signMask = lshift(1, nSigns - 1)
			local rice = 0
			local sumAbs = 0
			for m = 1, nSig do
				local base = 1
				local lvl
				if m <= 8 then
					base = 1 + G1[m]
					if m == firstG1 then
						base += g2
					end
					local thresh = (m == firstG1) and 3 or 2
					if m > 8 or base == thresh then
						-- coeff_abs_level_remaining
						local prefix = 0
						while prefix < 32 and decodeBypass() == 1 do
							prefix += 1
						end
						local rem
						if prefix <= 3 then
							rem = lshift(prefix, rice) + decodeBypassBits(rice)
						else
							local k = prefix - 3 + rice
							rem = (lshift(1, prefix - 3) + 2) * lshift(1, rice) + decodeBypassBits(k)
						end
						lvl = base + rem
						if lvl > 3 * lshift(1, rice) then
							rice = min(rice + 1, 4)
						end
					else
						lvl = base
					end
				else
					local prefix = 0
					while prefix < 32 and decodeBypass() == 1 do
						prefix += 1
					end
					local rem
					if prefix <= 3 then
						rem = lshift(prefix, rice) + decodeBypassBits(rice)
					else
						local k = prefix - 3 + rice
						rem = (lshift(1, prefix - 3) + 2) * lshift(1, rice) + decodeBypassBits(k)
					end
					lvl = 1 + rem
					if lvl > 3 * lshift(1, rice) then
						rice = min(rice + 1, 4)
					end
				end
				local pos = SIGPOS[m]
				local neg = false
				if hidden and m == nSig then
					sumAbs += lvl
					neg = sumAbs % 2 == 1
				else
					sumAbs += lvl
					neg = band(signs, signMask) ~= 0
					signMask = rshift(signMask, 1)
				end
				local xC, yC = lshift(xS, 2) + cX[pos + 1], lshift(yS, 2) + cY[pos + 1]
				local v = neg and -lvl or lvl
				if not cuBypass then
					local mm = 16
					if mlist then
						mm = mlist[yC * n + xC + 1]
					end
					v = clip16((v * scale * mm + add) // lshift(1, shift))
				end
				local ci = yC * n + xC + 1
				COEF[ci] = v
				nnz += 1
				NZ[nnz] = ci
				if xC > maxCol then
					maxCol = xC
				end
				if yC > maxRow then
					maxRow = yC
				end
			end
		end
	end
	-- residual
	if cuBypass then
		for i = 1, nn do
			RES[i] = COEF[i]
		end
	elseif tsFlag == 1 then
		local bdShift = 20 - BD
		local a = lshift(1, bdShift - 1)
		for i = 1, nn do
			RES[i] = (COEF[i] * 128 + a) // lshift(1, bdShift)
		end
	else
		inverseTransform(n, cuIntra and cIdx == 0 and n == 4, maxCol, maxRow)
	end
	for i = 1, nnz do
		COEF[NZ[i]] = 0
	end
	local plane = cIdx == 0 and PY or (cIdx == 1 and PU or PV)
	addResidual(plane, cIdx == 0 and YS or CS, x0, y0, n)
end

------------------------------------------------------------------------------------------------------------------------
-- transform tree, coding unit, coding quadtree, SAO syntax

local predictionUnit -- (prediction unit syntax and motion compensation: below)
local LAST_MERGE = false -- (merge_flag of the last prediction unit)
local cuDepth = 0 -- (coding tree depth of the coding unit)

-- mark the 4 x 4 blocks of a luma rectangle in G_EDGE (bits) / other grids
local function markEdges(x0, y0, w, h, leftBit, topBit)
	local bx0, by0 = rshift(x0, 2), rshift(y0, 2)
	local bw, bh = max(1, rshift(w, 2)), max(1, rshift(h, 2))
	for by = by0, by0 + bh - 1 do
		local i = by * PW + bx0
		writeu8(G_EDGE, i, bor(readu8(G_EDGE, i), leftBit))
	end
	for bx = bx0, bx0 + bw - 1 do
		local i = by0 * PW + bx
		writeu8(G_EDGE, i, bor(readu8(G_EDGE, i), topBit))
	end
end
local function setGrid(g: buffer, x0, y0, w, h, v)
	local bx0, by0 = rshift(x0, 2), rshift(y0, 2)
	local bw, bh = rshift(w, 2), rshift(h, 2)
	for by = by0, by0 + bh - 1 do
		buffer.fill(g, by * PW + bx0, v, bw)
	end
end

local function lumaModeAt(x, y)
	return readu8(G_IPM, blk(x, y))
end

local maxTrafoDepth = 0
local firstQgInUnit = true -- (no coding unit yet in this slice / tile / wavefront row: the slice's quantiser predicts)
local intraSplit = false
local cuPartMode = 0
local cuLog2Size = 3

local function transformUnit(x0, y0, xBase, yBase, log2Size, trafoDepth, blkIdx, cbfL, cbfCb, cbfCr, cbfCbP, cbfCrP)
	local n = lshift(1, log2Size)
	local chroma4 = log2Size == 2 -- (4:2:0: the chroma of four 4x4 luma blocks is one 4x4 block, sent with the last)
	local anyChroma
	if chroma4 then
		anyChroma = cbfCbP == 1 or cbfCrP == 1
	else
		anyChroma = cbfCb == 1 or cbfCr == 1
	end
	if (cbfL == 1 or anyChroma) and P.cuQpDelta and not isCuQpDeltaCoded then
		local v = 0
		local inc = 0
		while v < 5 and decodeBin(9 + inc) == 1 do
			v += 1
			inc = 1
		end
		if v >= 5 then
			local k = 0
			while k < 7 and decodeBypass() == 1 do
				v += lshift(1, k)
				k += 1
			end
			v += decodeBypassBits(k)
		end
		if v > 0 and decodeBypass() == 1 then
			v = -v
		end
		isCuQpDeltaCoded = true
		cuQpDeltaVal = v
		qpY = (qpYPred + v + 52 + 2 * QP_BD) % (52 + QP_BD) - QP_BD
	end
	-- luma
	if cuIntra then
		intraPredict(0, x0, y0, n, lumaModeAt(x0, y0))
	end
	if cbfL == 1 then
		residualCoding(x0, y0, log2Size, 0, cuIntra and lumaModeAt(x0, y0) or -1)
		local bx0, by0 = rshift(x0, 2), rshift(y0, 2)
		for by = by0, by0 + rshift(n, 2) - 1 do
			for bx = bx0, bx0 + rshift(n, 2) - 1 do
				local i = by * PW + bx
				writeu8(G_EDGE, i, bor(readu8(G_EDGE, i), 16))
			end
		end
	end
	markEdges(x0, y0, n, n, 1, 2)
	-- chroma
	local cm = cuChromaMode
	if not chroma4 then
		local xc, yc, nc = rshift(x0, 1), rshift(y0, 1), rshift(n, 1)
		if cuIntra then
			intraPredict(1, xc, yc, nc, cm)
		end
		if cbfCb == 1 then
			residualCoding(xc, yc, log2Size - 1, 1, cuIntra and cm or -1)
		end
		if cuIntra then
			intraPredict(2, xc, yc, nc, cm)
		end
		if cbfCr == 1 then
			residualCoding(xc, yc, log2Size - 1, 2, cuIntra and cm or -1)
		end
	elseif blkIdx == 3 then
		local xc, yc = rshift(xBase, 1), rshift(yBase, 1)
		if cuIntra then
			intraPredict(1, xc, yc, 4, cm)
		end
		if cbfCbP == 1 then
			residualCoding(xc, yc, 2, 1, cuIntra and cm or -1)
		end
		if cuIntra then
			intraPredict(2, xc, yc, 4, cm)
		end
		if cbfCrP == 1 then
			residualCoding(xc, yc, 2, 2, cuIntra and cm or -1)
		end
	end
end

local function transformTree(x0, y0, xBase, yBase, log2Size, trafoDepth, blkIdx, cbfCbP, cbfCrP)
	local split
	if log2Size <= S.log2MaxTb and log2Size > S.log2MinTb and trafoDepth < maxTrafoDepth and not (intraSplit and trafoDepth == 0) then
		split = decodeBin(37 + 5 - log2Size) == 1
	else
		local interSplit = S.maxTrDepthInter == 0 and not cuIntra and cuPartMode ~= 0 and trafoDepth == 0
		split = log2Size > S.log2MaxTb or (intraSplit and trafoDepth == 0) or interSplit
	end
	local cbfCb, cbfCr = 0, 0
	if log2Size > 2 then
		if trafoDepth == 0 or cbfCbP == 1 then
			cbfCb = decodeBin(42 + trafoDepth)
		end
		if trafoDepth == 0 or cbfCrP == 1 then
			cbfCr = decodeBin(42 + trafoDepth)
		end
	else
		-- (4:2:0, 4x4 luma: the chroma flags are the parent's)
		cbfCb, cbfCr = cbfCbP, cbfCrP
	end
	if split then
		local h = lshift(1, log2Size - 1)
		transformTree(x0, y0, x0, y0, log2Size - 1, trafoDepth + 1, 0, cbfCb, cbfCr)
		transformTree(x0 + h, y0, x0, y0, log2Size - 1, trafoDepth + 1, 1, cbfCb, cbfCr)
		transformTree(x0, y0 + h, x0, y0, log2Size - 1, trafoDepth + 1, 2, cbfCb, cbfCr)
		transformTree(x0 + h, y0 + h, x0, y0, log2Size - 1, trafoDepth + 1, 3, cbfCb, cbfCr)
	else
		local cbfL = 1
		if cuIntra or trafoDepth ~= 0 or cbfCb == 1 or cbfCr == 1 then
			cbfL = decodeBin(40 + (trafoDepth == 0 and 1 or 0))
		end
		if log2Size > 2 then
			transformUnit(x0, y0, xBase, yBase, log2Size, trafoDepth, blkIdx, cbfL, cbfCb, cbfCr, cbfCb, cbfCr)
		else
			transformUnit(x0, y0, xBase, yBase, log2Size, trafoDepth, blkIdx, cbfL, 0, 0, cbfCbP, cbfCrP)
		end
	end
end

-- PCM samples (the CABAC data ends before them, and restarts after)
local function pcmSamples(x0, y0, log2Size)
	local n = lshift(1, log2Size)
	BP = cabacNextByte() * 8
	local bdY, bdC = S.pcmBitDepth, S.pcmBitDepthC
	for y = 0, n - 1 do
		for x = 0, n - 1 do
			writeu16(PY, 2 * ((y0 + y) * YS + x0 + x), lshift(u(bdY), BD - bdY))
		end
	end
	local nc = rshift(n, 1)
	for _, plane in ipairs({ PU, PV }) do
		for y = 0, nc - 1 do
			for x = 0, nc - 1 do
				writeu16(plane, 2 * ((rshift(y0, 1) + y) * CS + rshift(x0, 1) + x), lshift(u(bdC), BD - bdC))
			end
		end
	end
	cabacStart((BP + 7) // 8)
end

local function codingUnit(x0, y0, log2Size, depth)
	local n = lshift(1, log2Size)
	cuBypass = false
	if P.transquantBypass then
		cuBypass = decodeBin(5) == 1
	end
	local skip = 0
	if SH.type ~= 2 then
		local inc = 0
		if avail(x0, y0, x0 - 1, y0) and band(readu8(G_CU, blk(x0 - 1, y0)), 2) ~= 0 then
			inc += 1
		end
		if avail(x0, y0, x0, y0 - 1) and band(readu8(G_CU, blk(x0, y0 - 1)), 2) ~= 0 then
			inc += 1
		end
		skip = decodeBin(6 + inc)
	end
	cuIntra = false
	intraSplit = false
	cuPartMode = 0
	cuLog2Size = log2Size
	cuDepth = depth
	local pcm = false
	-- (grids first: prediction units look at them)
	setGrid(G_DEPTH, x0, y0, n, n, depth)
	setGrid(G_IPM, x0, y0, n, n, 1)
	local cuFlags = (skip == 1 and 2 or 0) + (cuBypass and 12 or 0)
	setGrid(G_CU, x0, y0, n, n, cuFlags)
	markEdges(x0, y0, n, n, 5, 10)
	if skip == 1 then
		predictionUnit(x0, y0, n, x0, y0, n, n, 0, true)
	else
		local predIntra = SH.type == 2
		if SH.type ~= 2 then
			predIntra = decodeBin(12) == 1
		end
		cuIntra = predIntra
		local part = 0 -- 0 2Nx2N, 1 2NxN, 2 Nx2N, 3 NxN, 4 2NxnU, 5 2NxnD, 6 nLx2N, 7 nRx2N
		if not predIntra or log2Size == S.log2MinCb then
			if decodeBin(13) == 1 then
				part = 0
			elseif predIntra then
				part = 3
			elseif log2Size == S.log2MinCb then
				if decodeBin(13 + 1) == 1 then
					part = 1
				elseif log2Size == 3 then
					part = 2
				elseif decodeBin(13 + 2) == 1 then
					part = 2
				else
					part = 3
				end
			elseif not S.amp then
				part = decodeBin(13 + 1) == 1 and 1 or 2
			elseif decodeBin(13 + 1) == 1 then
				if decodeBin(13 + 3) == 1 then
					part = 1
				else
					part = decodeBypass() == 1 and 5 or 4
				end
			else
				if decodeBin(13 + 3) == 1 then
					part = 2
				else
					part = decodeBypass() == 1 and 7 or 6
				end
			end
		end
		cuPartMode = part
		if predIntra then
			setGrid(G_CU, x0, y0, n, n, cuFlags + 1)
			intraSplit = part == 3
			if part == 0 and S.pcm and log2Size >= S.log2MinPcm and log2Size <= S.log2MaxPcm then
				pcm = decodeTerminate() == 1
			end
			if pcm then
				pcmSamples(x0, y0, log2Size)
				if S.pcmLoopFilterDisabled then
					setGrid(G_CU, x0, y0, n, n, bor(cuFlags + 1, 4))
				end
			else
				local nb = intraSplit and 4 or 1
				local pb = intraSplit and rshift(n, 1) or n
				local prevFlag = table.create(4, 0)
				for i = 1, nb do
					prevFlag[i] = decodeBin(17)
				end
				for i = 1, nb do
					local xPb = x0 + ((i - 1) % 2) * pb
					local yPb = y0 + ((i - 1) // 2) * pb
					-- candidates from the left and above (above: only within this CTB)
					local candA, candB = 1, 1
					if avail(xPb, yPb, xPb - 1, yPb) then
						local b = blk(xPb - 1, yPb)
						if band(readu8(G_CU, b), 1) == 1 then
							candA = readu8(G_IPM, b)
						end
					end
					if avail(xPb, yPb, xPb, yPb - 1) and (yPb - 1) >= lshift(rshift(yPb, S.log2Ctb), S.log2Ctb) then
						local b = blk(xPb, yPb - 1)
						if band(readu8(G_CU, b), 1) == 1 then
							candB = readu8(G_IPM, b)
						end
					end
					local c0, c1, c2
					if candA == candB then
						if candA < 2 then
							c0, c1, c2 = 0, 1, 26
						else
							c0, c1, c2 = candA, 2 + (candA + 29) % 32, 2 + (candA - 2 + 1) % 32
						end
					else
						c0, c1 = candA, candB
						if candA ~= 0 and candB ~= 0 then
							c2 = 0
						elseif candA ~= 1 and candB ~= 1 then
							c2 = 1
						else
							c2 = 26
						end
					end
					local mode
					if prevFlag[i] == 1 then
						local idx = 0
						while idx < 2 and decodeBypass() == 1 do
							idx += 1
						end
						mode = idx == 0 and c0 or (idx == 1 and c1 or c2)
					else
						mode = decodeBypassBits(5)
						-- (the candidates ascending)
						if c0 > c1 then
							c0, c1 = c1, c0
						end
						if c0 > c2 then
							c0, c2 = c2, c0
						end
						if c1 > c2 then
							c1, c2 = c2, c1
						end
						if mode >= c0 then
							mode += 1
						end
						if mode >= c1 then
							mode += 1
						end
						if mode >= c2 then
							mode += 1
						end
					end
					cuIntraMode[i] = mode
					setGrid(G_IPM, xPb, yPb, pb, pb, mode)
				end
				-- chroma mode
				local cmIdx = 4
				if decodeBin(18) == 1 then
					cmIdx = decodeBypassBits(2)
				end
				local lm = cuIntraMode[1]
				if cmIdx == 4 then
					cuChromaMode = lm
				else
					local m = cmIdx == 0 and 0 or (cmIdx == 1 and 26 or (cmIdx == 2 and 10 or 1))
					if m == lm then
						m = 34
					end
					cuChromaMode = m
				end
			end
		else
			local h = rshift(n, 1)
			local q = rshift(n, 2)
			if part == 0 then
				predictionUnit(x0, y0, n, x0, y0, n, n, 0, false)
			elseif part == 1 then
				predictionUnit(x0, y0, n, x0, y0, n, h, 0, false)
				predictionUnit(x0, y0, n, x0, y0 + h, n, h, 1, false)
			elseif part == 2 then
				predictionUnit(x0, y0, n, x0, y0, h, n, 0, false)
				predictionUnit(x0, y0, n, x0 + h, y0, h, n, 1, false)
			elseif part == 4 then
				predictionUnit(x0, y0, n, x0, y0, n, q, 0, false)
				predictionUnit(x0, y0, n, x0, y0 + q, n, n - q, 1, false)
			elseif part == 5 then
				predictionUnit(x0, y0, n, x0, y0, n, n - q, 0, false)
				predictionUnit(x0, y0, n, x0, y0 + n - q, n, q, 1, false)
			elseif part == 6 then
				predictionUnit(x0, y0, n, x0, y0, q, n, 0, false)
				predictionUnit(x0, y0, n, x0 + q, y0, n - q, n, 1, false)
			elseif part == 7 then
				predictionUnit(x0, y0, n, x0, y0, n - q, n, 0, false)
				predictionUnit(x0, y0, n, x0 + n - q, y0, q, n, 1, false)
			else
				predictionUnit(x0, y0, n, x0, y0, h, h, 0, false)
				predictionUnit(x0, y0, n, x0 + h, y0, h, h, 1, false)
				predictionUnit(x0, y0, n, x0, y0 + h, h, h, 2, false)
				predictionUnit(x0, y0, n, x0 + h, y0 + h, h, h, 3, false)
			end
		end
		if not pcm then
			local rqtRoot = 1
			if not predIntra and not (part == 0 and LAST_MERGE) then
				rqtRoot = decodeBin(36)
			end
			if rqtRoot == 1 then
				maxTrafoDepth = predIntra and (S.maxTrDepthIntra + (intraSplit and 1 or 0)) or S.maxTrDepthInter
				transformTree(x0, y0, x0, y0, log2Size, 0, 0, 0, 0)
			end
		end
	end
	-- the CU's quantiser (for later predictions and the deblocking filter)
	if not isCuQpDeltaCoded then
		qpY = (qpYPred + cuQpDeltaVal + 52 + 2 * QP_BD) % (52 + QP_BD) - QP_BD
	end
	setGrid(G_QP, x0, y0, n, n, qpY + 64)
	lastQpY = qpY
	firstQgInUnit = false
end


local function codingQuadtree(x0, y0, log2Size, depth)
	local n = lshift(1, log2Size)
	local split
	if x0 + n <= S.width and y0 + n <= S.height and log2Size > S.log2MinCb then
		local inc = 0
		if avail(x0, y0, x0 - 1, y0) and readu8(G_DEPTH, blk(x0 - 1, y0)) > depth then
			inc += 1
		end
		if avail(x0, y0, x0, y0 - 1) and readu8(G_DEPTH, blk(x0, y0 - 1)) > depth then
			inc += 1
		end
		split = decodeBin(2 + inc) == 1
	else
		split = log2Size > S.log2MinCb
	end
	if log2Size >= log2MinCuQpDelta then
		-- a new quantisation group: its predicted quantiser
		isCuQpDeltaCoded = false
		cuQpDeltaVal = 0
		local prev = firstQgInUnit and SH.qp or lastQpY
		local mask = S.ctbSize - 1
		local qa, qb = prev, prev
		if band(x0, mask) ~= 0 then
			qa = readu8(G_QP, blk(x0 - 1, y0)) - 64
		end
		if band(y0, mask) ~= 0 then
			qb = readu8(G_QP, blk(x0, y0 - 1)) - 64
		end
		qpYPred = (qa + qb + 1) // 2
		qpY = qpYPred
	end
	if split then
		local h = rshift(n, 1)
		codingQuadtree(x0, y0, log2Size - 1, depth + 1)
		if x0 + h < S.width then
			codingQuadtree(x0 + h, y0, log2Size - 1, depth + 1)
		end
		if y0 + h < S.height then
			codingQuadtree(x0, y0 + h, log2Size - 1, depth + 1)
		end
		if x0 + h < S.width and y0 + h < S.height then
			codingQuadtree(x0 + h, y0 + h, log2Size - 1, depth + 1)
		end
	else
		codingUnit(x0, y0, log2Size, depth)
	end
end

-- SAO parameters of a CTB: { type[c], offsets[c] = { o1..o4 }, band[c], class[c] } (c 0..2)
local function saoSyntax(rx, ry, ctbAddrRs, ctbAddrTs)
	local mergeLeft, mergeUp = false, false
	if rx > 0 then
		local inSlice = ctbAddrRs > SH.sliceAddrRs
		local inTile = P.tileId[ctbAddrRs + 1] == P.tileId[ctbAddrRs]
		if inSlice and inTile then
			mergeLeft = decodeBin(0) == 1
		end
	end
	if ry > 0 and not mergeLeft then
		local up = ctbAddrRs - S.ctbW
		local inSlice = up >= SH.sliceAddrRs
		local inTile = P.tileId[ctbAddrRs + 1] == P.tileId[up + 1]
		if inSlice and inTile then
			mergeUp = decodeBin(0) == 1
		end
	end
	if mergeLeft then
		return CTB_SAO[ctbAddrRs]
	elseif mergeUp then
		return CTB_SAO[ctbAddrRs - S.ctbW + 1]
	end
	local sao = { type = { [0] = 0, 0, 0 }, off = { [0] = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }, band = { [0] = 0, 0, 0 },
		class = { [0] = 0, 0, 0 } }
	local cMax = lshift(1, min(BD, 10) - 5) - 1
	local offShift = BD - min(BD, 10)
	for c = 0, 2 do
		if (c == 0 and SH.saoLuma) or (c > 0 and SH.saoChroma) then
			if c == 0 or c == 1 then
				local t = 0
				if decodeBin(1) == 1 then
					t = decodeBypass() == 0 and 1 or 2
				end
				sao.type[c] = t
			else
				sao.type[2] = sao.type[1]
			end
			if sao.type[c] ~= 0 then
				local o = sao.off[c]
				for i = 1, 4 do
					local v = 0
					while v < cMax and decodeBypass() == 1 do
						v += 1
					end
					o[i] = v
				end
				if sao.type[c] == 1 then
					for i = 1, 4 do
						if o[i] ~= 0 and decodeBypass() == 1 then
							o[i] = -o[i]
						end
					end
					sao.band[c] = decodeBypassBits(5)
				else
					o[3], o[4] = -o[3], -o[4]
					if c == 0 then
						sao.class[0] = decodeBypassBits(2)
					elseif c == 1 then
						sao.class[1] = decodeBypassBits(2)
					else
						sao.class[2] = sao.class[1]
					end
				end
				for i = 1, 4 do
					o[i] = o[i] * lshift(1, offShift)
				end
			end
		end
	end
	return sao
end

------------------------------------------------------------------------------------------------------------------------
-- inter prediction: motion vectors (merge, AMVP, temporal) and motion compensation

-- motion of a 4 x 4 block: flags, mv0x, mv0y, mv1x, mv1y, ref0, ref1
local function motionAt(b)
	local f = readu8(G_MVF, b)
	local o = b * 8
	return f, buffer.readi16(G_MV, o), buffer.readi16(G_MV, o + 2), buffer.readi16(G_MV, o + 4), buffer.readi16(G_MV, o + 6),
		buffer.readi8(G_REF, b * 2), buffer.readi8(G_REF, b * 2 + 1)
end

local function isIntraAt(x, y)
	return band(readu8(G_CU, blk(x, y)), 1) == 1
end

-- availability of a neighbouring prediction block (6.4.2)
local function availPb(xCb, yCb, nCbS, xPb, yPb, w, h, partIdx, xN, yN)
	local ok
	if xCb <= xN and yCb <= yN and xCb + nCbS > xN and yCb + nCbS > yN then
		ok = not (lshift(w, 1) == nCbS and lshift(h, 1) == nCbS and partIdx == 1 and yCb + h <= yN and xCb + w > xN)
	else
		ok = avail(xPb, yPb, xN, yN)
	end
	if ok and isIntraAt(xN, yN) then
		return false
	end
	return ok
end

local function clipMv(v)
	if v < -32768 then
		return -32768
	elseif v > 32767 then
		return 32767
	end
	return v
end
local function scaleMv(mv, td, tb)
	td = clamp(td, -128, 127)
	tb = clamp(tb, -128, 127)
	local tx = (16384 + rshift(abs(td), 1))
	tx = td > 0 and tx // td or -(tx // -td)
	local dsf = clamp((tb * tx + 32) // 64, -4096, 4095)
	local p = dsf * mv
	if p >= 0 then
		return clipMv((p + 127) // 256)
	end
	return clipMv(-((-p + 127) // 256))
end

-- the temporal candidate for list X with reference index refIdx: available, mvx, mvy
local function temporalMv(xPb, yPb, w, h, X, refIdx)
	if not SH.temporalMvp then
		return false, 0, 0
	end
	local colPic = SH.colPic
	if not colPic or not colPic.col then
		return false, 0, 0
	end
	local col = colPic.col
	local cw = col.w
	local function fromBlock(x, y)
		local b = rshift(y, 4) * cw + rshift(x, 4)
		local f = readu8(col.flags, b)
		if f == 0 then
			return false
		end
		local mvx, mvy, poc, lt
		local L
		if band(f, 1) == 0 then
			L = 1
		elseif band(f, 2) == 0 then
			L = 0
		else
			L = SH.noBackwardPred and X or (SH.colFromL0 and 1 or 0)
		end
		mvx = buffer.readi16(col.mv, b * 8 + L * 4)
		mvy = buffer.readi16(col.mv, b * 8 + L * 4 + 2)
		poc = buffer.readi32(col.poc, b * 8 + L * 4)
		lt = band(rshift(f, 2 + L), 1) == 1
		local curLt = SH.refIsLt[X][refIdx]
		if lt ~= curLt then
			return false
		end
		local colDiff = colPic.poc - poc
		local curDiff = SH.poc - SH.refPoc[X][refIdx]
		if curLt or colDiff == curDiff or colDiff == 0 then
			return true, mvx, mvy
		end
		return true, scaleMv(mvx, colDiff, curDiff), scaleMv(mvy, colDiff, curDiff)
	end
	local xBr, yBr = xPb + w, yPb + h
	if rshift(yPb, S.log2Ctb) == rshift(yBr, S.log2Ctb) and yBr < S.height and xBr < S.width then
		local ok, mx, my = fromBlock(xBr, yBr)
		if ok then
			return true, mx, my
		end
	end
	return fromBlock(xPb + rshift(w, 1), yPb + rshift(h, 1))
end

-- merge candidates
local MF, MX0, MY0, MX1, MY1, MR0, MR1 = {}, {}, {}, {}, {}, {}, {}
local COMB_L0 = { 0, 1, 0, 2, 1, 2, 0, 3, 1, 3, 2, 3 }
local COMB_L1 = { 1, 0, 2, 0, 2, 1, 3, 0, 3, 1, 3, 2 }

local function deriveMerge(xCb, yCb, nCbS, xPb, yPb, w, h, partIdx, mergeIdx)
	local origW, origH = w, h
	if P.log2ParMrgLevel > 2 and nCbS == 8 then
		xPb, yPb, w, h, partIdx = xCb, yCb, nCbS, nCbS, 0
	end
	local n = 0
	local lvl = P.log2ParMrgLevel
	local function nb(xN, yN)
		if rshift(xPb, lvl) == rshift(xN, lvl) and rshift(yPb, lvl) == rshift(yN, lvl) then
			return nil
		end
		if not availPb(xCb, yCb, nCbS, xPb, yPb, w, h, partIdx, xN, yN) then
			return nil
		end
		return blk(xN, yN)
	end
	local function same(a, b)
		if not a or not b then
			return false
		end
		local fa, ax0, ay0, ax1, ay1, ar0, ar1 = motionAt(a)
		local fb, bx0, by0, bx1, by1, br0, br1 = motionAt(b)
		if fa ~= fb then
			return false
		end
		if band(fa, 1) ~= 0 and (ax0 ~= bx0 or ay0 ~= by0 or ar0 ~= br0) then
			return false
		end
		if band(fa, 2) ~= 0 and (ax1 ~= bx1 or ay1 ~= by1 or ar1 ~= br1) then
			return false
		end
		return true
	end
	local function add(b)
		n += 1
		MF[n], MX0[n], MY0[n], MX1[n], MY1[n], MR0[n], MR1[n] = motionAt(b)
	end
	local part = cuPartMode
	local a1 = nb(xPb - 1, yPb + h - 1)
	if a1 and partIdx == 1 and (part == 2 or part == 6 or part == 7) then
		a1 = nil
	end
	if a1 then
		add(a1)
	end
	local b1 = nb(xPb + w - 1, yPb - 1)
	if b1 and partIdx == 1 and (part == 1 or part == 4 or part == 5) then
		b1 = nil
	end
	if b1 and not same(a1, b1) then
		add(b1)
	end
	if n > mergeIdx then
		return n
	end
	local b0 = nb(xPb + w, yPb - 1)
	if b0 and not same(b1, b0) then
		add(b0)
	end
	local a0 = nb(xPb - 1, yPb + h)
	if a0 and not same(a1, a0) then
		add(a0)
	end
	if n < 4 then
		local b2 = nb(xPb - 1, yPb - 1)
		if b2 and not same(a1, b2) and not same(b1, b2) then
			add(b2)
		end
	end
	if n > mergeIdx then
		return n
	end
	-- temporal
	if SH.temporalMvp and n < SH.maxMergeCand then
		local ok0, x0, y0 = temporalMv(xPb, yPb, w, h, 0, 0)
		local ok1, x1, y1 = false, 0, 0
		if SH.type == 0 then
			ok1, x1, y1 = temporalMv(xPb, yPb, w, h, 1, 0)
		end
		if ok0 or ok1 then
			n += 1
			MF[n] = (ok0 and 1 or 0) + (ok1 and 2 or 0)
			MX0[n], MY0[n], MX1[n], MY1[n] = x0, y0, x1, y1
			MR0[n], MR1[n] = ok0 and 0 or -1, ok1 and 0 or -1
		end
	end
	-- combined bi-predictive
	if SH.type == 0 and n > 1 and n < SH.maxMergeCand then
		local numOrig = n
		local combIdx = 0
		while true do
			local l0, l1 = COMB_L0[combIdx + 1] + 1, COMB_L1[combIdx + 1] + 1
			if band(MF[l0], 1) ~= 0 and band(MF[l1], 2) ~= 0 then
				local samePic = SH.refList[0][MR0[l0]] == SH.refList[1][MR1[l1]]
				if not samePic or MX0[l0] ~= MX1[l1] or MY0[l0] ~= MY1[l1] then
					n += 1
					MF[n] = 3
					MX0[n], MY0[n], MR0[n] = MX0[l0], MY0[l0], MR0[l0]
					MX1[n], MY1[n], MR1[n] = MX1[l1], MY1[l1], MR1[l1]
				end
			end
			combIdx += 1
			if combIdx == numOrig * (numOrig - 1) or n == SH.maxMergeCand then
				break
			end
		end
	end
	-- zero candidates
	local numRef = SH.type == 1 and SH.numRefIdx[0] or min(SH.numRefIdx[0], SH.numRefIdx[1])
	local zeroIdx = 0
	while n < SH.maxMergeCand do
		n += 1
		local r = zeroIdx < numRef and zeroIdx or 0
		MF[n] = SH.type == 1 and 1 or 3
		MX0[n], MY0[n], MX1[n], MY1[n] = 0, 0, 0, 0
		MR0[n] = r
		MR1[n] = SH.type == 1 and -1 or r
		zeroIdx += 1
	end
	return n
end

-- AMVP predictor for list X, reference refIdx
local function deriveAmvp(xCb, yCb, nCbS, xPb, yPb, w, h, partIdx, X, refIdx, mvpFlag)
	local Y = 1 - X
	local targetPic = SH.refList[X][refIdx]
	local targetLt = SH.refIsLt[X][refIdx]
	local targetPoc = SH.refPoc[X][refIdx]
	local function candidate(b, allowScale)
		local f, mx0, my0, mx1, my1, r0, r1 = motionAt(b)
		local mvs = { [0] = { mx0, my0, r0 }, { mx1, my1, r1 } }
		if not allowScale then
			for _, L in ipairs({ X, Y }) do
				if band(f, lshift(1, L)) ~= 0 and SH.refList[L][mvs[L][3]] == targetPic then
					return true, mvs[L][1], mvs[L][2]
				end
			end
			return false
		end
		for _, L in ipairs({ X, Y }) do
			if band(f, lshift(1, L)) ~= 0 then
				local r = mvs[L][3]
				local lt = SH.refIsLt[L][r]
				if lt == targetLt then
					local mx, my = mvs[L][1], mvs[L][2]
					if not lt and not targetLt then
						local td = SH.poc - SH.refPoc[L][r]
						local tb = SH.poc - targetPoc
						if td ~= tb and td ~= 0 then
							mx, my = scaleMv(mx, td, tb), scaleMv(my, td, tb)
						end
					end
					return true, mx, my
				end
			end
		end
		return false
	end
	-- A
	local aBlocks = {}
	for _, p in ipairs({ { xPb - 1, yPb + h }, { xPb - 1, yPb + h - 1 } }) do
		if availPb(xCb, yCb, nCbS, xPb, yPb, w, h, partIdx, p[1], p[2]) then
			table.insert(aBlocks, blk(p[1], p[2]))
		end
	end
	local isScaled = #aBlocks > 0
	local availA, ax, ay = false, 0, 0
	for _, b in ipairs(aBlocks) do
		local ok, mx, my = candidate(b, false)
		if ok then
			availA, ax, ay = true, mx, my
			break
		end
	end
	if not availA then
		for _, b in ipairs(aBlocks) do
			local ok, mx, my = candidate(b, true)
			if ok then
				availA, ax, ay = true, mx, my
				break
			end
		end
	end
	-- B
	local bBlocks = {}
	for _, p in ipairs({ { xPb + w, yPb - 1 }, { xPb + w - 1, yPb - 1 }, { xPb - 1, yPb - 1 } }) do
		if availPb(xCb, yCb, nCbS, xPb, yPb, w, h, partIdx, p[1], p[2]) then
			table.insert(bBlocks, blk(p[1], p[2]))
		end
	end
	local availB, bx, by = false, 0, 0
	for _, b in ipairs(bBlocks) do
		local ok, mx, my = candidate(b, false)
		if ok then
			availB, bx, by = true, mx, my
			break
		end
	end
	if not isScaled and availB then
		availA, ax, ay = true, bx, by
	end
	if not isScaled then
		availB = false
		for _, b in ipairs(bBlocks) do
			local ok, mx, my = candidate(b, true)
			if ok then
				availB, bx, by = true, mx, my
				break
			end
		end
	end
	-- the list
	local lx, ly = {}, {}
	if availA then
		table.insert(lx, ax)
		table.insert(ly, ay)
	end
	if availB and not (availA and ax == bx and ay == by) then
		table.insert(lx, bx)
		table.insert(ly, by)
	end
	if #lx < 2 then
		local ok, tx, ty = temporalMv(xPb, yPb, w, h, X, refIdx)
		if ok then
			table.insert(lx, tx)
			table.insert(ly, ty)
		end
	end
	while #lx < 2 do
		table.insert(lx, 0)
		table.insert(ly, 0)
	end
	return lx[mvpFlag + 1], ly[mvpFlag + 1]
end

------------------------------------------------------------------------------------------------------------------------
-- motion compensation

local PRED0 = table.create(64 * 64, 0)
local PRED1 = table.create(64 * 64, 0)
local SRCB = table.create(80 * 80, 0)
local TMPF = table.create(80 * 80, 0)

-- luma prediction samples (14-bit intermediate) of a w x h block at (x0, y0) with quarter-sample vector (mvx, mvy)
local function mcLuma(ref, x0, y0, w, h, mvx, mvy, out)
	local plane = ref.Y
	local fx, fy = band(mvx, 3), band(mvy, 3)
	local xi, yi = x0 + mvx // 4, y0 + mvy // 4
	local pw, ph = S.width, S.height
	local sw, sh = w + 7, h + 7
	-- the source block with 3 samples before and 4 after (edges repeated)
	local sx0, sy0 = xi - 3, yi - 3
	if sx0 >= 0 and sy0 >= 0 and sx0 + sw <= pw and sy0 + sh <= ph then
		for y = 0, sh - 1 do
			local o = 2 * ((sy0 + y) * YS + sx0)
			local r = y * sw + 1
			for x = 0, sw - 1 do
				SRCB[r + x] = readu16(plane, o + 2 * x)
			end
		end
	else
		for y = 0, sh - 1 do
			local o = 2 * clamp(sy0 + y, 0, ph - 1) * YS
			local r = y * sw + 1
			for x = 0, sw - 1 do
				SRCB[r + x] = readu16(plane, o + 2 * clamp(sx0 + x, 0, pw - 1))
			end
		end
	end
	local shift3 = 14 - BD
	local shift1 = BD - 8
	local d1 = lshift(1, shift1)
	if fx == 0 and fy == 0 then
		local m = lshift(1, shift3)
		for y = 0, h - 1 do
			local r = (y + 3) * sw + 4
			local o = y * w + 1
			for x = 0, w - 1 do
				out[o + x] = SRCB[r + x] * m
			end
		end
	elseif fy == 0 then
		local c = QPEL[fx]
		local c0, c1, c2, c3, c4, c5, c6, c7 = c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8]
		for y = 0, h - 1 do
			local r = (y + 3) * sw + 1
			local o = y * w + 1
			for x = 0, w - 1 do
				local s = r + x
				out[o + x] = (c0 * SRCB[s] + c1 * SRCB[s + 1] + c2 * SRCB[s + 2] + c3 * SRCB[s + 3] + c4 * SRCB[s + 4]
					+ c5 * SRCB[s + 5] + c6 * SRCB[s + 6] + c7 * SRCB[s + 7]) // d1
			end
		end
	elseif fx == 0 then
		local c = QPEL[fy]
		local c0, c1, c2, c3, c4, c5, c6, c7 = c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8]
		for y = 0, h - 1 do
			local r = y * sw + 4
			local o = y * w + 1
			for x = 0, w - 1 do
				local s = r + x
				out[o + x] = (c0 * SRCB[s] + c1 * SRCB[s + sw] + c2 * SRCB[s + 2 * sw] + c3 * SRCB[s + 3 * sw]
					+ c4 * SRCB[s + 4 * sw] + c5 * SRCB[s + 5 * sw] + c6 * SRCB[s + 6 * sw] + c7 * SRCB[s + 7 * sw]) // d1
			end
		end
	else
		local c = QPEL[fx]
		local c0, c1, c2, c3, c4, c5, c6, c7 = c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8]
		-- horizontal pass over all sh rows
		for y = 0, sh - 1 do
			local r = y * sw + 1
			local o = y * w + 1
			for x = 0, w - 1 do
				local s = r + x
				TMPF[o + x] = (c0 * SRCB[s] + c1 * SRCB[s + 1] + c2 * SRCB[s + 2] + c3 * SRCB[s + 3] + c4 * SRCB[s + 4]
					+ c5 * SRCB[s + 5] + c6 * SRCB[s + 6] + c7 * SRCB[s + 7]) // d1
			end
		end
		c = QPEL[fy]
		c0, c1, c2, c3, c4, c5, c6, c7 = c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8]
		for y = 0, h - 1 do
			local o = y * w + 1
			for x = 0, w - 1 do
				local s = o + x
				out[o + x] = (c0 * TMPF[s] + c1 * TMPF[s + w] + c2 * TMPF[s + 2 * w] + c3 * TMPF[s + 3 * w] + c4 * TMPF[s + 4 * w]
					+ c5 * TMPF[s + 5 * w] + c6 * TMPF[s + 6 * w] + c7 * TMPF[s + 7 * w]) // 64
			end
		end
	end
end

-- chroma prediction samples of a w x h chroma block at (x0, y0) (chroma samples), eighth-sample vector
local function mcChroma(plane, x0, y0, w, h, mvx, mvy, out)
	local fx, fy = band(mvx, 7), band(mvy, 7)
	local xi, yi = x0 + mvx // 8, y0 + mvy // 8
	local pw, ph = rshift(S.width, 1), rshift(S.height, 1)
	local sw, sh = w + 3, h + 3
	local sx0, sy0 = xi - 1, yi - 1
	if sx0 >= 0 and sy0 >= 0 and sx0 + sw <= pw and sy0 + sh <= ph then
		for y = 0, sh - 1 do
			local o = 2 * ((sy0 + y) * CS + sx0)
			local r = y * sw + 1
			for x = 0, sw - 1 do
				SRCB[r + x] = readu16(plane, o + 2 * x)
			end
		end
	else
		for y = 0, sh - 1 do
			local o = 2 * clamp(sy0 + y, 0, ph - 1) * CS
			local r = y * sw + 1
			for x = 0, sw - 1 do
				SRCB[r + x] = readu16(plane, o + 2 * clamp(sx0 + x, 0, pw - 1))
			end
		end
	end
	local shift3 = 14 - BD
	local d1 = lshift(1, BD - 8)
	if fx == 0 and fy == 0 then
		local m = lshift(1, shift3)
		for y = 0, h - 1 do
			local r = (y + 1) * sw + 2
			local o = y * w + 1
			for x = 0, w - 1 do
				out[o + x] = SRCB[r + x] * m
			end
		end
	elseif fy == 0 then
		local c = EPEL[fx]
		local c0, c1, c2, c3 = c[1], c[2], c[3], c[4]
		for y = 0, h - 1 do
			local r = (y + 1) * sw + 1
			local o = y * w + 1
			for x = 0, w - 1 do
				local s = r + x
				out[o + x] = (c0 * SRCB[s] + c1 * SRCB[s + 1] + c2 * SRCB[s + 2] + c3 * SRCB[s + 3]) // d1
			end
		end
	elseif fx == 0 then
		local c = EPEL[fy]
		local c0, c1, c2, c3 = c[1], c[2], c[3], c[4]
		for y = 0, h - 1 do
			local r = y * sw + 2
			local o = y * w + 1
			for x = 0, w - 1 do
				local s = r + x
				out[o + x] = (c0 * SRCB[s] + c1 * SRCB[s + sw] + c2 * SRCB[s + 2 * sw] + c3 * SRCB[s + 3 * sw]) // d1
			end
		end
	else
		local c = EPEL[fx]
		local c0, c1, c2, c3 = c[1], c[2], c[3], c[4]
		for y = 0, sh - 1 do
			local r = y * sw + 1
			local o = y * w + 1
			for x = 0, w - 1 do
				local s = r + x
				TMPF[o + x] = (c0 * SRCB[s] + c1 * SRCB[s + 1] + c2 * SRCB[s + 2] + c3 * SRCB[s + 3]) // d1
			end
		end
		c = EPEL[fy]
		c0, c1, c2, c3 = c[1], c[2], c[3], c[4]
		for y = 0, h - 1 do
			local o = y * w + 1
			for x = 0, w - 1 do
				local s = o + x
				out[o + x] = (c0 * TMPF[s] + c1 * TMPF[s + w] + c2 * TMPF[s + 2 * w] + c3 * TMPF[s + 3 * w]) // 64
			end
		end
	end
end

-- write predicted samples: uni (p1 nil) or bi, default or explicit weights
local function writePred(plane: buffer, stride, x0, y0, w, h, p0, p1, wt0, wt1, comp)
	local maxv = MAXV
	if not wt0 then
		if not p1 then
			local sh = 14 - BD
			local add = lshift(1, sh - 1)
			local d = lshift(1, sh)
			for y = 0, h - 1 do
				local o = 2 * ((y0 + y) * stride + x0)
				local r = y * w + 1
				for x = 0, w - 1 do
					local v = (p0[r + x] + add) // d
					writeu16(plane, o + 2 * x, v < 0 and 0 or (v > maxv and maxv or v))
				end
			end
		else
			local sh = 15 - BD
			local add = lshift(1, sh - 1)
			local d = lshift(1, sh)
			for y = 0, h - 1 do
				local o = 2 * ((y0 + y) * stride + x0)
				local r = y * w + 1
				for x = 0, w - 1 do
					local v = (p0[r + x] + p1[r + x] + add) // d
					writeu16(plane, o + 2 * x, v < 0 and 0 or (v > maxv and maxv or v))
				end
			end
		end
		return
	end
	-- explicit weighted prediction (comp: 0 luma, 1 Cb, 2 Cr)
	local denom = comp == 0 and SH.lumaDenom or SH.chromaDenom
	local log2Wd = denom + 14 - BD
	local wi, oi = 1 + 2 * comp, 2 + 2 * comp
	if not p1 then
		local w0, o0 = wt0[wi], wt0[oi]
		local rnd = log2Wd >= 1 and lshift(1, log2Wd - 1) or 0
		local d = lshift(1, log2Wd)
		for y = 0, h - 1 do
			local o = 2 * ((y0 + y) * stride + x0)
			local r = y * w + 1
			for x = 0, w - 1 do
				local v
				if log2Wd >= 1 then
					v = (p0[r + x] * w0 + rnd) // d + o0
				else
					v = p0[r + x] * w0 + o0
				end
				writeu16(plane, o + 2 * x, v < 0 and 0 or (v > maxv and maxv or v))
			end
		end
	else
		local w0, o0 = wt0[wi], wt0[oi]
		local w1, o1 = wt1[wi], wt1[oi]
		local add = (o0 + o1 + 1) * lshift(1, log2Wd)
		local d = lshift(1, log2Wd + 1)
		for y = 0, h - 1 do
			local o = 2 * ((y0 + y) * stride + x0)
			local r = y * w + 1
			for x = 0, w - 1 do
				local v = (p0[r + x] * w0 + p1[r + x] * w1 + add) // d
				writeu16(plane, o + 2 * x, v < 0 and 0 or (v > maxv and maxv or v))
			end
		end
	end
end

local function motionCompensate(x0, y0, w, h, flags, mx0, my0, mx1, my1, r0, r1)
	local use0, use1 = band(flags, 1) ~= 0, band(flags, 2) ~= 0
	local ref0 = use0 and SH.refList[0][r0] or nil
	local ref1 = use1 and SH.refList[1][r1] or nil
	if (use0 and not ref0) or (use1 and not ref1) then
		fail("damaged data (a prediction refers to a missing reference picture)")
	end
	local wts = SH.weights
	if not wts and not (use0 and use1) then
		-- whole-sample vectors inside the picture: plain copies
		local ref, mx, my = ref0 or ref1, use0 and mx0 or mx1, use0 and my0 or my1
		if band(mx, 3) == 0 and band(my, 3) == 0 then
			local sx, sy = x0 + mx // 4, y0 + my // 4
			if sx >= 0 and sy >= 0 and sx + w <= S.width and sy + h <= S.height then
				local src = ref.Y
				for y = 0, h - 1 do
					buffer.copy(PY, 2 * ((y0 + y) * YS + x0), src, 2 * ((sy + y) * YS + sx), 2 * w)
				end
				if band(mx, 7) == 0 and band(my, 7) == 0 then
					local xc, yc, wc, hc = rshift(x0, 1), rshift(y0, 1), rshift(w, 1), rshift(h, 1)
					local sxc, syc = xc + mx // 8, yc + my // 8
					local srcU, srcV = ref.U, ref.V
					for y = 0, hc - 1 do
						local d, o = 2 * ((yc + y) * CS + xc), 2 * ((syc + y) * CS + sxc)
						buffer.copy(PU, d, srcU, o, 2 * wc)
						buffer.copy(PV, d, srcV, o, 2 * wc)
					end
					return
				end
				-- (chroma below)
				local xc, yc, wc, hc = rshift(x0, 1), rshift(y0, 1), rshift(w, 1), rshift(h, 1)
				mcChroma(ref.U, xc, yc, wc, hc, mx, my, PRED0)
				writePred(PU, CS, xc, yc, wc, hc, PRED0, nil, nil, nil, 1)
				mcChroma(ref.V, xc, yc, wc, hc, mx, my, PRED0)
				writePred(PV, CS, xc, yc, wc, hc, PRED0, nil, nil, nil, 2)
				return
			end
		end
	end
	local wt0 = wts and use0 and wts[0][r0] or nil
	local wt1 = wts and use1 and wts[1][r1] or nil
	if wts and not use0 then
		wt0 = wt1
	end
	-- luma
	if use0 and use1 then
		mcLuma(ref0, x0, y0, w, h, mx0, my0, PRED0)
		mcLuma(ref1, x0, y0, w, h, mx1, my1, PRED1)
		writePred(PY, YS, x0, y0, w, h, PRED0, PRED1, wts and wt0, wts and wt1, 0)
	else
		local ref, mx, my = ref0 or ref1, use0 and mx0 or mx1, use0 and my0 or my1
		mcLuma(ref, x0, y0, w, h, mx, my, PRED0)
		writePred(PY, YS, x0, y0, w, h, PRED0, nil, wts and wt0, nil, 0)
	end
	-- chroma
	local xc, yc, wc, hc = rshift(x0, 1), rshift(y0, 1), rshift(w, 1), rshift(h, 1)
	for c = 1, 2 do
		local dst = c == 1 and PU or PV
		if use0 and use1 then
			mcChroma(c == 1 and ref0.U or ref0.V, xc, yc, wc, hc, mx0, my0, PRED0)
			mcChroma(c == 1 and ref1.U or ref1.V, xc, yc, wc, hc, mx1, my1, PRED1)
			writePred(dst, CS, xc, yc, wc, hc, PRED0, PRED1, wts and wt0, wts and wt1, c)
		else
			local ref, mx, my = ref0 or ref1, use0 and mx0 or mx1, use0 and my0 or my1
			mcChroma(c == 1 and ref.U or ref.V, xc, yc, wc, hc, mx, my, PRED0)
			writePred(dst, CS, xc, yc, wc, hc, PRED0, nil, wts and wt0, nil, c)
		end
	end
end

-- keep a prediction block's motion (4 x 4 grid, and the 16 x 16 grid later pictures use for temporal prediction)
local function storeMotion(x0, y0, w, h, f, mx0, my0, mx1, my1, r0, r1)
	local bx0, by0 = rshift(x0, 2), rshift(y0, 2)
	local col = PIC.col
	for by = by0, by0 + rshift(h, 2) - 1 do
		for bx = bx0, bx0 + rshift(w, 2) - 1 do
			local b = by * PW + bx
			writeu8(G_MVF, b, f)
			buffer.writei16(G_MV, b * 8, mx0)
			buffer.writei16(G_MV, b * 8 + 2, my0)
			buffer.writei16(G_MV, b * 8 + 4, mx1)
			buffer.writei16(G_MV, b * 8 + 6, my1)
			buffer.writei8(G_REF, b * 2, r0)
			buffer.writei8(G_REF, b * 2 + 1, r1)
			if band(bx, 3) == 0 and band(by, 3) == 0 then
				local cb = rshift(by, 2) * col.w + rshift(bx, 2)
				local cf = f
				if band(f, 1) ~= 0 then
					buffer.writei16(col.mv, cb * 8, mx0)
					buffer.writei16(col.mv, cb * 8 + 2, my0)
					buffer.writei32(col.poc, cb * 8, SH.refPoc[0][r0])
					if SH.refIsLt[0][r0] then
						cf += 4
					end
				end
				if band(f, 2) ~= 0 then
					buffer.writei16(col.mv, cb * 8 + 4, mx1)
					buffer.writei16(col.mv, cb * 8 + 6, my1)
					buffer.writei32(col.poc, cb * 8 + 4, SH.refPoc[1][r1])
					if SH.refIsLt[1][r1] then
						cf += 8
					end
				end
				writeu8(col.flags, cb, cf)
			end
		end
	end
end

local function decodeMvd()
	local gx = decodeBin(31)
	local gy = decodeBin(31)
	if gx == 1 then
		gx += decodeBin(33 + 1)
	end
	if gy == 1 then
		gy += decodeBin(33 + 1)
	end
	local function value(g)
		if g == 0 then
			return 0
		end
		local v = 1
		if g == 2 then
			v = 2
			local k = 1
			while k < 31 and decodeBypass() == 1 do
				v += lshift(1, k)
				k += 1
			end
			v += decodeBypassBits(k)
		end
		return decodeBypass() == 1 and -v or v
	end
	local dx = value(gx)
	local dy = value(gy)
	return dx, dy
end

local function wrapMv(v)
	v = (v + 65536) % 65536
	return v >= 32768 and v - 65536 or v
end

predictionUnit = function(xCb, yCb, nCbS, xPb, yPb, w, h, partIdx, isSkip)
	local merge = isSkip
	if not isSkip then
		merge = decodeBin(20) == 1
	end
	LAST_MERGE = merge
	local f, mx0, my0, mx1, my1, r0, r1
	if merge then
		local idx = 0
		if SH.maxMergeCand > 1 then
			if decodeBin(21) == 1 then
				idx = 1
				while idx < SH.maxMergeCand - 1 and decodeBypass() == 1 do
					idx += 1
				end
			end
		end
		deriveMerge(xCb, yCb, nCbS, xPb, yPb, w, h, partIdx, idx)
		local k = idx + 1
		f, mx0, my0, mx1, my1, r0, r1 = MF[k], MX0[k], MY0[k], MX1[k], MY1[k], MR0[k], MR1[k]
		if f == 3 and w + h == 12 then
			f, r1 = 1, -1
		end
	else
		local idc = 0 -- 0 L0, 1 L1, 2 BI
		if SH.type == 0 then
			if w + h == 12 then
				idc = decodeBin(22 + 4)
			elseif decodeBin(22 + cuDepth) == 1 then
				idc = 2
			else
				idc = decodeBin(22 + 4)
			end
		end
		local function refIdx(num)
			local i = 0
			local maxI = num - 1
			local maxCtx = min(maxI, 2)
			while i < maxCtx and decodeBin(27 + i) == 1 do
				i += 1
			end
			if i == 2 then
				while i < maxI and decodeBypass() == 1 do
					i += 1
				end
			end
			return i
		end
		f, mx0, my0, mx1, my1, r0, r1 = 0, 0, 0, 0, 0, -1, -1
		local dx0, dy0, dx1, dy1, flag0, flag1 = 0, 0, 0, 0, 0, 0
		if idc ~= 1 then
			r0 = SH.numRefIdx[0] > 1 and refIdx(SH.numRefIdx[0]) or 0
			dx0, dy0 = decodeMvd()
			flag0 = decodeBin(35)
		end
		if idc ~= 0 then
			r1 = SH.numRefIdx[1] > 1 and refIdx(SH.numRefIdx[1]) or 0
			if SH.mvdL1Zero and idc == 2 then
				dx1, dy1 = 0, 0
			else
				dx1, dy1 = decodeMvd()
			end
			flag1 = decodeBin(35)
		end
		if idc ~= 1 then
			local px, py = deriveAmvp(xCb, yCb, nCbS, xPb, yPb, w, h, partIdx, 0, r0, flag0)
			mx0, my0 = wrapMv(px + dx0), wrapMv(py + dy0)
			f += 1
		end
		if idc ~= 0 then
			local px, py = deriveAmvp(xCb, yCb, nCbS, xPb, yPb, w, h, partIdx, 1, r1, flag1)
			mx1, my1 = wrapMv(px + dx1), wrapMv(py + dy1)
			f += 2
		end
	end
	if band(f, 1) == 0 then
		mx0, my0, r0 = 0, 0, -1
	end
	if band(f, 2) == 0 then
		mx1, my1, r1 = 0, 0, -1
	end
	storeMotion(xPb, yPb, w, h, f, mx0, my0, mx1, my1, r0, r1)
	markEdges(xPb, yPb, w, h, 4, 8)
	motionCompensate(xPb, yPb, w, h, f, mx0, my0, mx1, my1, r0, r1)
end

------------------------------------------------------------------------------------------------------------------------
-- in-loop filters: deblocking (8.7.2), then SAO (8.7.3), over the whole picture

local deblockPicture, saoPicture
do

local BSV = buffer.create(0) -- boundary strength of the left edge of each 4 x 4 block
local BSH = buffer.create(0) -- ... of the top edge

-- the reference picture of block b, list L (through the slice that holds it)
local function refPicOf(b, L, r)
	local x, y = (b % PW) * 4, (b // PW) * 4
	local lg = S.log2Ctb
	local hdr = CTB_HDR[rshift(y, lg) * S.ctbW + rshift(x, lg) + 1]
	return hdr.refList[L][r]
end

local function motionBs(bp, bq)
	local fp, px0, py0, px1, py1, pr0, pr1 = motionAt(bp)
	local fq, qx0, qy0, qx1, qy1, qr0, qr1 = motionAt(bq)
	local np = (fp == 3) and 2 or 1
	local nq = (fq == 3) and 2 or 1
	if np ~= nq then
		return 1
	end
	if np == 1 then
		local ra = band(fp, 1) ~= 0 and refPicOf(bp, 0, pr0) or refPicOf(bp, 1, pr1)
		local ax, ay = band(fp, 1) ~= 0 and px0 or px1, band(fp, 1) ~= 0 and py0 or py1
		local rb = band(fq, 1) ~= 0 and refPicOf(bq, 0, qr0) or refPicOf(bq, 1, qr1)
		local bx, by = band(fq, 1) ~= 0 and qx0 or qx1, band(fq, 1) ~= 0 and qy0 or qy1
		if ra ~= rb then
			return 1
		end
		return (abs(ax - bx) >= 4 or abs(ay - by) >= 4) and 1 or 0
	end
	local p0, p1 = refPicOf(bp, 0, pr0), refPicOf(bp, 1, pr1)
	local q0, q1 = refPicOf(bq, 0, qr0), refPicOf(bq, 1, qr1)
	local function far(ax, ay, bx, by)
		return abs(ax - bx) >= 4 or abs(ay - by) >= 4
	end
	if p0 == q0 and p0 == p1 and q0 == q1 then
		if (far(qx0, qy0, px0, py0) or far(qx1, qy1, px1, py1)) and (far(qx1, qy1, px0, py0) or far(qx0, qy0, px1, py1)) then
			return 1
		end
		return 0
	elseif q0 == p0 and q1 == p1 then
		return (far(qx0, qy0, px0, py0) or far(qx1, qy1, px1, py1)) and 1 or 0
	elseif q1 == p0 and q0 == p1 then
		return (far(qx1, qy1, px0, py0) or far(qx0, qy0, px1, py1)) and 1 or 0
	end
	return 1
end

-- boundary strength between blocks bp (p side) and bq (q side); edgeBit: transform edge bit of bq
local function boundaryStrength(bp, bq, tuBit)
	local cp, cq = readu8(G_CU, bp), readu8(G_CU, bq)
	if band(cp, 1) == 1 or band(cq, 1) == 1 then
		return 2
	end
	local eq = readu8(G_EDGE, bq)
	if band(eq, tuBit) ~= 0 and (band(eq, 16) ~= 0 or band(readu8(G_EDGE, bp), 16) ~= 0) then
		return 1
	end
	return motionBs(bp, bq)
end

-- may the edge between luma positions p and q (in different CTBs) be filtered?
local function crossOk(xp, yp, xq, yq)
	local lg = S.log2Ctb
	local cp = rshift(yp, lg) * S.ctbW + rshift(xp, lg) + 1
	local cq = rshift(yq, lg) * S.ctbW + rshift(xq, lg) + 1
	if cp == cq then
		return true
	end
	if not P.loopFilterAcrossTiles and P.tileId[cp] ~= P.tileId[cq] then
		return false
	end
	if CTB_SLICE[cp] ~= CTB_SLICE[cq] and not CTB_HDR[cq].loopFilterAcrossSlices then
		return false
	end
	return true
end

local function computeBs()
	local n = PW * PH
	BSV = ensure(BSV, n)
	BSH = ensure(BSH, n)
	buffer.fill(BSV, 0, 0, n)
	buffer.fill(BSH, 0, 0, n)
	local lg = S.log2Ctb
	for by = 0, PH - 1 do
		for bx = 0, PW - 1 do
			local b = by * PW + bx
			local e = readu8(G_EDGE, b)
			local x, y = bx * 4, by * 4
			local hdr = CTB_HDR[rshift(y, lg) * S.ctbW + rshift(x, lg) + 1]
			if hdr and not hdr.deblockDisabled then
				if band(bx, 1) == 0 and bx > 0 and band(e, 5) ~= 0 and crossOk(x - 1, y, x, y) then
					writeu8(BSV, b, boundaryStrength(b - 1, b, 1))
				end
				if band(by, 1) == 0 and by > 0 and band(e, 10) ~= 0 and crossOk(x, y - 1, x, y) then
					writeu8(BSH, b, boundaryStrength(b - PW, b, 2))
				end
			end
		end
	end
end

local function noFilterAt(x, y)
	return band(readu8(G_CU, blk(x, y)), 4) ~= 0
end

-- luma: the 4-sample edge segment at q0 = (x, y); vertical edge (dir 0) or horizontal (dir 1)
local function filterLumaSegment(x, y, vertical, bs)
	local plane = PY
	local xs, ls -- step across the edge, step along it (in bytes)
	if vertical then
		xs, ls = 2, 2 * YS
	else
		xs, ls = 2 * YS, 2
	end
	local xp, yp = vertical and x - 1 or x, vertical and y or y - 1
	local qpP = readu8(G_QP, blk(xp, yp)) - 64
	local qpQ = readu8(G_QP, blk(x, y)) - 64
	local qpL = (qpQ + qpP + 1) // 2
	local lg = S.log2Ctb
	local hdr = CTB_HDR[rshift(y, lg) * S.ctbW + rshift(x, lg) + 1]
	local sc = lshift(1, BD - 8)
	local beta = BETA_TAB[clamp(qpL + hdr.betaOffset, 0, 51)] * sc
	local tc = TC_TAB[clamp(qpL + 2 * (bs - 1) + hdr.tcOffset, 0, 53)] * sc
	if tc == 0 then
		return
	end
	local base = 2 * (y * YS + x)
	local function s(line, k) -- sample k (-4 .. 3) across the edge on line (0 .. 3)
		return readu16(plane, base + line * ls + k * xs)
	end
	local dp0 = abs(s(0, -3) - 2 * s(0, -2) + s(0, -1))
	local dp3 = abs(s(3, -3) - 2 * s(3, -2) + s(3, -1))
	local dq0 = abs(s(0, 2) - 2 * s(0, 1) + s(0, 0))
	local dq3 = abs(s(3, 2) - 2 * s(3, 1) + s(3, 0))
	local dpq0, dpq3 = dp0 + dq0, dp3 + dq3
	local dp, dq = dp0 + dp3, dq0 + dq3
	local d = dpq0 + dpq3
	if d >= beta then
		return
	end
	local function strongLine(line, dpq)
		return 2 * dpq < rshift(beta, 2) and abs(s(line, -4) - s(line, -1)) + abs(s(line, 0) - s(line, 3)) < rshift(beta, 3)
			and abs(s(line, -1) - s(line, 0)) < rshift(5 * tc + 1, 1)
	end
	local strong = strongLine(0, dpq0) and strongLine(3, dpq3)
	local dEp = dp < rshift(beta + rshift(beta, 1), 3)
	local dEq = dq < rshift(beta + rshift(beta, 1), 3)
	local noP = noFilterAt(xp, yp)
	local noQ = noFilterAt(x, y)
	local maxv = MAXV
	local tc2 = 2 * tc
	for line = 0, 3 do
		local o = base + line * ls
		local p0, p1, p2, p3 = readu16(plane, o - xs), readu16(plane, o - 2 * xs), readu16(plane, o - 3 * xs), readu16(plane, o - 4 * xs)
		local q0, q1, q2, q3 = readu16(plane, o), readu16(plane, o + xs), readu16(plane, o + 2 * xs), readu16(plane, o + 3 * xs)
		if strong then
			if not noP then
				writeu16(plane, o - xs, clamp((p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) // 8, p0 - tc2, p0 + tc2))
				writeu16(plane, o - 2 * xs, clamp((p2 + p1 + p0 + q0 + 2) // 4, p1 - tc2, p1 + tc2))
				writeu16(plane, o - 3 * xs, clamp((2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) // 8, p2 - tc2, p2 + tc2))
			end
			if not noQ then
				writeu16(plane, o, clamp((p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) // 8, q0 - tc2, q0 + tc2))
				writeu16(plane, o + xs, clamp((p0 + q0 + q1 + q2 + 2) // 4, q1 - tc2, q1 + tc2))
				writeu16(plane, o + 2 * xs, clamp((p0 + q0 + q1 + 3 * q2 + 2 * q3 + 4) // 8, q2 - tc2, q2 + tc2))
			end
		else
			local delta = (9 * (q0 - p0) - 3 * (q1 - p1) + 8) // 16
			if abs(delta) < tc * 10 then
				delta = clamp(delta, -tc, tc)
				if not noP then
					writeu16(plane, o - xs, clamp(p0 + delta, 0, maxv))
				end
				if not noQ then
					writeu16(plane, o, clamp(q0 - delta, 0, maxv))
				end
				local tch = rshift(tc, 1)
				if dEp and not noP then
					local dP = clamp((((p2 + p0 + 1) // 2) - p1 + delta) // 2, -tch, tch)
					writeu16(plane, o - 2 * xs, clamp(p1 + dP, 0, maxv))
				end
				if dEq and not noQ then
					local dQ = clamp((((q2 + q0 + 1) // 2) - q1 - delta) // 2, -tch, tch)
					writeu16(plane, o + xs, clamp(q1 + dQ, 0, maxv))
				end
			end
		end
	end
end

-- chroma: the 2-sample edge segment of plane at chroma q0 = (xc, yc); luma positions for the block data
local function filterChromaSegment(plane: buffer, cIdx, xc, yc, vertical, xL, yL)
	local xs, ls
	if vertical then
		xs, ls = 2, 2 * CS
	else
		xs, ls = 2 * CS, 2
	end
	local xp, yp = vertical and xL - 1 or xL, vertical and yL or yL - 1
	local qpP = readu8(G_QP, blk(xp, yp)) - 64
	local qpQ = readu8(G_QP, blk(xL, yL)) - 64
	local off = cIdx == 1 and P.cbQpOffset or P.crQpOffset
	local qpi = clamp(((qpQ + qpP + 1) // 2) + off, 0, 57)
	local qpc
	if qpi < 30 then
		qpc = qpi
	elseif qpi > 43 then
		qpc = qpi - 6
	else
		qpc = QPC_TAB[qpi]
	end
	local lg = S.log2Ctb
	local hdr = CTB_HDR[rshift(yL, lg) * S.ctbW + rshift(xL, lg) + 1]
	local tc = TC_TAB[clamp(qpc + 2 + hdr.tcOffset, 0, 53)] * lshift(1, BD - 8)
	if tc == 0 then
		return
	end
	local noP = noFilterAt(xp, yp)
	local noQ = noFilterAt(xL, yL)
	local maxv = MAXV
	local base = 2 * (yc * CS + xc)
	for line = 0, 1 do
		local o = base + line * ls
		local p0, p1 = readu16(plane, o - xs), readu16(plane, o - 2 * xs)
		local q0, q1 = readu16(plane, o), readu16(plane, o + xs)
		local delta = clamp(((q0 - p0) * 4 + p1 - q1 + 4) // 8, -tc, tc)
		if not noP then
			writeu16(plane, o - xs, clamp(p0 + delta, 0, maxv))
		end
		if not noQ then
			writeu16(plane, o, clamp(q0 - delta, 0, maxv))
		end
	end
end

function deblockPicture()
	computeBs()
	-- vertical edges
	for by = 0, PH - 1 do
		for bx = 2, PW - 1, 2 do
			local bs = readu8(BSV, by * PW + bx)
			if bs > 0 then
				filterLumaSegment(bx * 4, by * 4, true, bs)
			end
		end
		breathe()
	end
	for by = 0, PH - 1 do
		for bx = 4, PW - 1, 4 do
			local b = by * PW + bx
			if readu8(BSV, b) == 2 then
				filterChromaSegment(PU, 1, bx * 2, by * 2, true, bx * 4, by * 4)
				filterChromaSegment(PV, 2, bx * 2, by * 2, true, bx * 4, by * 4)
			end
		end
	end
	-- horizontal edges
	for by = 2, PH - 1, 2 do
		for bx = 0, PW - 1 do
			local bs = readu8(BSH, by * PW + bx)
			if bs > 0 then
				filterLumaSegment(bx * 4, by * 4, false, bs)
			end
		end
		breathe()
	end
	for by = 4, PH - 1, 4 do
		for bx = 0, PW - 1 do
			local b = by * PW + bx
			if readu8(BSH, b) == 2 then
				filterChromaSegment(PU, 1, bx * 2, by * 2, false, bx * 4, by * 4)
				filterChromaSegment(PV, 2, bx * 2, by * 2, false, bx * 4, by * 4)
			end
		end
	end
end

-- SAO
local SAO_SRC = { [0] = buffer.create(0), buffer.create(0), buffer.create(0) }
local EO_DX = { [0] = -1, 0, -1, 1 } -- (the first neighbour; the second is opposite)
local EO_DY = { [0] = 0, -1, -1, -1 }
local OKT = table.create(9, false)
local BANDT = table.create(32, 0)

-- may SAO of CTB (rx, ry) read samples of each neighbouring CTB? OKT[(dy + 1) * 3 + dx + 2]
local function saoNeighbours(rx, ry)
	local W, H = S.ctbW, S.ctbH
	local cur = ry * W + rx + 1
	for dy = -1, 1 do
		for dx = -1, 1 do
			local nx, ny = rx + dx, ry + dy
			local ok = false
			if nx >= 0 and ny >= 0 and nx < W and ny < H then
				local nb = ny * W + nx + 1
				if nb == cur then
					ok = true
				elseif CTB_HDR[nb] then
					ok = true
					if not P.loopFilterAcrossTiles and P.tileId[nb] ~= P.tileId[cur] then
						ok = false
					elseif CTB_SLICE[nb] ~= CTB_SLICE[cur] then
						-- (the later of the two slices decides)
						if P.rsToTs[nb] < P.rsToTs[cur] then
							ok = CTB_HDR[cur].loopFilterAcrossSlices
						else
							ok = CTB_HDR[nb].loopFilterAcrossSlices
						end
					end
				end
			end
			OKT[(dy + 1) * 3 + dx + 2] = ok
		end
	end
end

function saoPicture()
	local any = false
	for i = 1, S.ctbW * S.ctbH do
		local sao = CTB_SAO[i]
		if sao and (sao.type[0] ~= 0 or sao.type[1] ~= 0 or sao.type[2] ~= 0) then
			any = true
			break
		end
	end
	if not any then
		return
	end
	local planes = { [0] = PY, PU, PV }
	for c = 0, 2 do
		local len = buffer.len(planes[c])
		SAO_SRC[c] = ensure(SAO_SRC[c], len)
		buffer.copy(SAO_SRC[c], 0, planes[c], 0, len)
	end
	local maxv = MAXV
	local bandShift = BD - 5
	local checkNoFilter = (S.pcm and S.pcmLoopFilterDisabled) or P.transquantBypass
	for ry = 0, S.ctbH - 1 do
		breathe()
		for rx = 0, S.ctbW - 1 do
			local addr = ry * S.ctbW + rx + 1
			local sao = CTB_SAO[addr]
			local hdr = CTB_HDR[addr]
			if sao and hdr and (sao.type[0] ~= 0 or sao.type[1] ~= 0 or sao.type[2] ~= 0) then
				local needOk = true
				for c = 0, 2 do
					local t = sao.type[c]
					local enabled = (c == 0 and hdr.saoLuma) or (c > 0 and hdr.saoChroma)
					if t ~= 0 and enabled then
						local sc = c == 0 and 0 or 1
						local stride = c == 0 and YS or CS
						local pw, ph = rshift(S.width, sc), rshift(S.height, sc)
						local size = rshift(S.ctbSize, sc)
						local x0, y0 = rx * size, ry * size
						local x1, y1 = min(x0 + size, pw) - 1, min(y0 + size, ph) - 1
						local src, dst = SAO_SRC[c], planes[c]
						local off = sao.off[c]
						if t == 1 then
							for k = 1, 32 do
								BANDT[k] = 0
							end
							for k = 0, 3 do
								BANDT[band(k + sao.band[c], 31) + 1] = off[k + 1]
							end
							for y = y0, y1 do
								local o = 2 * (y * stride + x0)
								for x = x0, x1 do
									local v = readu16(src, o)
									local d = BANDT[rshift(v, bandShift) + 1]
									if d ~= 0 and not (checkNoFilter and noFilterAt(lshift(x, sc), lshift(y, sc))) then
										v += d
										writeu16(dst, o, v < 0 and 0 or (v > maxv and maxv or v))
									end
									o += 2
								end
							end
						else
							if needOk then
								saoNeighbours(rx, ry)
								needOk = false
							end
							local cls = sao.class[c]
							local dx, dy = EO_DX[cls], EO_DY[cls]
							local o1, o2, o3, o4 = off[1], off[2], off[3], off[4]
							local da = 2 * (dy * stride + dx) -- byte step to the first neighbour (the second: minus it)
							for y = y0, y1 do
								local ya, yb = y + dy, y - dy
								local rowA = ya < y0 and 0 or (ya > y1 and 6 or 3)
								local rowB = yb < y0 and 0 or (yb > y1 and 6 or 3)
								local o = 2 * (y * stride + x0)
								for x = x0, x1 do
									local xa, xb = x + dx, x - dx
									local okA = OKT[rowA + (xa < x0 and 1 or (xa > x1 and 3 or 2))]
									local okB = OKT[rowB + (xb < x0 and 1 or (xb > x1 and 3 or 2))]
									if okA and okB and not (checkNoFilter and noFilterAt(lshift(x, sc), lshift(y, sc))) then
										local v = readu16(src, o)
										local a = readu16(src, o + da)
										local b = readu16(src, o - da)
										local e = (v > a and 1 or (v < a and -1 or 0)) + (v > b and 1 or (v < b and -1 or 0))
										if e ~= 0 then
											-- edgeIdx 0, 1, (2), 3, 4: offsets 1, 2, -, 3, 4
											if e == -2 then
												v += o1
											elseif e == -1 then
												v += o2
											elseif e == 1 then
												v += o3
											else
												v += o4
											end
											writeu16(dst, o, v < 0 and 0 or (v > maxv and maxv or v))
										end
									end
									o += 2
								end
							end
						end
					end
				end
			end
		end
	end
end
end

------------------------------------------------------------------------------------------------------------------------
-- pictures, reference picture sets and lists, slice data, the decoder object

do

local CTX_WPP = table.create(NUM_CTX, 0) -- contexts after the 2nd CTB of a row (wavefronts)
local CTX_DS = table.create(NUM_CTX, 0) -- contexts at the end of a slice segment (dependent slices)
local ZS_PPS, ZS_SPS = nil, nil

-- z-scan order of every 4 x 4 block (CTBs in tile scan, then Morton order inside each)
local function setupZs()
	if ZS_PPS == P and ZS_SPS == S then
		return
	end
	ZS_PPS, ZS_SPS = P, S
	local lg = S.log2Ctb
	local per = lshift(1, lg - 2)
	local shift = 2 * (lg - 2)
	local morton = table.create(per * per, 0)
	for y = 0, per - 1 do
		for x = 0, per - 1 do
			local m = 0
			for i = 0, 4 do
				m += lshift(band(rshift(x, i), 1), 2 * i) + lshift(band(rshift(y, i), 1), 2 * i + 1)
			end
			morton[y * per + x + 1] = m
		end
	end
	for by = 0, PH - 1 do
		local cy = rshift(by, lg - 2)
		for bx = 0, PW - 1 do
			local cx = rshift(bx, lg - 2)
			local ts = P.rsToTs[cy * S.ctbW + cx + 1]
			local m = morton[band(by, per - 1) * per + band(bx, per - 1) + 1]
			buffer.writeu32(G_ZS, (by * PW + bx) * 4, lshift(ts, shift) + m)
		end
	end
end

local function newPicture(dec)
	local pic = table.remove(dec.pool)
	local w, h = S.width, S.height
	if not pic then
		local cw, ch = (w + 15) // 16, (h + 15) // 16
		pic = {
			Y = buffer.create(2 * w * h),
			U = buffer.create(2 * (w // 2) * (h // 2)),
			V = buffer.create(2 * (w // 2) * (h // 2)),
			col = { w = cw, flags = buffer.create(cw * ch), mv = buffer.create(cw * ch * 8), poc = buffer.create(cw * ch * 8) },
		}
	end
	buffer.fill(pic.col.flags, 0, 0)
	pic.poc = 0
	pic.lt = false
	return pic
end

local function releasePicture(dec, pic)
	if #dec.pool < 4 then
		table.insert(dec.pool, pic)
	end
end

-- a stand-in for a reference picture the stream lacks (mid grey, no motion)
local function missingPicture(dec, poc, lt)
	local pic = newPicture(dec)
	local mid = lshift(1, BD - 1)
	for _, plane in ipairs({ pic.Y, pic.U, pic.V }) do
		for o = 0, buffer.len(plane) - 2, 2 do
			writeu16(plane, o, mid)
		end
	end
	pic.poc = poc
	pic.lt = lt
	return pic
end

-- 8.3.2: mark the DPB by the slice's reference picture set; the current set's pictures (generated if missing)
local function applyRps(dec, sh, poc, irapNoRasl)
	local dpb = dec.dpb
	if irapNoRasl then
		for _, pic in ipairs(dpb) do
			releasePicture(dec, pic)
		end
		table.clear(dpb)
	end
	local before, after, ltCurr = {}, {}, {}
	local keep = {}
	local rps = sh.rps
	if rps then
		local maxLsb = lshift(1, S.log2MaxPocLsb)
		-- long-term first (they may hold pictures the short-term search would otherwise take)
		for _, lt in ipairs(sh.lt) do
			local p = lt.pocLsb
			if lt.msbPresent then
				p += poc - lt.msbCycle * maxLsb - (poc % maxLsb)
			end
			local found
			for _, pic in ipairs(dpb) do
				if not keep[pic] then
					local pp = lt.msbPresent and pic.poc or (pic.poc % maxLsb)
					if pp == p then
						found = pic
						break
					end
				end
			end
			if found then
				found.lt = true
				keep[found] = true
			end
			if lt.used == 1 then
				if not found then
					found = missingPicture(dec, p, true)
					keep[found] = true
					table.insert(dpb, found)
				end
				table.insert(ltCurr, found)
			end
		end
		local function short(delta, used, into)
			local p = poc + delta
			local found
			for _, pic in ipairs(dpb) do
				if not pic.lt and pic.poc == p then
					found = pic
					break
				end
			end
			if found then
				keep[found] = true
			end
			if used == 1 then
				if not found then
					found = missingPicture(dec, p, false)
					keep[found] = true
					table.insert(dpb, found)
				end
				table.insert(into, found)
			end
		end
		for i, d in ipairs(rps.neg) do
			short(d, rps.negUsed[i], before)
		end
		for i, d in ipairs(rps.pos) do
			short(d, rps.posUsed[i], after)
		end
	end
	-- everything else is no longer a reference
	for i = #dpb, 1, -1 do
		local pic = dpb[i]
		if not keep[pic] then
			table.remove(dpb, i)
			releasePicture(dec, pic)
		end
	end
	dec.rpsBefore, dec.rpsAfter, dec.rpsLt = before, after, ltCurr
end

-- 8.3.4: the reference picture lists of a slice
local function buildLists(dec, sh, poc)
	sh.poc = poc
	sh.refList = { [0] = {}, {} }
	sh.refPoc = { [0] = {}, {} }
	sh.refIsLt = { [0] = {}, {} }
	sh.colPic = nil
	sh.noBackwardPred = true
	if sh.type == 2 then
		return
	end
	local before, after, lts = dec.rpsBefore, dec.rpsAfter, dec.rpsLt
	if #before + #after + #lts == 0 then
		fail("damaged data (a predicted slice has no reference pictures)")
	end
	for X = 0, sh.type == 0 and 1 or 0 do
		local n = sh.numRefIdx[X]
		local numTemp = max(n, sh.numPicTotalCurr)
		local temp, tempLt = {}, {}
		local first, second = before, after
		if X == 1 then
			first, second = after, before
		end
		while #temp < numTemp do
			for _, pic in ipairs(first) do
				if #temp < numTemp then
					table.insert(temp, pic)
					table.insert(tempLt, false)
				end
			end
			for _, pic in ipairs(second) do
				if #temp < numTemp then
					table.insert(temp, pic)
					table.insert(tempLt, false)
				end
			end
			for _, pic in ipairs(lts) do
				if #temp < numTemp then
					table.insert(temp, pic)
					table.insert(tempLt, true)
				end
			end
		end
		local entries = sh.listEntries[X]
		for i = 0, n - 1 do
			local idx = entries and entries[i] or i
			local pic = temp[idx + 1]
			if not pic then
				fail("damaged data (bad reference list)")
			end
			sh.refList[X][i] = pic
			sh.refPoc[X][i] = pic.poc
			sh.refIsLt[X][i] = tempLt[idx + 1]
			if pic.poc > poc then
				sh.noBackwardPred = false
			end
		end
	end
	if sh.temporalMvp then
		sh.colPic = sh.refList[sh.colFromL0 and 0 or 1][sh.colRefIdx]
	end
end

-- set up the module state for a new picture
local function startPicture(dec, sh, nalType, tid)
	local sps, pps = sh.sps, sh.pps
	S, P = sps, pps
	local key = ("%d,%d,%d"):format(sps.width, sps.height, sps.bitDepth)
	if dec.dimsKey ~= key then
		dec.dimsKey = key
		table.clear(dec.dpb)
		table.clear(dec.pool)
	end
	BD = sps.bitDepth
	MAXV = lshift(1, BD) - 1
	QP_BD = 6 * (BD - 8)
	YS, CS = sps.width, sps.width // 2
	PW, PH = sps.width // 4, sps.height // 4
	local n = PW * PH
	G_IPM = ensure(G_IPM, n)
	G_CU = ensure(G_CU, n)
	G_QP = ensure(G_QP, n)
	G_EDGE = ensure(G_EDGE, n)
	G_DEPTH = ensure(G_DEPTH, n)
	G_MVF = ensure(G_MVF, n)
	G_MV = ensure(G_MV, n * 8)
	G_REF = ensure(G_REF, n * 2)
	if buffer.len(G_ZS) < n * 4 then
		G_ZS = buffer.create(n * 4)
		ZS_PPS = nil
	end
	buffer.fill(G_EDGE, 0, 0, n)
	buffer.fill(G_MVF, 0, 0, n)
	buffer.fill(G_CU, 0, 0, n)
	setupZs()
	for i = 1, sps.ctbW * sps.ctbH do
		CTB_SLICE[i] = -1
		CTB_HDR[i] = nil
		CTB_SAO[i] = nil
	end
	log2MinCuQpDelta = sps.log2Ctb - pps.diffCuQpDeltaDepth
	-- picture order count (8.3.1)
	local irap = nalType >= 16 and nalType <= 23
	local maxLsb = lshift(1, sps.log2MaxPocLsb)
	local msb
	if irap and dec.noRasl then
		msb = 0
	else
		local prevLsb = dec.prevPocTid0 % maxLsb
		local prevMsb = dec.prevPocTid0 - prevLsb
		if sh.pocLsb < prevLsb and prevLsb - sh.pocLsb >= maxLsb // 2 then
			msb = prevMsb + maxLsb
		elseif sh.pocLsb > prevLsb and sh.pocLsb - prevLsb > maxLsb // 2 then
			msb = prevMsb - maxLsb
		else
			msb = prevMsb
		end
	end
	local poc = msb + sh.pocLsb
	local subLayerNonRef = nalType <= 14 and nalType % 2 == 0
	if tid == 0 and not (nalType >= 6 and nalType <= 9) and not subLayerNonRef then
		dec.prevPocTid0 = poc
	end
	dec.poc = poc
	applyRps(dec, sh, poc, irap and dec.noRasl)
	PIC = newPicture(dec)
	PIC.poc = poc
	PY, PU, PV = PIC.Y, PIC.U, PIC.V
	dec.cur = PIC
	dec.anyDeblock = false
	-- the picture's display size
	dec.width = sps.width - sps.cropL - sps.cropR
	dec.height = sps.height - sps.cropT - sps.cropB
	dec.cropX, dec.cropY = sps.cropL, sps.cropT
	dec.fullRange, dec.bt709 = sps.fullRange, sps.bt709
	dec.sarW, dec.sarH = sps.sarW, sps.sarH
end

-- is the CTB above-right of CTB rs in the same slice and tile (wavefront synchronisation)?
local function topRightAvailable(rs, sliceAddr)
	local W = S.ctbW
	local x, y = rs % W, rs // W
	if y == 0 or x + 1 >= W then
		return false
	end
	local t = rs - W + 1
	return CTB_SLICE[t + 1] == sliceAddr and P.tileId[t + 1] == P.tileId[rs + 1]
end

-- slice segment data (7.3.8.1)
local function sliceData(dec, sh)
	SH = sh
	CUR_SADDR = sh.sliceAddrRs
	if not sh.deblockDisabled then
		dec.anyDeblock = true
	end
	local W = S.ctbW
	local total = W * S.ctbH
	local lg = S.log2Ctb
	local rs = sh.address
	local ts = P.rsToTs[rs + 1]
	local tileStart = ts == 0 or (P.tiles and P.tileId[rs + 1] ~= P.tileId[P.tsToRs[ts] + 1])
	local rowStart = P.wpp and (rs % W == 0 or (P.tiles and P.tileId[rs + 1] ~= P.tileId[rs]))
	cabacStart(BP // 8)
	if tileStart then
		cabacInitContexts(sh)
	elseif rowStart then
		if topRightAvailable(rs, sh.sliceAddrRs) then
			table.move(CTX_WPP, 1, NUM_CTX, 1, CTX)
		else
			cabacInitContexts(sh)
		end
	elseif sh.dependent then
		table.move(CTX_DS, 1, NUM_CTX, 1, CTX)
	else
		cabacInitContexts(sh)
	end
	if not sh.dependent or tileStart or rowStart then
		firstQgInUnit = true
	end
	while true do
		CTB_SLICE[rs + 1] = sh.sliceAddrRs
		CTB_HDR[rs + 1] = sh
		local rx, ry = rs % W, rs // W
		if sh.saoLuma or sh.saoChroma then
			CTB_SAO[rs + 1] = saoSyntax(rx, ry, rs, ts)
		end
		codingQuadtree(lshift(rx, lg), lshift(ry, lg), lg, 0)
		local eos = decodeTerminate()
		if P.wpp and (rx == 1 or (rs > 1 and P.tileId[rs + 1] ~= P.tileId[rs - 1])) then
			table.move(CTX, 1, NUM_CTX, 1, CTX_WPP)
		end
		ts += 1
		if eos == 1 then
			if P.dependentSlices then
				table.move(CTX, 1, NUM_CTX, 1, CTX_DS)
			end
			break
		end
		if ts >= total then
			fail("damaged data (a slice runs past the picture)")
		end
		rs = P.tsToRs[ts + 1]
		local newTile = P.tiles and P.tileId[rs + 1] ~= P.tileId[P.tsToRs[ts] + 1]
		local newRow = P.wpp and (rs % W == 0 or (P.tiles and P.tileId[rs + 1] ~= P.tileId[rs]))
		if newTile or newRow then
			if decodeTerminate() ~= 1 then
				fail("damaged data (bad substream end)")
			end
			cabacStart(cabacNextByte())
			firstQgInUnit = true
			if newTile then
				cabacInitContexts(sh)
			elseif topRightAvailable(rs, sh.sliceAddrRs) then
				table.move(CTX_WPP, 1, NUM_CTX, 1, CTX)
			else
				cabacInitContexts(sh)
			end
		end
		breathe()
	end
end

-- filters, the 8-bit planes, and the picture into the DPB
local function finishPicture(dec)
	local pic = dec.cur
	dec.cur = nil
	if dec.anyDeblock then
		deblockPicture()
	end
	if S.sao then
		saoPicture()
	end
	local w, h = S.width, S.height
	local nY, nC = w * h, (w // 2) * (h // 2)
	local oY, oU, oV = ensure(dec.outY, nY), ensure(dec.outU, nC), ensure(dec.outV, nC)
	dec.outY, dec.outU, dec.outV = oY, oU, oV
	local planes = { { PY, oY, nY }, { PU, oU, nC }, { PV, oV, nC } }
	if BD == 8 then
		for _, t in ipairs(planes) do
			local src, dst = t[1], t[2]
			for i = 0, t[3] - 1 do
				writeu8(dst, i, readu16(src, 2 * i))
			end
		end
	else
		local sh = BD - 8
		local add = lshift(1, sh - 1)
		for _, t in ipairs(planes) do
			local src, dst = t[1], t[2]
			for i = 0, t[3] - 1 do
				local v = rshift(readu16(src, 2 * i) + add, sh)
				writeu8(dst, i, v > 255 and 255 or v)
			end
		end
	end
	table.insert(dec.dpb, pic)
	if #dec.dpb > 16 then
		table.remove(dec.dpb, 1)
	end
	local cw = w // 2
	return {
		Y = oY,
		U = oU,
		V = oV,
		ys = w,
		cs = cw,
		yo = 0,
		co = 0,
		poc = pic.poc,
	}
end

local Decoder = {}
Decoder.__index = Decoder

-- one NAL unit (without start code / length) at buf[pos .. pos + size)
function Decoder:nal(buf: buffer, pos: number, size: number)
	if size < 2 then
		return
	end
	local h0, h1 = readu8(buf, pos), readu8(buf, pos + 1)
	local nalType = band(rshift(h0, 1), 63)
	local layer = band(h0, 1) * 32 + rshift(h1, 3)
	local tid = band(h1, 7) - 1
	if layer > 0 then
		return
	end
	if nalType == 33 or nalType == 34 or nalType <= 21 then
		loadNal(buf, pos, size)
		BP = 16
	end
	if nalType == 33 then
		local sps = parseSps()
		self.spsList[sps.id] = sps
		if not self.width then
			self.width = sps.width - sps.cropL - sps.cropR
			self.height = sps.height - sps.cropT - sps.cropB
			self.sarW, self.sarH = sps.sarW, sps.sarH
			self.fullRange, self.bt709 = sps.fullRange, sps.bt709
		end
	elseif nalType == 34 then
		local pps = parsePps()
		self.ppsList[pps.id] = pps
	elseif nalType == 36 or nalType == 37 then
		self.afterEos = true
	elseif nalType <= 9 or (nalType >= 16 and nalType <= 21) then
		local sh = parseSliceHeader(self, nalType)
		if sh.first then
			if self.cur then
				self.out = finishPicture(self)
			end
			local irap = nalType >= 16
			if irap then
				self.noRasl = nalType <= 20 or self.firstPic or self.afterEos
				self.firstPic = false
				self.afterEos = false
				self.started = true
			end
			if not self.started or ((nalType == 8 or nalType == 9) and self.noRasl) then
				self.skipping = true
				return
			end
			self.skipping = false
			startPicture(self, sh, nalType, tid)
		elseif self.skipping or not self.cur then
			return
		end
		if sh.dependent then
			sh.sliceAddrRs = self.lastIndependent.sliceAddrRs
		else
			sh.sliceAddrRs = sh.address
			buildLists(self, sh, self.poc)
			self.lastIndependent = sh
		end
		sliceData(self, sh)
	end
end

-- forget the pictures decoded so far (the parameter sets stay): the next IRAP picture starts the stream again
function Decoder:reset()
	self.cur = nil
	self.out = nil
	table.clear(self.dpb)
	self.firstPic = true
	self.started = false
	self.skipping = false
	self.prevPocTid0 = 0
end

function Decoder:flushPicture()
	if self.cur then
		self.out = finishPicture(self)
	end
	local out = self.out
	self.out = nil
	return out
end

-- one access unit of length-prefixed NAL units
function Decoder:decodeSample(buf: buffer, pos: number, len: number)
	local stop = pos + len
	local nl = self.nalLength
	while pos + nl <= stop do
		local size = 0
		for i = 0, nl - 1 do
			size = size * 256 + readu8(buf, pos + i)
		end
		pos += nl
		if size > stop - pos then
			fail("damaged data (a NAL unit runs past its sample)")
		end
		self:nal(buf, pos, size)
		pos += size
	end
	return self:flushPicture()
end

-- one access unit in Annex B form (start codes)
function Decoder:decodeAccessUnit(buf: buffer, pos: number, len: number)
	local stop = pos + len
	local p = pos
	local start = nil
	while p + 2 < stop do
		if readu8(buf, p + 2) > 1 then
			p += 3
		elseif readu8(buf, p) == 0 and readu8(buf, p + 1) == 0 and readu8(buf, p + 2) == 1 then
			if start then
				local e = p
				while e > start and readu8(buf, e - 1) == 0 do
					e -= 1
				end
				self:nal(buf, start, e - start)
			end
			p += 3
			start = p
		else
			p += 1
		end
	end
	if start and start < stop then
		local e = stop
		while e > start and readu8(buf, e - 1) == 0 do
			e -= 1
		end
		self:nal(buf, start, e - start)
	end
	return self:flushPicture()
end

-- hvcC: { nalLength, nals = { buffer ... } } (parameter set NAL units, each without a length), or the hvcC box's
-- payload as a buffer
function Hevc.new(hvcC)
	if typeof(hvcC) == "buffer" then
		hvcC = Hevc.parseConfig(hvcC, 0, buffer.len(hvcC))
	end
	local self = setmetatable({
		spsList = {},
		ppsList = {},
		dpb = {},
		pool = {},
		nalLength = hvcC and hvcC.nalLength or 4,
		prevPocTid0 = 0,
		firstPic = true,
		afterEos = false,
		started = false,
		skipping = false,
		noRasl = true,
		poc = 0,
		outY = buffer.create(0),
		outU = buffer.create(0),
		outV = buffer.create(0),
	}, Decoder)
	if hvcC then
		for _, nal in ipairs(hvcC.nals) do
			self:nal(nal, 0, buffer.len(nal))
		end
	end
	return self
end

-- the payload of an MP4 'hvcC' box (or MKV CodecPrivate for V_MPEGH/ISO/HEVC)
function Hevc.parseConfig(buf: buffer, pos: number, size: number)
	if size < 23 then
		fail("damaged data (short hvcC)")
	end
	local nalLength = band(readu8(buf, pos + 21), 3) + 1
	local numArrays = readu8(buf, pos + 22)
	local p = pos + 23
	local stop = pos + size
	local nals = {}
	for _ = 1, numArrays do
		if p + 3 > stop then
			break
		end
		local n = readu8(buf, p + 1) * 256 + readu8(buf, p + 2)
		p += 3
		for _ = 1, n do
			if p + 2 > stop then
				break
			end
			local len = readu8(buf, p) * 256 + readu8(buf, p + 1)
			p += 2
			if p + len > stop then
				break
			end
			local b = buffer.create(len)
			buffer.copy(b, 0, buf, p, len)
			table.insert(nals, b)
			p += len
		end
	end
	return { nalLength = nalLength, nals = nals }
end
end

return Hevc
