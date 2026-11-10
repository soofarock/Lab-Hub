--!native
--!optimize 2
-- CELT decoder (RFC 6716 section 4.3): the transform layer of Opus, used for music and for the high band of hybrid
-- frames. Float decoding at 48 kHz, ported from libopus celt/ (BSD-3-Clause, see the notice in the Opus module).
--
--   local st = Celt.new(channels)          -- 1 or 2 output channels
--   st.start, st.endBand                   -- coded bands (Opus sets these per frame: hybrid starts at 17)
--   st.streamChannels                      -- channels in the stream (1 or 2)
--   Celt.decode(st, ec, len, frameSize, out, outOff, accum) -> samples
--       ec: an Entropy decoder over the frame (len bytes); out[c][outOff + i] gets 48 kHz samples in -1..1,
--       added to what is there when accum is true. A frame of len <= 1 is concealed as a lost one
--       (pitch-periodic extrapolation, then noise).

local Celt = {}

local T
local Entropy
if script then
	T = require(script.Parent.CeltTables)
	Entropy = require(script.Parent.Entropy)
else
	T = require("./CeltTables")
	Entropy = require("./Entropy")
end

local ilog = Entropy.ilog
local floor, sqrt, cos, exp, min, max, abs = math.floor, math.sqrt, math.cos, math.exp, math.min, math.max, math.abs
local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

local NB = 21
local OVERLAP = 120
local SHORT_MDCT = 120
local MAXLM = 3
local BUF = 2048
local BITRES = 3
local EBANDS = T.eBands -- 1-based: eBands[i] is C eBands[i - 1]
local LOGN = T.logN
local WINDOW = T.window
local CACHE_INDEX, CACHE_BITS, CACHE_CAPS = T.cacheIndex, T.cacheBits, T.cacheCaps
local ALLOC = T.allocVectors
local NB_ALLOC = 11
local EMEANS = {}
for i, v in ipairs(T.eMeans) do
	EMEANS[i] = v / 16 -- the table is Q4
end
local PREEMPH = 0.85000610
local SPREAD_AGGRESSIVE = 3
local SPREAD_NORMAL = 2
local MAX_FINE_BITS = 8
local FINE_OFFSET = 21
local QTHETA_OFFSET = 4
local QTHETA_OFFSET_TWOPHASE = 16
local COMBFILTER_MINPERIOD = 15

local function eb(i) -- C eBands[i]
	return EBANDS[i + 1]
end

-- C integer division (truncates toward zero)
local function tdiv(a, b)
	local q = a / b
	if q >= 0 then
		return floor(q)
	end
	return -floor(-q)
end

local function int16(x)
	return (x + 32768) % 65536 - 32768
end

local function frac_mul16(a, b)
	return (16384 + int16(a) * int16(b)) // 32768
end

local function isqrt32(v)
	local r = floor(sqrt(v))
	while r * r > v do
		r -= 1
	end
	while (r + 1) * (r + 1) <= v do
		r += 1
	end
	return r
end

local function lcg(seed)
	return (1664525 * seed + 1013904223) % 4294967296
end

local TRIM_ICDF = { 126, 124, 119, 109, 87, 41, 19, 9, 4, 2, 0 }
local SPREAD_ICDF = { 25, 23, 2, 0 }
local TAPSET_ICDF = { 2, 1, 0 }
local SMALL_ENERGY_ICDF = { 2, 1, 0 }
local LOG2_FRAC = { 0, 8, 13, 16, 19, 21, 23, 24, 26, 27, 28, 29, 30, 31, 32, 32, 33, 34, 34, 35, 36, 36, 37, 37 }
local TF_SELECT = {
	{ 0, -1, 0, -1, 0, -1, 0, -1 },
	{ 0, -1, 0, -2, 1, 0, 1, -1 },
	{ 0, -2, 0, -3, 2, 0, 1, -1 },
	{ 0, -2, 0, -3, 3, 0, 1, -1 },
}
local PRED_COEF = { 29440 / 32768, 26112 / 32768, 21248 / 32768, 16384 / 32768 }
local BETA_COEF = { 30147 / 32768, 22282 / 32768, 12124 / 32768, 6554 / 32768 }
local BETA_INTRA = 4915 / 32768
local ORDERY = { 1, 0, 3, 0, 2, 1, 7, 0, 4, 3, 6, 1, 5, 2, 15, 0, 8, 7, 12, 3, 11, 4, 14, 1, 9, 6, 13, 2, 10, 5 }
local EXP2_TABLE8 = { 16384, 17866, 19483, 21247, 23170, 25267, 27554, 30048 }
local BIT_INTERLEAVE = { 0, 1, 1, 1, 2, 3, 3, 3, 2, 3, 3, 3, 2, 3, 3, 3 }
local BIT_DEINTERLEAVE = { 0x00, 0x03, 0x0C, 0x0F, 0x30, 0x33, 0x3C, 0x3F, 0xC0, 0xC3, 0xCC, 0xCF, 0xF0, 0xF3, 0xFC, 0xFF }
local COMB_GAINS = {
	{ 0.3066406250, 0.2170410156, 0.1296386719 },
	{ 0.4638671875, 0.2680664062, 0.0 },
	{ 0.7998046875, 0.1000976562, 0.0 },
}

---------------------------------------------------------------------------------------------- pulse cache / PVQ
local function cacheBase(LM, bandIdx) -- 1-based index of cache[0] in CACHE_BITS, for C LM (before the ++)
	return CACHE_INDEX[(LM + 1) * NB + bandIdx + 1] + 1
end

local function getPulses(i)
	if i < 8 then
		return i
	end
	return lshift(8 + band(i, 7), (i // 8) - 1)
end

local function bits2pulses(bandIdx, LM, bits)
	local c = cacheBase(LM, bandIdx)
	local lo, hi = 0, CACHE_BITS[c]
	bits -= 1
	for _ = 1, 6 do
		local mid = (lo + hi + 1) // 2
		if CACHE_BITS[c + mid] >= bits then
			hi = mid
		else
			lo = mid
		end
	end
	local lov = lo == 0 and -1 or CACHE_BITS[c + lo]
	if bits - lov <= CACHE_BITS[c + hi] - bits then
		return lo
	end
	return hi
end

local function pulses2bits(bandIdx, LM, pulses)
	if pulses == 0 then
		return 0
	end
	return CACHE_BITS[cacheBase(LM, bandIdx) + pulses] + 1
end

-- U(n, k): the PVQ codebook sizes (V(n, k) = U(n, k) + U(n, k + 1) codewords of n dimensions and k pulses)
local UMAX = 210
local Urows = {}
local function U(n, k)
	if n > k then
		n, k = k, n
	end
	local row = Urows[n]
	if not row then
		-- rows built in order: U(n, k) = U(n - 1, k) + U(n, k - 1) + U(n - 1, k - 1)
		for r = 0, n do
			if not Urows[r] then
				local cur = table.create(UMAX + 1, 0)
				if r == 0 then
					cur[1] = 1
				else
					local prev = Urows[r - 1]
					for kk = 1, UMAX do
						cur[kk + 1] = prev[kk + 1] + cur[kk] + prev[kk]
					end
				end
				Urows[r] = cur
			end
		end
		row = Urows[n]
	end
	return row[k + 1]
end

local function decodePulses(ec, y, n, k)
	-- the codeword index, then cwrsi
	local i = ec:uint(U(n, k) + U(n, k + 1))
	local yy = 0
	local j = 1
	while n > 2 do
		local p, s, k0, val
		if k >= n then
			p = U(n, k + 1)
			s = i >= p and -1 or 0
			if s ~= 0 then
				i -= p
			end
			k0 = k
			local q = U(n, n)
			if q > i then
				k = n
				repeat
					k -= 1
					p = U(k, n)
				until p <= i
			else
				p = U(n, k)
				while p > i do
					k -= 1
					p = U(n, k)
				end
			end
			i -= p
			val = k0 - k
			if s ~= 0 then
				val = -val
			end
			y[j] = val
			j += 1
			yy += val * val
		else
			p = U(k, n)
			local q = U(k + 1, n)
			if p <= i and i < q then
				i -= p
				y[j] = 0
				j += 1
			else
				s = i >= q and -1 or 0
				if s ~= 0 then
					i -= q
				end
				k0 = k
				repeat
					k -= 1
					p = U(k, n)
				until p <= i
				i -= p
				val = k0 - k
				if s ~= 0 then
					val = -val
				end
				y[j] = val
				j += 1
				yy += val * val
			end
		end
		n -= 1
	end
	-- n == 2
	local p = 2 * k + 1
	local s = i >= p and -1 or 0
	if s ~= 0 then
		i -= p
	end
	local k0 = k
	k = (i + 1) // 2
	if k ~= 0 then
		i -= 2 * k - 1
	end
	local val = k0 - k
	if s ~= 0 then
		val = -val
	end
	y[j] = val
	yy += val * val
	val = k
	if i ~= 0 then
		val = -val
	end
	y[j + 1] = val
	yy += val * val
	return yy
end

---------------------------------------------------------------------------------------------- vector helpers
local function expRotation1(X, off, len, stride, c, s)
	local ms = -s
	for i = 0, len - stride - 1 do
		local x1 = X[off + i + 1]
		local x2 = X[off + i + stride + 1]
		X[off + i + stride + 1] = c * x2 + s * x1
		X[off + i + 1] = c * x1 + ms * x2
	end
	for i = len - 2 * stride - 1, 0, -1 do
		local x1 = X[off + i + 1]
		local x2 = X[off + i + stride + 1]
		X[off + i + stride + 1] = c * x2 + s * x1
		X[off + i + 1] = c * x1 + ms * x2
	end
end

local SPREAD_FACTOR = { 15, 10, 5 }
local function expRotation(X, off, len, dir, stride, K, spread)
	if 2 * K >= len or spread == 0 then
		return
	end
	local factor = SPREAD_FACTOR[spread]
	local gain = len / (len + factor * K)
	local theta = 0.5 * gain * gain
	local c = cos(0.5 * math.pi * theta)
	local s = cos(0.5 * math.pi * (1 - theta))
	local stride2 = 0
	if len >= 8 * stride then
		stride2 = 1
		while (stride2 * stride2 + stride2) * stride + (stride // 4) < len do
			stride2 += 1
		end
	end
	len = len // stride
	for i = 0, stride - 1 do
		local o = off + i * len
		if dir < 0 then
			if stride2 ~= 0 then
				expRotation1(X, o, len, stride2, s, c)
			end
			expRotation1(X, o, len, 1, c, s)
		else
			expRotation1(X, o, len, 1, c, -s)
			if stride2 ~= 0 then
				expRotation1(X, o, len, stride2, s, -c)
			end
		end
	end
end

local iyBuf = table.create(256, 0)
local function algUnquant(X, off, N, K, spread, B, ec, gain)
	local iy = iyBuf
	local Ryy = decodePulses(ec, iy, N, K)
	local g = gain / sqrt(Ryy)
	for i = 1, N do
		X[off + i] = iy[i] * g
	end
	expRotation(X, off, N, -1, B, K, spread)
	if B <= 1 then
		return 1
	end
	local N0 = N // B
	local mask = 0
	for i = 0, B - 1 do
		local t = 0
		for j = 1, N0 do
			if iy[i * N0 + j] ~= 0 then
				t = 1
				break
			end
		end
		if t ~= 0 then
			mask = bor(mask, lshift(1, i))
		end
	end
	return mask
end

local function renormaliseVector(X, off, N, gain)
	local E = 1e-15
	for i = 1, N do
		local v = X[off + i]
		E += v * v
	end
	local g = gain / sqrt(E)
	for i = 1, N do
		X[off + i] *= g
	end
end

local function haar1(X, off, N0, stride)
	N0 //= 2
	local k = 0.70710678
	for i = 0, stride - 1 do
		for j = 0, N0 - 1 do
			local a = off + stride * 2 * j + i + 1
			local b = off + stride * (2 * j + 1) + i + 1
			local t1 = k * X[a]
			local t2 = k * X[b]
			X[a] = t1 + t2
			X[b] = t1 - t2
		end
	end
end

local tmpBuf = table.create(1024, 0)
local function deinterleaveHadamard(X, off, N0, stride, hadamard)
	local N = N0 * stride
	local tmp = tmpBuf
	if hadamard then
		local base = stride - 2 -- ORDERY index base (0-based)
		for i = 0, stride - 1 do
			local o = ORDERY[base + i + 1]
			for j = 0, N0 - 1 do
				tmp[o * N0 + j + 1] = X[off + j * stride + i + 1]
			end
		end
	else
		for i = 0, stride - 1 do
			for j = 0, N0 - 1 do
				tmp[i * N0 + j + 1] = X[off + j * stride + i + 1]
			end
		end
	end
	for i = 1, N do
		X[off + i] = tmp[i]
	end
end

local function interleaveHadamard(X, off, N0, stride, hadamard)
	local N = N0 * stride
	local tmp = tmpBuf
	if hadamard then
		local base = stride - 2
		for i = 0, stride - 1 do
			local o = ORDERY[base + i + 1]
			for j = 0, N0 - 1 do
				tmp[j * stride + i + 1] = X[off + o * N0 + j + 1]
			end
		end
	else
		for i = 0, stride - 1 do
			for j = 0, N0 - 1 do
				tmp[j * stride + i + 1] = X[off + i * N0 + j + 1]
			end
		end
	end
	for i = 1, N do
		X[off + i] = tmp[i]
	end
end

local function bitexactCos(x)
	local tmp = (4096 + x * x) // 8192
	local x2 = tmp
	x2 = (32767 - x2) + frac_mul16(x2, (-7651 + frac_mul16(x2, (8277 + frac_mul16(-626, x2)))))
	return 1 + x2
end

local function bitexactLog2tan(isin, icos)
	local lc = ilog(icos)
	local ls = ilog(isin)
	icos = icos * 2 ^ (15 - lc)
	isin = isin * 2 ^ (15 - ls)
	return (ls - lc) * 2048 + frac_mul16(isin, frac_mul16(isin, -2597) + 7932) - frac_mul16(icos, frac_mul16(icos, -2597) + 7932)
end

local function computeQn(N, b, offset, pulseCap, stereo)
	local N2 = 2 * N - 1
	if stereo and N == 2 then
		N2 -= 1
	end
	local qb = tdiv(b + N2 * offset, N2)
	qb = min(b - pulseCap - 32, qb)
	qb = min(64, qb)
	local qn
	if qb < 4 then
		qn = 1
	else
		qn = EXP2_TABLE8[band(qb, 7) + 1] // (2 ^ (14 - (qb // 8)))
		qn = ((qn + 1) // 2) * 2
	end
	return qn
end

---------------------------------------------------------------------------------------------- band quantisation (decode side)
-- ctx: { ec, i, intensity, spread, tfChange, remaining, seed, disableInv, avoidSplitNoise }
-- returns b, fill, inv, imid, iside, delta, itheta, qalloc
local function computeTheta(ctx, N, b, B, B0, LM, stereo, fill)
	local ec = ctx.ec
	local i = ctx.i
	local pulseCap = LOGN[i + 1] + LM * 8
	local offset = (pulseCap // 2) - ((stereo and N == 2) and QTHETA_OFFSET_TWOPHASE or QTHETA_OFFSET)
	local qn = computeQn(N, b, offset, pulseCap, stereo)
	if stereo and i >= ctx.intensity then
		qn = 1
	end
	local itheta = 0
	local inv = 0
	local tell = ec:tellFrac()
	if qn ~= 1 then
		if stereo and N > 2 then
			local p0 = 3
			local x0 = qn // 2
			local ft = p0 * (x0 + 1) + x0
			local fs = ec:decode(ft)
			local x
			if fs < (x0 + 1) * p0 then
				x = fs // p0
			else
				x = x0 + 1 + (fs - (x0 + 1) * p0)
			end
			local fl = x <= x0 and p0 * x or (x - 1 - x0) + (x0 + 1) * p0
			local fh = x <= x0 and p0 * (x + 1) or (x - x0) + (x0 + 1) * p0
			ec:update(fl, fh, ft)
			itheta = x
		elseif B0 > 1 or stereo then
			itheta = ec:uint(qn + 1)
		else
			local h = qn // 2
			local ft = (h + 1) * (h + 1)
			local fm = ec:decode(ft)
			local fs, fl
			if fm < (h * (h + 1)) // 2 then
				itheta = (isqrt32(8 * fm + 1) - 1) // 2
				fs = itheta + 1
				fl = (itheta * (itheta + 1)) // 2
			else
				itheta = (2 * (qn + 1) - isqrt32(8 * (ft - fm - 1) + 1)) // 2
				fs = qn + 1 - itheta
				fl = ft - (((qn + 1 - itheta) * (qn + 2 - itheta)) // 2)
			end
			ec:update(fl, fl + fs, ft)
		end
		itheta = (itheta * 16384) // qn
	elseif stereo then
		if b > 16 and ctx.remaining > 16 then
			inv = ec:bitLogp(2)
		else
			inv = 0
		end
		if ctx.disableInv then
			inv = 0
		end
		itheta = 0
	end
	local qalloc = ec:tellFrac() - tell
	b -= qalloc
	local imid, iside, delta
	if itheta == 0 then
		imid, iside = 32767, 0
		fill = band(fill, lshift(1, B) - 1)
		delta = -16384
	elseif itheta == 16384 then
		imid, iside = 0, 32767
		fill = band(fill, lshift(lshift(1, B) - 1, B))
		delta = 16384
	else
		imid = bitexactCos(itheta)
		iside = bitexactCos(16384 - itheta)
		delta = frac_mul16((N - 1) * 128, bitexactLog2tan(iside, imid))
	end
	return b, fill, inv, imid, iside, delta, itheta, qalloc
end

local function quantBandN1(ctx, X, xo, Y, yo, lowOut, lowOutOff)
	local ec = ctx.ec
	for c = 0, (Y and 1 or 0) do
		local sign = 0
		if ctx.remaining >= 8 then
			sign = ec:bits(1)
			ctx.remaining -= 8
		end
		local arr, o = X, xo
		if c == 1 then
			arr, o = Y, yo
		end
		arr[o + 1] = sign ~= 0 and -1 or 1
	end
	if lowOut then
		lowOut[lowOutOff + 1] = X[xo + 1]
	end
	return 1
end

local quantPartition
quantPartition = function(ctx, X, xo, N, b, B, low, lowo, LM, gain, fill)
	local i = ctx.i
	local B0 = B
	local cm = 0
	local c = cacheBase(LM, i)
	if LM ~= -1 and b > CACHE_BITS[c + CACHE_BITS[c]] + 12 and N > 2 then
		N //= 2
		local yo = xo + N
		LM -= 1
		if B == 1 then
			fill = bor(band(fill, 1), lshift(fill, 1))
		end
		B = (B + 1) // 2
		local inv, imid, iside, delta, itheta, qalloc
		b, fill, inv, imid, iside, delta, itheta, qalloc = computeTheta(ctx, N, b, B, B0, LM, false, fill)
		local mid = imid / 32768
		local side = iside / 32768
		if B0 > 1 and band(itheta, 0x3fff) ~= 0 then
			if itheta > 8192 then
				delta -= delta // (2 ^ (4 - LM))
			else
				delta = min(0, delta + ((N * 8) // (2 ^ (5 - LM))))
			end
		end
		local mbits = max(0, min(b, tdiv(b - delta, 2)))
		local sbits = b - mbits
		ctx.remaining -= qalloc
		local low2, low2o = nil, 0
		if low then
			low2, low2o = low, lowo + N
		end
		local rebalance = ctx.remaining
		if mbits >= sbits then
			cm = quantPartition(ctx, X, xo, N, mbits, B, low, lowo, LM, gain * mid, fill)
			rebalance = mbits - (rebalance - ctx.remaining)
			if rebalance > 24 and itheta ~= 0 then
				sbits += rebalance - 24
			end
			cm = bor(cm, lshift(quantPartition(ctx, X, yo, N, sbits, B, low2, low2o, LM, gain * side, rshift(fill, B)), B0 // 2))
		else
			cm = lshift(quantPartition(ctx, X, yo, N, sbits, B, low2, low2o, LM, gain * side, rshift(fill, B)), B0 // 2)
			rebalance = sbits - (rebalance - ctx.remaining)
			if rebalance > 24 and itheta ~= 16384 then
				mbits += rebalance - 24
			end
			cm = bor(cm, quantPartition(ctx, X, xo, N, mbits, B, low, lowo, LM, gain * mid, fill))
		end
	else
		local q = bits2pulses(i, LM, b)
		local currBits = pulses2bits(i, LM, q)
		ctx.remaining -= currBits
		while ctx.remaining < 0 and q > 0 do
			ctx.remaining += currBits
			q -= 1
			currBits = pulses2bits(i, LM, q)
			ctx.remaining -= currBits
		end
		if q ~= 0 then
			local K = getPulses(q)
			cm = algUnquant(X, xo, N, K, ctx.spread, B, ctx.ec, gain)
		else
			local cmMask = lshift(1, B) - 1
			fill = band(fill, cmMask)
			if fill == 0 then
				for j = 1, N do
					X[xo + j] = 0
				end
			else
				if not low then
					for j = 1, N do
						ctx.seed = lcg(ctx.seed)
						local s = ctx.seed
						if s >= 2147483648 then
							s -= 4294967296
						end
						X[xo + j] = s // 1048576
					end
					cm = cmMask
				else
					for j = 1, N do
						ctx.seed = lcg(ctx.seed)
						local tmp = 1 / 256
						if band(ctx.seed, 0x8000) == 0 then
							tmp = -tmp
						end
						X[xo + j] = low[lowo + j] + tmp
					end
					cm = fill
				end
				renormaliseVector(X, xo, N, gain)
			end
		end
	end
	return cm
end

local function quantBand(ctx, X, xo, N, b, B, low, lowo, LM, lowOut, lowOutOff, gain, scratch, scratchOff, fill)
	local N0 = N
	local NB_ = N
	local B0 = B
	local timeDivide = 0
	local recombine = 0
	local longBlocks = B0 == 1
	local tfChange = ctx.tfChange
	NB_ = NB_ // B
	if N == 1 then
		return quantBandN1(ctx, X, xo, nil, 0, lowOut, lowOutOff)
	end
	if tfChange > 0 then
		recombine = tfChange
	end
	if scratch and low and (recombine ~= 0 or (NB_ % 2 == 0 and tfChange < 0) or B0 > 1) then
		for j = 1, N do
			scratch[scratchOff + j] = low[lowo + j]
		end
		low, lowo = scratch, scratchOff
	end
	for k = 0, recombine - 1 do
		if low then
			haar1(low, lowo, N // (2 ^ k), 2 ^ k)
		end
		fill = bor(BIT_INTERLEAVE[band(fill, 0xF) + 1], lshift(BIT_INTERLEAVE[rshift(fill, 4) + 1], 2))
	end
	B = B // (2 ^ recombine)
	NB_ = NB_ * (2 ^ recombine)
	while NB_ % 2 == 0 and tfChange < 0 do
		if low then
			haar1(low, lowo, NB_, B)
		end
		fill = bor(fill, lshift(fill, B))
		B *= 2
		NB_ //= 2
		timeDivide += 1
		tfChange += 1
	end
	B0 = B
	local NB0 = NB_
	if B0 > 1 and low then
		deinterleaveHadamard(low, lowo, NB_ // (2 ^ recombine), B0 * (2 ^ recombine), longBlocks)
	end
	local cm = quantPartition(ctx, X, xo, N, b, B, low, lowo, LM, gain, fill)
	if B0 > 1 then
		interleaveHadamard(X, xo, NB_ // (2 ^ recombine), B0 * (2 ^ recombine), longBlocks)
	end
	NB_ = NB0
	B = B0
	for _ = 1, timeDivide do
		B //= 2
		NB_ *= 2
		cm = bor(cm, rshift(cm, B))
		haar1(X, xo, NB_, B)
	end
	for k = 0, recombine - 1 do
		cm = BIT_DEINTERLEAVE[cm + 1]
		haar1(X, xo, N0 // (2 ^ k), 2 ^ k)
	end
	B *= 2 ^ recombine
	if lowOut then
		local n = sqrt(N0)
		for j = 1, N0 do
			lowOut[lowOutOff + j] = n * X[xo + j]
		end
	end
	cm = band(cm, lshift(1, B) - 1)
	return cm
end

local function stereoMerge(X, xo, Y, yo, mid, N)
	local xp, side = 0, 0
	for j = 1, N do
		local y = Y[yo + j]
		xp += y * X[xo + j]
		side += y * y
	end
	xp = mid * xp
	local mm = mid * mid
	local El = mm + side - 2 * xp
	local Er = mm + side + 2 * xp
	if Er < 6e-4 or El < 6e-4 then
		for j = 1, N do
			Y[yo + j] = X[xo + j]
		end
		return
	end
	local lgain = 1 / sqrt(El)
	local rgain = 1 / sqrt(Er)
	for j = 1, N do
		local l = mid * X[xo + j]
		local r = Y[yo + j]
		X[xo + j] = lgain * (l - r)
		Y[yo + j] = rgain * (l + r)
	end
end

local function quantBandStereo(ctx, X, xo, Y, yo, N, b, B, low, lowo, LM, lowOut, lowOutOff, scratch, scratchOff, fill)
	if N == 1 then
		return quantBandN1(ctx, X, xo, Y, yo, lowOut, lowOutOff)
	end
	local origFill = fill
	local inv, imid, iside, delta, itheta, qalloc
	b, fill, inv, imid, iside, delta, itheta, qalloc = computeTheta(ctx, N, b, B, B, LM, true, fill)
	local mid = imid / 32768
	local side = iside / 32768
	local cm = 0
	local ec = ctx.ec
	if N == 2 then
		local mbits = b
		local sbits = 0
		if itheta ~= 0 and itheta ~= 16384 then
			sbits = 8
		end
		mbits -= sbits
		local c = itheta > 8192
		ctx.remaining -= qalloc + sbits
		local x2, x2o, y2, y2o = X, xo, Y, yo
		if c then
			x2, x2o, y2, y2o = Y, yo, X, xo
		end
		local sign = 0
		if sbits ~= 0 then
			sign = ec:bits(1)
		end
		sign = 1 - 2 * sign
		cm = quantBand(ctx, x2, x2o, N, mbits, B, low, lowo, LM, lowOut, lowOutOff, 1, scratch, scratchOff, origFill)
		y2[y2o + 1] = -sign * x2[x2o + 2]
		y2[y2o + 2] = sign * x2[x2o + 1]
		X[xo + 1] *= mid
		X[xo + 2] *= mid
		Y[yo + 1] *= side
		Y[yo + 2] *= side
		local tmp = X[xo + 1]
		X[xo + 1] = tmp - Y[yo + 1]
		Y[yo + 1] = tmp + Y[yo + 1]
		tmp = X[xo + 2]
		X[xo + 2] = tmp - Y[yo + 2]
		Y[yo + 2] = tmp + Y[yo + 2]
	else
		local mbits = max(0, min(b, tdiv(b - delta, 2)))
		local sbits = b - mbits
		ctx.remaining -= qalloc
		local rebalance = ctx.remaining
		if mbits >= sbits then
			cm = quantBand(ctx, X, xo, N, mbits, B, low, lowo, LM, lowOut, lowOutOff, 1, scratch, scratchOff, fill)
			rebalance = mbits - (rebalance - ctx.remaining)
			if rebalance > 24 and itheta ~= 0 then
				sbits += rebalance - 24
			end
			cm = bor(cm, quantBand(ctx, Y, yo, N, sbits, B, nil, 0, LM, nil, 0, side, nil, 0, rshift(fill, B)))
		else
			cm = quantBand(ctx, Y, yo, N, sbits, B, nil, 0, LM, nil, 0, side, nil, 0, rshift(fill, B))
			rebalance = sbits - (rebalance - ctx.remaining)
			if rebalance > 24 and itheta ~= 16384 then
				mbits += rebalance - 24
			end
			cm = bor(cm, quantBand(ctx, X, xo, N, mbits, B, low, lowo, LM, lowOut, lowOutOff, 1, scratch, scratchOff, fill))
		end
	end
	if N ~= 2 then
		stereoMerge(X, xo, Y, yo, mid, N)
	end
	if inv ~= 0 then
		for j = 1, N do
			Y[yo + j] = -Y[yo + j]
		end
	end
	return cm
end

-- X: C*N normalised coefficients (Y at offset N when stereo); collapse: C*NB masks (1-based)
local normBuf = table.create(2 * 1000, 0)
local function quantAllBands(st, start, endBand, X, stereo, collapse, pulses, shortBlocks, spread, dualStereo, intensity, tfRes,
	totalBits, balance, ec, LM, codedBands)
	local M = 2 ^ LM
	local B = shortBlocks ~= 0 and M or 1
	local N_ = M * SHORT_MDCT
	local C = stereo and 2 or 1
	local normOffset = M * eb(start)
	local norm = normBuf
	local norm2o = M * eb(NB - 1) - normOffset -- norm2 = norm + this
	local scratch, scratchOff = X, M * eb(NB - 1) -- lowband_scratch = X_ + M*eBands[effEBands-1]
	local lowbandOffset = 0
	local updateLowband = true
	local ctx = {
		ec = ec, intensity = intensity, spread = spread, seed = st.rng, disableInv = st.disableInv, i = 0, tfChange = 0,
		remaining = 0, avoidSplitNoise = B > 1,
	}
	for i = start, endBand - 1 do
		ctx.i = i
		local last = i == endBand - 1
		local xo = M * eb(i)
		local Xa, Ya, yo = X, nil, 0
		if stereo then
			Ya, yo = X, N_ + M * eb(i)
		end
		local N = M * eb(i + 1) - M * eb(i)
		local tell = ec:tellFrac()
		if i ~= start then
			balance -= tell
		end
		local remaining = totalBits - tell - 1
		ctx.remaining = remaining
		local b
		if i <= codedBands - 1 then
			local currBalance = tdiv(balance, min(3, codedBands - i))
			b = max(0, min(16383, min(remaining + 1, pulses[i + 1] + currBalance)))
		else
			b = 0
		end
		if (M * eb(i) - N >= M * eb(start) or i == start + 1) and (updateLowband or lowbandOffset == 0) then
			lowbandOffset = i
		end
		if i == start + 1 then
			-- special_hybrid_folding
			local n1 = M * (eb(start + 1) - eb(start))
			local n2 = M * (eb(start + 2) - eb(start + 1))
			for j = 0, n2 - n1 - 1 do
				norm[n1 + j + 1] = norm[2 * n1 - n2 + j + 1]
			end
			if dualStereo then
				for j = 0, n2 - n1 - 1 do
					norm[norm2o + n1 + j + 1] = norm[norm2o + 2 * n1 - n2 + j + 1]
				end
			end
		end
		ctx.tfChange = tfRes[i + 1]
		local scr, scrOff = scratch, scratchOff
		if last then
			scr = nil
		end
		local effLow = -1
		local xcm, ycm
		if lowbandOffset ~= 0 and (spread ~= SPREAD_AGGRESSIVE or B > 1 or ctx.tfChange < 0) then
			effLow = max(0, M * eb(lowbandOffset) - normOffset - N)
			local foldStart = lowbandOffset
			repeat
				foldStart -= 1
			until not (M * eb(foldStart) > effLow + normOffset)
			local foldEnd = lowbandOffset - 1
			repeat
				foldEnd += 1
			until not (foldEnd < i and M * eb(foldEnd) < effLow + normOffset + N)
			xcm, ycm = 0, 0
			local fi = foldStart
			repeat
				xcm = bor(xcm, collapse[fi * C + 1])
				ycm = bor(ycm, collapse[fi * C + C])
				fi += 1
			until fi >= foldEnd
		else
			xcm = lshift(1, B) - 1
			ycm = xcm
		end
		if dualStereo and i == intensity then
			dualStereo = false
			for j = 1, M * eb(i) - normOffset do
				norm[j] = 0.5 * (norm[j] + norm[norm2o + j])
			end
		end
		local lowOut, lowOutOff = nil, 0
		if not last then
			lowOut, lowOutOff = norm, M * eb(i) - normOffset
		end
		if dualStereo then
			local lowX, lowXo = nil, 0
			if effLow ~= -1 then
				lowX, lowXo = norm, effLow
			end
			xcm = quantBand(ctx, Xa, xo, N, b // 2, B, lowX, lowXo, LM, lowOut, lowOutOff, 1, scr, scrOff, xcm)
			local lowY, lowYo = nil, 0
			if effLow ~= -1 then
				lowY, lowYo = norm, norm2o + effLow
			end
			local lowOut2 = nil
			if not last then
				lowOut2 = norm
			end
			ycm = quantBand(ctx, Ya, yo, N, b // 2, B, lowY, lowYo, LM, lowOut2, norm2o + M * eb(i) - normOffset, 1, scr, scrOff, ycm)
		else
			local lowX, lowXo = nil, 0
			if effLow ~= -1 then
				lowX, lowXo = norm, effLow
			end
			if Ya then
				xcm = quantBandStereo(ctx, Xa, xo, Ya, yo, N, b, B, lowX, lowXo, LM, lowOut, lowOutOff, scr, scrOff, bor(xcm, ycm))
			else
				xcm = quantBand(ctx, Xa, xo, N, b, B, lowX, lowXo, LM, lowOut, lowOutOff, 1, scr, scrOff, bor(xcm, ycm))
			end
			ycm = xcm
		end
		collapse[i * C + 1] = band(xcm, 0xFF)
		collapse[i * C + C] = band(ycm, 0xFF)
		balance += pulses[i + 1] + tell
		updateLowband = b > N * 8
		ctx.avoidSplitNoise = false
	end
	st.rng = ctx.seed
end

---------------------------------------------------------------------------------------------- energy
local function laplaceDecode(ec, fs, decay)
	local val = 0
	local fm = ec:decodeBin(15)
	local fl = 0
	if fm >= fs then
		val += 1
		fl = fs
		fs = (((32768 - 32 - fs) * (16384 - decay)) // 32768) + 1
		while fs > 1 and fm >= fl + 2 * fs do
			fs *= 2
			fl += fs
			fs = ((fs - 2) * decay) // 32768
			fs += 1
			val += 1
		end
		if fs <= 1 then
			local di = (fm - fl) // 2
			val += di
			fl += 2 * di
		end
		if fm < fl + fs then
			val = -val
		else
			fl += fs
		end
	end
	ec:update(fl, min(fl + fs, 32768), 32768)
	return val
end

local function unquantCoarseEnergy(start, endBand, oldE, intra, ec, C, LM)
	local probBase = (LM * 2 + (intra and 1 or 0)) * 42 -- e_prob_model[LM][intra]
	local prev = { 0, 0 }
	local coef, beta
	if intra then
		coef, beta = 0, BETA_INTRA
	else
		coef, beta = PRED_COEF[LM + 1], BETA_COEF[LM + 1]
	end
	local budget = ec.storage * 8
	local PM = T.eProbModel
	for i = start, endBand - 1 do
		for c = 0, C - 1 do
			local tell = ec:tell()
			local qi
			if budget - tell >= 15 then
				local pi = 2 * min(i, 20)
				qi = laplaceDecode(ec, PM[probBase + pi + 1] * 128, PM[probBase + pi + 2] * 64)
			elseif budget - tell >= 2 then
				qi = ec:icdf(SMALL_ENERGY_ICDF, 2)
				qi = bit32.bxor(rshift(qi, 1), -band(qi, 1))
				if qi >= 2147483648 then
					qi -= 4294967296
				end
			elseif budget - tell >= 1 then
				qi = -ec:bitLogp(1)
			else
				qi = -1
			end
			local idx = i + c * NB + 1
			local q = qi
			oldE[idx] = max(-9, oldE[idx])
			local tmp = coef * oldE[idx] + prev[c + 1] + q
			oldE[idx] = tmp
			prev[c + 1] = prev[c + 1] + q - beta * q
		end
	end
end

local function unquantFineEnergy(start, endBand, oldE, fineQuant, ec, C)
	for i = start, endBand - 1 do
		local extra = fineQuant[i + 1]
		if extra > 0 and ec:tell() + C * extra <= ec.storage * 8 then
			for c = 0, C - 1 do
				local q2 = ec:bits(extra)
				local offset = (q2 + 0.5) / (2 ^ extra) - 0.5
				oldE[i + c * NB + 1] += offset
			end
		end
	end
end

local function unquantEnergyFinalise(start, endBand, oldE, fineQuant, finePriority, bitsLeft, ec, C)
	for prio = 0, 1 do
		local i = start
		while i < endBand and bitsLeft >= C do
			if not (fineQuant[i + 1] >= MAX_FINE_BITS or finePriority[i + 1] ~= prio) then
				for c = 0, C - 1 do
					local q2 = ec:bits(1)
					local offset = (q2 - 0.5) * (2 ^ (14 - fineQuant[i + 1] - 1)) / 16384
					oldE[i + c * NB + 1] += offset
					bitsLeft -= 1
				end
			end
			i += 1
		end
	end
end

---------------------------------------------------------------------------------------------- bit allocation
local function initCaps(cap, LM, C)
	for i = 0, NB - 1 do
		local N = (eb(i + 1) - eb(i)) * (2 ^ LM)
		cap[i + 1] = ((CACHE_CAPS[NB * (2 * LM + C - 1) + i + 1] + 64) * C * N) // 4
	end
end

local function interpBits2pulses(start, endBand, skipStart, bits1, bits2, thresh, cap, total, skipRsv, intensityRsv,
	dualStereoRsv, bits, ebits, finePriority, C, LM, ec)
	local allocFloor = C * 8
	local stereo = C > 1 and 1 or 0
	local logM = LM * 8
	local lo, hi = 0, 64
	local psum
	for _ = 1, 6 do
		local mid = (lo + hi) // 2
		psum = 0
		local done = false
		for j = endBand - 1, start, -1 do
			local tmp = bits1[j + 1] + ((mid * bits2[j + 1]) // 64)
			if tmp >= thresh[j + 1] or done then
				done = true
				psum += min(tmp, cap[j + 1])
			elseif tmp >= allocFloor then
				psum += allocFloor
			end
		end
		if psum > total then
			hi = mid
		else
			lo = mid
		end
	end
	psum = 0
	local done = false
	for j = endBand - 1, start, -1 do
		local tmp = bits1[j + 1] + ((lo * bits2[j + 1]) // 64)
		if tmp < thresh[j + 1] and not done then
			if tmp >= allocFloor then
				tmp = allocFloor
			else
				tmp = 0
			end
		else
			done = true
		end
		tmp = min(tmp, cap[j + 1])
		bits[j + 1] = tmp
		psum += tmp
	end
	local codedBands = endBand
	while true do
		local j = codedBands - 1
		if j <= skipStart then
			total += skipRsv
			break
		end
		local left = total - psum
		local width = eb(codedBands) - eb(start)
		local percoeff = left // width
		left -= width * percoeff
		local rem = max(left - (eb(j) - eb(start)), 0)
		local bandWidth = eb(codedBands) - eb(j)
		local bandBits = bits[j + 1] + percoeff * bandWidth + rem
		if bandBits >= max(thresh[j + 1], allocFloor + 8) then
			if ec:bitLogp(1) ~= 0 then
				break
			end
			psum += 8
			bandBits -= 8
		end
		psum -= bits[j + 1] + intensityRsv
		if intensityRsv > 0 then
			intensityRsv = LOG2_FRAC[j - start + 1]
		end
		psum += intensityRsv
		if bandBits >= allocFloor then
			psum += allocFloor
			bits[j + 1] = allocFloor
		else
			bits[j + 1] = 0
		end
		codedBands -= 1
	end
	local intensity
	if intensityRsv > 0 then
		intensity = start + ec:uint(codedBands + 1 - start)
	else
		intensity = 0
	end
	if intensity <= start then
		total += dualStereoRsv
		dualStereoRsv = 0
	end
	local dualStereo = false
	if dualStereoRsv > 0 then
		dualStereo = ec:bitLogp(1) ~= 0
	end
	local left = total - psum
	local width = eb(codedBands) - eb(start)
	local percoeff = left // width
	left -= width * percoeff
	for j = start, codedBands - 1 do
		bits[j + 1] += percoeff * (eb(j + 1) - eb(j))
	end
	for j = start, codedBands - 1 do
		local tmp = min(left, eb(j + 1) - eb(j))
		bits[j + 1] += tmp
		left -= tmp
	end
	local balance = 0
	local j = start
	while j < codedBands do
		local N0 = eb(j + 1) - eb(j)
		local N = N0 * (2 ^ LM)
		local bit = bits[j + 1] + balance
		local excess
		if N > 1 then
			excess = max(bit - cap[j + 1], 0)
			bits[j + 1] = bit - excess
			local den = C * N + ((C == 2 and N > 2 and not dualStereo and j < intensity) and 1 or 0)
			local NClogN = den * (LOGN[j + 1] + logM)
			local offset = (NClogN // 2) - den * FINE_OFFSET
			if N == 2 then
				offset += (den * 8) // 4
			end
			if bits[j + 1] + offset < den * 2 * 8 then
				offset += NClogN // 4
			elseif bits[j + 1] + offset < den * 3 * 8 then
				offset += NClogN // 8
			end
			local e = max(0, bits[j + 1] + offset + den * 4)
			e = (e // den) // 8
			if C * e > (bits[j + 1] // 8) then
				e = (bits[j + 1] // (2 ^ stereo)) // 8
			end
			e = min(e, MAX_FINE_BITS)
			ebits[j + 1] = e
			finePriority[j + 1] = (e * den * 8 >= bits[j + 1] + offset) and 1 or 0
			bits[j + 1] -= C * e * 8
		else
			excess = max(0, bit - C * 8)
			bits[j + 1] = bit - excess
			ebits[j + 1] = 0
			finePriority[j + 1] = 1
		end
		if excess > 0 then
			local extraFine = min(excess // (2 ^ (stereo + 3)), MAX_FINE_BITS - ebits[j + 1])
			ebits[j + 1] += extraFine
			local extraBits = extraFine * C * 8
			finePriority[j + 1] = (extraBits >= excess - balance) and 1 or 0
			excess -= extraBits
		end
		balance = excess
		j += 1
	end
	for jj = j, endBand - 1 do
		ebits[jj + 1] = (bits[jj + 1] // (2 ^ stereo)) // 8
		bits[jj + 1] = 0
		finePriority[jj + 1] = ebits[jj + 1] < 1 and 1 or 0
	end
	return codedBands, balance, intensity, dualStereo
end

local function computeAllocation(start, endBand, offsets, cap, allocTrim, total, pulses, ebits, finePriority, C, LM, ec)
	total = max(total, 0)
	local skipStart = start
	local skipRsv = total >= 8 and 8 or 0
	total -= skipRsv
	local intensityRsv, dualStereoRsv = 0, 0
	if C == 2 then
		intensityRsv = LOG2_FRAC[endBand - start + 1]
		if intensityRsv > total then
			intensityRsv = 0
		else
			total -= intensityRsv
			dualStereoRsv = total >= 8 and 8 or 0
			total -= dualStereoRsv
		end
	end
	local bits1, bits2, thresh, trimOffset = {}, {}, {}, {}
	for j = start, endBand - 1 do
		local w = eb(j + 1) - eb(j)
		thresh[j + 1] = max(C * 8, (3 * w * (2 ^ LM) * 8) // 16)
		trimOffset[j + 1] = (C * w * (allocTrim - 5 - LM) * (endBand - j - 1) * (2 ^ (LM + 3))) // 64
		if w * (2 ^ LM) == 1 then
			trimOffset[j + 1] -= C * 8
		end
	end
	local lo, hi = 1, NB_ALLOC - 1
	repeat
		local done = false
		local psum = 0
		local mid = (lo + hi) // 2
		for j = endBand - 1, start, -1 do
			local N = eb(j + 1) - eb(j)
			local bitsj = (C * N * ALLOC[mid * NB + j + 1] * (2 ^ LM)) // 4
			if bitsj > 0 then
				bitsj = max(0, bitsj + trimOffset[j + 1])
			end
			bitsj += offsets[j + 1]
			if bitsj >= thresh[j + 1] or done then
				done = true
				psum += min(bitsj, cap[j + 1])
			elseif bitsj >= C * 8 then
				psum += C * 8
			end
		end
		if psum > total then
			hi = mid - 1
		else
			lo = mid + 1
		end
	until lo > hi
	hi = lo
	lo -= 1
	for j = start, endBand - 1 do
		local N = eb(j + 1) - eb(j)
		local bits1j = (C * N * ALLOC[lo * NB + j + 1] * (2 ^ LM)) // 4
		local bits2j
		if hi >= NB_ALLOC then
			bits2j = cap[j + 1]
		else
			bits2j = (C * N * ALLOC[hi * NB + j + 1] * (2 ^ LM)) // 4
		end
		if bits1j > 0 then
			bits1j = max(0, bits1j + trimOffset[j + 1])
		end
		if bits2j > 0 then
			bits2j = max(0, bits2j + trimOffset[j + 1])
		end
		if lo > 0 then
			bits1j += offsets[j + 1]
		end
		bits2j += offsets[j + 1]
		if offsets[j + 1] > 0 then
			skipStart = j
		end
		bits2j = max(0, bits2j - bits1j)
		bits1[j + 1] = bits1j
		bits2[j + 1] = bits2j
	end
	return interpBits2pulses(start, endBand, skipStart, bits1, bits2, thresh, cap, total, skipRsv, intensityRsv, dualStereoRsv,
		pulses, ebits, finePriority, C, LM, ec)
end

local function tfDecode(start, endBand, isTransient, tfRes, LM, ec)
	local budget = ec.storage * 8
	local tell = ec:tell()
	local logp = isTransient and 2 or 4
	local tfSelectRsv = (LM > 0 and tell + logp + 1 <= budget) and 1 or 0
	budget -= tfSelectRsv
	local tfChanged, curr = 0, 0
	for i = start, endBand - 1 do
		if tell + logp <= budget then
			curr = bit32.bxor(curr, ec:bitLogp(logp))
			tell = ec:tell()
			tfChanged = bor(tfChanged, curr)
		end
		tfRes[i + 1] = curr
		logp = isTransient and 4 or 5
	end
	local tfSelect = 0
	local row = TF_SELECT[LM + 1]
	local t4 = isTransient and 4 or 0
	if tfSelectRsv ~= 0 and row[t4 + tfChanged + 1] ~= row[t4 + 2 + tfChanged + 1] then
		tfSelect = ec:bitLogp(1)
	end
	for i = start, endBand - 1 do
		tfRes[i + 1] = row[t4 + 2 * tfSelect + tfRes[i + 1] + 1]
	end
end

local function antiCollapse(X, collapse, LM, C, size, start, endBand, logE, prev1logE, prev2logE, pulses, seed)
	for i = start, endBand - 1 do
		local N0 = eb(i + 1) - eb(i)
		local depth = ((1 + pulses[i + 1]) // N0) // (2 ^ LM)
		local thresh = 0.5 * exp(0.6931471805599453 * (-0.125 * depth))
		local sqrt1 = 1 / sqrt(N0 * (2 ^ LM))
		for c = 0, C - 1 do
			local prev1 = prev1logE[c * NB + i + 1]
			local prev2 = prev2logE[c * NB + i + 1]
			if C == 1 then
				prev1 = max(prev1, prev1logE[NB + i + 1])
				prev2 = max(prev2, prev2logE[NB + i + 1])
			end
			local Ediff = logE[c * NB + i + 1] - min(prev1, prev2)
			Ediff = max(0, Ediff)
			local r = 2 * exp(0.6931471805599453 * (-Ediff))
			if LM == 3 then
				r *= 1.41421356
			end
			r = min(thresh, r)
			r = r * sqrt1
			local xo = c * size + eb(i) * (2 ^ LM)
			local renorm = false
			for k = 0, (2 ^ LM) - 1 do
				if band(collapse[i * C + c + 1], lshift(1, k)) == 0 then
					for j = 0, N0 - 1 do
						seed = lcg(seed)
						X[xo + j * (2 ^ LM) + k + 1] = band(seed, 0x8000) ~= 0 and r or -r
					end
					renorm = true
				end
			end
			if renorm then
				renormaliseVector(X, xo, N0 * (2 ^ LM), 1)
			end
		end
	end
end

---------------------------------------------------------------------------------------------- synthesis
-- complex FFT (forward, unscaled) of sizes 60 / 120 / 240 / 480, in natural order, on interleaved re/im
local fftPlans = {}
local function fftPlan(n)
	local p = fftPlans[n]
	if p then
		return p
	end
	local factors = {}
	local m = n
	for _, r in ipairs({ 4, 2, 3, 5 }) do
		while m % r == 0 do
			table.insert(factors, r)
			m //= r
		end
	end
	-- digit-reversal permutation for decimation in time with these radices (first factor = innermost stage)
	local perm = table.create(n, 0)
	for i = 0, n - 1 do
		local rev, x, span = 0, i, n
		for _, r in ipairs(factors) do
			span //= r
			rev += (x % r) * span
			x //= r
		end
		perm[i + 1] = rev
	end
	local tw = { re = {}, im = {} }
	for k = 0, n - 1 do
		tw.re[k + 1] = cos(-2 * math.pi * k / n)
		tw.im[k + 1] = math.sin(-2 * math.pi * k / n)
	end
	p = { n = n, factors = factors, perm = perm, tw = tw, re = table.create(n, 0), im = table.create(n, 0) }
	fftPlans[n] = p
	return p
end

local function fft(plan, data, base)
	-- data[base + 2k + 1] = re, data[base + 2k + 2] = im (k = 0..n-1)
	local n = plan.n
	local re, im, perm = plan.re, plan.im, plan.perm
	for i = 1, n do
		local q = perm[i] + 1 -- where input i goes (mixed-radix digit reversal)
		re[q] = data[base + 2 * i - 1]
		im[q] = data[base + 2 * i]
	end
	local twr, twi = plan.tw.re, plan.tw.im
	local L = 1
	local factors = plan.factors
	for f = #factors, 1, -1 do
		local r = factors[f]
		local size = L * r
		local tstep = n // size
		for blk = 0, n - 1, size do
			for j = 0, L - 1 do
				-- inputs blk + j + q*L, twiddled by W_size^(j*q)
				local i0 = blk + j + 1
				if r == 2 then
					local i1 = i0 + L
					local t = (j * tstep) % n + 1
					local wr, wi = twr[t], twi[t]
					local xr, xi = re[i1] * wr - im[i1] * wi, re[i1] * wi + im[i1] * wr
					local ar, ai = re[i0], im[i0]
					re[i0], im[i0] = ar + xr, ai + xi
					re[i1], im[i1] = ar - xr, ai - xi
				elseif r == 4 then
					local i1, i2, i3 = i0 + L, i0 + 2 * L, i0 + 3 * L
					local t1 = (j * tstep) % n + 1
					local t2 = (2 * j * tstep) % n + 1
					local t3 = (3 * j * tstep) % n + 1
					local ar, ai = re[i0], im[i0]
					local br, bi = re[i1] * twr[t1] - im[i1] * twi[t1], re[i1] * twi[t1] + im[i1] * twr[t1]
					local cr, ci = re[i2] * twr[t2] - im[i2] * twi[t2], re[i2] * twi[t2] + im[i2] * twr[t2]
					local dr, di = re[i3] * twr[t3] - im[i3] * twi[t3], re[i3] * twi[t3] + im[i3] * twr[t3]
					local s0r, s0i = ar + cr, ai + ci
					local s1r, s1i = ar - cr, ai - ci
					local s2r, s2i = br + dr, bi + di
					local s3r, s3i = br - dr, bi - di
					re[i0], im[i0] = s0r + s2r, s0i + s2i
					re[i2], im[i2] = s0r - s2r, s0i - s2i
					-- forward: multiply s3 by -i
					re[i1], im[i1] = s1r + s3i, s1i - s3r
					re[i3], im[i3] = s1r - s3i, s1i + s3r
				else
					-- general radix (3 or 5): naive r-point DFT of the twiddled inputs
					local xr, xi = {}, {}
					for q = 0, r - 1 do
						local idx = i0 + q * L
						local t = (j * q * tstep) % n + 1
						xr[q + 1] = re[idx] * twr[t] - im[idx] * twi[t]
						xi[q + 1] = re[idx] * twi[t] + im[idx] * twr[t]
					end
					local step = n // r
					for k = 0, r - 1 do
						local sr, si = 0, 0
						for q = 0, r - 1 do
							local t = (k * q * step) % n + 1
							sr += xr[q + 1] * twr[t] - xi[q + 1] * twi[t]
							si += xr[q + 1] * twi[t] + xi[q + 1] * twr[t]
						end
						re[i0 + k * L], im[i0 + k * L] = sr, si
					end
				end
			end
		end
		L = size
	end
	for i = 1, n do
		data[base + 2 * (i - 1) + 1] = re[i]
		data[base + 2 * (i - 1) + 2] = im[i]
	end
end

local trigTables = {}
local function trigFor(N)
	local t = trigTables[N]
	if not t then
		t = {}
		local N4 = N // 4
		for i = 0, N4 - 1 do
			t[2 * i + 1] = -math.sin(2 * math.pi * (i + 0.125) / N)
			t[2 * i + 2] = cos(2 * math.pi * (i + 0.125) / N)
		end
		trigTables[N] = t
	end
	return t
end

-- inverse MDCT of N/2 coefficients in[inOff + k*stride] into out[outOff ..] (overlap windowed TDAC)
local function mdctBackward(inA, inOff, out, outOff, shift, stride)
	local N = 1920 // (2 ^ shift)
	local N2 = N // 2
	local N4 = N // 4
	local trig = trigFor(N)
	local plan = fftPlan(N4)
	local ypo = outOff + OVERLAP // 2 -- yp = out + overlap/2 (0-based offset)
	-- pre-rotation into natural order (the FFT here takes natural-order input)
	local xp1 = inOff
	local xp2 = inOff + stride * (N2 - 1)
	for i = 0, N4 - 1 do
		local x1 = inA[xp1 + 1]
		local x2 = inA[xp2 + 1]
		local t0, t1 = trig[2 * i + 1], trig[2 * i + 2]
		local yr = x2 * t1 + x1 * t0
		local yi = x1 * t1 - x2 * t0
		out[ypo + 2 * i + 2] = yr
		out[ypo + 2 * i + 1] = yi
		xp1 += 2 * stride
		xp2 -= 2 * stride
	end
	fft(plan, out, ypo)
	-- post-rotation
	local yp0 = ypo
	local yp1 = ypo + N2 - 2
	for i = 0, ((N4 + 1) // 2) - 1 do
		local re = out[yp0 + 2]
		local im = out[yp0 + 1]
		local t0 = trig[2 * i + 1]
		local t1 = trig[2 * i + 2]
		local yr = re * t1 + im * t0
		local yi = re * t0 - im * t1
		re = out[yp1 + 2]
		im = out[yp1 + 1]
		out[yp0 + 1] = yr
		out[yp1 + 2] = yi
		t0 = trig[2 * (N4 - i - 1) + 1]
		t1 = trig[2 * (N4 - i - 1) + 2]
		yr = re * t1 + im * t0
		yi = re * t0 - im * t1
		out[yp1 + 1] = yr
		out[yp0 + 2] = yi
		yp0 += 2
		yp1 -= 2
	end
	-- mirror on both sides for TDAC
	local xp = outOff + OVERLAP - 1
	local yp = outOff
	for i = 0, OVERLAP // 2 - 1 do
		local x1 = out[xp + 1]
		local x2 = out[yp + 1]
		local w1 = WINDOW[i + 1]
		local w2 = WINDOW[OVERLAP - i]
		out[yp + 1] = x2 * w2 - x1 * w1
		out[xp + 1] = x2 * w1 + x1 * w2
		yp += 1
		xp -= 1
	end
end

local function denormaliseBands(X, xOff, freq, bandLogE, eOff, start, endBand, M, silence)
	local N = M * SHORT_MDCT
	local bound = M * eb(endBand)
	if silence then
		bound = 0
		start, endBand = 0, 0
	end
	local f = 0
	if start ~= 0 then
		for i = 1, M * eb(start) do
			freq[i] = 0
		end
	end
	f = M * eb(start)
	local x = xOff + M * eb(start)
	for i = start, endBand - 1 do
		local j = M * eb(i)
		local bandEnd = M * eb(i + 1)
		local lg = bandLogE[eOff + i + 1] + EMEANS[i + 1]
		local g = exp(0.6931471805599453 * min(32, lg))
		while j < bandEnd do
			f += 1
			x += 1
			freq[f] = X[x] * g
			j += 1
		end
	end
	for i = bound + 1, N do
		freq[i] = 0
	end
end

local freqBuf = table.create(1920, 0)
local freqBuf2 = table.create(1920, 0)
local function celtSynthesis(st, X, outSyn, oldBandE, start, effEnd, C, CC, isTransient, LM, silence)
	local mem = st.mem
	local M = 2 ^ LM
	local N = M * SHORT_MDCT
	local B, NBl, shift
	if isTransient then
		B, NBl, shift = M, SHORT_MDCT, MAXLM
	else
		B, NBl, shift = 1, SHORT_MDCT * M, MAXLM - LM
	end
	local freq = freqBuf
	if CC == 2 and C == 1 then
		denormaliseBands(X, 0, freq, oldBandE, 0, start, effEnd, M, silence)
		-- freq2 = out_syn[1] + overlap/2: use a scratch copy
		local freq2 = freqBuf2
		for i = 1, N do
			freq2[i] = freq[i]
		end
		for b = 0, B - 1 do
			mdctBackward(freq2, b, mem[1], outSyn + NBl * b, shift, B)
		end
		for b = 0, B - 1 do
			mdctBackward(freq, b, mem[2], outSyn + NBl * b, shift, B)
		end
	elseif CC == 1 and C == 2 then
		local freq2 = freqBuf2
		denormaliseBands(X, 0, freq, oldBandE, 0, start, effEnd, M, silence)
		denormaliseBands(X, N, freq2, oldBandE, NB, start, effEnd, M, silence)
		for i = 1, N do
			freq[i] = 0.5 * freq[i] + 0.5 * freq2[i]
		end
		for b = 0, B - 1 do
			mdctBackward(freq, b, mem[1], outSyn + NBl * b, shift, B)
		end
	else
		for c = 0, CC - 1 do
			denormaliseBands(X, c * N, freq, oldBandE, c * NB, start, effEnd, M, silence)
			for b = 0, B - 1 do
				mdctBackward(freq, b, mem[c + 1], outSyn + NBl * b, shift, B)
			end
		end
	end
end

-- comb (pitch post-) filter: y[yo + i] from x[xo + i] (0-based offsets), i = 0 .. N-1. With y == x and yo == xo it
-- runs in place, where x[i - T] for i >= T is already filtered output (the post-filter is recursive).
local function combFilterXY(y, yo, x, xo, T0, T1, N, g0, g1, tapset0, tapset1, overlap)
	local xb, yb = xo + 1, yo + 1 -- x[xb + i] is x_i
	if g0 == 0 and g1 == 0 then
		if x ~= y or xo ~= yo then
			for i = 0, N - 1 do
				y[yb + i] = x[xb + i]
			end
		end
		return
	end
	T0 = max(T0, COMBFILTER_MINPERIOD)
	T1 = max(T1, COMBFILTER_MINPERIOD)
	local G0, G1 = COMB_GAINS[tapset0 + 1], COMB_GAINS[tapset1 + 1]
	local g00, g01, g02 = g0 * G0[1], g0 * G0[2], g0 * G0[3]
	local g10, g11, g12 = g1 * G1[1], g1 * G1[2], g1 * G1[3]
	local x1 = x[xb - T1 + 1]
	local x2 = x[xb - T1]
	local x3 = x[xb - T1 - 1]
	local x4 = x[xb - T1 - 2]
	if g0 == g1 and T0 == T1 and tapset0 == tapset1 then
		overlap = 0
	end
	local i = 0
	while i < overlap do
		local x0 = x[xb + i - T1 + 2]
		local w = WINDOW[i + 1]
		local f = w * w
		local of = 1 - f
		y[yb + i] = x[xb + i] + of * g00 * x[xb + i - T0] + of * g01 * (x[xb + i - T0 + 1] + x[xb + i - T0 - 1])
			+ of * g02 * (x[xb + i - T0 + 2] + x[xb + i - T0 - 2])
			+ f * g10 * x2 + f * g11 * (x1 + x3) + f * g12 * (x0 + x4)
		x4 = x3
		x3 = x2
		x2 = x1
		x1 = x0
		i += 1
	end
	if g1 == 0 then
		if x ~= y or xo ~= yo then
			for k = i, N - 1 do
				y[yb + k] = x[xb + k]
			end
		end
		return
	end
	-- comb_filter_const
	for k = i, N - 1 do
		y[yb + k] = x[xb + k] + g10 * x[xb + k - T1] + g11 * (x[xb + k - T1 + 1] + x[xb + k - T1 - 1])
			+ g12 * (x[xb + k - T1 + 2] + x[xb + k - T1 - 2])
	end
end

local function combFilter(arr, o, T0, T1, N, g0, g1, tapset0, tapset1, overlap)
	combFilterXY(arr, o, arr, o, T0, T1, N, g0, g1, tapset0, tapset1, overlap)
end

---------------------------------------------------------------------------------------------- packet loss concealment
local FRAME_NONE, FRAME_NORMAL, FRAME_PLC_NOISE, FRAME_PLC_PERIODIC = 0, 1, 2, 3
local PLC_PITCH_LAG_MAX, PLC_PITCH_LAG_MIN = 720, 100
local LPC_ORDER = 24
local MAX_PERIOD = 1024

local acScratch = table.create(MAX_PERIOD, 0)
-- ac[k + 1] = sum over i of x_i * x_(i-k), k = 0..lag, for x_i = x[xo + i + 1] (i < n), windowed at both ends
local function autocorr(x, xo, ac, window, overlap, lag, n)
	local xx = acScratch
	for i = 1, n do
		xx[i] = x[xo + i]
	end
	if overlap > 0 then
		for i = 1, overlap do
			local w = window[i]
			xx[i] = x[xo + i] * w
			xx[n - i + 1] = x[xo + n - i + 1] * w
		end
	end
	for k = 0, lag do
		local d = 0
		for i = k + 1, n do
			d += xx[i] * xx[i - k]
		end
		ac[k + 1] = d
	end
end

local function celtLpc(lpc, lo, ac, p)
	local err = ac[1]
	for i = 1, p do
		lpc[lo + i] = 0
	end
	if ac[1] > 1e-10 then
		for i = 0, p - 1 do
			local rr = 0
			for j = 0, i - 1 do
				rr += lpc[lo + j + 1] * ac[i - j + 1]
			end
			rr += ac[i + 2]
			local r = -rr / err
			lpc[lo + i + 1] = r
			for j = 0, (i + 1) // 2 - 1 do
				local t1 = lpc[lo + j + 1]
				local t2 = lpc[lo + i - j]
				lpc[lo + j + 1] = t1 + r * t2
				lpc[lo + i - j] = t2 + r * t1
			end
			err -= r * r * err
			if err <= 0.001 * ac[1] then
				break
			end
		end
	end
end

local ac5, lpc4, lpc5 = table.create(5, 0), table.create(4, 0), table.create(5, 0)
local function pitchDownsample(mem, C, xlp, len)
	for c = 1, C do
		local x = mem[c]
		if c == 1 then
			xlp[1] = 0.25 * x[2] + 0.5 * x[1]
			for i = 1, len - 1 do
				xlp[i + 1] = 0.25 * x[2 * i] + 0.25 * x[2 * i + 2] + 0.5 * x[2 * i + 1]
			end
		else
			xlp[1] += 0.25 * x[2] + 0.5 * x[1]
			for i = 1, len - 1 do
				xlp[i + 1] += 0.25 * x[2 * i] + 0.25 * x[2 * i + 2] + 0.5 * x[2 * i + 1]
			end
		end
	end
	autocorr(xlp, 0, ac5, nil, 0, 4, len)
	ac5[1] *= 1.0001
	for i = 1, 4 do
		ac5[i + 1] -= ac5[i + 1] * (0.008 * i) * (0.008 * i)
	end
	celtLpc(lpc4, 0, ac5, 4)
	local tmp = 1
	for i = 1, 4 do
		tmp *= 0.9
		lpc4[i] *= tmp
	end
	local c1 = 0.8
	lpc5[1] = lpc4[1] + 0.8
	lpc5[2] = lpc4[2] + c1 * lpc4[1]
	lpc5[3] = lpc4[3] + c1 * lpc4[2]
	lpc5[4] = lpc4[4] + c1 * lpc4[3]
	lpc5[5] = c1 * lpc4[4]
	local m0, m1, m2, m3, m4 = 0, 0, 0, 0, 0
	for i = 1, len do
		local xi = xlp[i]
		local sum = xi + lpc5[1] * m0 + lpc5[2] * m1 + lpc5[3] * m2 + lpc5[4] * m3 + lpc5[5] * m4
		m4, m3, m2, m1, m0 = m3, m2, m1, m0, xi
		xlp[i] = sum
	end
end

local function findBestPitch(xcorr, y, yo, len, maxPitch)
	local Syy = 1
	local bn0, bn1, bd0, bd1, bp0, bp1 = -1, -1, 0, 0, 0, 1
	for j = 1, len do
		Syy += y[yo + j] * y[yo + j]
	end
	for i = 0, maxPitch - 1 do
		local xc = xcorr[i + 1]
		if xc > 0 then
			local x16 = xc * 1e-12
			local num = x16 * x16
			if num * bd1 > bn1 * Syy then
				if num * bd0 > bn0 * Syy then
					bn1, bd1, bp1 = bn0, bd0, bp0
					bn0, bd0, bp0 = num, Syy, i
				else
					bn1, bd1, bp1 = num, Syy, i
				end
			end
		end
		local a, b = y[yo + i + len + 1], y[yo + i + 1]
		Syy += a * a - b * b
		Syy = max(1, Syy)
	end
	return bp0, bp1
end

local xlp4, ylp4, xcorrBuf = table.create(512, 0), table.create(512, 0), table.create(512, 0)
local function pitchSearch(xlp, xo, y, yo, len, maxPitch)
	local lag = len + maxPitch
	local n4, l4 = len // 4, lag // 4
	for j = 0, n4 - 1 do
		xlp4[j + 1] = xlp[xo + 2 * j + 1]
	end
	for j = 0, l4 - 1 do
		ylp4[j + 1] = y[yo + 2 * j + 1]
	end
	local xcorr = xcorrBuf
	for i = 0, maxPitch // 4 - 1 do
		local s = 0
		for j = 1, n4 do
			s += xlp4[j] * ylp4[i + j]
		end
		xcorr[i + 1] = s
	end
	local b0, b1 = findBestPitch(xcorr, ylp4, 0, n4, maxPitch // 4)
	local half = len // 2
	for i = 0, maxPitch // 2 - 1 do
		xcorr[i + 1] = 0
		if abs(i - 2 * b0) <= 2 or abs(i - 2 * b1) <= 2 then
			local s = 0
			for j = 1, half do
				s += xlp[xo + j] * y[yo + i + j]
			end
			xcorr[i + 1] = max(-1, s)
		end
	end
	b0, b1 = findBestPitch(xcorr, y, yo, half, maxPitch // 2)
	local offset = 0
	if b0 > 0 and b0 < maxPitch // 2 - 1 then
		local a, b, c = xcorr[b0], xcorr[b0 + 1], xcorr[b0 + 2]
		if (c - a) > 0.7 * (b - a) then
			offset = 1
		elseif (a - c) > 0.7 * (b - c) then
			offset = -1
		end
	end
	return 2 * b0 - offset
end

local lpPitchBuf = table.create(BUF // 2, 0)
local function plcPitchSearch(st)
	pitchDownsample(st.mem, st.channels, lpPitchBuf, BUF // 2)
	local p = pitchSearch(lpPitchBuf, PLC_PITCH_LAG_MAX // 2, lpPitchBuf, 0, BUF - PLC_PITCH_LAG_MAX,
		PLC_PITCH_LAG_MAX - PLC_PITCH_LAG_MIN)
	return PLC_PITCH_LAG_MAX - p
end

local etmp = table.create(OVERLAP, 0)
local function prefilterAndFold(st, N)
	for c = 1, st.channels do
		local mem = st.mem[c]
		combFilterXY(etmp, 0, mem, BUF - N, st.postfilterPeriodOld, st.postfilterPeriod, OVERLAP,
			-st.postfilterGainOld, -st.postfilterGain, st.postfilterTapsetOld, st.postfilterTapset, 0)
		for i = 0, OVERLAP // 2 - 1 do
			mem[BUF - N + i + 1] = WINDOW[i + 1] * etmp[OVERLAP - i] + WINDOW[OVERLAP - i] * etmp[i + 1]
		end
	end
end

local sigBuf = table.create(2 * PLC_PITCH_LAG_MAX + LPC_ORDER, 0)
local excBuf = table.create(2 * PLC_PITCH_LAG_MAX, 0)
local oldOverlap = table.create(OVERLAP // 2, 0)
local lpcMem = table.create(LPC_ORDER, 0)
local acPlc = table.create(LPC_ORDER + 1, 0)

local function decodeLost(st, N, LM)
	local C = st.channels
	local outSyn = BUF - N
	local oldBandE, bgE = st.oldBandE, st.backgroundLogE
	local lossDuration = st.lossDuration
	local start = st.start
	local frameType = FRAME_PLC_PERIODIC
	if st.plcDuration >= 40 or start ~= 0 or st.skipPlc then
		frameType = FRAME_PLC_NOISE
	end
	if frameType == FRAME_PLC_NOISE then
		local endBand = st.endBand
		local effEnd = max(start, min(endBand, NB))
		for c = 1, C do
			table.move(st.mem[c], N + 1, BUF + OVERLAP, 1)
		end
		if st.prefilterAndFold then
			prefilterAndFold(st, N)
		end
		local decay = (2 ^ LM) * 0.0625
		if st.lastFrameType ~= FRAME_PLC_NOISE then
			decay += max(1, min(160, lossDuration) * 0.0625)
		end
		for c = 0, C - 1 do
			for i = start, endBand - 1 do
				local k = c * NB + i + 1
				oldBandE[k] = max(bgE[k], oldBandE[k] - decay)
			end
		end
		local seed = st.rng
		local X = st.X
		local M = 2 ^ LM
		for c = 0, C - 1 do
			for i = start, effEnd - 1 do
				local boffs = N * c + eb(i) * M
				local blen = (eb(i + 1) - eb(i)) * M
				for j = 1, blen do
					seed = lcg(seed)
					local s = if seed >= 2147483648 then seed - 4294967296 else seed
					X[boffs + j] = s // 1048576
				end
				renormaliseVector(X, boffs, blen, 1)
			end
		end
		st.rng = seed
		celtSynthesis(st, X, outSyn, oldBandE, start, effEnd, C, C, false, LM, false)
		for c = 1, C do
			local mem = st.mem[c]
			st.postfilterPeriod = max(st.postfilterPeriod, COMBFILTER_MINPERIOD)
			st.postfilterPeriodOld = max(st.postfilterPeriodOld, COMBFILTER_MINPERIOD)
			combFilter(mem, outSyn, st.postfilterPeriodOld, st.postfilterPeriod, SHORT_MDCT, st.postfilterGainOld,
				st.postfilterGain, st.postfilterTapsetOld, st.postfilterTapset, OVERLAP)
			if LM ~= 0 then
				combFilter(mem, outSyn + SHORT_MDCT, st.postfilterPeriod, st.postfilterPeriod, N - SHORT_MDCT,
					st.postfilterGain, st.postfilterGain, st.postfilterTapset, st.postfilterTapset, OVERLAP)
			end
		end
		st.postfilterPeriodOld = st.postfilterPeriod
		st.postfilterGainOld = st.postfilterGain
		st.postfilterTapsetOld = st.postfilterTapset
		st.prefilterAndFold = false
		st.skipPlc = true
	else
		local fade = 1
		local pitchIndex
		local fresh = st.lastFrameType ~= FRAME_PLC_PERIODIC
		if fresh then
			pitchIndex = plcPitchSearch(st)
			st.lastPitchIndex = pitchIndex
		else
			pitchIndex = st.lastPitchIndex
			if st.plcDuration * SHORT_MDCT >= pitchIndex then
				fade = 0.8
			end
		end
		local excLength = max(MAX_PERIOD, 2 * pitchIndex)
		local sig = sigBuf -- sig[LPC_ORDER + i + 1] is C sig[i]
		local exc = excBuf -- exc[i + 1] is C exc[i]
		for c = 1, C do
			local buf = st.mem[c]
			pitchIndex = st.lastPitchIndex
			for i = 0, excLength + LPC_ORDER - 1 do
				sig[i + 1] = buf[BUF - excLength - LPC_ORDER + i + 1]
			end
			local lo = (c - 1) * LPC_ORDER
			local lpc = st.lpc
			if fresh then
				autocorr(sig, LPC_ORDER + excLength - MAX_PERIOD, acPlc, WINDOW, OVERLAP, LPC_ORDER, MAX_PERIOD)
				acPlc[1] *= 1.0001
				for i = 1, LPC_ORDER do
					acPlc[i + 1] -= acPlc[i + 1] * (0.008 * 0.008) * i * i
				end
				celtLpc(lpc, lo, acPlc, LPC_ORDER)
			end
			-- exc = sig filtered by 1 + sum lpc[j] z^-(j+1)
			for i = 0, excLength - 1 do
				local at = LPC_ORDER + i + 1
				local sum = sig[at]
				for j = 1, LPC_ORDER do
					sum += lpc[lo + j] * sig[at - j]
				end
				exc[i + 1] = sum
			end
			local decay
			if fresh then
				local E1, E2 = 1, 1
				for i = 0, pitchIndex - 1 do
					local e = exc[excLength - pitchIndex + i + 1]
					E1 += e * e
					e = exc[excLength - 2 * pitchIndex + i + 1]
					E2 += e * e
				end
				E1 = min(E1, E2)
				decay = sqrt(E1 / E2)
				st.plcDecay[c] = decay
			else
				decay = st.plcDecay[c]
			end
			do
				local K = excLength // pitchIndex
				local E0 = 1
				for i = 0, pitchIndex - 1 do
					local e = exc[excLength - pitchIndex + i + 1]
					E0 += e * e
				end
				local k = 2
				while k <= K do
					local Ek = 1
					for i = 0, pitchIndex - 1 do
						local e = exc[excLength - k * pitchIndex + i + 1]
						Ek += e * e
					end
					if Ek < 0.25 * E0 or E0 < 0.25 * Ek then
						break
					end
					k += 1
				end
				pitchIndex *= k - 1
			end
			if st.lastFrameType == FRAME_NORMAL then
				for i = 1, OVERLAP // 2 do
					oldOverlap[i] = buf[BUF + i]
				end
			end
			table.move(buf, N + 1, BUF, 1)
			local extOff = excLength - pitchIndex
			local extLen = N + OVERLAP
			local attenuation = fade * decay
			local S1 = 0
			local j = 0
			for i = 0, extLen - 1 do
				if j >= pitchIndex then
					j -= pitchIndex
					attenuation *= decay
				end
				buf[BUF - N + i + 1] = attenuation * exc[extOff + j + 1]
				local tmp = attenuation * sig[LPC_ORDER + extOff + j + 1]
				S1 += tmp * tmp
				j += 1
			end
			for i = 0, LPC_ORDER - 1 do
				lpcMem[i + 1] = buf[BUF - N - 1 - i + 1]
			end
			-- all-pole synthesis in place: y[n] = x[n] - sum lpc[k] y[n-1-k]
			for i = 0, extLen - 1 do
				local at = BUF - N + i + 1
				local sum = buf[at]
				for k = 1, LPC_ORDER do
					sum -= lpc[lo + k] * lpcMem[k]
				end
				for k = LPC_ORDER, 2, -1 do
					lpcMem[k] = lpcMem[k - 1]
				end
				lpcMem[1] = sum
				buf[at] = sum
			end
			local S2 = 0
			for i = 0, extLen - 1 do
				local tmp = buf[BUF - N + i + 1]
				S2 += tmp * tmp
			end
			if not (S1 > 0.2 * S2) then
				for i = 0, extLen - 1 do
					buf[BUF - N + i + 1] = 0
				end
			elseif S1 < S2 then
				local ratio = sqrt((S1 + 1) / (S2 + 1))
				for i = 0, OVERLAP - 1 do
					local g = 1 - WINDOW[i + 1] * (1 - ratio)
					buf[BUF - N + i + 1] *= g
				end
				for i = OVERLAP, extLen - 1 do
					buf[BUF - N + i + 1] *= ratio
				end
			end
			if st.lastFrameType == FRAME_NORMAL then
				combFilterXY(etmp, 0, buf, BUF - N, st.postfilterPeriodOld, st.postfilterPeriodOld, OVERLAP,
					-st.postfilterGainOld, -st.postfilterGainOld, st.postfilterTapsetOld, st.postfilterTapsetOld, 0)
				for i = 0, OVERLAP // 2 - 1 do
					local w1 = WINDOW[i + 1]
					local w2 = WINDOW[OVERLAP - i]
					local x2 = oldOverlap[i + 1]
					local x1 = w2 * etmp[OVERLAP - i] - w1 * etmp[i + 1]
					buf[BUF - N + i + 1] = w2 * x2 - w1 * x1
					buf[BUF - N + OVERLAP - i] = w1 * x2 + w2 * x1
				end
				combFilter(buf, BUF - N, st.postfilterPeriodOld, st.postfilterPeriodOld, OVERLAP,
					st.postfilterGainOld, st.postfilterGainOld, st.postfilterTapsetOld, st.postfilterTapsetOld, 0)
			end
		end
		st.prefilterAndFold = true
	end
	st.lossDuration = min(10000, lossDuration + 2 ^ LM)
	st.plcDuration = min(10000, st.plcDuration + 2 ^ LM)
	st.lastFrameType = frameType
end

---------------------------------------------------------------------------------------------- decoder
function Celt.new(channels)
	local st = {
		channels = channels, streamChannels = channels, start = 0, endBand = NB, disableInv = channels == 1,
		rng = 0, lossDuration = 0, plcDuration = 0, lastFrameType = FRAME_NONE, skipPlc = true,
		prefilterAndFold = false, lastPitchIndex = 0, plcDecay = { 0, 0 }, lpc = table.create(2 * LPC_ORDER, 0),
		postfilterPeriod = 0, postfilterPeriodOld = 0, postfilterGain = 0, postfilterGainOld = 0,
		postfilterTapset = 0, postfilterTapsetOld = 0,
		preemphMem = { 0, 0 },
		mem = { table.create(BUF + OVERLAP, 0), table.create(BUF + OVERLAP, 0) },
		oldBandE = table.create(2 * NB, 0), oldLogE = table.create(2 * NB, -28), oldLogE2 = table.create(2 * NB, -28),
		backgroundLogE = table.create(2 * NB, 0),
		X = table.create(2 * 960, 0),
	}
	return st
end

function Celt.reset(st)
	local fresh = Celt.new(st.channels)
	for k, v in pairs(fresh) do
		if k ~= "start" and k ~= "endBand" and k ~= "streamChannels" then
			st[k] = v
		end
	end
end

local function deemphasis(st, outSyn, N, CC, out, outOff, accum)
	local coef = PREEMPH
	for c = 1, CC do
		local x = st.mem[c]
		local m = st.preemphMem[c]
		local y = out[c] or out[1]
		for j = 1, N do
			local tmp = x[outSyn + j] + 1e-30 + m
			m = coef * tmp
			if accum then
				y[outOff + j] += tmp / 32768
			else
				y[outOff + j] = tmp / 32768
			end
		end
		st.preemphMem[c] = m
	end
end

function Celt.decode(st, ec, len, frameSize, out, outOff, accum)
	local CC = st.channels
	local C = st.streamChannels
	local start, endBand = st.start, st.endBand
	local LM = 0
	while LM <= MAXLM and SHORT_MDCT * (2 ^ LM) ~= frameSize do
		LM += 1
	end
	if LM > MAXLM then
		error("CELT: bad frame size " .. tostring(frameSize))
	end
	local M = 2 ^ LM
	local N = M * SHORT_MDCT
	local outSyn = BUF - N -- 0-based offset of out_syn in mem[c]
	local effEnd = min(endBand, NB)
	local oldBandE, oldLogE, oldLogE2, bgE = st.oldBandE, st.oldLogE, st.oldLogE2, st.backgroundLogE
	if len <= 1 or not ec then
		decodeLost(st, N, LM)
		deemphasis(st, outSyn, N, CC, out, outOff, accum)
		return frameSize
	end
	if st.lossDuration == 0 then
		st.skipPlc = false
	end
	if C == 1 then
		for i = 1, NB do
			oldBandE[i] = max(oldBandE[i], oldBandE[NB + i])
		end
	end
	local totalBits = len * 8
	local tell = ec:tell()
	local silence
	if tell >= totalBits then
		silence = true
	elseif tell == 1 then
		silence = ec:bitLogp(15) ~= 0
	else
		silence = false
	end
	if silence then
		tell = len * 8
		ec.nbitsTotal += tell - ec:tell()
	end
	local postfilterGain, postfilterPitch, postfilterTapset = 0, 0, 0
	if start == 0 and tell + 16 <= totalBits then
		if ec:bitLogp(1) ~= 0 then
			local octave = ec:uint(6)
			postfilterPitch = (16 * (2 ^ octave)) + ec:bits(4 + octave) - 1
			local qg = ec:bits(3)
			if ec:tell() + 2 <= totalBits then
				postfilterTapset = ec:icdf(TAPSET_ICDF, 2)
			end
			postfilterGain = 0.09375 * (qg + 1)
		end
		tell = ec:tell()
	end
	local isTransient = false
	if LM > 0 and tell + 3 <= totalBits then
		isTransient = ec:bitLogp(3) ~= 0
		tell = ec:tell()
	end
	local shortBlocks = isTransient and M or 0
	local intraEner = false
	if tell + 3 <= totalBits then
		intraEner = ec:bitLogp(3) ~= 0
	end
	if not intraEner and st.lossDuration ~= 0 then
		local missing = min(10, st.lossDuration // M)
		local safety = LM == 0 and 1.5 or (LM == 1 and 0.5 or 0)
		for c = 0, 1 do
			for i = start, endBand - 1 do
				local k = c * NB + i + 1
				if oldBandE[k] < max(oldLogE[k], oldLogE2[k]) then
					local E0, E1, E2 = oldBandE[k], oldLogE[k], oldLogE2[k]
					local slope = max(E1 - E0, 0.5 * (E2 - E0))
					slope = min(slope, 2)
					E0 -= max(0, (1 + missing) * slope)
					oldBandE[k] = max(-20, E0)
				else
					oldBandE[k] = min(min(oldBandE[k], oldLogE[k]), oldLogE2[k])
				end
				oldBandE[k] -= safety
			end
		end
	end
	unquantCoarseEnergy(start, endBand, oldBandE, intraEner, ec, C, LM)
	local tfRes = table.create(NB, 0)
	tfDecode(start, endBand, isTransient, tfRes, LM, ec)
	tell = ec:tell()
	local spread = SPREAD_NORMAL
	if tell + 4 <= totalBits then
		spread = ec:icdf(SPREAD_ICDF, 5)
	end
	local cap = table.create(NB, 0)
	initCaps(cap, LM, C)
	local offsets = table.create(NB, 0)
	local dynallocLogp = 6
	totalBits *= 8
	tell = ec:tellFrac()
	for i = start, endBand - 1 do
		local width = C * (eb(i + 1) - eb(i)) * (2 ^ LM)
		local quanta = min(width * 8, max(48, width))
		local loopLogp = dynallocLogp
		local boost = 0
		while tell + loopLogp * 8 < totalBits and boost < cap[i + 1] do
			local flag = ec:bitLogp(loopLogp)
			tell = ec:tellFrac()
			if flag == 0 then
				break
			end
			boost += quanta
			totalBits -= quanta
			loopLogp = 1
		end
		offsets[i + 1] = boost
		if boost > 0 then
			dynallocLogp = max(2, dynallocLogp - 1)
		end
	end
	local allocTrim = 5
	if tell + 48 <= totalBits then
		allocTrim = ec:icdf(TRIM_ICDF, 7)
	end
	local bits = len * 64 - ec:tellFrac() - 1
	local antiCollapseRsv = (isTransient and LM >= 2 and bits >= (LM + 2) * 8) and 8 or 0
	bits -= antiCollapseRsv
	local pulses = table.create(NB, 0)
	local fineQuant = table.create(NB, 0)
	local finePriority = table.create(NB, 0)
	local codedBands, balance, intensity, dualStereo =
		computeAllocation(start, endBand, offsets, cap, allocTrim, bits, pulses, fineQuant, finePriority, C, LM, ec)
	unquantFineEnergy(start, endBand, oldBandE, fineQuant, ec, C)
	for c = 1, CC do
		local mem = st.mem[c]
		table.move(mem, N + 1, BUF + OVERLAP, 1)
	end
	local X = st.X
	for i = 1, C * N do
		X[i] = 0
	end
	local collapse = table.create(C * NB, 0)
	quantAllBands(st, start, endBand, X, C == 2, collapse, pulses, shortBlocks, spread, dualStereo, intensity, tfRes,
		len * 64 - antiCollapseRsv, balance, ec, LM, codedBands)
	local antiCollapseOn = false
	if antiCollapseRsv > 0 then
		antiCollapseOn = ec:bits(1) ~= 0
	end
	unquantEnergyFinalise(start, endBand, oldBandE, fineQuant, finePriority, len * 8 - ec:tell(), ec, C)
	if antiCollapseOn then
		antiCollapse(X, collapse, LM, C, N, start, endBand, oldBandE, oldLogE, oldLogE2, pulses, st.rng)
	end
	if silence then
		for i = 1, C * NB do
			oldBandE[i] = -28
		end
	end
	if st.prefilterAndFold then
		prefilterAndFold(st, N)
	end
	celtSynthesis(st, X, outSyn, oldBandE, start, effEnd, C, CC, isTransient, LM, silence)
	for c = 1, CC do
		local mem = st.mem[c]
		st.postfilterPeriod = max(st.postfilterPeriod, COMBFILTER_MINPERIOD)
		st.postfilterPeriodOld = max(st.postfilterPeriodOld, COMBFILTER_MINPERIOD)
		combFilter(mem, outSyn, st.postfilterPeriodOld, st.postfilterPeriod, SHORT_MDCT, st.postfilterGainOld,
			st.postfilterGain, st.postfilterTapsetOld, st.postfilterTapset, OVERLAP)
		if LM ~= 0 then
			combFilter(mem, outSyn + SHORT_MDCT, st.postfilterPeriod, postfilterPitch, N - SHORT_MDCT, st.postfilterGain,
				postfilterGain, st.postfilterTapset, postfilterTapset, OVERLAP)
		end
	end
	st.postfilterPeriodOld = st.postfilterPeriod
	st.postfilterGainOld = st.postfilterGain
	st.postfilterTapsetOld = st.postfilterTapset
	st.postfilterPeriod = postfilterPitch
	st.postfilterGain = postfilterGain
	st.postfilterTapset = postfilterTapset
	if LM ~= 0 then
		st.postfilterPeriodOld = st.postfilterPeriod
		st.postfilterGainOld = st.postfilterGain
		st.postfilterTapsetOld = st.postfilterTapset
	end
	if C == 1 then
		for i = 1, NB do
			oldBandE[NB + i] = oldBandE[i]
		end
	end
	if not isTransient then
		for i = 1, 2 * NB do
			oldLogE2[i] = oldLogE[i]
			oldLogE[i] = oldBandE[i]
		end
	else
		for i = 1, 2 * NB do
			oldLogE[i] = min(oldLogE[i], oldBandE[i])
		end
	end
	local maxBg = min(160, st.lossDuration + M) * 0.001
	for i = 1, 2 * NB do
		bgE[i] = min(bgE[i] + maxBg, oldBandE[i])
	end
	for c = 0, 1 do
		for i = 0, start - 1 do
			oldBandE[c * NB + i + 1] = 0
			oldLogE[c * NB + i + 1] = -28
			oldLogE2[c * NB + i + 1] = -28
		end
		for i = endBand, NB - 1 do
			oldBandE[c * NB + i + 1] = 0
			oldLogE[c * NB + i + 1] = -28
			oldLogE2[c * NB + i + 1] = -28
		end
	end
	st.rng = ec.rng
	deemphasis(st, outSyn, N, CC, out, outOff, accum)
	st.lossDuration = 0
	st.plcDuration = 0
	st.lastFrameType = FRAME_NORMAL
	st.prefilterAndFold = false
	return frameSize
end

return Celt
