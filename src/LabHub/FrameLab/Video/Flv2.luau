--!native
--!optimize 2
-- FrameLab video codec "FLV2": small files for long videos (about 75 KB a second: 10 minutes in about 15 MB).
-- Built like the classic video codecs, kept simple enough to decode in Luau every frame:
--   * colour as brightness (Y) at full size and two colour planes (Cb, Cr) at half size (4:2:0)
--   * 16 x 16 macroblocks: SKIP (copy from the last picture), INTER (copy from where it moved to in the last picture,
--     plus a small correction) or INTRA (drawn fresh)
--   * motion to a quarter of a pixel (bilinear), a whole-picture slide for camera pans
--   * corrections as 8 x 8 DCT blocks (libjpeg's integer inverse DCT: same result on every machine), JPEG quantisation tables
--   * an adaptive binary range coder (LZMA style) with contexts, coder streams per chunk (a chunk starts with a
--     keyframe every 4 s, so seeking only decodes from the last keyframe)
--   * two layers: every other frame is droppable (predicted from the last reference frame, never used as one, coded
--     in the chunk's second stream), so a slow device can skip half the decoding (r.SkipDroppable) and show 12 fps;
--     droppable frames are coded at 0.7 of the quality (DroppableQuality): about 6% fewer bytes for the same picture
--   * rate control: the encoder keeps to a byte budget per second (TargetKBps), averaged over RateWindow seconds
--     (default 3): a busy scene (everything moving) borrows bytes from the quiet seconds around it instead of dropping
--     to a coarse quality at once (that left whole moving areas as stale or smeared blocks). The quality stays between
--     MinQuality (20) and MaxQuality (75): above 75 a quiet scene spent bytes nobody can see, and the next busy scene
--     then started deep in debt and fell to quality 3 (flat 8 x 8 blocks, smeared text) for seconds; debt older than
--     two windows is forgiven, and the steps grow with how far off the budget is
--
-- Writing (importer):
--   local w = Flv2.writer(width, height, fps, { TargetKBps = 25, Quality = 50, KeyEvery, Search, Layers = 2, RateWindow = 3 })
--   w:add(image)           -- { width, height, data = RGBA buffer }
--   local bytes, stats = w:finish()
-- A long video can be written in parts at once (one writer each, every part a whole number of chunks: KeyEvery frames,
-- 4 s by default), then put together:
--   local w = Flv2.writer(width, height, fps, { ..., FirstFrame = k })   -- this part starts at frame k of the video
--   local part = w:finishPart()           -- { chunks, frames, stats }
--   local bytes, stats = Flv2.assemble({ part1, part2, ... }, width, height, fps, keyEvery, layers)
-- Renditions: one video at several sizes in one entry ("FLVS"), so each device plays the size it can keep up with:
--   local bytes = Flv2.packSet({ { bytes = flv2, width, height, bytesPerSecond }, ... })   (largest first)
--   Flv2.readSet(bytes) -> { { offset, size, width, height, bytesPerSecond }, ... } or nil (not a set)
--   Flv2.pick(list, lines) -> index of the largest rendition at most `lines` tall (else the smallest)
--   Video.Stream.reader opens a set at the size Video.Stream.deviceLines() picks (or options.Rendition)
-- Reading (player): the same reader as FLV1 streams
--   local r = Flv2.reader(bytes)
--   r.width, r.height, r.fps, r.frameCount, r.duration, r.pw (row stride of r.rgba is pw * 4), r.bw (8 x 8 blocks per row)
--   local info = r:advance()    -- next frame; info = { key, dx, dy, blocks = { 8 x 8 block ids that changed } }
--   r.render()                  -- brings r.rgba up to the last frame (call before reading pixels)
--   r.SkipDroppable = true      -- runtime: skip droppable frames from the next chunk on (about half the decode work)
--   r.FastColour = true         -- runtime: colour without the chroma blend (about half the work of render)
--   r:seek(frame)               -- 0-based
--   r.bytes                     -- the bytes it was opened with
--   r.frame

local Flv2 = {}
Flv2.Magic = "FLV2"
local HEADER, DIR_ENTRY = 24, 16
local TOP = 16777216
local TWO32 = 4294967296
local MODE_SKIP, MODE_INTER, MODE_INTRA = 0, 1, 2
local NB = 8

local floor, abs, min, max = math.floor, math.abs, math.min, math.max
local readu8, writeu8 = buffer.readu8, buffer.writeu8

local ZIGZAG = {
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}
local BAND = table.create(64, 7)
do
	local b = { 0, 1, 2, 3, 4, 4, 5, 5, 5, 5 }
	for i = 1, 64 do
		BAND[i] = b[i] or (i <= 21 and 6 or 7)
	end
end
local LUMA_Q = {
	16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
	18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
}
local CHROMA_Q = table.create(64, 99)
do
	local c = { 17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99 }
	for i = 1, 32 do
		CHROMA_Q[i] = c[i]
	end
end

-- quantisation tables for quality q (1..100): intra luma, inter luma, intra chroma, inter chroma (row-major, 64 each)
local qcache = {}
local function qtables(q)
	local c = qcache[q]
	if c then
		return c
	end
	local s = (q < 50) and (5000 // q) or (200 - 2 * q)
	local il, pl, ic, pc = table.create(64), table.create(64), table.create(64), table.create(64)
	for i = 1, 64 do
		il[i] = math.clamp((LUMA_Q[i] * s + 50) // 100, 1, 255)
		pl[i] = math.clamp((((LUMA_Q[i] + 16) // 2) * s + 50) // 100, 1, 255)
		ic[i] = math.clamp((CHROMA_Q[i] * s + 50) // 100, 1, 255)
		pc[i] = math.clamp((((CHROMA_Q[i] + 16) // 2) * s + 50) // 100, 1, 255)
	end
	c = { il, pl, ic, pc }
	qcache[q] = c
	return c
end
Flv2.qtables = qtables

local function newModels()
	local function P(n)
		return table.create(n, 1024)
	end
	return {
		skip = P(3), intra = P(3), mvzero = P(4), mvsign = P(2), mvmag = P(64), cbp = P(18),
		more = P(96), nz = P(96), gt1 = P(96), mag = P(2048), dczero = P(4), dcsign = P(4), dcmag = P(256),
	}
end

-- ------------------------------------------------------------------------------------------- range coder
local function newEncoder()
	local out = buffer.create(65536)
	local n = 0
	local low, range, cache, cacheSize = 0, 0xFFFFFFFF, 0, 1
	local function put(v)
		if n >= buffer.len(out) then
			local nb = buffer.create(buffer.len(out) * 2)
			buffer.copy(nb, 0, out, 0, n)
			out = nb
		end
		writeu8(out, n, v)
		n += 1
	end
	local function shiftLow()
		if low < 0xFF000000 or low >= TWO32 then
			local carry = (low >= TWO32) and 1 or 0
			local temp = cache
			repeat
				put((temp + carry) % 256)
				temp = 255
				cacheSize -= 1
			until cacheSize == 0
			cache = (low // TOP) % 256
		end
		cacheSize += 1
		low = (low % TOP) * 256
	end
	local E = {}
	function E.bit(probs, i, b)
		local p = probs[i + 1]
		local bound = (range // 2048) * p
		if b == 0 then
			range = bound
			probs[i + 1] = p + (2048 - p) // 16
		else
			low += bound
			range -= bound
			probs[i + 1] = p - p // 16
		end
		while range < TOP do
			range *= 256
			shiftLow()
		end
	end
	function E.direct(value, nbits)
		for k = nbits - 1, 0, -1 do
			range = range // 2
			if (value // 2 ^ k) % 2 == 1 then
				low += range
			end
			while range < TOP do
				range *= 256
				shiftLow()
			end
		end
	end
	function E.size()
		return n
	end
	function E.finish()
		for _ = 1, 5 do
			shiftLow()
		end
		local r = buffer.create(n)
		buffer.copy(r, 0, out, 0, n)
		return r
	end
	return E
end

local function newDecoder(b, start, size)
	local pos, stop = start + 1, start + size -- the first byte is always 0
	local code, range = 0, 0xFFFFFFFF
	local function byte()
		local v = 0
		if pos < stop then
			v = readu8(b, pos)
		end
		pos += 1
		return v
	end
	for _ = 1, 4 do
		code = code * 256 + byte()
	end
	local function bit(probs, i)
		local p = probs[i + 1]
		local bound = (range // 2048) * p
		local r
		if code < bound then
			range = bound
			probs[i + 1] = p + (2048 - p) // 16
			r = 0
		else
			code -= bound
			range -= bound
			probs[i + 1] = p - p // 16
			r = 1
		end
		while range < TOP do
			range *= 256
			code = (code % TOP) * 256 + byte()
		end
		return r
	end
	local function direct(nbits)
		local v = 0
		for _ = 1, nbits do
			range = range // 2
			if code >= range then
				code -= range
				v = v * 2 + 1
			else
				v *= 2
			end
			while range < TOP do
				range *= 256
				code = (code % TOP) * 256 + byte()
			end
		end
		return v
	end
	return bit, direct
end

-- ------------------------------------------------------------------------------------------- symbols
local function putMag(E, probs, base, v)
	v -= 2
	local g, lim = 0, 1
	while v >= lim do
		v -= lim
		g += 1
		lim = 2 ^ g
	end
	for i = 0, g - 1 do
		E.bit(probs, base + min(i, 15), 1)
	end
	E.bit(probs, base + min(g, 15), 0)
	if g > 0 then
		E.direct(v, g)
	end
end

local function getMag(bit, direct, probs, base)
	local g = 0
	while bit(probs, base + min(g, 15)) == 1 do
		g += 1
	end
	local v = (g > 0) and direct(g) or 0
	return v + 2 ^ g + 1
end

-- coefs: 64 values in zigzag order (1-based); codes positions start..63
local function putCoefs(E, m, cls, coefs, start)
	local last = -1
	for k = 63, start, -1 do
		if coefs[k + 1] ~= 0 then
			last = k
			break
		end
	end
	local prev, k = 0, start
	while true do
		local band = BAND[k + 1]
		local cx = (cls * NB + band) * 3 + prev
		if prev ~= 0 or k == start then
			if last < k then
				E.bit(m.more, cx, 0)
				return
			end
			E.bit(m.more, cx, 1)
		end
		local v = coefs[k + 1]
		if v == 0 then
			E.bit(m.nz, cx, 0)
			prev = 0
		else
			E.bit(m.nz, cx, 1)
			local a = abs(v)
			if a == 1 then
				E.bit(m.gt1, cx, 0)
				prev = 1
			else
				E.bit(m.gt1, cx, 1)
				putMag(E, m.mag, (cls * NB + band) * 64, a)
				prev = 2
			end
			E.direct(v < 0 and 1 or 0, 1)
		end
		k += 1
		if k > 63 then
			return
		end
	end
end

-- out: 64 values, row-major (1-based), zeroed by the caller; returns the zigzag position of the last nonzero (-1: none)
local function getCoefs(bit, direct, m, cls, out, start)
	local prev, k = 0, start
	local last = -1
	local more, nz, gt1, mag = m.more, m.nz, m.gt1, m.mag
	while k <= 63 do
		local band = BAND[k + 1]
		local cx = (cls * NB + band) * 3 + prev
		if prev ~= 0 or k == start then
			if bit(more, cx) == 0 then
				return last
			end
		end
		if bit(nz, cx) == 0 then
			prev = 0
		else
			local a
			if bit(gt1, cx) == 0 then
				a = 1
				prev = 1
			else
				a = getMag(bit, direct, mag, (cls * NB + band) * 64)
				prev = 2
			end
			if direct(1) == 1 then
				a = -a
			end
			out[ZIGZAG[k + 1] + 1] = a
			last = k
		end
		k += 1
	end
	return last
end

local function putDc(E, m, cls, d)
	if d == 0 then
		E.bit(m.dczero, cls, 0)
		return
	end
	E.bit(m.dczero, cls, 1)
	E.bit(m.dcsign, cls, d < 0 and 1 or 0)
	putMag(E, m.dcmag, cls * 64, abs(d) + 1)
end

local function getDc(bit, direct, m, cls)
	if bit(m.dczero, cls) == 0 then
		return 0
	end
	local s = bit(m.dcsign, cls)
	local v = getMag(bit, direct, m.dcmag, cls * 64) - 1
	return s == 1 and -v or v
end

local function putMv(E, m, comp, d)
	if d == 0 then
		E.bit(m.mvzero, comp, 0)
		return
	end
	E.bit(m.mvzero, comp, 1)
	E.bit(m.mvsign, comp, d < 0 and 1 or 0)
	putMag(E, m.mvmag, comp * 32, abs(d) + 1)
end

local function getMv(bit, direct, m, comp)
	if bit(m.mvzero, comp) == 0 then
		return 0
	end
	local s = bit(m.mvsign, comp)
	local v = getMag(bit, direct, m.mvmag, comp * 32) - 1
	return s == 1 and -v or v
end

-- ------------------------------------------------------------------------------------------- transforms
-- exact integer inverse DCT (libjpeg's "islow", jidctint.c): C (64, row-major [v][u], dequantised) -> out (64,
-- row-major [y][x]); last: zigzag position of the last nonzero coefficient when known (0: DC only)
local ws = table.create(64, 0)
local function idct(C, out, last)
	if last and last <= 0 then
		local v = (4 * C[1] + 16) // 32
		for k = 1, 64 do
			out[k] = v
		end
		return
	end
	for u = 1, 8 do
		local i0, i1, i2, i3, i4, i5, i6, i7 = C[u], C[8 + u], C[16 + u], C[24 + u], C[32 + u], C[40 + u], C[48 + u], C[56 + u]
		if i1 == 0 and i2 == 0 and i3 == 0 and i4 == 0 and i5 == 0 and i6 == 0 and i7 == 0 then
			local d = i0 * 4
			ws[u], ws[8 + u], ws[16 + u], ws[24 + u], ws[32 + u], ws[40 + u], ws[48 + u], ws[56 + u] = d, d, d, d, d, d, d, d
		else
			local z1 = (i2 + i6) * 4433
			local t2 = z1 - i6 * 15137
			local t3 = z1 + i2 * 6270
			local t0 = (i0 + i4) * 8192
			local t1 = (i0 - i4) * 8192
			local t10, t13, t11, t12 = t0 + t3, t0 - t3, t1 + t2, t1 - t2
			local q1, q2, q3, q4 = i7 + i1, i5 + i3, i7 + i3, i5 + i1
			local z5 = (q3 + q4) * 9633
			local a0, a1, a2, a3 = i7 * 2446, i5 * 16819, i3 * 25172, i1 * 12299
			q1, q2, q3, q4 = -q1 * 7373, -q2 * 20995, -q3 * 16069 + z5, -q4 * 3196 + z5
			a0 += q1 + q3
			a1 += q2 + q4
			a2 += q2 + q3
			a3 += q1 + q4
			ws[u] = (t10 + a3 + 1024) // 2048
			ws[56 + u] = (t10 - a3 + 1024) // 2048
			ws[8 + u] = (t11 + a2 + 1024) // 2048
			ws[48 + u] = (t11 - a2 + 1024) // 2048
			ws[16 + u] = (t12 + a1 + 1024) // 2048
			ws[40 + u] = (t12 - a1 + 1024) // 2048
			ws[24 + u] = (t13 + a0 + 1024) // 2048
			ws[32 + u] = (t13 - a0 + 1024) // 2048
		end
	end
	for o = 0, 56, 8 do
		local i0, i1, i2, i3, i4, i5, i6, i7 = ws[o + 1], ws[o + 2], ws[o + 3], ws[o + 4], ws[o + 5], ws[o + 6], ws[o + 7], ws[o + 8]
		if i1 == 0 and i2 == 0 and i3 == 0 and i4 == 0 and i5 == 0 and i6 == 0 and i7 == 0 then
			local d = (i0 + 16) // 32
			out[o + 1], out[o + 2], out[o + 3], out[o + 4], out[o + 5], out[o + 6], out[o + 7], out[o + 8] = d, d, d, d, d, d, d, d
		else
			local z1 = (i2 + i6) * 4433
			local t2 = z1 - i6 * 15137
			local t3 = z1 + i2 * 6270
			local t0 = (i0 + i4) * 8192
			local t1 = (i0 - i4) * 8192
			local t10, t13, t11, t12 = t0 + t3, t0 - t3, t1 + t2, t1 - t2
			local q1, q2, q3, q4 = i7 + i1, i5 + i3, i7 + i3, i5 + i1
			local z5 = (q3 + q4) * 9633
			local a0, a1, a2, a3 = i7 * 2446, i5 * 16819, i3 * 25172, i1 * 12299
			q1, q2, q3, q4 = -q1 * 7373, -q2 * 20995, -q3 * 16069 + z5, -q4 * 3196 + z5
			a0 += q1 + q3
			a1 += q2 + q4
			a2 += q2 + q3
			a3 += q1 + q4
			out[o + 1] = (t10 + a3 + 131072) // 262144
			out[o + 8] = (t10 - a3 + 131072) // 262144
			out[o + 2] = (t11 + a2 + 131072) // 262144
			out[o + 7] = (t11 - a2 + 131072) // 262144
			out[o + 3] = (t12 + a1 + 131072) // 262144
			out[o + 6] = (t12 - a1 + 131072) // 262144
			out[o + 4] = (t13 + a0 + 131072) // 262144
			out[o + 5] = (t13 - a0 + 131072) // 262144
		end
	end
end
Flv2.idct = idct

-- float forward DCT (encoder): f (64 row-major [y][x]) -> F (64 row-major [v][u]), the JPEG DCT.
-- Worked out with the AAN factorisation (as libjpeg's jfdctflt.c: 5 multiplies a row) and scaled once at the end.
local AANS = table.create(64, 0)
do
	local s = table.create(8, 1)
	for k = 1, 7 do
		s[k + 1] = math.cos(k * math.pi / 16) * math.sqrt(2)
	end
	for v = 0, 7 do
		for u = 0, 7 do
			AANS[v * 8 + u + 1] = 1 / (8 * s[v + 1] * s[u + 1])
		end
	end
end
local tF = table.create(64, 0)
local function fdct(f, F)
	for o = 0, 56, 8 do
		local d0, d1, d2, d3, d4, d5, d6, d7 = f[o + 1], f[o + 2], f[o + 3], f[o + 4], f[o + 5], f[o + 6], f[o + 7], f[o + 8]
		local t0, t7, t1, t6, t2, t5, t3, t4 = d0 + d7, d0 - d7, d1 + d6, d1 - d6, d2 + d5, d2 - d5, d3 + d4, d3 - d4
		local t10, t13, t11, t12 = t0 + t3, t0 - t3, t1 + t2, t1 - t2
		tF[o + 1], tF[o + 5] = t10 + t11, t10 - t11
		local z1 = (t12 + t13) * 0.70710678118654752
		tF[o + 3], tF[o + 7] = t13 + z1, t13 - z1
		t10, t11, t12 = t4 + t5, t5 + t6, t6 + t7
		local z5 = (t10 - t12) * 0.38268343236508977
		local z2 = 0.54119610014619698 * t10 + z5
		local z4 = 1.30656296487637652 * t12 + z5
		local z3 = t11 * 0.70710678118654752
		local z11, z13 = t7 + z3, t7 - z3
		tF[o + 6], tF[o + 4], tF[o + 2], tF[o + 8] = z13 + z2, z13 - z2, z11 + z4, z11 - z4
	end
	for u = 1, 8 do
		local d0, d1, d2, d3, d4, d5, d6, d7 = tF[u], tF[8 + u], tF[16 + u], tF[24 + u], tF[32 + u], tF[40 + u], tF[48 + u], tF[56 + u]
		local t0, t7, t1, t6, t2, t5, t3, t4 = d0 + d7, d0 - d7, d1 + d6, d1 - d6, d2 + d5, d2 - d5, d3 + d4, d3 - d4
		local t10, t13, t11, t12 = t0 + t3, t0 - t3, t1 + t2, t1 - t2
		F[u], F[32 + u] = (t10 + t11) * AANS[u], (t10 - t11) * AANS[32 + u]
		local z1 = (t12 + t13) * 0.70710678118654752
		F[16 + u], F[48 + u] = (t13 + z1) * AANS[16 + u], (t13 - z1) * AANS[48 + u]
		t10, t11, t12 = t4 + t5, t5 + t6, t6 + t7
		local z5 = (t10 - t12) * 0.38268343236508977
		local z2 = 0.54119610014619698 * t10 + z5
		local z4 = 1.30656296487637652 * t12 + z5
		local z3 = t11 * 0.70710678118654752
		local z11, z13 = t7 + z3, t7 - z3
		F[40 + u], F[24 + u], F[8 + u], F[56 + u] = (z13 + z2) * AANS[40 + u], (z13 - z2) * AANS[24 + u], (z11 + z4) * AANS[8 + u],
			(z11 - z4) * AANS[56 + u]
	end
end
Flv2.fdct = fdct

-- ------------------------------------------------------------------------------------------- prediction
-- n x n block of plane (w x h bytes) at quarter-pixel position (x4 / 4, y4 / 4) into out (row-major, 1-based),
-- bilinear: ((4 - fx)(4 - fy) A + fx (4 - fy) B + (4 - fx) fy C + fx fy D + 8) // 16; edges are clamped
local function fetchQ(plane, w, h, x4, y4, n, out)
	local x, fx = x4 // 4, x4 % 4
	local y, fy = y4 // 4, y4 % 4
	if x >= 0 and y >= 0 and x + n < w and y + n < h then
		if fx == 0 and fy == 0 then
			for r = 0, n - 1 do
				local o = (y + r) * w + x - 1
				local d = r * n
				for c = 1, n do
					out[d + c] = readu8(plane, o + c)
				end
			end
		elseif fy == 0 then
			local wa = 4 - fx
			for r = 0, n - 1 do
				local o = (y + r) * w + x - 1
				local d = r * n
				local a = readu8(plane, o + 1)
				for c = 1, n do
					local b = readu8(plane, o + c + 1)
					out[d + c] = (wa * a + fx * b + 2) // 4
					a = b
				end
			end
		elseif fx == 0 then
			local wa = 4 - fy
			for r = 0, n - 1 do
				local o = (y + r) * w + x - 1
				local d = r * n
				for c = 1, n do
					out[d + c] = (wa * readu8(plane, o + c) + fy * readu8(plane, o + w + c) + 2) // 4
				end
			end
		else
			local wa, wb, wc, wd = (4 - fx) * (4 - fy), fx * (4 - fy), (4 - fx) * fy, fx * fy
			for r = 0, n - 1 do
				local o = (y + r) * w + x - 1
				local d = r * n
				local a, cc = readu8(plane, o + 1), readu8(plane, o + w + 1)
				for c = 1, n do
					local b, dd = readu8(plane, o + c + 1), readu8(plane, o + w + c + 1)
					out[d + c] = (wa * a + wb * b + wc * cc + wd * dd + 8) // 16
					a, cc = b, dd
				end
			end
		end
		return
	end
	-- near the edges: clamped reads
	local wa, wb, wc, wd = (4 - fx) * (4 - fy), fx * (4 - fy), (4 - fx) * fy, fx * fy
	for r = 0, n - 1 do
		local o0 = math.clamp(y + r, 0, h - 1) * w
		local o1 = math.clamp(y + r + 1, 0, h - 1) * w
		local d = r * n
		for c = 0, n - 1 do
			local x0, x1 = math.clamp(x + c, 0, w - 1), math.clamp(x + c + 1, 0, w - 1)
			out[d + c + 1] = (wa * readu8(plane, o0 + x0) + wb * readu8(plane, o0 + x1) + wc * readu8(plane, o1 + x0) + wd * readu8(plane, o1 + x1) + 8) // 16
		end
	end
end
Flv2.fetchQ = fetchQ

local function chromaMv(v)
	if v >= 0 then
		return (v + 1) // 2
	end
	return -((-v + 1) // 2)
end

local function median3(a, b, c)
	if a > b then
		a, b = b, a
	end
	if b > c then
		b = c
	end
	if a > b then
		return a
	end
	return b
end

-- ------------------------------------------------------------------------------------------- colour
-- picture rectangle [x0, x1) x [y0, y1) of the planes -> RGBA (stride PW * 4), widened to even edges. Chroma is
-- upsampled with a triangle filter ((9 a + 3 b + 3 c + d + 8) // 16), worked out once per 2 x 2 pixels.
local RCR, BCB, GCB, GCR, CL = {}, {}, {}, {}, {}
for c = 0, 255 do
	RCR[c + 1] = (359 * (c - 128) + 128) // 256
	BCB[c + 1] = (454 * (c - 128) + 128) // 256
	GCB[c + 1] = 88 * (c - 128)
	GCR[c + 1] = 183 * (c - 128) + 128
end
for v = -400, 700 do
	CL[v + 401] = math.clamp(v, 0, 255)
end
local writeu32 = buffer.writeu32
local A255 = 0xFF000000
local function toRGBA(Y, Cb, Cr, PW, PH, rgba, x0, y0, x1, y1)
	local CW, CH = PW // 2, PH // 2
	local i0, i1 = x0 // 2, (x1 + 1) // 2 - 1
	local j0, j1 = y0 // 2, (y1 + 1) // 2 - 1
	for j = j0, j1 do
		local rj = j * CW
		local ru = max(j - 1, 0) * CW
		local rd = min(j + 1, CH - 1) * CW
		for i = i0, i1 do
			local il, ir = max(i - 1, 0), min(i + 1, CW - 1)
			local a9 = 9 * readu8(Cb, rj + i) + 8
			local u3, d3 = 3 * readu8(Cb, ru + i), 3 * readu8(Cb, rd + i)
			local l3, r3 = 3 * readu8(Cb, rj + il), 3 * readu8(Cb, rj + ir)
			local cb00 = (a9 + u3 + l3 + readu8(Cb, ru + il)) // 16 + 1
			local cb01 = (a9 + u3 + r3 + readu8(Cb, ru + ir)) // 16 + 1
			local cb10 = (a9 + d3 + l3 + readu8(Cb, rd + il)) // 16 + 1
			local cb11 = (a9 + d3 + r3 + readu8(Cb, rd + ir)) // 16 + 1
			a9 = 9 * readu8(Cr, rj + i) + 8
			u3, d3 = 3 * readu8(Cr, ru + i), 3 * readu8(Cr, rd + i)
			l3, r3 = 3 * readu8(Cr, rj + il), 3 * readu8(Cr, rj + ir)
			local cr00 = (a9 + u3 + l3 + readu8(Cr, ru + il)) // 16 + 1
			local cr01 = (a9 + u3 + r3 + readu8(Cr, ru + ir)) // 16 + 1
			local cr10 = (a9 + d3 + l3 + readu8(Cr, rd + il)) // 16 + 1
			local cr11 = (a9 + d3 + r3 + readu8(Cr, rd + ir)) // 16 + 1
			local yo = 2 * j * PW + 2 * i
			local o = yo * 4
			local l = readu8(Y, yo) + 401
			writeu32(rgba, o, CL[l + RCR[cr00]] + 256 * CL[l - (GCB[cb00] + GCR[cr00]) // 256] + 65536 * CL[l + BCB[cb00]] + A255)
			l = readu8(Y, yo + 1) + 401
			writeu32(rgba, o + 4, CL[l + RCR[cr01]] + 256 * CL[l - (GCB[cb01] + GCR[cr01]) // 256] + 65536 * CL[l + BCB[cb01]] + A255)
			yo += PW
			o = yo * 4
			l = readu8(Y, yo) + 401
			writeu32(rgba, o, CL[l + RCR[cr10]] + 256 * CL[l - (GCB[cb10] + GCR[cr10]) // 256] + 65536 * CL[l + BCB[cb10]] + A255)
			l = readu8(Y, yo + 1) + 401
			writeu32(rgba, o + 4, CL[l + RCR[cr11]] + 256 * CL[l - (GCB[cb11] + GCR[cr11]) // 256] + 65536 * CL[l + BCB[cb11]] + A255)
		end
	end
end
Flv2.toRGBA = toRGBA

-- the same with each 2 x 2 pixels sharing their chroma sample (no blend): about half the work, for slow devices
-- (the strips drawn from the picture don't show the difference)
local function toRGBAFast(Y, Cb, Cr, PW, PH, rgba, x0, y0, x1, y1)
	local CW = PW // 2
	local i0, i1 = x0 // 2, (x1 + 1) // 2 - 1
	for j = y0 // 2, (y1 + 1) // 2 - 1 do
		local rj = j * CW
		for i = i0, i1 do
			local cb, cr = readu8(Cb, rj + i) + 1, readu8(Cr, rj + i) + 1
			local ro, go, bo = RCR[cr], (GCB[cb] + GCR[cr]) // 256, BCB[cb]
			local yo = 2 * j * PW + 2 * i
			local o = yo * 4
			local l = readu8(Y, yo) + 401
			writeu32(rgba, o, CL[l + ro] + 256 * CL[l - go] + 65536 * CL[l + bo] + A255)
			l = readu8(Y, yo + 1) + 401
			writeu32(rgba, o + 4, CL[l + ro] + 256 * CL[l - go] + 65536 * CL[l + bo] + A255)
			yo += PW
			o = yo * 4
			l = readu8(Y, yo) + 401
			writeu32(rgba, o, CL[l + ro] + 256 * CL[l - go] + 65536 * CL[l + bo] + A255)
			l = readu8(Y, yo + 1) + 401
			writeu32(rgba, o + 4, CL[l + ro] + 256 * CL[l - go] + 65536 * CL[l + bo] + A255)
		end
	end
end

local function pad16(n)
	return (n + 15) // 16 * 16
end

local function isFlv2(b)
	return buffer.len(b) >= HEADER and buffer.readstring(b, 0, 4) == Flv2.Magic
end
function Flv2.isStream(bytes)
	return isFlv2(type(bytes) == "string" and buffer.fromstring(bytes) or bytes)
end

-- decoder prediction straight into the picture: block n x n at (px, py) of dst from src at quarter-pixel offset
-- (vx, vy); same values as fetchQ (whole pixels inside the picture are row copies)
local function moveBlock(src, dst, w, h, px, py, vx, vy, n, tmp)
	local x, fx = px + vx // 4, vx % 4
	local y, fy = py + vy // 4, vy % 4
	if x >= 0 and y >= 0 and x + n < w and y + n < h then
		if fx == 0 and fy == 0 then
			for r = 0, n - 1 do
				buffer.copy(dst, (py + r) * w + px, src, (y + r) * w + x, n)
			end
		elseif fy == 0 then
			local wa = 4 - fx
			for r = 0, n - 1 do
				local o = (y + r) * w + x
				local d = (py + r) * w + px - 1
				local a = readu8(src, o)
				for c = 1, n do
					local bb = readu8(src, o + c)
					writeu8(dst, d + c, (wa * a + fx * bb + 2) // 4)
					a = bb
				end
			end
		elseif fx == 0 then
			local wa = 4 - fy
			for r = 0, n - 1 do
				local o = (y + r) * w + x - 1
				local d = (py + r) * w + px - 1
				for c = 1, n do
					writeu8(dst, d + c, (wa * readu8(src, o + c) + fy * readu8(src, o + w + c) + 2) // 4)
				end
			end
		else
			local wa, wb, wc, wd = (4 - fx) * (4 - fy), fx * (4 - fy), (4 - fx) * fy, fx * fy
			for r = 0, n - 1 do
				local o = (y + r) * w + x
				local d = (py + r) * w + px - 1
				local a, cc = readu8(src, o), readu8(src, o + w)
				for c = 1, n do
					local bb, dd = readu8(src, o + c), readu8(src, o + w + c)
					writeu8(dst, d + c, (wa * a + wb * bb + wc * cc + wd * dd + 8) // 16)
					a, cc = bb, dd
				end
			end
		end
		return
	end
	fetchQ(src, w, h, 4 * px + vx, 4 * py + vy, n, tmp)
	for r = 0, n - 1 do
		local o = (py + r) * w + px - 1
		local d = r * n
		for c = 1, n do
			writeu8(dst, o + c, tmp[d + c])
		end
	end
end

-- adds the residual res (8 x 8) to the picture block at (px, py), clipped to 0..255
local function addRes(plane, w, px, py, res)
	for yy = 0, 7 do
		local o = (py + yy) * w + px - 1
		local rr = yy * 8
		for xx = 1, 8 do
			local v = readu8(plane, o + xx) + res[rr + xx]
			writeu8(plane, o + xx, v < 0 and 0 or (v > 255 and 255 or v))
		end
	end
end

-- ------------------------------------------------------------------------------------------- reader
-- options.Ready(chunkIndex) -> bool: for a video still arriving (streamed from the server), whether that chunk's bytes
-- are in place yet; the player waits for it (r:ready(frame)). options.ChunkData(chunkIndex) -> buffer, offset [, sizeA,
-- sizeB]: where a chunk's bytes are when they are kept apart from `bytes` (which then needs only the header and chunk
-- directory), and the sizes of its two coder streams when the directory doesn't have them (a stream made as it plays)
function Flv2.reader(bytes, options)
	options = options or {}
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not isFlv2(b) then
		error("not a FrameLab FLV2 video")
	end
	local r = {}
	r.codec = "FLV2"
	r.bytes = b -- (what the reader was opened with: the whole video, or its header and directory)
	r.fps = readu8(b, 5)
	r.width, r.height = buffer.readu16(b, 6), buffer.readu16(b, 8)
	r.frameCount = buffer.readu32(b, 10)
	r.keyEvery = buffer.readu16(b, 14)
	local nChunks = buffer.readu16(b, 16)
	local layers = math.max(1, readu8(b, 18))
	r.layers = layers
	r.SkipDroppable = false -- true: skip the droppable frames (half the frames of a 2-layer video) from the next chunk on
	local dataStart = HEADER + nChunks * DIR_ENTRY
	r.chunks = {}
	for i = 1, nChunks do
		local d = HEADER + (i - 1) * DIR_ENTRY
		r.chunks[i] = { off = dataStart + buffer.readu32(b, d), sizeA = buffer.readu32(b, d + 4), sizeB = buffer.readu32(b, d + 8),
			first = buffer.readu32(b, d + 12) }
	end
	r.duration = r.frameCount / r.fps
	local PW, PH = pad16(r.width), pad16(r.height)
	local CW, CH = PW // 2, PH // 2
	local MBW, MBH = PW // 16, PH // 16
	local BW = PW // 8
	r.pw, r.ph, r.bw, r.bh = PW, PH, BW, PH // 8
	r.rgba = buffer.create(PW * PH * 4)
	buffer.fill(r.rgba, 0, 255)
	r.frame = -1
	-- planes: the reference picture, the next one being decoded, a droppable picture
	local function planes()
		local p = { Y = buffer.create(PW * PH), Cb = buffer.create(CW * CH), Cr = buffer.create(CW * CH) }
		buffer.fill(p.Cb, 0, 128)
		buffer.fill(p.Cr, 0, 128)
		return p
	end
	local ref, work, drop = planes(), planes(), planes()
	local chunkIndex, chunkFirst = 0, 0
	local bitA, directA, mA, bitB, directB, mB
	local bOn = false
	local nMB = MBW * MBH
	local modes = table.create(nMB, 0)
	local mvx, mvy = table.create(nMB, 0), table.create(nMB, 0)
	local hasMv = table.create(nMB, false)
	local dirtyMB = table.create(nMB, false)
	local predY, predCb, predCr = table.create(256, 0), table.create(64, 0), table.create(64, 0)
	local coef, res = table.create(64, 0), table.create(64, 0)
	local deq = table.create(64, 0)

	local function openChunk(i)
		local c = r.chunks[i]
		local src, base = b, c.off
		local sizeA, sizeB = c.sizeA, c.sizeB
		if options.ChunkData then
			local sA, sB
			src, base, sA, sB = options.ChunkData(i)
			if not src then
				error(("FLV2: chunk %d isn't loaded"):format(i), 0)
			end
			if sA then
				sizeA, sizeB = sA, sB
			end
		end
		bitA, directA = newDecoder(src, base, sizeA)
		bitB, directB = newDecoder(src, base + sizeA, sizeB)
		mA, mB = newModels(), newModels()
		chunkIndex, chunkFirst = i, c.first
		bOn = not r.SkipDroppable
	end

	-- one frame from a coder stream: predicted from src, written to dst; onHeader(key, gx, gy) runs before any plane
	-- changes; returns the macroblocks it coded (1-based ids)
	local coded = {}
	local function decodeFrame(bit, direct, m, src, dst, onHeader)
		local key = direct(1)
		local q = direct(7)
		local gx, gy = direct(7) - 64, direct(7) - 64
		onHeader(key, gx, gy)
		local tabs = qtables(q)
		local Y, Cb, Cr = dst.Y, dst.Cb, dst.Cr
		-- start from the reference picture: a still macroblock then costs nothing
		buffer.copy(Y, 0, src.Y)
		buffer.copy(Cb, 0, src.Cb)
		buffer.copy(Cr, 0, src.Cr)
		local GX, GY = 4 * gx, 4 * gy
		for i = 1, nMB do
			hasMv[i] = false
			dirtyMB[i] = false
		end
		for mby = 0, MBH - 1 do
			local dc0, dc1, dc2 = 0, 0, 0
			for mbx = 0, MBW - 1 do
				local idx = mby * MBW + mbx + 1
				local x, y = mbx * 16, mby * 16
				local mode = MODE_INTRA
				local vx, vy = GX, GY
				if key == 0 then
					local lm = (mbx > 0) and modes[idx - 1] or MODE_INTER
					local tm = (mby > 0) and modes[idx - MBW] or MODE_INTER
					if bit(m.skip, (lm == MODE_SKIP and 1 or 0) + (tm == MODE_SKIP and 1 or 0)) == 1 then
						mode = MODE_SKIP
					elseif bit(m.intra, (lm == MODE_INTRA and 1 or 0) + (tm == MODE_INTRA and 1 or 0)) == 1 then
						mode = MODE_INTRA
					else
						mode = MODE_INTER
						local lx, ly, tx, ty, rx, ry = GX, GY, GX, GY, GX, GY
						if mbx > 0 and hasMv[idx - 1] then
							lx, ly = mvx[idx - 1], mvy[idx - 1]
						end
						if mby > 0 and hasMv[idx - MBW] then
							tx, ty = mvx[idx - MBW], mvy[idx - MBW]
						end
						if mby > 0 and mbx + 1 < MBW and hasMv[idx - MBW + 1] then
							rx, ry = mvx[idx - MBW + 1], mvy[idx - MBW + 1]
						end
						vx = median3(lx, tx, rx) + getMv(bit, direct, m, 0)
						vy = median3(ly, ty, ry) + getMv(bit, direct, m, 1)
					end
				end
				modes[idx] = mode
				if mode ~= MODE_INTRA then
					hasMv[idx] = true
					mvx[idx], mvy[idx] = vx, vy
					local cvx, cvy = chromaMv(vx), chromaMv(vy)
					if vx ~= 0 or vy ~= 0 then
						moveBlock(src.Y, Y, PW, PH, x, y, vx, vy, 16, predY)
						moveBlock(src.Cb, Cb, CW, CH, x // 2, y // 2, cvx, cvy, 8, predCb)
						moveBlock(src.Cr, Cr, CW, CH, x // 2, y // 2, cvx, cvy, 8, predCr)
					end
					if mode == MODE_INTER then
						dirtyMB[idx] = true
						local c0 = bit(m.cbp, 0)
						local c1 = bit(m.cbp, 3 + c0)
						local c2 = bit(m.cbp, 6 + c0)
						local c3 = bit(m.cbp, 9 + min(c2 + c1, 2))
						local c4 = bit(m.cbp, 12)
						local c5 = bit(m.cbp, 15)
						local cbp = { c0, c1, c2, c3, c4, c5 }
						for bi = 1, 6 do
							local chroma = bi > 4
							local tab = chroma and tabs[4] or tabs[2]
							if cbp[bi] == 1 then
								for k = 1, 64 do
									coef[k] = 0
								end
								local last = getCoefs(bit, direct, m, chroma and 3 or 1, coef, 0)
								for k = 1, 64 do
									deq[k] = coef[k] * tab[k]
								end
								idct(deq, res, last)
								if bi <= 4 then
									addRes(Y, PW, x + ((bi - 1) % 2) * 8, y + ((bi - 1) // 2) * 8, res)
								elseif bi == 5 then
									addRes(Cb, CW, x // 2, y // 2, res)
								else
									addRes(Cr, CW, x // 2, y // 2, res)
								end
							end
						end
					end
					dc0, dc1, dc2 = 0, 0, 0
				else
					dirtyMB[idx] = true
					for bi = 1, 6 do
						local plane = (bi <= 4) and 0 or (bi - 4)
						local cls = plane ~= 0 and 2 or 0
						local tab = plane ~= 0 and tabs[3] or tabs[1]
						for k = 1, 64 do
							coef[k] = 0
						end
						local dc = getDc(bit, direct, m, cls)
						if plane == 0 then
							dc0 += dc
							dc = dc0
						elseif plane == 1 then
							dc1 += dc
							dc = dc1
						else
							dc2 += dc
							dc = dc2
						end
						coef[1] = dc
						local last = getCoefs(bit, direct, m, cls, coef, 1)
						for k = 1, 64 do
							deq[k] = coef[k] * tab[k]
						end
						idct(deq, res, max(last, 0))
						local plane_, w, px, py
						if plane == 0 then
							plane_, w, px, py = Y, PW, x + ((bi - 1) % 2) * 8, y + ((bi - 1) // 2) * 8
						else
							plane_, w, px, py = (plane == 1) and Cb or Cr, CW, x // 2, y // 2
						end
						for yy = 0, 7 do
							local o = (py + yy) * w + px
							local rr = yy * 8
							for xx = 1, 8 do
								local v = res[rr + xx] + 128
								writeu8(plane_, o + xx - 1, v < 0 and 0 or (v > 255 and 255 or v))
							end
						end
					end
				end
			end
		end
		table.clear(coded)
		for k = 1, nMB do
			if dirtyMB[k] then
				table.insert(coded, k)
			end
		end
		return coded
	end
	local tmp = buffer.create(PW * PH * 4)
	local function slide(dx, dy)
		local rgba = r.rgba
		buffer.copy(tmp, 0, rgba, 0)
		for y = 0, PH - 1 do
			local sy = y + dy
			if sy >= 0 and sy < PH then
				local x0, x1 = max(0, -dx), min(PW, PW - dx)
				if x1 > x0 then
					buffer.copy(rgba, (y * PW + x0) * 4, tmp, (sy * PW + x0 + dx) * 4, (x1 - x0) * 4)
				end
			end
		end
	end

	-- r.rgba is brought up to date lazily (render): marks say which 2 x 2 pixel groups need converting from the
	-- planes now shown
	local mark = buffer.create(CW * CH)
	local pending = false
	local shown = ref -- the planes r.rgba shows (once rendered)
	local function markRect(x0, y0, x1, y1) -- luma pixels, half-open; widened by one group for the chroma blend
		local i0, i1 = max(0, x0 // 2 - 1), min(CW - 1, (x1 - 1) // 2 + 1)
		local j0, j1 = max(0, y0 // 2 - 1), min(CH - 1, (y1 - 1) // 2 + 1)
		if i1 < i0 or j1 < j0 then
			return
		end
		for j = j0, j1 do
			buffer.fill(mark, j * CW + i0, 1, i1 - i0 + 1)
		end
		pending = true
	end
	function r.render()
		if not pending then
			return
		end
		local Y, Cb, Cr, rgba = shown.Y, shown.Cb, shown.Cr, r.rgba
		local convert = r.FastColour and toRGBAFast or toRGBA
		for j = 0, CH - 1 do
			local o = j * CW
			local i = 0
			while i < CW do
				if readu8(mark, o + i) == 1 then
					local i1 = i
					while i1 + 1 < CW and readu8(mark, o + i1 + 1) == 1 do
						i1 += 1
					end
					convert(Y, Cb, Cr, PW, PH, rgba, 2 * i, 2 * j, 2 * i1 + 2, 2 * j + 2)
					i = i1 + 1
				else
					i += 1
				end
			end
		end
		buffer.fill(mark, 0, 0)
		pending = false
	end
	function r.planes()
		return shown.Y, shown.Cb, shown.Cr
	end

	local lastB = nil -- { gx, gy, mbs } when r.rgba shows a droppable frame
	local function blocksOf(list, mbs)
		for _, idx in ipairs(mbs) do
			local mbx, mby = (idx - 1) % MBW, (idx - 1) // MBW
			local b0 = mby * 2 * BW + mbx * 2
			table.insert(list, b0)
			table.insert(list, b0 + BW)
		end
	end

	local function nextFrame(display)
		local nf = r.frame + 1
		if chunkIndex == 0 or (r.chunks[chunkIndex + 1] and nf >= r.chunks[chunkIndex + 1].first) then
			openChunk(chunkIndex + 1)
		end
		local isB = layers == 2 and (nf - chunkFirst) % 2 == 1
		r.frame = nf
		if isB and (not bOn or r.SkipDroppable or not display) then
			bOn = false -- the droppable stream can only restart with the next chunk
			return { key = false, dx = 0, dy = 0, blocks = {} }
		end
		local dst = isB and drop or work
		local info
		local onHeader = function(key, gx, gy)
			if not display then
				return
			end
			if key == 1 then
				info = { key = true, dx = 0, dy = 0, blocks = {} }
				return
			end
			-- slide of the shown picture: relative to the reference, minus a droppable frame's own slide shown now
			local dx, dy = gx, gy
			if not isB and lastB then
				dx, dy = gx - lastB.gx, gy - lastB.gy
			end
			info = { key = false, dx = dx, dy = dy, blocks = {} }
			if dx ~= 0 or dy ~= 0 then
				r.render() -- converts what is pending from the planes shown before the slide
				slide(dx, dy)
				if dx > 0 then
					markRect(PW - dx, 0, PW, PH)
				elseif dx < 0 then
					markRect(0, 0, -dx, PH)
				end
				if dy > 0 then
					markRect(0, PH - dy, PW, PH)
				elseif dy < 0 then
					markRect(0, 0, PW, -dy)
				end
			end
		end
		local mbs = decodeFrame(isB and bitB or bitA, isB and directB or directA, isB and mB or mA, ref, dst, onHeader)
		if not isB then
			ref, work = work, ref
		end
		if not display then
			return nil
		end
		shown = isB and drop or ref
		if info.key then
			markRect(0, 0, PW, PH)
			lastB = nil
			return info
		end
		local blocks = info.blocks
		for _, idx in ipairs(mbs) do
			local x, y = ((idx - 1) % MBW) * 16, ((idx - 1) // MBW) * 16
			markRect(x, y, x + 16, y + 16)
		end
		blocksOf(blocks, mbs)
		if not isB and lastB then
			-- what the droppable frame drew goes back to the reference picture (moved by this frame's slide)
			for _, idx in ipairs(lastB.mbs) do
				local x, y = ((idx - 1) % MBW) * 16 - info.dx, ((idx - 1) // MBW) * 16 - info.dy
				markRect(x, y, x + 16, y + 16)
				local b0 = math.clamp(y, 0, PH - 1) // 8 * BW
				table.insert(blocks, b0)
				table.insert(blocks, math.clamp(y + 8, 0, PH - 1) // 8 * BW)
				table.insert(blocks, math.clamp(y + 15, 0, PH - 1) // 8 * BW)
			end
		end
		lastB = isB and { gx = info.dx, gy = info.dy, mbs = table.clone(mbs) } or nil
		return info
	end

	function r:advance()
		if r.frame + 1 >= r.frameCount then
			return nil
		end
		return nextFrame(true)
	end

	-- the chunk holding a frame (1-based), and whether its bytes are there (always, unless the video is streaming in)
	function r:chunkOf(frame)
		local ci = 1
		for i, c in ipairs(r.chunks) do
			if c.first <= frame then
				ci = i
			else
				break
			end
		end
		return ci
	end
	function r:ready(frame)
		if not options.Ready then
			return true
		end
		return options.Ready(r:chunkOf(math.clamp(frame, 0, r.frameCount - 1)))
	end

	-- 0-based frame; decodes the reference frames from the chunk's keyframe (a droppable target shows the reference
	-- frame before it); droppable frames stay off until the next chunk
	function r:seek(frame)
		frame = math.clamp(frame, 0, r.frameCount - 1)
		local ci = 1
		for i, c in ipairs(r.chunks) do
			if c.first <= frame then
				ci = i
			end
		end
		chunkIndex = ci - 1
		r.frame = r.chunks[ci].first - 1
		while r.frame < frame do
			nextFrame(false)
		end
		bOn = (frame == r.chunks[ci].first) and not r.SkipDroppable
		shown = ref
		lastB = nil
		markRect(0, 0, PW, PH)
		return { key = true, dx = 0, dy = 0, blocks = {} }
	end

	return r
end

-- ------------------------------------------------------------------------------------------- writer
function Flv2.writer(width, height, fps, options)
	options = options or {}
	local w = {}
	local PW, PH = pad16(width), pad16(height)
	local CW, CH = PW // 2, PH // 2
	local MBW, MBH = PW // 16, PH // 16
	local nMB = MBW * MBH
	fps = math.clamp(floor(fps + 0.5), 1, 60)
	w.width, w.height, w.fps = width, height, fps
	local keyEvery = options.KeyEvery or fps * 4
	local q = options.Quality or 50
	local target = options.TargetBytesPerSecond or ((options.TargetKBps or 25) * 1024)
	if options.TargetKBps == false then
		target = nil
	end
	local search = options.Search or 16
	local rateWindow = options.RateWindow or 3
	local qMin, qMax = options.MinQuality or 20, options.MaxQuality or 75
	local layers = (options.Layers == 1) and 1 or 2
	local dropQuality = options.DroppableQuality or 0.7 -- a droppable frame's quality, as a share of the others'
	local frames = 0
	local firstFrame = options.FirstFrame or 0 -- where this part starts in the whole video (chunk directory)
	local chunks = {}
	local E, m, EA, mA, EB, mB
	local chunkFirst, chunkBytes0 = 0, 0
	local budget = 0
	local stats = { skip = 0, inter = 0, intra = 0, slides = 0, keyframes = 0, qMin = 100, qMax = 0 }
	-- planes: source (this frame), reconstruction (current, last), last source luma
	local sY, sCb, sCr = table.create(PW * PH, 0), table.create(CW * CH, 0), table.create(CW * CH, 0)
	local lastSY -- table (last frame's source luma) or nil
	local function planes()
		return { Y = buffer.create(PW * PH), Cb = buffer.create(CW * CH), Cr = buffer.create(CW * CH) }
	end
	local prev, work, drop = planes(), planes(), planes() -- reference, next reference, droppable
	local cur = prev
	local modes = table.create(nMB, 0)
	local mvx, mvy = table.create(nMB, 0), table.create(nMB, 0)
	local hasMv = table.create(nMB, false)
	local predY, predCb, predCr = table.create(256, 0), table.create(64, 0), table.create(64, 0)
	local tmpY = table.create(256, 0)
	local blk, F = table.create(64, 0), table.create(64, 0)
	local qcs = {}
	for i = 1, 6 do
		qcs[i] = table.create(64, 0)
	end
	local zz, deq, res = table.create(64, 0), table.create(64, 0), table.create(64, 0)
	local sy, scb, scr = table.create(256, 0), table.create(64, 0), table.create(64, 0)

	local full = table.create(PW * PH * 2, 0) -- full-size Cb, Cr before averaging
	local function loadSource(image)
		local data, iw, ih = image.data, image.width, image.height
		for y = 0, PH - 1 do
			local yy = min(y, ih - 1)
			for x = 0, PW - 1 do
				local o = (yy * iw + min(x, iw - 1)) * 4
				local r, g, b = readu8(data, o), readu8(data, o + 1), readu8(data, o + 2)
				local i = y * PW + x
				sY[i + 1] = (77 * r + 150 * g + 29 * b + 128) // 256
				full[i * 2 + 1] = (-43 * r - 85 * g + 128 * b + 128) // 256 + 128
				full[i * 2 + 2] = (128 * r - 107 * g - 21 * b + 128) // 256 + 128
			end
		end
		for j = 0, CH - 1 do
			for i = 0, CW - 1 do
				local a = ((2 * j) * PW + 2 * i) * 2
				local c = ((2 * j + 1) * PW + 2 * i) * 2
				local cb = (full[a + 1] + full[a + 3] + full[c + 1] + full[c + 3] + 2) // 4
				local cr = (full[a + 2] + full[a + 4] + full[c + 2] + full[c + 4] + 2) // 4
				sCb[j * CW + i + 1] = math.clamp(cb, 0, 255)
				sCr[j * CW + i + 1] = math.clamp(cr, 0, 255)
			end
		end
	end

	-- whole-picture slide (camera pan) from the source luma at half size
	local function findGlobal()
		if not lastSY then
			return 0, 0
		end
		local h, ww = PH // 2, PW // 2
		local function err(dx, dy)
			local y0, y1 = max(0, -dy), min(h, h - dy)
			local x0, x1 = max(0, -dx), min(ww, ww - dx)
			if y1 <= y0 or x1 <= x0 then
				return 1e9
			end
			-- (every 4th pixel each way: the slide is found as well, 4x less work)
			local s, n = 0, 0
			for y = y0, y1 - 1, 2 do
				local a = 2 * y * PW
				local bb = 2 * (y + dy) * PW
				for x = x0, x1 - 1, 2 do
					s += abs(sY[a + 2 * x + 1] - lastSY[bb + 2 * (x + dx) + 1])
				end
				n += (x1 - x0 + 1) // 2
			end
			return s / math.max(n, 1)
		end
		local e0 = err(0, 0)
		if e0 < 1.5 then
			return 0, 0
		end
		local R = 12
		local best, bx = e0, 0
		for dx = -R, R do
			if dx ~= 0 then
				local e = err(dx, 0)
				if e < best then
					best, bx = e, dx
				end
			end
		end
		local by = 0
		for dy = -R, R do
			if dy ~= 0 then
				local e = err(bx, dy)
				if e < best then
					best, by = e, dy
				end
			end
		end
		if (bx ~= 0 or by ~= 0) and best < 0.5 * e0 then
			return bx * 2, by * 2
		end
		return 0, 0
	end

	local function startChunk()
		if EA then
			table.insert(chunks, { first = firstFrame + chunkFirst, a = EA.finish(), b = EB.finish() })
		end
		EA, EB = newEncoder(), newEncoder()
		mA, mB = newModels(), newModels()
		chunkFirst = frames
		chunkBytes0 = 0
	end

	-- the source block (8 x 8) minus a prediction block, forward DCT into F
	local function residualDct(src, sw, sx, sy_, pred, pw, px, py)
		for yy = 0, 7 do
			local s = (sy_ + yy) * sw + sx
			local p = (py + yy) * pw + px
			local d = yy * 8
			for xx = 1, 8 do
				blk[d + xx] = src[s + xx] - pred[p + xx]
			end
		end
		fdct(blk, F)
	end

	-- whether every coefficient of an 8 x 8 residual (source block minus prediction) quantises to zero with table tab
	-- (lowest step tmin). Two shortcuts before the transform: the DC coefficient is the sum / 8 (a block whose average
	-- moved is coded), and the transform keeps the energy, so a residual with less energy than (0.7 x the smallest
	-- step)^2 has no coefficient that reaches a step
	local function blockZero(src, sw, sx, sy_, pred, pw, px, py, tab, tmin)
		local sum, e2 = 0, 0
		for yy = 0, 7 do
			local s = (sy_ + yy) * sw + sx
			local p = (py + yy) * pw + px
			for xx = 1, 8 do
				local d = src[s + xx] - pred[p + xx]
				sum += d
				e2 += d * d
			end
		end
		if abs(sum) * 0.125 / tab[1] + 0.3 >= 1 then
			return false
		end
		if e2 < 0.49 * tmin * tmin then
			return true
		end
		residualDct(src, sw, sx, sy_, pred, pw, px, py)
		for k = 1, 64 do
			if abs(F[k]) / tab[k] + 0.3 >= 1 then
				return false
			end
		end
		return true
	end

	-- every coefficient of the residual against the prediction quantises to zero
	local function quantZero(tl, tc, tlMin, tcMin)
		for bi = 0, 3 do
			local ox, oy = (bi % 2) * 8, (bi // 2) * 8
			if not blockZero(sy, 16, ox, oy, predY, 16, ox, oy, tl, tlMin) then
				return false
			end
		end
		return blockZero(scb, 8, 0, 0, predCb, 8, 0, 0, tc, tcMin) and blockZero(scr, 8, 0, 0, predCr, 8, 0, 0, tc, tcMin)
	end

	-- the macroblock being coded (luma pixels), the whole-picture slide and the search range (quarter pixels)
	local mbX, mbY, GX, GY, S2 = 0, 0, 0, 0, 0

	-- the prediction from the reference picture at quarter-pixel motion (ax, ay)
	local function predict(ax, ay)
		local cvx, cvy = chromaMv(ax), chromaMv(ay)
		fetchQ(prev.Y, PW, PH, 4 * mbX + ax, 4 * mbY + ay, 16, predY)
		fetchQ(prev.Cb, CW, CH, 2 * mbX + cvx, 2 * mbY + cvy, 8, predCb)
		fetchQ(prev.Cr, CW, CH, 2 * mbX + cvx, 2 * mbY + cvy, 8, predCr)
	end

	-- sum of absolute differences against the reference at (ax, ay) quarter pixels; stops once past `best` (that
	-- candidate loses anyway). Whole-pixel positions read the reference directly.
	local function sad(ax, ay, best)
		local x4, y4 = 4 * mbX + ax, 4 * mbY + ay
		local ix, iy = x4 // 4, y4 // 4
		local s = 0
		if x4 % 4 == 0 and y4 % 4 == 0 and ix >= 0 and iy >= 0 and ix + 16 < PW and iy + 16 < PH then
			local P = prev.Y
			for r = 0, 15 do
				local o = (iy + r) * PW + ix - 1
				local d = r * 16
				for c = 1, 16 do
					s += abs(sy[d + c] - readu8(P, o + c))
				end
				if s >= best then
					return s
				end
			end
			return s
		end
		local fx, fy = x4 % 4, y4 % 4
		if ix >= 0 and iy >= 0 and ix + 16 < PW and iy + 16 < PH then
			-- inside the picture: the bilinear prediction (as fetchQ) worked out row by row, so a losing candidate stops
			-- early
			local P = prev.Y
			if fy == 0 then
				local wa = 4 - fx
				for r = 0, 15 do
					local o = (iy + r) * PW + ix
					local d = r * 16
					local a = readu8(P, o)
					for c = 1, 16 do
						local bb = readu8(P, o + c)
						s += abs(sy[d + c] - (wa * a + fx * bb + 2) // 4)
						a = bb
					end
					if s >= best then
						return s
					end
				end
			elseif fx == 0 then
				local wa = 4 - fy
				for r = 0, 15 do
					local o = (iy + r) * PW + ix - 1
					local d = r * 16
					for c = 1, 16 do
						s += abs(sy[d + c] - (wa * readu8(P, o + c) + fy * readu8(P, o + PW + c) + 2) // 4)
					end
					if s >= best then
						return s
					end
				end
			else
				local wa, wb, wc, wd = (4 - fx) * (4 - fy), fx * (4 - fy), (4 - fx) * fy, fx * fy
				for r = 0, 15 do
					local o = (iy + r) * PW + ix
					local d = r * 16
					local a, cc = readu8(P, o), readu8(P, o + PW)
					for c = 1, 16 do
						local bb, dd = readu8(P, o + c), readu8(P, o + PW + c)
						s += abs(sy[d + c] - (wa * a + wb * bb + wc * cc + wd * dd + 8) // 16)
						a, cc = bb, dd
					end
					if s >= best then
						return s
					end
				end
			end
			return s
		end
		fetchQ(prev.Y, PW, PH, x4, y4, 16, tmpY)
		for r = 0, 15 do
			local d = r * 16
			for c = 1, 16 do
				s += abs(sy[d + c] - tmpY[d + c])
			end
			if s >= best then
				return s
			end
		end
		return s
	end

	local function inRange(ax, ay)
		return abs(ax - GX) <= S2 and abs(ay - GY) <= S2
	end
	local STEPS, SUBSTEPS = { 32, 16, 8, 4 }, { 2, 1 }

	local function writeBlock(plane, pw, px, py, pred, sw, ox, oy, withRes)
		for yy = 0, 7 do
			local o = (py + yy) * pw + px
			local s = (oy + yy) * sw + ox
			local rr = yy * 8
			for xx = 1, 8 do
				local v = pred[s + xx]
				if withRes then
					v += res[rr + xx]
					v = v < 0 and 0 or (v > 255 and 255 or v)
				end
				writeu8(plane, o + xx - 1, v)
			end
		end
	end

	function w:add(image)
		assert(image.width == width and image.height == height, "Flv2: frame size differs from the stream's")
		loadSource(image)
		local key = (frames % keyEvery) == 0
		if key then
			startChunk()
			stats.keyframes += 1
		end
		local gx, gy = 0, 0
		if not key then
			gx, gy = findGlobal()
		end
		if gx ~= 0 or gy ~= 0 then
			stats.slides += 1
		end
		local droppable = layers == 2 and (frames - chunkFirst) % 2 == 1
		if droppable then
			E, m = EB, mB
		else
			E, m = EA, mA
		end
		E.direct(key and 1 or 0, 1)
		-- (a droppable frame is coded coarser: nothing is predicted from it, so its error doesn't carry on, and its
		-- bytes go to the frames that are)
		local fq = droppable and max(1, floor(q * dropQuality + 0.5)) or q
		E.direct(fq, 7)
		E.direct(gx + 64, 7)
		E.direct(gy + 64, 7)
		local tabs = qtables(fq)
		local tl, tc = tabs[2], tabs[4]
		local tlMin, tcMin = math.min(table.unpack(tl)), math.min(table.unpack(tc))
		cur = droppable and drop or work
		local Y, Cb, Cr = cur.Y, cur.Cb, cur.Cr
		GX, GY = 4 * gx, 4 * gy
		for i = 1, nMB do
			hasMv[i] = false
		end
		S2 = search * 4
		for mby = 0, MBH - 1 do
			local dc0, dc1, dc2 = 0, 0, 0
			for mbx = 0, MBW - 1 do
				local idx = mby * MBW + mbx + 1
				local x, y = mbx * 16, mby * 16
				mbX, mbY = x, y
				for r = 0, 15 do
					local s = (y + r) * PW + x
					for c = 1, 16 do
						sy[r * 16 + c] = sY[s + c]
					end
				end
				for r = 0, 7 do
					local s = (y // 2 + r) * CW + x // 2
					for c = 1, 8 do
						scb[r * 8 + c] = sCb[s + c]
						scr[r * 8 + c] = sCr[s + c]
					end
				end
				local mode = MODE_INTRA
				local vx, vy = GX, GY
				if not key then
					local lx, ly, tx, ty, rx, ry = GX, GY, GX, GY, GX, GY
					if mbx > 0 and hasMv[idx - 1] then
						lx, ly = mvx[idx - 1], mvy[idx - 1]
					end
					if mby > 0 and hasMv[idx - MBW] then
						tx, ty = mvx[idx - MBW], mvy[idx - MBW]
					end
					if mby > 0 and mbx + 1 < MBW and hasMv[idx - MBW + 1] then
						rx, ry = mvx[idx - MBW + 1], mvy[idx - MBW + 1]
					end
					local pdx, pdy = median3(lx, tx, rx), median3(ly, ty, ry)
					predict(GX, GY)
					if quantZero(tl, tc, tlMin, tcMin) then
						mode = MODE_SKIP
					else
						-- start from the best of: the slide, no motion, the predicted motion and the neighbours' (whole
						-- pixels), then a diamond search in whole pixels, then half and quarter pixels around the best
						local bvx, bvy, bs = GX, GY, sad(GX, GY, math.huge)
						for ci = 1, 4 do
							local cx, cy
							if ci == 1 then
								cx, cy = 0, 0
							elseif ci == 2 then
								cx, cy = pdx, pdy
							elseif ci == 3 then
								cx, cy = lx, ly
							else
								cx, cy = tx, ty
							end
							cx, cy = cx - cx % 4, cy - cy % 4
							if inRange(cx, cy) then
								local s = sad(cx, cy, bs)
								if s < bs then
									bvx, bvy, bs = cx, cy, s
								end
							end
						end
						for _, step in STEPS do
							local moved = true
							while moved do
								moved = false
								local bx, by = bvx, bvy
								for d = 1, 4 do
									local cx, cy = bx, by
									if d == 1 then
										cx += step
									elseif d == 2 then
										cx -= step
									elseif d == 3 then
										cy += step
									else
										cy -= step
									end
									if inRange(cx, cy) then
										local s = sad(cx, cy, bs)
										if s < bs then
											bvx, bvy, bs = cx, cy, s
											moved = true
										end
									end
								end
							end
						end
						for _, sub in SUBSTEPS do
							local bx, by = bvx, bvy
							for ddx = -sub, sub, sub do
								for ddy = -sub, sub, sub do
									if ddx ~= 0 or ddy ~= 0 then
										local cx, cy = bx + ddx, by + ddy
										if inRange(cx, cy) then
											local s = sad(cx, cy, bs)
											if s < bs then
												bvx, bvy, bs = cx, cy, s
											end
										end
									end
								end
							end
						end
						local mean = 0
						for k = 1, 256 do
							mean += sy[k]
						end
						mean /= 256
						local act = 0
						for k = 1, 256 do
							act += abs(sy[k] - mean)
						end
						if act < bs * 0.6 and bs > 256 * 6 then
							mode = MODE_INTRA
						else
							mode = MODE_INTER
							vx, vy = bvx, bvy
						end
					end
					local lm = (mbx > 0) and modes[idx - 1] or MODE_INTER
					local tm = (mby > 0) and modes[idx - MBW] or MODE_INTER
					E.bit(m.skip, (lm == MODE_SKIP and 1 or 0) + (tm == MODE_SKIP and 1 or 0), mode == MODE_SKIP and 1 or 0)
					if mode ~= MODE_SKIP then
						E.bit(m.intra, (lm == MODE_INTRA and 1 or 0) + (tm == MODE_INTRA and 1 or 0), mode == MODE_INTRA and 1 or 0)
					end
					if mode == MODE_INTER then
						putMv(E, m, 0, vx - pdx)
						putMv(E, m, 1, vy - pdy)
						predict(vx, vy)
					end
				end
				modes[idx] = mode
				if mode ~= MODE_INTRA then
					hasMv[idx] = true
					mvx[idx], mvy[idx] = vx, vy
				end
				if mode == MODE_SKIP then
					stats.skip += 1
					for bi = 0, 3 do
						local ox, oy = (bi % 2) * 8, (bi // 2) * 8
						writeBlock(Y, PW, x + ox, y + oy, predY, 16, ox, oy, false)
					end
					writeBlock(Cb, CW, x // 2, y // 2, predCb, 8, 0, 0, false)
					writeBlock(Cr, CW, x // 2, y // 2, predCr, 8, 0, 0, false)
					dc0, dc1, dc2 = 0, 0, 0
				elseif mode == MODE_INTER then
					stats.inter += 1
					local cbp = table.create(6, 0)
					for bi = 1, 6 do
						local tab
						if bi <= 4 then
							local ox, oy = ((bi - 1) % 2) * 8, ((bi - 1) // 2) * 8
							residualDct(sy, 16, ox, oy, predY, 16, ox, oy)
							tab = tl
						elseif bi == 5 then
							residualDct(scb, 8, 0, 0, predCb, 8, 0, 0)
							tab = tc
						else
							residualDct(scr, 8, 0, 0, predCr, 8, 0, 0)
							tab = tc
						end
						local qc = qcs[bi]
						local any = 0
						for k = 1, 64 do
							local f = F[k]
							local a = floor(abs(f) / tab[k] + 0.3)
							if f < 0 then
								a = -a
							end
							qc[k] = a
							if a ~= 0 then
								any = 1
							end
						end
						cbp[bi] = any
					end
					E.bit(m.cbp, 0, cbp[1])
					E.bit(m.cbp, 3 + cbp[1], cbp[2])
					E.bit(m.cbp, 6 + cbp[1], cbp[3])
					E.bit(m.cbp, 9 + min(cbp[3] + cbp[2], 2), cbp[4])
					E.bit(m.cbp, 12, cbp[5])
					E.bit(m.cbp, 15, cbp[6])
					for bi = 1, 6 do
						local chroma = bi > 4
						local tab = chroma and tc or tl
						local withRes = cbp[bi] == 1
						if withRes then
							local qc = qcs[bi]
							for k = 1, 64 do
								zz[k] = qc[ZIGZAG[k] + 1]
							end
							putCoefs(E, m, chroma and 3 or 1, zz, 0)
							for k = 1, 64 do
								deq[k] = qc[k] * tab[k]
							end
							idct(deq, res)
						end
						if bi <= 4 then
							local ox, oy = ((bi - 1) % 2) * 8, ((bi - 1) // 2) * 8
							writeBlock(Y, PW, x + ox, y + oy, predY, 16, ox, oy, withRes)
						elseif bi == 5 then
							writeBlock(Cb, CW, x // 2, y // 2, predCb, 8, 0, 0, withRes)
						else
							writeBlock(Cr, CW, x // 2, y // 2, predCr, 8, 0, 0, withRes)
						end
					end
					dc0, dc1, dc2 = 0, 0, 0
				else
					stats.intra += 1
					for bi = 1, 6 do
						local plane = (bi <= 4) and 0 or (bi - 4)
						local tab = plane ~= 0 and tabs[3] or tabs[1]
						local cls = plane ~= 0 and 2 or 0
						local src, sw, ox, oy = sy, 16, ((bi - 1) % 2) * 8, ((bi - 1) // 2) * 8
						if plane == 1 then
							src, sw, ox, oy = scb, 8, 0, 0
						elseif plane == 2 then
							src, sw, ox, oy = scr, 8, 0, 0
						end
						for yy = 0, 7 do
							local s = (oy + yy) * sw + ox
							for xx = 1, 8 do
								blk[yy * 8 + xx] = src[s + xx] - 128
							end
						end
						fdct(blk, F)
						local qc = qcs[1]
						for k = 1, 64 do
							local v = F[k] / tab[k]
							qc[k] = v < 0 and -floor(-v + 0.5) or floor(v + 0.5)
						end
						local dc = qc[1]
						local pred = (plane == 0) and dc0 or ((plane == 1) and dc1 or dc2)
						putDc(E, m, cls, dc - pred)
						if plane == 0 then
							dc0 = dc
						elseif plane == 1 then
							dc1 = dc
						else
							dc2 = dc
						end
						for k = 1, 64 do
							zz[k] = qc[ZIGZAG[k] + 1]
						end
						putCoefs(E, m, cls, zz, 1)
						for k = 1, 64 do
							deq[k] = qc[k] * tab[k]
						end
						idct(deq, res)
						local plane_, pw, px, py
						if plane == 0 then
							plane_, pw, px, py = Y, PW, x + ox, y + oy
						else
							plane_, pw, px, py = (plane == 1) and Cb or Cr, CW, x // 2, y // 2
						end
						for yy = 0, 7 do
							local o = (py + yy) * pw + px
							for xx = 1, 8 do
								local v = res[yy * 8 + xx] + 128
								writeu8(plane_, o + xx - 1, v < 0 and 0 or (v > 255 and 255 or v))
							end
						end
					end
				end
			end
		end
		if not droppable then
			if not lastSY then
				lastSY = table.create(PW * PH, 0)
			end
			lastSY, sY = sY, lastSY
			prev, work = work, prev
		end
		frames += 1
		stats.qMin, stats.qMax = min(stats.qMin, q), max(stats.qMax, q)
		if target then
			local produced = EA.size() + EB.size()
			local spent = produced - chunkBytes0
			chunkBytes0 = produced
			local perFrame = target / fps
			local second = perFrame * fps
			budget += perFrame - spent
			if rateWindow <= 0.25 then
				-- the old, tight control
				if budget < -second * 0.25 then
					q = max(3, q - ((budget < -second) and 3 or 1))
				elseif budget > second * 0.25 then
					q = min(95, q + 1)
				end
			else
				-- saved-up bytes are capped at the window, debt at two windows; the step follows how far off the budget is
				budget = max(min(budget, second * rateWindow), -2 * second * rateWindow)
				local f = budget / second
				if f < -1 then
					q -= 4
				elseif f < -0.4 then
					q -= 2
				elseif f < -0.1 then
					q -= 1
				elseif f > 0.6 then
					q += 1
				end
				q = max(qMin, min(qMax, q))
			end
		end
	end

	-- the last reconstruction (what a reader shows for the last frame added)
	function w:planes()
		return cur.Y, cur.Cb, cur.Cr
	end

	-- this part's chunks (Flv2.assemble puts parts together)
	function w:finishPart()
		if EA then
			table.insert(chunks, { first = firstFrame + chunkFirst, a = EA.finish(), b = EB.finish() })
			EA, EB, E = nil, nil, nil
		end
		return { chunks = chunks, frames = frames, stats = stats, keyEvery = keyEvery, layers = layers, firstFrame = firstFrame }
	end

	function w:finish()
		return Flv2.assemble({ w:finishPart() }, width, height, fps, keyEvery, layers)
	end

	return w
end

-- ------------------------------------------------------------------------------------------- renditions
-- "FLVS", version u8 (1), count u8, 2 bytes reserved, then 16 bytes per rendition: offset u32 (from the start), size
-- u32, width u16, height u16, bytes per second u32; the FLV2 streams follow
Flv2.SetMagic = "FLVS"
local SET_HEAD, SET_ENTRY = 8, 16

function Flv2.packSet(list)
	local total = SET_HEAD + #list * SET_ENTRY
	for _, e in ipairs(list) do
		total += buffer.len(e.bytes)
	end
	local out = buffer.create(total)
	buffer.writestring(out, 0, Flv2.SetMagic)
	writeu8(out, 4, 1)
	writeu8(out, 5, #list)
	local off = SET_HEAD + #list * SET_ENTRY
	for i, e in ipairs(list) do
		local d = SET_HEAD + (i - 1) * SET_ENTRY
		buffer.writeu32(out, d, off)
		buffer.writeu32(out, d + 4, buffer.len(e.bytes))
		buffer.writeu16(out, d + 8, e.width)
		buffer.writeu16(out, d + 10, e.height)
		buffer.writeu32(out, d + 12, math.floor(e.bytesPerSecond or 0))
		buffer.copy(out, off, e.bytes, 0)
		off += buffer.len(e.bytes)
	end
	return out
end

function Flv2.isSet(b)
	return buffer.len(b) >= SET_HEAD and buffer.readstring(b, 0, 4) == Flv2.SetMagic
end

-- the set's table of renditions (needs only the first 8 + 16 x count bytes)
function Flv2.readSet(b)
	if not Flv2.isSet(b) then
		return nil
	end
	local list = {}
	for i = 1, readu8(b, 5) do
		local d = SET_HEAD + (i - 1) * SET_ENTRY
		if d + SET_ENTRY > buffer.len(b) then
			break
		end
		list[i] = { offset = buffer.readu32(b, d), size = buffer.readu32(b, d + 4), width = buffer.readu16(b, d + 8),
			height = buffer.readu16(b, d + 10), bytesPerSecond = buffer.readu32(b, d + 12) }
	end
	return list
end
Flv2.setHeadSize = function(count)
	return SET_HEAD + count * SET_ENTRY
end

function Flv2.pick(list, lines)
	local best, smallest
	for i, e in ipairs(list) do
		local l = math.min(e.width, e.height)
		if l <= lines and (not best or l > math.min(list[best].width, list[best].height)) then
			best = i
		end
		if not smallest or l < math.min(list[smallest].width, list[smallest].height) then
			smallest = i
		end
	end
	return best or smallest or 1
end

-- parts (from w:finishPart(), in order) -> the video's bytes, stats
function Flv2.assemble(parts, width, height, fps, keyEvery, layers)
	local chunks, frames = {}, 0
	local stats = { skip = 0, inter = 0, intra = 0, slides = 0, keyframes = 0, qMin = 100, qMax = 0 }
	for _, p in ipairs(parts) do
		for _, c in ipairs(p.chunks) do
			table.insert(chunks, c)
		end
		frames = math.max(frames, p.firstFrame + p.frames)
		local st = p.stats
		for _, k in ipairs({ "skip", "inter", "intra", "slides", "keyframes" }) do
			stats[k] += st[k] or 0
		end
		if (st.qMax or 0) > 0 then
			stats.qMin, stats.qMax = min(stats.qMin, st.qMin), max(stats.qMax, st.qMax)
		end
	end
	local total = 0
	for _, c in ipairs(chunks) do
		total += buffer.len(c.a) + buffer.len(c.b)
	end
	local dirSize = #chunks * DIR_ENTRY
	local out = buffer.create(HEADER + dirSize + total)
	buffer.writestring(out, 0, Flv2.Magic)
	writeu8(out, 4, 1)
	writeu8(out, 5, fps)
	buffer.writeu16(out, 6, width)
	buffer.writeu16(out, 8, height)
	buffer.writeu32(out, 10, frames)
	buffer.writeu16(out, 14, keyEvery)
	buffer.writeu16(out, 16, #chunks)
	writeu8(out, 18, layers)
	local off = 0
	for i, c in ipairs(chunks) do
		local d = HEADER + (i - 1) * DIR_ENTRY
		buffer.writeu32(out, d, off)
		buffer.writeu32(out, d + 4, buffer.len(c.a))
		buffer.writeu32(out, d + 8, buffer.len(c.b))
		buffer.writeu32(out, d + 12, c.first)
		buffer.copy(out, HEADER + dirSize + off, c.a, 0)
		buffer.copy(out, HEADER + dirSize + off + buffer.len(c.a), c.b, 0)
		off += buffer.len(c.a) + buffer.len(c.b)
	end
	stats.frames = frames
	stats.bytes = buffer.len(out)
	stats.seconds = frames / fps
	stats.bytesPerSecond = stats.bytes / math.max(stats.seconds, 1e-9)
	stats.codec = "FLV2"
	return out, stats
end

return Flv2
