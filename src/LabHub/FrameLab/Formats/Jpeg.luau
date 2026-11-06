--!native
--!optimize 2
-- JPEG decoder: baseline and progressive Huffman JPEG (SOF0 / SOF1 / SOF2), 8-bit, any chroma subsampling, restart
-- markers, greyscale / YCbCr / Adobe CMYK & YCCK, EXIF orientation. (Arithmetic coding and 12-bit / lossless JPEG are
-- rare and not supported.) Chroma is upsampled with the same triangle filter as libjpeg ("fancy upsampling") for the
-- usual 2x1 and 2x2 subsampling.
--
--   local image = Jpeg.decode(bytes, options)   -- bytes: buffer or string
--   image.width, image.height, image.data (buffer, RGBA 8-bit, row-major), image.hasAlpha (false)
--   options (all optional):
--     MaxSize = 320   only this big is needed: a large picture is decoded at 1/2, 1/4 or 1/8 of its size (straight from
--                     its DCT blocks, much faster and lighter; never below MaxSize on the longest side)
--     Yield = true    pause (task.wait) every few milliseconds, so a big picture doesn't freeze the game
--   Jpeg.isJpeg(bytes)

local Jpeg = {}

local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

function Jpeg.isJpeg(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return buffer.len(b) >= 3 and buffer.readu8(b, 0) == 0xFF and buffer.readu8(b, 1) == 0xD8 and buffer.readu8(b, 2) == 0xFF
end

local ZIGZAG = {
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}

-- IDCT basis: C[x * 8 + u] = c(u) / 2 * cos((2x + 1) u pi / 16)
local IDCT = table.create(64, 0)
for x = 0, 7 do
	for u = 0, 7 do
		local cu = (u == 0) and math.sqrt(0.5) or 1
		IDCT[x * 8 + u + 1] = cu / 2 * math.cos((2 * x + 1) * u * math.pi / 16)
	end
end

-- reduced-size output (1/2, 1/4, 1/8): an N x N block from the lowest N x N frequencies, basis
-- c(u) / 2 * cos((2x + 1) u pi / 2N) (the DC term gives the block's mean, like the full size)
local IDCTN = {}
for _, N in ipairs({ 1, 2, 4 }) do
	local t = table.create(64, 0)
	for x = 0, N - 1 do
		for u = 0, N - 1 do
			local cu = (u == 0) and math.sqrt(0.5) or 1
			t[x * 8 + u + 1] = cu / 2 * math.cos((2 * x + 1) * u * math.pi / (2 * N))
		end
	end
	IDCTN[N] = t
end

-- Huffman table: 16-bit lookup, value = length * 256 + symbol (0 = no code)
local function buildHuffman(counts, symbols)
	local lut = table.create(65536, 0)
	local code, k = 0, 1
	for len = 1, 16 do
		for _ = 1, counts[len] do
			local sym = symbols[k]
			k += 1
			local fill = lshift(1, 16 - len)
			local start = lshift(code, 16 - len)
			local v = len * 256 + sym
			for i = start, start + fill - 1 do
				lut[i + 1] = v
			end
			code += 1
		end
		code *= 2
	end
	return lut
end

local function be16(b, o)
	return buffer.readu8(b, o) * 256 + buffer.readu8(b, o + 1)
end

-- EXIF orientation (1..8) from an APP1 segment, or nil
local function exifOrientation(b, o, len)
	if len < 14 or buffer.readstring(b, o, 6) ~= "Exif\0\0" then
		return nil
	end
	local t = o + 6
	local little = buffer.readstring(b, t, 2) == "II"
	local function u16(p)
		if little then
			return buffer.readu8(b, p) + buffer.readu8(b, p + 1) * 256
		end
		return be16(b, p)
	end
	local function u32(p)
		if little then
			return u16(p) + u16(p + 2) * 65536
		end
		return u16(p) * 65536 + u16(p + 2)
	end
	local ifd = t + u32(t + 4)
	if ifd + 2 > o + len then
		return nil
	end
	local n = u16(ifd)
	for i = 0, n - 1 do
		local e = ifd + 2 + i * 12
		if e + 12 > o + len then
			break
		end
		if u16(e) == 0x0112 then
			return u16(e + 8)
		end
	end
	return nil
end

local function parseDHT(b, p, segEnd, dcTables, acTables)
	while p < segEnd do
		local tc, th = rshift(buffer.readu8(b, p), 4), band(buffer.readu8(b, p), 15)
		p += 1
		local counts, total = {}, 0
		for i = 1, 16 do
			counts[i] = buffer.readu8(b, p + i - 1)
			total += counts[i]
		end
		p += 16
		local syms = table.create(total, 0)
		for i = 1, total do
			syms[i] = buffer.readu8(b, p + i - 1)
		end
		p += total
		local lut = buildHuffman(counts, syms)
		if tc == 0 then
			dcTables[th] = lut
		else
			acTables[th] = lut
		end
	end
end

-- The standard tables (ITU T.81 Annex K). Motion JPEG video frames usually leave out their Huffman tables and
-- use these.
local STD_DHT_HEX = "0000010501010101010100000000000000000102030405060708090a0b100002010303020403050504040000017d01020300041105122131410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9fa0100030101010101010101010000000000000102030405060708090a0b1100020102040403040705040400010277000102031104052131061241510761711322328108144291a1b1c109233352f0156272d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a737475767778797a82838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9fa"
local stdDC, stdAC
local function standardTables()
	if not stdDC then
		local b = buffer.create(#STD_DHT_HEX // 2)
		for i = 0, buffer.len(b) - 1 do
			buffer.writeu8(b, i, tonumber(string.sub(STD_DHT_HEX, i * 2 + 1, i * 2 + 2), 16))
		end
		stdDC, stdAC = {}, {}
		parseDHT(b, 0, buffer.len(b), stdDC, stdAC)
	end
	return stdDC, stdAC
end

function Jpeg.decode(bytes, options)
	options = options or {}
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local yield = options.Yield == true
	local lastYield = os.clock()
	local function breathe()
		if yield and os.clock() - lastYield > 0.008 then
			task.wait()
			lastYield = os.clock()
		end
	end
	-- reduced size: N x N samples per 8 x 8 block; baseline files keep only the coefficients that needs (COEF[k]:
	-- where zig-zag coefficient k goes in a block of BS, or -1)
	local N, BS, COEF = 8, 64, ZIGZAG
	if not Jpeg.isJpeg(b) then
		error("JPEG: not a JPEG file")
	end
	local len = buffer.len(b)
	local qt = {}
	local dcTables, acTables = {}, {}
	local frame = nil
	local progressive = false
	local restartInterval = 0
	local adobe = nil
	local orientation = nil
	local pos = 2

	-- bit reader state (per scan)
	local bitbuf, bitcnt = 0, 0
	local markerHit = false
	local function fill()
		while bitcnt <= 24 do
			local byte = 0
			if not markerHit and pos < len then
				byte = buffer.readu8(b, pos)
				if byte == 0xFF then
					local nxt = pos + 1 < len and buffer.readu8(b, pos + 1) or 0
					if nxt == 0 then
						pos += 2
					else
						markerHit = true -- a marker: feed zeros until the scan code resyncs
						byte = 0
					end
				else
					pos += 1
				end
			end
			bitbuf = bor(lshift(bitbuf, 8), byte)
			bitcnt += 8
		end
	end
	local function getBits(n)
		if n == 0 then
			return 0
		end
		if bitcnt < n then
			fill()
		end
		local v = band(rshift(bitbuf, bitcnt - n), lshift(1, n) - 1)
		bitcnt -= n
		bitbuf = band(bitbuf, lshift(1, bitcnt) - 1)
		return v
	end
	local function getBit()
		return getBits(1)
	end
	local function decodeHuff(lut)
		if bitcnt < 16 then
			fill()
		end
		local peek = band(rshift(bitbuf, bitcnt - 16), 0xFFFF)
		local v = lut[peek + 1]
		if v == 0 then
			error("JPEG: bad Huffman code")
		end
		local l = rshift(v, 8)
		bitcnt -= l
		bitbuf = band(bitbuf, lshift(1, bitcnt) - 1)
		return band(v, 255)
	end
	local function extend(v, s)
		if s == 0 then
			return 0
		end
		if v < lshift(1, s - 1) then
			return v - lshift(1, s) + 1
		end
		return v
	end
	local function resetBits()
		bitbuf, bitcnt, markerHit = 0, 0, false
	end

	local function decodeScan(scomps, ss, se, ah, al)
		local single = #scomps == 1
		local eobrun = 0
		local function blockBaseline(c, off)
			local coef = c.coef
			local t = decodeHuff(c.dc)
			local diff = t == 0 and 0 or extend(getBits(t), t)
			c.pred += diff
			coef[off + 1] = c.pred
			local k = 1
			while k < 64 do
				local rs = decodeHuff(c.ac)
				local s, r = band(rs, 15), rshift(rs, 4)
				if s == 0 then
					if r < 15 then
						break
					end
					k += 16
				else
					k += r
					if k > 63 then
						break
					end
					local v = extend(getBits(s), s)
					local z = COEF[k + 1]
					if z >= 0 then
						coef[off + z + 1] = v
					end
					k += 1
				end
			end
		end
		local function blockDCFirst(c, off)
			local t = decodeHuff(c.dc)
			local diff = t == 0 and 0 or extend(getBits(t), t)
			c.pred += diff
			c.coef[off + 1] = c.pred * lshift(1, al)
		end
		local function blockDCRefine(c, off)
			if getBit() == 1 then
				-- the bit is still zero in the value (it is a multiple of 2^(al + 1)), so OR = add, for either sign
				c.coef[off + 1] += lshift(1, al)
			end
		end
		local function blockACFirst(c, off)
			if eobrun > 0 then
				eobrun -= 1
				return
			end
			local coef = c.coef
			local k = ss
			while k <= se do
				local rs = decodeHuff(c.ac)
				local s, r = band(rs, 15), rshift(rs, 4)
				if s == 0 then
					if r < 15 then
						eobrun = lshift(1, r) - 1
						if r > 0 then
							eobrun += getBits(r)
						end
						break
					end
					k += 16
				else
					k += r
					coef[off + ZIGZAG[k + 1] + 1] = extend(getBits(s), s) * lshift(1, al)
					k += 1
				end
			end
		end
		local p1 = lshift(1, al)
		local m1 = -p1
		local function blockACRefine(c, off)
			local coef = c.coef
			local k = ss
			if eobrun <= 0 then
				while k <= se do
					local rs = decodeHuff(c.ac)
					local s, r = band(rs, 15), rshift(rs, 4)
					local val = 0
					if s == 0 then
						if r < 15 then
							eobrun = lshift(1, r)
							if r > 0 then
								eobrun += getBits(r)
							end
							break
						end
					else
						val = (getBit() == 1) and p1 or m1
					end
					while k <= se do
						local z = off + ZIGZAG[k + 1] + 1
						if coef[z] ~= 0 then
							if getBit() == 1 then
								if band(math.abs(coef[z]), p1) == 0 then
									coef[z] += (coef[z] >= 0) and p1 or m1
								end
							end
						else
							if r == 0 then
								if val ~= 0 then
									coef[z] = val
								end
								k += 1
								break
							end
							r -= 1
						end
						k += 1
					end
				end
			end
			if eobrun > 0 then
				while k <= se do
					local z = off + ZIGZAG[k + 1] + 1
					if coef[z] ~= 0 then
						if getBit() == 1 then
							if band(math.abs(coef[z]), p1) == 0 then
								coef[z] += (coef[z] >= 0) and p1 or m1
							end
						end
					end
					k += 1
				end
				eobrun -= 1
			end
		end
		local fn
		if not progressive then
			fn = blockBaseline
		elseif ss == 0 then
			fn = (ah == 0) and blockDCFirst or blockDCRefine
		else
			fn = (ah == 0) and blockACFirst or blockACRefine
		end

		for _, c in ipairs(scomps) do
			c.pred = 0
		end
		resetBits()
		local mcuCount
		if single then
			local c = scomps[1]
			mcuCount = c.bw * c.bh
		else
			mcuCount = frame.mcusX * frame.mcusY
		end
		local interval = restartInterval > 0 and restartInterval or mcuCount
		local m = 0
		while m < mcuCount do
			for _ = 1, interval do
				if m >= mcuCount then
					break
				end
				if single then
					local c = scomps[1]
					local row, col = m // c.bw, m % c.bw
					fn(c, (row * c.bpl + col) * BS)
				else
					local mr, mc = m // frame.mcusX, m % frame.mcusX
					for _, c in ipairs(scomps) do
						for v = 0, c.v - 1 do
							for h = 0, c.h - 1 do
								local row = mr * c.v + v
								local col = mc * c.h + h
								fn(c, (row * c.bpl + col) * BS)
							end
						end
					end
				end
				m += 1
				if m % 32 == 0 then
					breathe()
				end
			end
			if m >= mcuCount then
				break
			end
			-- restart marker: realign, reset predictions
			resetBits()
			while pos + 1 < len and not (buffer.readu8(b, pos) == 0xFF and buffer.readu8(b, pos + 1) >= 0xD0 and buffer.readu8(b, pos + 1) <= 0xD7) do
				pos += 1
			end
			pos += 2
			for _, c in ipairs(scomps) do
				c.pred = 0
			end
			eobrun = 0
		end
		-- skip to the next marker
		resetBits()
		while pos + 1 < len and not (buffer.readu8(b, pos) == 0xFF and buffer.readu8(b, pos + 1) ~= 0 and not (buffer.readu8(b, pos + 1) >= 0xD0 and buffer.readu8(b, pos + 1) <= 0xD7)) do
			pos += 1
		end
	end

	while pos + 4 <= len do
		if buffer.readu8(b, pos) ~= 0xFF then
			pos += 1
			continue
		end
		local marker = buffer.readu8(b, pos + 1)
		pos += 2
		if marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) or marker == 0xFF then
			if marker == 0xFF then
				pos -= 1 -- fill byte
			end
			continue
		end
		if marker == 0xD9 then
			break
		end
		local segLen = be16(b, pos)
		local s = pos + 2
		local segEnd = pos + segLen
		if marker == 0xDB then
			local p = s
			while p < segEnd do
				local pq, tq = rshift(buffer.readu8(b, p), 4), band(buffer.readu8(b, p), 15)
				p += 1
				local q = table.create(64, 0)
				for k = 0, 63 do
					local v
					if pq == 0 then
						v = buffer.readu8(b, p + k)
					else
						v = be16(b, p + k * 2)
					end
					q[ZIGZAG[k + 1] + 1] = v
				end
				p += pq == 0 and 64 or 128
				qt[tq] = q
			end
		elseif marker == 0xC4 then
			parseDHT(b, s, segEnd, dcTables, acTables)
		elseif marker == 0xC0 or marker == 0xC1 or marker == 0xC2 then
			progressive = marker == 0xC2
			if buffer.readu8(b, s) ~= 8 then
				error("JPEG: only 8-bit samples are supported")
			end
			local h, w = be16(b, s + 1), be16(b, s + 3)
			local nc = buffer.readu8(b, s + 5)
			local comps = {}
			local hmax, vmax = 1, 1
			for i = 0, nc - 1 do
				local o = s + 6 + i * 3
				local c = { id = buffer.readu8(b, o), h = rshift(buffer.readu8(b, o + 1), 4), v = band(buffer.readu8(b, o + 1), 15), tq = buffer.readu8(b, o + 2) }
				hmax, vmax = math.max(hmax, c.h), math.max(vmax, c.v)
				table.insert(comps, c)
			end
			frame = { width = w, height = h, comps = comps, hmax = hmax, vmax = vmax }
			local scale = 1
			if options.MaxSize then
				-- subsampled colour is already half size: keep it at least MaxSize too
				local need = options.MaxSize * ((hmax > 1 or vmax > 1) and 2 or 1)
				while scale < 8 and math.max(w, h) / (scale * 2) >= need do
					scale *= 2
				end
			end
			N = 8 // scale
			frame.scale = scale
			if N < 8 and not progressive then
				-- baseline: keep only the N x N lowest frequencies of each block (progressive scans refine what is
				-- stored, so they keep all 64)
				BS = N * N
				COEF = table.create(64, -1)
				for k = 0, 63 do
					local z = ZIGZAG[k + 1]
					local r, c = z // 8, z % 8
					COEF[k + 1] = (r < N and c < N) and (r * N + c) or -1
				end
			end
			frame.mcusX = math.ceil(w / (8 * hmax))
			frame.mcusY = math.ceil(h / (8 * vmax))
			for _, c in ipairs(comps) do
				-- blocks that hold real samples (single-component scans walk these) and the MCU-padded grid
				c.bw = math.ceil(math.ceil(w * c.h / hmax) / 8)
				c.bh = math.ceil(math.ceil(h * c.v / vmax) / 8)
				c.bpl = frame.mcusX * c.h
				c.bpc = frame.mcusY * c.v
				c.coef = table.create(c.bpl * c.bpc * BS, 0)
			end
		elseif marker == 0xC3 or (marker >= 0xC5 and marker <= 0xCF and marker ~= 0xC8 and marker ~= 0xCC) then
			error("JPEG: this file uses lossless or arithmetic coding, which isn't supported")
		elseif marker == 0xDD then
			restartInterval = be16(b, s)
		elseif marker == 0xE1 and not orientation then
			orientation = exifOrientation(b, s, segLen - 2)
		elseif marker == 0xEE then
			if segLen >= 14 and buffer.readstring(b, s, 5) == "Adobe" then
				adobe = { transform = buffer.readu8(b, s + 11) }
			end
		elseif marker == 0xDA then
			if not frame then
				error("JPEG: scan before frame header")
			end
			local ns = buffer.readu8(b, s)
			local scomps = {}
			for i = 0, ns - 1 do
				local id = buffer.readu8(b, s + 1 + i * 2)
				local tbl = buffer.readu8(b, s + 2 + i * 2)
				for _, c in ipairs(frame.comps) do
					if c.id == id then
						local td, ta = rshift(tbl, 4), band(tbl, 15)
						c.dc, c.ac = dcTables[td], acTables[ta]
						if not c.dc or not c.ac then
							local sd, sa = standardTables()
							c.dc, c.ac = c.dc or sd[td], c.ac or sa[ta]
						end
						table.insert(scomps, c)
					end
				end
			end
			local p = s + 1 + ns * 2
			local ss, se = buffer.readu8(b, p), buffer.readu8(b, p + 1)
			local ah, al = rshift(buffer.readu8(b, p + 2), 4), band(buffer.readu8(b, p + 2), 15)
			pos = segEnd
			decodeScan(scomps, ss, se, ah, al)
			continue
		end
		pos = segEnd
	end
	if not frame then
		error("JPEG: no image found")
	end

	-- dequantise + IDCT every block into a sample plane per component
	local W, H = frame.width, frame.height
	local tmp = table.create(64, 0)
	for _, c in ipairs(frame.comps) do
		local q = qt[c.tq]
		if not q then
			error("JPEG: missing quantisation table")
		end
		local pw, ph = c.bpl * N, c.bpc * N
		local plane = buffer.create(pw * ph)
		local coef = c.coef
		if N < 8 then
			-- reduced size: N x N samples per block from the lowest frequencies
			local T = IDCTN[N]
			local cs = (BS == 64) and 8 or N -- coefficient row stride as stored
			for by = 0, c.bpc - 1 do
				for bx = 0, c.bpl - 1 do
					local off = (by * c.bpl + bx) * BS
					for v = 0, N - 1 do
						local r = off + v * cs
						for x = 0, N - 1 do
							local acc = 0
							for u = 0, N - 1 do
								acc += T[x * 8 + u + 1] * coef[r + u + 1] * q[v * 8 + u + 1]
							end
							tmp[v * 8 + x + 1] = acc
						end
					end
					for x = 0, N - 1 do
						local base = (by * N) * pw + bx * N + x
						for y = 0, N - 1 do
							local acc = 0
							for v = 0, N - 1 do
								acc += T[y * 8 + v + 1] * tmp[v * 8 + x + 1]
							end
							acc = math.floor(acc + 128.5)
							buffer.writeu8(plane, base + y * pw, acc < 0 and 0 or (acc > 255 and 255 or acc))
						end
					end
				end
				breathe()
			end
		end
		for by = 0, (N == 8) and c.bpc - 1 or -1 do
			for bx = 0, c.bpl - 1 do
				local off = (by * c.bpl + bx) * 64
				-- rows: tmp[y][x] = sum_u C[x][u] * F[y][u]
				for y = 0, 7 do
					local r = off + y * 8
					local f0, f1, f2, f3 = coef[r + 1] * q[y * 8 + 1], coef[r + 2] * q[y * 8 + 2], coef[r + 3] * q[y * 8 + 3], coef[r + 4] * q[y * 8 + 4]
					local f4, f5, f6, f7 = coef[r + 5] * q[y * 8 + 5], coef[r + 6] * q[y * 8 + 6], coef[r + 7] * q[y * 8 + 7], coef[r + 8] * q[y * 8 + 8]
					for x = 0, 7 do
						local cb = x * 8
						tmp[y * 8 + x + 1] = IDCT[cb + 1] * f0 + IDCT[cb + 2] * f1 + IDCT[cb + 3] * f2 + IDCT[cb + 4] * f3
							+ IDCT[cb + 5] * f4 + IDCT[cb + 6] * f5 + IDCT[cb + 7] * f6 + IDCT[cb + 8] * f7
					end
				end
				-- columns
				for x = 0, 7 do
					local t0, t1, t2, t3 = tmp[x + 1], tmp[x + 9], tmp[x + 17], tmp[x + 25]
					local t4, t5, t6, t7 = tmp[x + 33], tmp[x + 41], tmp[x + 49], tmp[x + 57]
					local base = (by * 8) * pw + bx * 8 + x
					for y = 0, 7 do
						local cb = y * 8
						local v = IDCT[cb + 1] * t0 + IDCT[cb + 2] * t1 + IDCT[cb + 3] * t2 + IDCT[cb + 4] * t3
							+ IDCT[cb + 5] * t4 + IDCT[cb + 6] * t5 + IDCT[cb + 7] * t6 + IDCT[cb + 8] * t7
						v = math.floor(v + 128.5)
						buffer.writeu8(plane, base + y * pw, v < 0 and 0 or (v > 255 and 255 or v))
					end
				end
			end
			breathe()
		end
		c.plane, c.pw = plane, pw
		c.coef = nil
	end

	if N < 8 then
		W, H = math.ceil(W / frame.scale), math.ceil(H / frame.scale)
	end

	-- full-resolution sample of component c at (x, y): libjpeg-style triangle upsampling for 2x1 / 2x2, else nearest
	local hmax, vmax = frame.hmax, frame.vmax
	local function upsampled(c)
		local sx, sy = hmax // c.h, vmax // c.v
		if sx == 1 and sy == 1 then
			return c.plane, c.pw
		end
		local cw = math.ceil(W * c.h / hmax)
		local ch = math.ceil(H * c.v / vmax)
		local out = buffer.create(W * H)
		local src, pw = c.plane, c.pw
		local function at(x, y)
			x = x < 0 and 0 or (x >= cw and cw - 1 or x)
			y = y < 0 and 0 or (y >= ch and ch - 1 or y)
			return buffer.readu8(src, y * pw + x)
		end
		if sx == 2 and sy == 1 then
			for y = 0, H - 1 do
				for x = 0, W - 1 do
					local cx = x // 2
					local near, far = at(cx, y), at(cx + ((x % 2 == 0) and -1 or 1), y)
					local v = (x % 2 == 0) and (3 * near + far + 1) // 4 or (3 * near + far + 2) // 4
					buffer.writeu8(out, y * W + x, v)
				end
				breathe()
			end
		elseif sx == 2 and sy == 2 then
			for y = 0, H - 1 do
				local cy = y // 2
				local ny = cy + ((y % 2 == 0) and -1 or 1)
				for x = 0, W - 1 do
					local cx = x // 2
					local nx = cx + ((x % 2 == 0) and -1 or 1)
					-- vertical first (3:1), then horizontal (3:1) with libjpeg's rounding
					local a = 3 * at(cx, cy) + at(cx, ny)
					local bb = 3 * at(nx, cy) + at(nx, ny)
					local v = (x % 2 == 0) and (3 * a + bb + 8) // 16 or (3 * a + bb + 7) // 16
					buffer.writeu8(out, y * W + x, v)
				end
				breathe()
			end
		else
			for y = 0, H - 1 do
				for x = 0, W - 1 do
					buffer.writeu8(out, y * W + x, at(x // sx, y // sy))
				end
			end
		end
		return out, W
	end

	local comps = frame.comps
	local planes, strides = {}, {}
	for i, c in ipairs(comps) do
		planes[i], strides[i] = upsampled(c)
	end
	local out = buffer.create(W * H * 4)
	local n = #comps
	local transform = adobe and adobe.transform
	if transform == nil then
		transform = (n == 3) and 1 or 0 -- JFIF: 3 components are YCbCr
	end
	local function clamp(v)
		v = math.floor(v + 0.5)
		return v < 0 and 0 or (v > 255 and 255 or v)
	end
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local o = (y * W + x) * 4
			local r, g, bl
			if n == 1 then
				r = buffer.readu8(planes[1], y * strides[1] + x)
				g, bl = r, r
			else
				local c1 = buffer.readu8(planes[1], y * strides[1] + x)
				local c2 = buffer.readu8(planes[2], y * strides[2] + x)
				local c3 = buffer.readu8(planes[3], y * strides[3] + x)
				if transform ~= 0 then
					local cb, cr = c2 - 128, c3 - 128
					r = clamp(c1 + 1.402 * cr)
					g = clamp(c1 - 0.344136 * cb - 0.714136 * cr)
					bl = clamp(c1 + 1.772 * cb)
				else
					r, g, bl = c1, c2, c3
				end
				if n == 4 then
					-- Adobe CMYK / YCCK are stored inverted: RGB = inverted C,M,Y times inverted K
					local k = buffer.readu8(planes[4], y * strides[4] + x)
					r, g, bl = clamp(r * k / 255), clamp(g * k / 255), clamp(bl * k / 255)
				end
			end
			buffer.writeu8(out, o, r)
			buffer.writeu8(out, o + 1, g)
			buffer.writeu8(out, o + 2, bl)
			buffer.writeu8(out, o + 3, 255)
		end
		breathe()
	end

	-- EXIF orientation: turn the picture upright
	if orientation and orientation > 1 and orientation <= 8 then
		local swap = orientation >= 5
		local OW, OH = swap and H or W, swap and W or H
		local rot = buffer.create(OW * OH * 4)
		for y = 0, H - 1 do
			for x = 0, W - 1 do
				local nx, ny
				if orientation == 2 then
					nx, ny = W - 1 - x, y
				elseif orientation == 3 then
					nx, ny = W - 1 - x, H - 1 - y
				elseif orientation == 4 then
					nx, ny = x, H - 1 - y
				elseif orientation == 5 then
					nx, ny = y, x
				elseif orientation == 6 then
					nx, ny = H - 1 - y, x
				elseif orientation == 7 then
					nx, ny = H - 1 - y, W - 1 - x
				else
					nx, ny = y, W - 1 - x
				end
				buffer.writeu32(rot, (ny * OW + nx) * 4, buffer.readu32(out, (y * W + x) * 4))
			end
		end
		return { width = OW, height = OH, data = rot, hasAlpha = false, orientation = orientation }
	end
	return { width = W, height = H, data = out, hasAlpha = false }
end

return Jpeg
