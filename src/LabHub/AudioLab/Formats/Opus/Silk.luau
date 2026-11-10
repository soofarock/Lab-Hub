--!native
--!optimize 2
-- SILK decoder (RFC 6716 section 4.2): the speech layer of Opus, used by SILK-only and hybrid frames.
-- Fixed-point, ported from libopus silk/ (BSD-3-Clause, see the notice in the Opus module); output matches libopus
-- sample for sample.
--
--   local dec = Silk.new()
--   dec.control.payloadSizeMs, .nChannelsInternal, .internalSampleRate (8000/12000/16000), .nChannelsAPI
--   Silk.decode(dec, lostFlag, newPacket, ec, out, outOff, maxSamples) -> samples written at 48 kHz
--       lostFlag 0 decodes a frame from ec, 1 conceals a lost one; out[c][outOff + i] gets samples in -1..1.
--   Silk.reset(dec)

local Silk = {}

local T
if script then
	T = require(script.Parent.SilkTables)
else
	T = require("./SilkTables")
end

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local band, countlz = bit32.band, bit32.countlz

local P2 = {}
for i = 0, 62 do
	P2[i] = 2 ^ i
end

local TYPE_NO_VOICE_ACTIVITY, TYPE_VOICED = 0, 2
local CODE_INDEPENDENTLY, CODE_INDEPENDENTLY_NO_LTP_SCALING, CODE_CONDITIONALLY = 0, 1, 2
local MAX_LPC_ORDER = 16
local LTP_ORDER = 5
local MAX_FRAME_LENGTH = 320

-- fixed-point helpers (C semantics on exact integers held in doubles)
local function s16(x)
	x %= 65536
	if x >= 32768 then
		x -= 65536
	end
	return x
end
local function s32(x)
	x %= 4294967296
	if x >= 2147483648 then
		x -= 4294967296
	end
	return x
end
local function sat16(x)
	if x > 32767 then
		return 32767
	elseif x < -32768 then
		return -32768
	end
	return x
end
local function sat32(x)
	if x > 2147483647 then
		return 2147483647
	elseif x < -2147483648 then
		return -2147483648
	end
	return x
end
local function limit(a, l1, l2)
	if l1 > l2 then
		if a > l1 then
			return l1
		elseif a < l2 then
			return l2
		end
		return a
	end
	if a > l2 then
		return l2
	elseif a < l1 then
		return l1
	end
	return a
end
-- C integer division (towards zero)
local function tdiv(a, b)
	local q = a / b
	if q >= 0 then
		return floor(q)
	end
	return -floor(-q)
end
-- silk_RSHIFT_ROUND
local function rround(a, s)
	if s == 1 then
		return a // 2 + a % 2
	end
	return (a // P2[s - 1] + 1) // 2
end
-- silk_SMULWB: (a * (int16)b) >> 16
local function smulwb(a, b)
	return (a * s16(b)) // 65536
end
-- silk_SMULWW: (a * b) >> 16, 32-bit result
local function smulww(a, b)
	local bl = b % 65536
	return s32(a * ((b - bl) / 65536) + (a * bl) // 65536)
end
-- floor((a * b + r) / 2^s) for 32-bit a, b and s >= 16, exact
local function mulShift(a, b, s, r)
	local al = a % 65536
	local ah = (a - al) / 65536
	return (ah * b + (al * b + r) // 65536) // P2[s - 16]
end
local function smmul(a, b)
	return mulShift(a, b, 32, 0)
end
local function clz32(x)
	if x == 0 then
		return 32
	end
	return countlz(x)
end
local function lshiftSat32(a, s)
	return limit(a, -P2[31 - s], (2147483647 // P2[s])) * P2[s]
end
-- silk_RAND
local function rand(seed)
	local al = seed % 65536
	local ah = (seed - al) / 65536
	return s32(907633515 + ((ah * 196314165) % 65536) * 65536 + al * 196314165)
end
-- low 7 bits of silk_ROR32(x, 24 - lz) (silk_CLZ_FRAC)
local function fracQ7(x, lz)
	local r = 24 - lz
	if r >= 0 then
		return band(x // P2[r], 127)
	end
	return band(x * P2[-r], 127)
end
local function sqrtApprox(x)
	if x <= 0 then
		return 0
	end
	local lz = clz32(x)
	local frac = fracQ7(x, lz)
	local y = if lz % 2 == 1 then 32768 else 46214
	y = y // P2[lz // 2]
	return y + smulwb(y, 213 * frac)
end
local function inverse32VarQ(b32, Qres)
	local bHeadrm = clz32(abs(b32)) - 1
	local bNrm = b32 * P2[bHeadrm]
	local bInv = tdiv(536870911, bNrm // 65536)
	local result = bInv * 65536
	local errQ32 = s32((536870912 - smulwb(bNrm, bInv)) * 8)
	result = s32(result + smulww(errQ32, bInv))
	local lshift = 61 - bHeadrm - Qres
	if lshift <= 0 then
		return lshiftSat32(result, -lshift)
	elseif lshift < 32 then
		return result // P2[lshift]
	end
	return 0
end
local function div32VarQ(a32, b32, Qres)
	local aHeadrm = clz32(abs(a32)) - 1
	local aNrm = a32 * P2[aHeadrm]
	local bHeadrm = clz32(abs(b32)) - 1
	local bNrm = b32 * P2[bHeadrm]
	local bInv = tdiv(536870911, bNrm // 65536)
	local result = smulwb(aNrm, bInv)
	aNrm = s32(aNrm - s32(smmul(bNrm, result) * 8))
	result = result + smulwb(aNrm, bInv)
	local lshift = 29 + aHeadrm - bHeadrm - Qres
	if lshift < 0 then
		return lshiftSat32(result, -lshift)
	elseif lshift < 32 then
		return result // P2[lshift]
	end
	return 0
end
local function log2lin(inLog)
	if inLog < 0 then
		return 0
	elseif inLog >= 3967 then
		return 2147483647
	end
	local out = P2[inLog // 128]
	local frac = inLog % 128
	local t = frac + (frac * (128 - frac) * -174) // 65536
	if inLog < 2048 then
		return out + (out * t) // 128
	end
	return out + (out // 128) * t
end
local function zeros(n)
	return table.create(n, 0)
end

-- LPC helpers ----------------------------------------------------------------------------------------------------

local function bwexpander(ar, d, chirp)
	local cm1 = chirp - 65536
	for i = 1, d - 1 do
		ar[i] = s16(rround(chirp * ar[i], 16))
		chirp += rround(chirp * cm1, 16)
	end
	ar[d] = s16(rround(chirp * ar[d], 16))
end

local function bwexpander32(ar, d, chirp)
	local cm1 = chirp - 65536
	for i = 1, d - 1 do
		ar[i] = smulww(chirp, ar[i])
		chirp += rround(chirp * cm1, 16)
	end
	ar[d] = smulww(chirp, ar[d])
end

local A_LIMIT = floor(0.99975 * 2 ^ 24 + 0.5)
local INV_MAX_GAIN_Q30 = floor((1 / 1e4) * 2 ^ 30 + 0.5)
local Atmp = zeros(MAX_LPC_ORDER)
local function LPCinversePredGain(AQ12, order)
	local DC = 0
	local A = Atmp
	for k = 1, order do
		DC += AQ12[k]
		A[k] = AQ12[k] * 4096
	end
	if DC >= 4096 then
		return 0
	end
	local invGain = 1073741824
	for k = order - 1, 1, -1 do
		local ak = A[k + 1]
		if ak > A_LIMIT or ak < -A_LIMIT then
			return 0
		end
		local rcQ31 = -(ak * 128)
		local rcMult1 = 1073741824 - smmul(rcQ31, rcQ31)
		invGain = smmul(invGain, rcMult1) * 4
		if invGain < INV_MAX_GAIN_Q30 then
			return 0
		end
		local mult2Q = 32 - clz32(abs(rcMult1))
		local rcMult2 = inverse32VarQ(rcMult1, mult2Q + 30)
		local rnd = P2[mult2Q - 1]
		for n = 0, (k + 1) // 2 - 1 do
			local tmp1 = A[n + 1]
			local tmp2 = A[k - n]
			local t64 = mulShift(sat32(tmp1 - mulShift(tmp2, rcQ31, 31, 1073741824)), rcMult2, mult2Q, rnd)
			if t64 > 2147483647 or t64 < -2147483648 then
				return 0
			end
			A[n + 1] = t64
			t64 = mulShift(sat32(tmp2 - mulShift(tmp1, rcQ31, 31, 1073741824)), rcMult2, mult2Q, rnd)
			if t64 > 2147483647 or t64 < -2147483648 then
				return 0
			end
			A[k - n] = t64
		end
	end
	local a0 = A[1]
	if a0 > A_LIMIT or a0 < -A_LIMIT then
		return 0
	end
	local rcQ31 = -(a0 * 128)
	local rcMult1 = 1073741824 - smmul(rcQ31, rcQ31)
	invGain = smmul(invGain, rcMult1) * 4
	if invGain < INV_MAX_GAIN_Q30 then
		return 0
	end
	return invGain
end

local CHIRP_0999 = floor(0.999 * 65536 + 0.5)
local function LPCfit(aOut, aIn, Qout, Qin, d)
	local idx = 0
	local i = 0
	local sh = Qin - Qout
	while i < 10 do
		local maxabs = 0
		for k = 1, d do
			local a = abs(aIn[k])
			if a > maxabs then
				maxabs = a
				idx = k - 1
			end
		end
		maxabs = rround(maxabs, sh)
		if maxabs > 32767 then
			maxabs = min(maxabs, 163838)
			local chirp = CHIRP_0999 - tdiv((maxabs - 32767) * 16384, (maxabs * (idx + 1)) // 4)
			bwexpander32(aIn, d, chirp)
		else
			break
		end
		i += 1
	end
	if i == 10 then
		for k = 1, d do
			aOut[k] = sat16(rround(aIn[k], sh))
			aIn[k] = aOut[k] * P2[sh]
		end
	else
		for k = 1, d do
			aOut[k] = s16(rround(aIn[k], sh))
		end
	end
end

local ORD16 = { 0, 15, 8, 7, 4, 11, 12, 3, 2, 13, 10, 5, 6, 9, 14, 1 }
local ORD10 = { 0, 9, 6, 3, 4, 5, 8, 1, 2, 7 }
local cosLSF = zeros(MAX_LPC_ORDER)
local Ppoly, Qpoly = zeros(9), zeros(9)
local a32QA1 = zeros(MAX_LPC_ORDER)

local function findPoly(out, cLSF, off, dd)
	out[1] = 65536
	out[2] = -cLSF[off + 1]
	for k = 1, dd - 1 do
		local ftmp = cLSF[off + 2 * k + 1]
		out[k + 2] = out[k] * 2 - mulShift(ftmp, out[k + 1], 16, 32768)
		for n = k, 2, -1 do
			out[n + 1] += out[n - 1] - mulShift(ftmp, out[n], 16, 32768)
		end
		out[2] -= ftmp
	end
end

local function NLSF2A(aQ12, NLSF, d)
	local ordering = if d == 16 then ORD16 else ORD10
	local COS = T.LSFCosTab_FIX_Q12
	for k = 1, d do
		local nl = NLSF[k]
		local fInt = nl // 256
		local fFrac = nl - fInt * 256
		local cosVal = COS[fInt + 1]
		local delta = COS[fInt + 2] - cosVal
		cosLSF[ordering[k] + 1] = rround(cosVal * 256 + delta * fFrac, 4)
	end
	local dd = d // 2
	findPoly(Ppoly, cosLSF, 0, dd)
	findPoly(Qpoly, cosLSF, 1, dd)
	local a = a32QA1
	for k = 0, dd - 1 do
		local Ptmp = Ppoly[k + 2] + Ppoly[k + 1]
		local Qtmp = Qpoly[k + 2] - Qpoly[k + 1]
		a[k + 1] = -Qtmp - Ptmp
		a[d - k] = Qtmp - Ptmp
	end
	LPCfit(aQ12, a, 12, 17, d)
	local i = 0
	while LPCinversePredGain(aQ12, d) == 0 and i < 16 do
		bwexpander32(a, d, 65536 - 2 * P2[i])
		for k = 1, d do
			aQ12[k] = s16(rround(a[k], 5))
		end
		i += 1
	end
end

local function NLSFstabilize(NLSF, dMin, L)
	for _ = 1, 20 do
		local minDiff = NLSF[1] - dMin[1]
		local I = 0
		for i = 1, L - 1 do
			local diff = NLSF[i + 1] - (NLSF[i] + dMin[i + 1])
			if diff < minDiff then
				minDiff = diff
				I = i
			end
		end
		local diff = 32768 - (NLSF[L] + dMin[L + 1])
		if diff < minDiff then
			minDiff = diff
			I = L
		end
		if minDiff >= 0 then
			return
		end
		if I == 0 then
			NLSF[1] = dMin[1]
		elseif I == L then
			NLSF[L] = 32768 - dMin[L + 1]
		else
			local minCenter = 0
			for k = 0, I - 1 do
				minCenter += dMin[k + 1]
			end
			minCenter += dMin[I + 1] // 2
			local maxCenter = 32768
			for k = L, I + 1, -1 do
				maxCenter -= dMin[k + 1]
			end
			maxCenter -= dMin[I + 1] // 2
			local center = s16(limit(rround(NLSF[I] + NLSF[I + 1], 1), minCenter, maxCenter))
			NLSF[I] = s16(center - dMin[I + 1] // 2)
			NLSF[I + 1] = s16(NLSF[I] + dMin[I + 1])
		end
	end
	-- still unstable after 20 passes: sort and clamp
	for i = 2, L do
		local v = NLSF[i]
		local j = i - 1
		while j >= 1 and NLSF[j] > v do
			NLSF[j + 1] = NLSF[j]
			j -= 1
		end
		NLSF[j + 1] = v
	end
	NLSF[1] = max(NLSF[1], dMin[1])
	for i = 1, L - 1 do
		NLSF[i + 1] = max(NLSF[i + 1], sat16(NLSF[i] + dMin[i + 1]))
	end
	NLSF[L] = min(NLSF[L], 32768 - dMin[L + 1])
	for i = L - 2, 0, -1 do
		NLSF[i + 1] = min(NLSF[i + 1], NLSF[i + 2] - dMin[i + 2])
	end
end

local ecIx, predQ8 = zeros(MAX_LPC_ORDER), zeros(MAX_LPC_ORDER)
local function NLSFunpack(CB, CB1index)
	local order = CB.order
	local sel = CB.ec_sel
	local selBase = CB1index * order // 2
	local pred = CB.pred_Q8
	for i = 0, order - 1, 2 do
		local entry = sel[selBase + i // 2 + 1]
		ecIx[i + 1] = band(entry // 2, 7) * 9
		predQ8[i + 1] = pred[i + band(entry, 1) * (order - 1) + 1]
		ecIx[i + 2] = band(entry // 32, 7) * 9
		predQ8[i + 2] = pred[i + band(entry // 16, 1) * (order - 1) + 2]
	end
end

local resQ10 = zeros(MAX_LPC_ORDER)
local function NLSFdecode(pNLSF, NLSFIndices, CB)
	NLSFunpack(CB, NLSFIndices[1])
	local order = CB.order
	local step = CB.quantStepSize_Q16
	local outQ10 = 0
	for i = order - 1, 0, -1 do
		local predQ10 = (s16(outQ10) * predQ8[i + 1]) // 256
		outQ10 = NLSFIndices[i + 2] * 1024
		if outQ10 > 0 then
			outQ10 -= 102
		elseif outQ10 < 0 then
			outQ10 += 102
		end
		outQ10 = predQ10 + (outQ10 * step) // 65536
		resQ10[i + 1] = outQ10
	end
	local cbBase = NLSFIndices[1] * order
	local W, C = CB.CB1_Wght_Q9, CB.CB1_NLSF_Q8
	for i = 1, order do
		local tmp = tdiv(resQ10[i] * 16384, W[cbBase + i]) + C[cbBase + i] * 128
		pNLSF[i] = limit(tmp, 0, 32767)
	end
	NLSFstabilize(pNLSF, CB.deltaMin_Q15, order)
end

-- out[outOff + ix] = in[inOff + ix] filtered by 1 - B(z), for ix = d .. len-1 (0-based); out[outOff .. + d-1] = 0
local function LPCanalysisFilter(out, outOff, inp, inOff, B, len, d)
	for ix = d, len - 1 do
		local p = inOff + ix -- 1-based index of in_ptr[0] (= in[ix - 1])
		local acc = 0
		for j = 0, d - 1 do
			acc += inp[p - j] * B[j + 1]
		end
		acc = s32(acc)
		local out32 = rround(s32(inp[p + 1] * 4096 - acc), 12)
		out[outOff + ix + 1] = sat16(out32)
	end
	for j = 1, d do
		out[outOff + j] = 0
	end
end

local function sumSqrShift(x, off, len)
	local shft = 31 - clz32(len)
	local nrg = len
	local i = 0
	while i < len - 1 do
		local a, b = x[off + i + 1], x[off + i + 2]
		nrg += (a * a + b * b) // P2[shft]
		i += 2
	end
	if i < len then
		local a = x[off + i + 1]
		nrg += (a * a) // P2[shft]
	end
	shft = max(0, shft + 3 - clz32(nrg))
	nrg = 0
	i = 0
	while i < len - 1 do
		local a, b = x[off + i + 1], x[off + i + 2]
		nrg += (a * a + b * b) // P2[shft]
		i += 2
	end
	if i < len then
		local a = x[off + i + 1]
		nrg += (a * a) // P2[shft]
	end
	return nrg, shft
end

-- resampler (8/12/16 kHz up to 48 kHz: 2x IIR then a 12-phase FIR) ----------------------------------------------

local UP2_0 = { 1746, 14986, 39083 - 65536 }
local UP2_1 = { 6854, 25769, 55542 - 65536 }
local FIR12 = T.resampler_frac_FIR_12
local DELAY_DEC = { [8] = 0, [12] = 4, [16] = 7 }

local function newResampler()
	return {
		sIIR = zeros(6), sFIR = zeros(8), delayBuf = zeros(96),
		batchSize = 0, invRatio_Q16 = 0, Fs_in_kHz = 0, Fs_out_kHz = 0, inputDelay = 0,
		buf = zeros(2 * 160 + 8),
	}
end

local function resamplerInit(S, fsIn, fsOut)
	S.sIIR = zeros(6)
	S.sFIR = zeros(8)
	S.delayBuf = zeros(96)
	assert(fsOut == 48000, "SILK: output must be 48 kHz")
	S.inputDelay = DELAY_DEC[fsIn // 1000]
	S.Fs_in_kHz = fsIn // 1000
	S.Fs_out_kHz = fsOut // 1000
	S.batchSize = S.Fs_in_kHz * 10
	local inv = tdiv(fsIn * 32768, fsOut) * 4
	while smulww(inv, fsOut) < fsIn * 2 do
		inv += 1
	end
	S.invRatio_Q16 = inv
end

local function copyResampler(dst, src)
	for k, v in src do
		if type(v) == "table" then
			table.move(v, 1, #v, 1, dst[k])
		else
			dst[k] = v
		end
	end
end

local function up2HQ(S, out, outOff, inp, inOff, len)
	local s1, s2, s3, s4, s5, s6 = S[1], S[2], S[3], S[4], S[5], S[6]
	for k = 0, len - 1 do
		local in32 = inp[inOff + k + 1] * 1024
		local Y = in32 - s1
		local X = smulwb(Y, UP2_0[1])
		local o1 = s1 + X
		s1 = in32 + X
		Y = o1 - s2
		X = smulwb(Y, UP2_0[2])
		local o2 = s2 + X
		s2 = o1 + X
		Y = o2 - s3
		X = Y + smulwb(Y, UP2_0[3])
		o1 = s3 + X
		s3 = o2 + X
		out[outOff + 2 * k + 1] = sat16(rround(o1, 10))
		Y = in32 - s4
		X = smulwb(Y, UP2_1[1])
		o1 = s4 + X
		s4 = in32 + X
		Y = o1 - s5
		X = smulwb(Y, UP2_1[2])
		o2 = s5 + X
		s5 = o1 + X
		Y = o2 - s6
		X = Y + smulwb(Y, UP2_1[3])
		o1 = s6 + X
		s6 = o2 + X
		out[outOff + 2 * k + 2] = sat16(rround(o1, 10))
	end
	S[1], S[2], S[3], S[4], S[5], S[6] = s1, s2, s3, s4, s5, s6
end

-- returns the next output position (0-based)
local function IIRFIR(S, out, outPos, inp, inOff, inLen)
	local buf = S.buf
	local sFIR = S.sFIR
	for i = 1, 8 do
		buf[i] = sFIR[i]
	end
	local inc = S.invRatio_Q16
	local nIn
	while true do
		nIn = min(inLen, S.batchSize)
		up2HQ(S.sIIR, buf, 8, inp, inOff, nIn)
		local maxIndex = nIn * 131072
		local index = 0
		while index < maxIndex do
			local frac = index % 65536
			local ti = (frac * 12) // 65536
			local b = (index - frac) / 65536 -- buf[b + 1] is buf_ptr[0]
			local c0, c1 = FIR12[ti * 4 + 1], FIR12[ti * 4 + 2]
			local c2, c3 = FIR12[ti * 4 + 3], FIR12[ti * 4 + 4]
			local r = (11 - ti) * 4
			local res = buf[b + 1] * c0 + buf[b + 2] * c1 + buf[b + 3] * c2 + buf[b + 4] * c3
				+ buf[b + 5] * FIR12[r + 4] + buf[b + 6] * FIR12[r + 3] + buf[b + 7] * FIR12[r + 2] + buf[b + 8] * FIR12[r + 1]
			outPos += 1
			out[outPos] = sat16(rround(res, 15))
			index += inc
		end
		inOff += nIn
		inLen -= nIn
		if inLen > 0 then
			for i = 1, 8 do
				buf[i] = buf[nIn * 2 + i]
			end
		else
			break
		end
	end
	for i = 1, 8 do
		sFIR[i] = buf[nIn * 2 + i]
	end
	return outPos
end

-- in[inOff + 1 .. inOff + inLen] -> out[1 ..]
local function resample(S, out, inp, inOff, inLen)
	local nSamples = S.Fs_in_kHz - S.inputDelay
	local db = S.delayBuf
	for i = 1, nSamples do
		db[S.inputDelay + i] = inp[inOff + i]
	end
	local pos = IIRFIR(S, out, 0, db, 0, S.Fs_in_kHz)
	IIRFIR(S, out, S.Fs_out_kHz, inp, inOff + nSamples, inLen - S.Fs_in_kHz)
	for i = 1, S.inputDelay do
		db[i] = inp[inOff + inLen - S.inputDelay + i]
	end
	return pos
end

-- channel state ----------------------------------------------------------------------------------------------------

local function CNGreset(c)
	local step = tdiv(32767, c.LPC_order + 1)
	local acc = 0
	for i = 1, c.LPC_order do
		acc += step
		c.sCNG.smthNLSF[i] = acc
	end
	c.sCNG.smthGain = 0
	c.sCNG.randSeed = 3176576
end

local function PLCreset(c)
	local plc = c.sPLC
	plc.pitchL_Q8 = c.frame_length * 128
	plc.prevGain_Q16[1] = 65536
	plc.prevGain_Q16[2] = 65536
	plc.subfr_length = 20
	plc.nb_subfr = 2
end

local function resetChannel(c)
	c.prev_gain_Q16 = 65536
	c.exc_Q14 = zeros(MAX_FRAME_LENGTH)
	c.sLPC_Q14_buf = zeros(MAX_LPC_ORDER)
	c.outBuf = zeros(MAX_FRAME_LENGTH + 160)
	c.lagPrev = 0
	c.LastGainIndex = 0
	c.fs_kHz = 0
	c.fs_API_hz = 0
	c.nb_subfr = 0
	c.frame_length = 0
	c.subfr_length = 0
	c.ltp_mem_length = 0
	c.LPC_order = 0
	c.prevNLSF_Q15 = zeros(MAX_LPC_ORDER)
	c.first_frame_after_reset = 1
	c.pitch_lag_low_bits_iCDF = nil
	c.pitch_contour_iCDF = nil
	c.nFramesDecoded = 0
	c.nFramesPerPacket = 0
	c.ec_prevSignalType = 0
	c.ec_prevLagIndex = 0
	c.VAD_flags = { 0, 0, 0 }
	c.LBRR_flag = 0
	c.LBRR_flags = { 0, 0, 0 }
	c.resampler = newResampler()
	c.NLSF_CB = nil
	c.indices = {
		GainsIndices = zeros(4), LTPIndex = zeros(4), NLSFIndices = zeros(MAX_LPC_ORDER + 1),
		lagIndex = 0, contourIndex = 0, signalType = 0, quantOffsetType = 0,
		NLSFInterpCoef_Q2 = 0, PERIndex = 0, LTP_scaleIndex = 0, Seed = 0,
	}
	c.sCNG = { exc = zeros(MAX_FRAME_LENGTH), smthNLSF = zeros(MAX_LPC_ORDER), synth = zeros(MAX_LPC_ORDER), smthGain = 0, randSeed = 0, fs_kHz = 0 }
	c.lossCnt = 0
	c.prevSignalType = 0
	c.sPLC = {
		pitchL_Q8 = 0, LTPCoef_Q14 = zeros(LTP_ORDER), prevLPC_Q12 = zeros(MAX_LPC_ORDER), last_frame_lost = 0,
		rand_seed = 0, randScale_Q14 = 0, conc_energy = 0, conc_energy_shift = 0, prevLTP_scale_Q14 = 0,
		prevGain_Q16 = { 0, 0 }, fs_kHz = 0, nb_subfr = 0, subfr_length = 0,
	}
	CNGreset(c)
	PLCreset(c)
end

local CB_NB_MB = {
	nVectors = 32, order = 10, quantStepSize_Q16 = floor(0.18 * 65536 + 0.5),
	CB1_NLSF_Q8 = T.NLSF_CB1_NB_MB_Q8, CB1_Wght_Q9 = T.NLSF_CB1_Wght_Q9, CB1_iCDF = T.NLSF_CB1_iCDF_NB_MB,
	pred_Q8 = T.NLSF_PRED_NB_MB_Q8, ec_sel = T.NLSF_CB2_SELECT_NB_MB, ec_iCDF = T.NLSF_CB2_iCDF_NB_MB,
	deltaMin_Q15 = T.NLSF_DELTA_MIN_NB_MB_Q15,
}
local CB_WB = {
	nVectors = 32, order = 16, quantStepSize_Q16 = floor(0.15 * 65536 + 0.5),
	CB1_NLSF_Q8 = T.NLSF_CB1_WB_Q8, CB1_Wght_Q9 = T.NLSF_CB1_WB_Wght_Q9, CB1_iCDF = T.NLSF_CB1_iCDF_WB,
	pred_Q8 = T.NLSF_PRED_WB_Q8, ec_sel = T.NLSF_CB2_SELECT_WB, ec_iCDF = T.NLSF_CB2_iCDF_WB,
	deltaMin_Q15 = T.NLSF_DELTA_MIN_WB_Q15,
}

local function setFs(c, fsKHz, fsAPI)
	c.subfr_length = 5 * fsKHz
	local frameLength = c.nb_subfr * c.subfr_length
	if c.fs_kHz ~= fsKHz or c.fs_API_hz ~= fsAPI then
		resamplerInit(c.resampler, fsKHz * 1000, fsAPI)
		c.fs_API_hz = fsAPI
	end
	if c.fs_kHz ~= fsKHz or frameLength ~= c.frame_length then
		if fsKHz == 8 then
			c.pitch_contour_iCDF = if c.nb_subfr == 4 then T.pitch_contour_NB_iCDF else T.pitch_contour_10_ms_NB_iCDF
		else
			c.pitch_contour_iCDF = if c.nb_subfr == 4 then T.pitch_contour_iCDF else T.pitch_contour_10_ms_iCDF
		end
		if c.fs_kHz ~= fsKHz then
			c.ltp_mem_length = 20 * fsKHz
			if fsKHz == 8 or fsKHz == 12 then
				c.LPC_order = 10
				c.NLSF_CB = CB_NB_MB
			else
				c.LPC_order = 16
				c.NLSF_CB = CB_WB
			end
			if fsKHz == 16 then
				c.pitch_lag_low_bits_iCDF = T.uniform8_iCDF
			elseif fsKHz == 12 then
				c.pitch_lag_low_bits_iCDF = T.uniform6_iCDF
			else
				c.pitch_lag_low_bits_iCDF = T.uniform4_iCDF
			end
			c.first_frame_after_reset = 1
			c.lagPrev = 100
			c.LastGainIndex = 10
			c.prevSignalType = TYPE_NO_VOICE_ACTIVITY
			c.outBuf = zeros(MAX_FRAME_LENGTH + 160)
			c.sLPC_Q14_buf = zeros(MAX_LPC_ORDER)
		end
		c.fs_kHz = fsKHz
		c.frame_length = frameLength
	end
end

-- bitstream --------------------------------------------------------------------------------------------------------

local LTP_GAIN_ICDF = { T.LTP_gain_iCDF_0, T.LTP_gain_iCDF_1, T.LTP_gain_iCDF_2 }
local LTP_VQ = { T.LTP_gain_vq_0, T.LTP_gain_vq_1, T.LTP_gain_vq_2 }
local LBRR_ICDF = { T.LBRR_flags_2_iCDF, T.LBRR_flags_3_iCDF }

local function decodeIndices(c, ec, frameIndex, decodeLBRR, condCoding)
	local idx = c.indices
	local Ix
	if decodeLBRR or c.VAD_flags[frameIndex + 1] ~= 0 then
		Ix = ec:icdf(T.type_offset_VAD_iCDF, 8) + 2
	else
		Ix = ec:icdf(T.type_offset_no_VAD_iCDF, 8)
	end
	idx.signalType = Ix // 2
	idx.quantOffsetType = Ix % 2
	local gi = idx.GainsIndices
	if condCoding == CODE_CONDITIONALLY then
		gi[1] = ec:icdf(T.delta_gain_iCDF, 8)
	else
		gi[1] = ec:icdf(T.gain_iCDF, 8, idx.signalType * 8 + 1) * 8
		gi[1] += ec:icdf(T.uniform8_iCDF, 8)
	end
	for i = 2, c.nb_subfr do
		gi[i] = ec:icdf(T.delta_gain_iCDF, 8)
	end
	local CB = c.NLSF_CB
	local ni = idx.NLSFIndices
	ni[1] = ec:icdf(CB.CB1_iCDF, 8, (idx.signalType // 2) * CB.nVectors + 1)
	NLSFunpack(CB, ni[1])
	for i = 1, CB.order do
		Ix = ec:icdf(CB.ec_iCDF, 8, ecIx[i] + 1)
		if Ix == 0 then
			Ix -= ec:icdf(T.NLSF_EXT_iCDF, 8)
		elseif Ix == 8 then
			Ix += ec:icdf(T.NLSF_EXT_iCDF, 8)
		end
		ni[i + 1] = Ix - 4
	end
	if c.nb_subfr == 4 then
		idx.NLSFInterpCoef_Q2 = ec:icdf(T.NLSF_interpolation_factor_iCDF, 8)
	else
		idx.NLSFInterpCoef_Q2 = 4
	end
	if idx.signalType == TYPE_VOICED then
		local absolute = true
		if condCoding == CODE_CONDITIONALLY and c.ec_prevSignalType == TYPE_VOICED then
			local delta = ec:icdf(T.pitch_delta_iCDF, 8)
			if delta > 0 then
				idx.lagIndex = s16(c.ec_prevLagIndex + delta - 9)
				absolute = false
			end
		end
		if absolute then
			idx.lagIndex = ec:icdf(T.pitch_lag_iCDF, 8) * (c.fs_kHz // 2)
			idx.lagIndex += ec:icdf(c.pitch_lag_low_bits_iCDF, 8)
		end
		c.ec_prevLagIndex = idx.lagIndex
		idx.contourIndex = ec:icdf(c.pitch_contour_iCDF, 8)
		idx.PERIndex = ec:icdf(T.LTP_per_index_iCDF, 8)
		local cdf = LTP_GAIN_ICDF[idx.PERIndex + 1]
		for k = 1, c.nb_subfr do
			idx.LTPIndex[k] = ec:icdf(cdf, 8)
		end
		if condCoding == CODE_INDEPENDENTLY then
			idx.LTP_scaleIndex = ec:icdf(T.LTPscale_iCDF, 8)
		else
			idx.LTP_scaleIndex = 0
		end
	end
	c.ec_prevSignalType = idx.signalType
	idx.Seed = ec:icdf(T.uniform4_iCDF, 8)
end

local function decodeSplit(child, i1, i2, ec, p, tbl)
	if p > 0 then
		local a = ec:icdf(tbl, 8, T.shell_code_table_offsets[p + 1] + 1)
		child[i1] = a
		child[i2] = p - a
	else
		child[i1] = 0
		child[i2] = 0
	end
end

local p3, p2, p1 = zeros(2), zeros(4), zeros(8)
local function shellDecoder(pulses, off, ec, pulses4)
	local t0, t1, t2, t3 = T.shell_code_table0, T.shell_code_table1, T.shell_code_table2, T.shell_code_table3
	local o = off
	decodeSplit(p3, 1, 2, ec, pulses4, t3)
	decodeSplit(p2, 1, 2, ec, p3[1], t2)
	decodeSplit(p1, 1, 2, ec, p2[1], t1)
	decodeSplit(pulses, o + 1, o + 2, ec, p1[1], t0)
	decodeSplit(pulses, o + 3, o + 4, ec, p1[2], t0)
	decodeSplit(p1, 3, 4, ec, p2[2], t1)
	decodeSplit(pulses, o + 5, o + 6, ec, p1[3], t0)
	decodeSplit(pulses, o + 7, o + 8, ec, p1[4], t0)
	decodeSplit(p2, 3, 4, ec, p3[2], t2)
	decodeSplit(p1, 5, 6, ec, p2[3], t1)
	decodeSplit(pulses, o + 9, o + 10, ec, p1[5], t0)
	decodeSplit(pulses, o + 11, o + 12, ec, p1[6], t0)
	decodeSplit(p1, 7, 8, ec, p2[4], t1)
	decodeSplit(pulses, o + 13, o + 14, ec, p1[7], t0)
	decodeSplit(pulses, o + 15, o + 16, ec, p1[8], t0)
end

local signIcdf = { 0, 0 }
local function decodeSigns(ec, pulses, length, signalType, quantOffsetType, sumPulses)
	local i0 = 7 * (quantOffsetType + signalType * 2)
	local SIGN = T.sign_iCDF
	length = (length + 8) // 16
	for i = 0, length - 1 do
		local p = sumPulses[i + 1]
		if p > 0 then
			signIcdf[1] = SIGN[i0 + min(band(p, 31), 6) + 1]
			for j = 1, 16 do
				local q = pulses[i * 16 + j]
				if q > 0 then
					pulses[i * 16 + j] = q * (2 * ec:icdf(signIcdf, 8) - 1)
				end
			end
		end
	end
end

local sumPulses, nLshifts = zeros(20), zeros(20)
local function decodePulses(ec, pulses, signalType, quantOffsetType, frameLength)
	local rateLevel = ec:icdf(T.rate_levels_iCDF, 8, (signalType // 2) * 9 + 1)
	local iter = frameLength // 16
	if iter * 16 < frameLength then
		iter += 1
	end
	local PPB = T.pulses_per_block_iCDF
	local base = rateLevel * 18 + 1
	for i = 1, iter do
		nLshifts[i] = 0
		sumPulses[i] = ec:icdf(PPB, 8, base)
		while sumPulses[i] == 17 do
			nLshifts[i] += 1
			sumPulses[i] = ec:icdf(PPB, 8, 9 * 18 + 1 + (if nLshifts[i] == 10 then 1 else 0))
		end
	end
	for i = 1, iter do
		if sumPulses[i] > 0 then
			shellDecoder(pulses, (i - 1) * 16, ec, sumPulses[i])
		else
			for k = (i - 1) * 16 + 1, i * 16 do
				pulses[k] = 0
			end
		end
	end
	for i = 1, iter do
		local nLS = nLshifts[i]
		if nLS > 0 then
			for k = (i - 1) * 16 + 1, i * 16 do
				local a = pulses[k]
				for _ = 1, nLS do
					a = a * 2 + ec:icdf(T.lsb_iCDF, 8)
				end
				pulses[k] = a
			end
			sumPulses[i] += nLS * 32
		end
	end
	decodeSigns(ec, pulses, frameLength, signalType, quantOffsetType, sumPulses)
end

local function decodePitch(lagIndex, contourIndex, pitchLags, fsKHz, nbSubfr)
	local cb, size
	if fsKHz == 8 then
		if nbSubfr == 4 then
			cb, size = T.CB_lags_stage2, 11
		else
			cb, size = T.CB_lags_stage2_10_ms, 3
		end
	else
		if nbSubfr == 4 then
			cb, size = T.CB_lags_stage3, 34
		else
			cb, size = T.CB_lags_stage3_10_ms, 12
		end
	end
	local minLag, maxLag = 2 * fsKHz, 18 * fsKHz
	local lag = minLag + lagIndex
	for k = 0, nbSubfr - 1 do
		pitchLags[k + 1] = limit(lag + cb[k * size + contourIndex + 1], minLag, maxLag)
	end
end

local INV_SCALE_Q16 = (65536 * ((86 * 128) // 6)) // 63
local GAIN_OFFSET = (2 * 128) // 6 + 16 * 128
local function gainsDequant(gainQ16, ind, c, conditional, nbSubfr)
	local prev = c.LastGainIndex
	for k = 0, nbSubfr - 1 do
		if k == 0 and not conditional then
			prev = max(ind[1], prev - 16)
		else
			local indTmp = ind[k + 1] - 4
			local thr = 2 * 36 - 64 + prev
			if indTmp > thr then
				prev += indTmp * 2 - thr
			else
				prev += indTmp
			end
		end
		prev = limit(prev, 0, 63)
		gainQ16[k + 1] = log2lin(min((INV_SCALE_Q16 * prev) // 65536 + GAIN_OFFSET, 3967))
	end
	c.LastGainIndex = prev
end

local NLSFq15, NLSF0q15 = zeros(MAX_LPC_ORDER), zeros(MAX_LPC_ORDER)
local function decodeParameters(c, ctrl, condCoding)
	local idx = c.indices
	gainsDequant(ctrl.Gains_Q16, idx.GainsIndices, c, condCoding == CODE_CONDITIONALLY, c.nb_subfr)
	local order = c.LPC_order
	NLSFdecode(NLSFq15, idx.NLSFIndices, c.NLSF_CB)
	local A0, A1 = ctrl.PredCoef_Q12[1], ctrl.PredCoef_Q12[2]
	NLSF2A(A1, NLSFq15, order)
	if c.first_frame_after_reset == 1 then
		idx.NLSFInterpCoef_Q2 = 4
	end
	if idx.NLSFInterpCoef_Q2 < 4 then
		local prevNLSF = c.prevNLSF_Q15
		for i = 1, order do
			NLSF0q15[i] = prevNLSF[i] + (idx.NLSFInterpCoef_Q2 * (NLSFq15[i] - prevNLSF[i])) // 4
		end
		NLSF2A(A0, NLSF0q15, order)
	else
		for i = 1, order do
			A0[i] = A1[i]
		end
	end
	for i = 1, order do
		c.prevNLSF_Q15[i] = NLSFq15[i]
	end
	if c.lossCnt ~= 0 then
		bwexpander(A0, order, 63570)
		bwexpander(A1, order, 63570)
	end
	if idx.signalType == TYPE_VOICED then
		decodePitch(idx.lagIndex, idx.contourIndex, ctrl.pitchL, c.fs_kHz, c.nb_subfr)
		local cbk = LTP_VQ[idx.PERIndex + 1]
		for k = 0, c.nb_subfr - 1 do
			local Ix = idx.LTPIndex[k + 1]
			for i = 1, LTP_ORDER do
				ctrl.LTPCoef_Q14[k * LTP_ORDER + i] = cbk[Ix * LTP_ORDER + i] * 128
			end
		end
		ctrl.LTP_scale_Q14 = T.LTPScales_table_Q14[idx.LTP_scaleIndex + 1]
	else
		for k = 1, c.nb_subfr do
			ctrl.pitchL[k] = 0
		end
		for k = 1, LTP_ORDER * c.nb_subfr do
			ctrl.LTPCoef_Q14[k] = 0
		end
		idx.PERIndex = 0
		ctrl.LTP_scale_Q14 = 0
	end
end

-- synthesis --------------------------------------------------------------------------------------------------------

local sLTP = zeros(MAX_FRAME_LENGTH)
local sLTP_Q15 = zeros(2 * MAX_FRAME_LENGTH)
local resQ14 = zeros(80)
local sLPC = zeros(80 + MAX_LPC_ORDER)
local Atmp12 = zeros(MAX_LPC_ORDER)

local function decodeCore(c, ctrl, xq, pulses)
	local idx = c.indices
	local offsetQ10 = T.Quantization_Offsets_Q10[(idx.signalType // 2) * 2 + idx.quantOffsetType + 1]
	local interpFlag = idx.NLSFInterpCoef_Q2 < 4
	local seed = idx.Seed
	local exc = c.exc_Q14
	local L = c.frame_length
	for i = 1, L do
		seed = rand(seed)
		local p = pulses[i]
		local e = p * 16384
		if e > 0 then
			e -= 80 * 16
		elseif e < 0 then
			e += 80 * 16
		end
		e += offsetQ10 * 16
		if seed < 0 then
			e = -e
		end
		exc[i] = e
		seed = s32(seed + p)
	end
	local order = c.LPC_order
	local subfr = c.subfr_length
	local ltpMem = c.ltp_mem_length
	local outBuf = c.outBuf
	for i = 1, MAX_LPC_ORDER do
		sLPC[i] = c.sLPC_Q14_buf[i]
	end
	local excOff = 0
	local xqOff = 0
	local sLTPbufIdx = ltpMem -- 0-based
	local lag = 0
	for k = 0, c.nb_subfr - 1 do
		local A = ctrl.PredCoef_Q12[k // 2 + 1]
		for i = 1, order do
			Atmp12[i] = A[i]
		end
		local Bbase = k * LTP_ORDER
		local B = ctrl.LTPCoef_Q14
		local signalType = idx.signalType
		local gain = ctrl.Gains_Q16[k + 1]
		local gainQ10 = gain // 64
		local invGainQ31 = inverse32VarQ(gain, 47)
		local gainAdj
		if gain ~= c.prev_gain_Q16 then
			gainAdj = div32VarQ(c.prev_gain_Q16, gain, 16)
			for i = 1, MAX_LPC_ORDER do
				sLPC[i] = smulww(gainAdj, sLPC[i])
			end
		else
			gainAdj = 65536
		end
		c.prev_gain_Q16 = gain
		if c.lossCnt ~= 0 and c.prevSignalType == TYPE_VOICED and idx.signalType ~= TYPE_VOICED and k < 2 then
			for i = 1, LTP_ORDER do
				B[Bbase + i] = 0
			end
			B[Bbase + 3] = 4096
			signalType = TYPE_VOICED
			ctrl.pitchL[k + 1] = c.lagPrev
		end
		if signalType == TYPE_VOICED then
			lag = ctrl.pitchL[k + 1]
			if k == 0 or (k == 2 and interpFlag) then
				local startIdx = ltpMem - lag - order - 2
				if k == 2 then
					for i = 1, 2 * subfr do
						outBuf[ltpMem + i] = xq[i]
					end
				end
				LPCanalysisFilter(sLTP, startIdx, outBuf, startIdx + k * subfr, Atmp12, ltpMem - startIdx, order)
				if k == 0 then
					invGainQ31 = smulwb(invGainQ31, ctrl.LTP_scale_Q14) * 4
				end
				for i = 0, lag + 1 do
					sLTP_Q15[sLTPbufIdx - i] = smulwb(invGainQ31, sLTP[ltpMem - i])
				end
			elseif gainAdj ~= 65536 then
				for i = 0, lag + 1 do
					sLTP_Q15[sLTPbufIdx - i] = smulww(gainAdj, sLTP_Q15[sLTPbufIdx - i])
				end
			end
		end
		local pres, presOff
		if signalType == TYPE_VOICED then
			local p = sLTPbufIdx - lag + 2 + 1 -- 1-based index of pred_lag_ptr[0]
			local b0, b1, b2, b3, b4 = B[Bbase + 1], B[Bbase + 2], B[Bbase + 3], B[Bbase + 4], B[Bbase + 5]
			for i = 1, subfr do
				local pred = 2 + (sLTP_Q15[p] * b0) // 65536
				pred += (sLTP_Q15[p - 1] * b1) // 65536
				pred += (sLTP_Q15[p - 2] * b2) // 65536
				pred += (sLTP_Q15[p - 3] * b3) // 65536
				pred += (sLTP_Q15[p - 4] * b4) // 65536
				p += 1
				local r = s32(exc[excOff + i] + pred * 2)
				resQ14[i] = r
				sLTPbufIdx += 1
				sLTP_Q15[sLTPbufIdx] = r * 2
			end
			pres, presOff = resQ14, 0
		else
			pres, presOff = exc, excOff
		end
		for i = 1, subfr do
			local pred = order // 2
			local base = MAX_LPC_ORDER + i
			for j = 1, order do
				pred += (sLPC[base - j] * Atmp12[j]) // 65536
			end
			local v = sat32(pres[presOff + i] + lshiftSat32(pred, 4))
			sLPC[base] = v
			xq[xqOff + i] = sat16(rround(smulww(v, gainQ10), 8))
		end
		for i = 1, MAX_LPC_ORDER do
			sLPC[i] = sLPC[subfr + i]
		end
		excOff += subfr
		xqOff += subfr
	end
	for i = 1, MAX_LPC_ORDER do
		c.sLPC_Q14_buf[i] = sLPC[i]
	end
end

-- packet loss concealment and comfort noise --------------------------------------------------------------------------

local HARM_ATT_Q15 = { 32440, 31130 }
local PLC_RAND_ATTENUATE_V_Q15 = { 31130, 26214 }
local PLC_RAND_ATTENUATE_UV_Q15 = { 32440, 29491 }

local function PLCupdate(c, ctrl)
	local plc = c.sPLC
	local idx = c.indices
	c.prevSignalType = idx.signalType
	local ltpGain = 0
	local nb = c.nb_subfr
	if idx.signalType == TYPE_VOICED then
		local j = 0
		while j * c.subfr_length < ctrl.pitchL[nb] do
			if j == nb then
				break
			end
			local t = 0
			for i = 1, LTP_ORDER do
				t += ctrl.LTPCoef_Q14[(nb - 1 - j) * LTP_ORDER + i]
			end
			if t > ltpGain then
				ltpGain = t
				for i = 1, LTP_ORDER do
					plc.LTPCoef_Q14[i] = ctrl.LTPCoef_Q14[(nb - 1 - j) * LTP_ORDER + i]
				end
				plc.pitchL_Q8 = ctrl.pitchL[nb - j] * 256
			end
			j += 1
		end
		for i = 1, LTP_ORDER do
			plc.LTPCoef_Q14[i] = 0
		end
		plc.LTPCoef_Q14[3] = ltpGain
		if ltpGain < 11469 then
			local scale = tdiv(11469 * 1024, max(ltpGain, 1))
			for i = 1, LTP_ORDER do
				plc.LTPCoef_Q14[i] = s16((plc.LTPCoef_Q14[i] * s16(scale)) // 1024)
			end
		elseif ltpGain > 15565 then
			local scale = tdiv(15565 * 16384, max(ltpGain, 1))
			for i = 1, LTP_ORDER do
				plc.LTPCoef_Q14[i] = s16((plc.LTPCoef_Q14[i] * s16(scale)) // 16384)
			end
		end
	else
		plc.pitchL_Q8 = c.fs_kHz * 18 * 256
		for i = 1, LTP_ORDER do
			plc.LTPCoef_Q14[i] = 0
		end
	end
	for i = 1, c.LPC_order do
		plc.prevLPC_Q12[i] = ctrl.PredCoef_Q12[2][i]
	end
	plc.prevLTP_scale_Q14 = ctrl.LTP_scale_Q14
	plc.prevGain_Q16[1] = ctrl.Gains_Q16[nb - 1]
	plc.prevGain_Q16[2] = ctrl.Gains_Q16[nb]
	plc.subfr_length = c.subfr_length
	plc.nb_subfr = nb
end

local excBuf = zeros(160)
local sLTP_Q14 = zeros(2 * MAX_FRAME_LENGTH)
local Aplc = zeros(MAX_LPC_ORDER)
local function PLCconceal(c, ctrl, frame)
	local plc = c.sPLC
	local subfr, nb = c.subfr_length, c.nb_subfr
	local prevGainQ10a = plc.prevGain_Q16[1] // 64
	local prevGainQ10b = plc.prevGain_Q16[2] // 64
	if c.first_frame_after_reset ~= 0 then
		for i = 1, MAX_LPC_ORDER do
			plc.prevLPC_Q12[i] = 0
		end
	end
	local exc = c.exc_Q14
	for k = 0, 1 do
		local g = if k == 0 then prevGainQ10a else prevGainQ10b
		for i = 0, subfr - 1 do
			excBuf[k * subfr + i + 1] = sat16(smulww(exc[i + (k + nb - 2) * subfr + 1], g) // 256)
		end
	end
	local e1, sh1 = sumSqrShift(excBuf, 0, subfr)
	local e2, sh2 = sumSqrShift(excBuf, subfr, subfr)
	local randBase
	if e1 // P2[sh2] < e2 // P2[sh1] then
		randBase = max(0, (plc.nb_subfr - 1) * plc.subfr_length - 128)
	else
		randBase = max(0, plc.nb_subfr * plc.subfr_length - 128)
	end
	local B = plc.LTPCoef_Q14
	local randScale = plc.randScale_Q14
	local att = min(1, c.lossCnt) + 1
	local harmGain = HARM_ATT_Q15[att]
	local randGain = if c.prevSignalType == TYPE_VOICED then PLC_RAND_ATTENUATE_V_Q15[att] else PLC_RAND_ATTENUATE_UV_Q15[att]
	local order = c.LPC_order
	bwexpander(plc.prevLPC_Q12, order, 64881)
	for i = 1, order do
		Aplc[i] = plc.prevLPC_Q12[i]
	end
	if c.lossCnt == 0 then
		randScale = 16384
		if c.prevSignalType == TYPE_VOICED then
			for i = 1, LTP_ORDER do
				randScale -= B[i]
			end
			randScale = max(3277, randScale)
			randScale = s16((randScale * plc.prevLTP_scale_Q14) // 16384)
		else
			local invGain = LPCinversePredGain(plc.prevLPC_Q12, order)
			local down = min(1073741824 // 8, invGain)
			down = max(1073741824 // 256, down)
			down *= 8
			randGain = smulwb(down, randGain) // 16384
		end
	end
	local seed = plc.rand_seed
	local lag = rround(plc.pitchL_Q8, 8)
	local ltpMem = c.ltp_mem_length
	local bufIdx = ltpMem
	local idx = ltpMem - lag - order - 2
	LPCanalysisFilter(sLTP, idx, c.outBuf, idx, Aplc, ltpMem - idx, order)
	local invGainQ30 = inverse32VarQ(plc.prevGain_Q16[2], 46)
	invGainQ30 = min(invGainQ30, 1073741823)
	for i = idx + order, ltpMem - 1 do
		sLTP_Q14[i + 1] = smulwb(invGainQ30, sLTP[i + 1])
	end
	for _ = 0, nb - 1 do
		local p = bufIdx - lag + 2 + 1
		local b0, b1, b2, b3, b4 = B[1], B[2], B[3], B[4], B[5]
		for _ = 1, subfr do
			local pred = 2 + (sLTP_Q14[p] * b0) // 65536
			pred += (sLTP_Q14[p - 1] * b1) // 65536
			pred += (sLTP_Q14[p - 2] * b2) // 65536
			pred += (sLTP_Q14[p - 3] * b3) // 65536
			pred += (sLTP_Q14[p - 4] * b4) // 65536
			p += 1
			seed = rand(seed)
			local ri = band(seed // 33554432, 127)
			bufIdx += 1
			sLTP_Q14[bufIdx] = s32((pred + smulwb(exc[randBase + ri + 1], randScale)) * 4)
		end
		for j = 1, LTP_ORDER do
			B[j] = (harmGain * B[j]) // 32768
		end
		randScale = (randScale * s16(randGain)) // 32768
		plc.pitchL_Q8 = plc.pitchL_Q8 + smulwb(plc.pitchL_Q8, 655)
		plc.pitchL_Q8 = min(plc.pitchL_Q8, 18 * c.fs_kHz * 256)
		lag = rround(plc.pitchL_Q8, 8)
	end
	local base = ltpMem - MAX_LPC_ORDER -- sLPC_Q14_ptr[0] is sLTP_Q14[base + 1]
	for i = 1, MAX_LPC_ORDER do
		sLTP_Q14[base + i] = c.sLPC_Q14_buf[i]
	end
	for i = 1, c.frame_length do
		local at = base + MAX_LPC_ORDER + i
		local pred = order // 2
		for j = 1, order do
			pred += (sLTP_Q14[at - j] * Aplc[j]) // 65536
		end
		local v = sat32(sLTP_Q14[at] + lshiftSat32(pred, 4))
		sLTP_Q14[at] = v
		frame[i] = sat16(rround(smulww(v, prevGainQ10b), 8))
	end
	for i = 1, MAX_LPC_ORDER do
		c.sLPC_Q14_buf[i] = sLTP_Q14[base + c.frame_length + i]
	end
	plc.rand_seed = seed
	plc.randScale_Q14 = randScale
	for i = 1, 4 do
		ctrl.pitchL[i] = lag
	end
end

local function PLC(c, ctrl, frame, lost)
	if c.fs_kHz ~= c.sPLC.fs_kHz then
		PLCreset(c)
		c.sPLC.fs_kHz = c.fs_kHz
	end
	if lost then
		PLCconceal(c, ctrl, frame)
		c.lossCnt += 1
	else
		PLCupdate(c, ctrl)
	end
end

local function PLCglue(c, frame, length)
	local plc = c.sPLC
	if c.lossCnt ~= 0 then
		plc.conc_energy, plc.conc_energy_shift = sumSqrShift(frame, 0, length)
		plc.last_frame_lost = 1
	else
		if plc.last_frame_lost ~= 0 then
			local energy, shift = sumSqrShift(frame, 0, length)
			if shift > plc.conc_energy_shift then
				plc.conc_energy = plc.conc_energy // P2[shift - plc.conc_energy_shift]
			elseif shift < plc.conc_energy_shift then
				energy = energy // P2[plc.conc_energy_shift - shift]
			end
			if energy > plc.conc_energy then
				local LZ = clz32(plc.conc_energy) - 1
				plc.conc_energy = plc.conc_energy * P2[LZ]
				energy = energy // P2[max(24 - LZ, 0)]
				local fracQ24 = tdiv(plc.conc_energy, max(energy, 1))
				local gain = sqrtApprox(fracQ24) * 16
				local slope = tdiv(65536 - gain, length) * 4
				for i = 1, length do
					frame[i] = smulwb(gain, frame[i])
					gain += slope
					if gain > 65536 then
						break
					end
				end
			end
		end
		plc.last_frame_lost = 0
	end
end

local Acng = zeros(MAX_LPC_ORDER)
local cngSig = zeros(MAX_FRAME_LENGTH + MAX_LPC_ORDER)
local function CNG(c, ctrl, frame, length)
	local cng = c.sCNG
	if c.fs_kHz ~= cng.fs_kHz then
		CNGreset(c)
		cng.fs_kHz = c.fs_kHz
	end
	local order = c.LPC_order
	if c.lossCnt == 0 and c.prevSignalType == TYPE_NO_VOICE_ACTIVITY then
		for i = 1, order do
			cng.smthNLSF[i] += smulwb(c.prevNLSF_Q15[i] - cng.smthNLSF[i], 16348)
		end
		local maxGain, subfr = 0, 0
		for i = 0, c.nb_subfr - 1 do
			if ctrl.Gains_Q16[i + 1] > maxGain then
				maxGain = ctrl.Gains_Q16[i + 1]
				subfr = i
			end
		end
		local sl = c.subfr_length
		table.move(cng.exc, 1, (c.nb_subfr - 1) * sl, sl + 1)
		for i = 1, sl do
			cng.exc[i] = c.exc_Q14[subfr * sl + i]
		end
		for i = 1, c.nb_subfr do
			local g = ctrl.Gains_Q16[i]
			cng.smthGain += smulwb(g - cng.smthGain, 4634)
			if smulww(cng.smthGain, 46396) > g then
				cng.smthGain = g
			end
		end
	end
	if c.lossCnt ~= 0 then
		local gain = smulww(c.sPLC.randScale_Q14, c.sPLC.prevGain_Q16[2])
		if gain >= 2097152 or cng.smthGain > 8388608 then
			gain = (gain // 65536) * (gain // 65536)
			gain = s32((cng.smthGain // 65536) * (cng.smthGain // 65536) - gain * 32)
			gain = s32(sqrtApprox(gain) * 65536)
		else
			gain = smulww(gain, gain)
			gain = s32(smulww(cng.smthGain, cng.smthGain) - gain * 32)
			gain = s32(sqrtApprox(gain) * 256)
		end
		local gainQ10 = gain // 64
		-- excitation
		local mask = 255
		while mask > length do
			mask //= 2
		end
		local seed = cng.randSeed
		for i = 1, length do
			seed = rand(seed)
			cngSig[MAX_LPC_ORDER + i] = cng.exc[band(seed // 16777216, mask) + 1]
		end
		cng.randSeed = seed
		NLSF2A(Acng, cng.smthNLSF, order)
		for i = 1, MAX_LPC_ORDER do
			cngSig[i] = cng.synth[i]
		end
		for i = 1, length do
			local at = MAX_LPC_ORDER + i
			local pred = order // 2
			for j = 1, order do
				pred += (cngSig[at - j] * Acng[j]) // 65536
			end
			local v = sat32(cngSig[at] + lshiftSat32(pred, 4))
			cngSig[at] = v
			frame[i] = sat16(frame[i] + sat16(rround(smulww(v, gainQ10), 8)))
		end
		for i = 1, MAX_LPC_ORDER do
			cng.synth[i] = cngSig[length + i]
		end
	else
		for i = 1, order do
			cng.synth[i] = 0
		end
	end
end

-- frame and packet -------------------------------------------------------------------------------------------------

local pulsesBuf = zeros(MAX_FRAME_LENGTH)
local frameBuf = zeros(MAX_FRAME_LENGTH)
local ctrlScratch = {
	pitchL = zeros(4), Gains_Q16 = zeros(4), PredCoef_Q12 = { zeros(MAX_LPC_ORDER), zeros(MAX_LPC_ORDER) },
	LTPCoef_Q14 = zeros(LTP_ORDER * 4), LTP_scale_Q14 = 0,
}

-- decodes one frame of channel c into pOut[off + 1 .. off + frame_length]
local function decodeFrame(c, ec, pOut, off, lostFlag, condCoding)
	local L = c.frame_length
	local ctrl = ctrlScratch
	ctrl.LTP_scale_Q14 = 0
	local frame = frameBuf
	local mv = c.ltp_mem_length - L
	local outBuf = c.outBuf
	if lostFlag == 0 or (lostFlag == 2 and c.LBRR_flags[c.nFramesDecoded + 1] == 1) then
		decodeIndices(c, ec, c.nFramesDecoded, lostFlag ~= 0, condCoding)
		decodePulses(ec, pulsesBuf, c.indices.signalType, c.indices.quantOffsetType, L)
		decodeParameters(c, ctrl, condCoding)
		decodeCore(c, ctrl, frame, pulsesBuf)
		table.move(outBuf, L + 1, L + mv, 1)
		table.move(frame, 1, L, mv + 1, outBuf)
		PLC(c, ctrl, frame, false)
		c.lossCnt = 0
		c.prevSignalType = c.indices.signalType
		c.first_frame_after_reset = 0
	else
		PLC(c, ctrl, frame, true)
		table.move(outBuf, L + 1, L + mv, 1)
		table.move(frame, 1, L, mv + 1, outBuf)
	end
	CNG(c, ctrl, frame, L)
	PLCglue(c, frame, L)
	c.lagPrev = ctrl.pitchL[c.nb_subfr]
	table.move(frame, 1, L, off + 1, pOut)
	return L
end

local function stereoDecodePred(ec, predQ13)
	local n = ec:icdf(T.stereo_pred_joint_iCDF, 8)
	local ix02 = n // 5
	local ix12 = n - 5 * ix02
	local ix00 = ec:icdf(T.uniform3_iCDF, 8)
	local ix01 = ec:icdf(T.uniform5_iCDF, 8)
	local ix10 = ec:icdf(T.uniform3_iCDF, 8)
	local ix11 = ec:icdf(T.uniform5_iCDF, 8)
	local Q = T.stereo_pred_quant_Q13
	for k = 0, 1 do
		local a = (if k == 0 then ix00 else ix10) + 3 * (if k == 0 then ix02 else ix12)
		local b = if k == 0 then ix01 else ix11
		local low = Q[a + 1]
		local step = smulwb(Q[a + 2] - low, 6554)
		predQ13[k + 1] = low + s16(step) * (2 * b + 1)
	end
	predQ13[1] -= predQ13[2]
end

-- x1, x2: arrays where index 1 is C index 0 (two history samples, then the frame)
local function stereoMStoLR(st, x1, x2, predQ13, fsKHz, frameLength)
	x1[1], x1[2] = st.sMid[1], st.sMid[2]
	x2[1], x2[2] = st.sSide[1], st.sSide[2]
	st.sMid[1], st.sMid[2] = x1[frameLength + 1], x1[frameLength + 2]
	st.sSide[1], st.sSide[2] = x2[frameLength + 1], x2[frameLength + 2]
	local pred0, pred1 = st.predPrev[1], st.predPrev[2]
	local interp = 8 * fsKHz
	local denom = tdiv(65536, interp)
	local delta0 = rround(s16(predQ13[1] - st.predPrev[1]) * s16(denom), 16)
	local delta1 = rround(s16(predQ13[2] - st.predPrev[2]) * s16(denom), 16)
	for n = 0, frameLength - 1 do
		if n < interp then
			pred0 += delta0
			pred1 += delta1
		elseif n == interp then
			pred0, pred1 = predQ13[1], predQ13[2]
		end
		local a, b, cc = x1[n + 1], x1[n + 2], x1[n + 3]
		local sum = (a + cc + b * 2) * 512
		sum = x2[n + 2] * 256 + smulwb(sum, pred0)
		sum = sum + smulwb(b * 2048, pred1)
		x2[n + 2] = sat16(rround(sum, 8))
	end
	st.predPrev[1] = predQ13[1]
	st.predPrev[2] = predQ13[2]
	for n = 2, frameLength + 1 do
		local a, b = x1[n], x2[n]
		x1[n] = sat16(a + b)
		x2[n] = sat16(a - b)
	end
end

-- API ----------------------------------------------------------------------------------------------------------------

function Silk.new()
	local dec = {
		control = { payloadSizeMs = 20, nChannelsInternal = 1, internalSampleRate = 16000, nChannelsAPI = 1, prevPitchLag = 0 },
		ch = { {}, {} },
		stereo = { predPrev = { 0, 0 }, sMid = { 0, 0 }, sSide = { 0, 0 } },
		nChannelsAPI = 0, nChannelsInternal = 0, prevDecodeOnlyMiddle = 0,
		tmp = { zeros(MAX_FRAME_LENGTH + 2), zeros(MAX_FRAME_LENGTH + 2) },
		res = zeros(960),
		predQ13 = { 0, 0 },
	}
	resetChannel(dec.ch[1])
	resetChannel(dec.ch[2])
	return dec
end

function Silk.reset(dec)
	resetChannel(dec.ch[1])
	resetChannel(dec.ch[2])
	local st = dec.stereo
	st.predPrev[1], st.predPrev[2], st.sMid[1], st.sMid[2], st.sSide[1], st.sSide[2] = 0, 0, 0, 0, 0, 0
	dec.prevDecodeOnlyMiddle = 0
end

local pulsesLBRR = zeros(MAX_FRAME_LENGTH)
function Silk.decode(dec, lostFlag, newPacket, ec, out, outOff, _maxSamples)
	local ctl = dec.control
	local ch = dec.ch
	local nInt = ctl.nChannelsInternal
	local stereo = dec.stereo
	local predQ13 = dec.predQ13
	predQ13[1], predQ13[2] = 0, 0
	local decodeOnlyMiddle = 0
	if newPacket then
		for n = 1, nInt do
			ch[n].nFramesDecoded = 0
		end
	end
	if nInt > dec.nChannelsInternal then
		resetChannel(ch[2])
	end
	local stereoToMono = nInt == 1 and dec.nChannelsInternal == 2 and ctl.internalSampleRate == 1000 * ch[1].fs_kHz
	if ch[1].nFramesDecoded == 0 then
		for n = 1, nInt do
			local c = ch[n]
			local ms = ctl.payloadSizeMs
			if ms == 0 or ms == 10 then
				c.nFramesPerPacket, c.nb_subfr = 1, 2
			elseif ms == 20 then
				c.nFramesPerPacket, c.nb_subfr = 1, 4
			elseif ms == 40 then
				c.nFramesPerPacket, c.nb_subfr = 2, 4
			elseif ms == 60 then
				c.nFramesPerPacket, c.nb_subfr = 3, 4
			else
				error("SILK: invalid frame size")
			end
			local fsDec = ctl.internalSampleRate // 1024 + 1
			if fsDec ~= 8 and fsDec ~= 12 and fsDec ~= 16 then
				error("SILK: invalid sample rate")
			end
			setFs(c, fsDec, 48000)
		end
	end
	if ctl.nChannelsAPI == 2 and nInt == 2 and (dec.nChannelsAPI == 1 or dec.nChannelsInternal == 1) then
		stereo.predPrev[1], stereo.predPrev[2] = 0, 0
		stereo.sSide[1], stereo.sSide[2] = 0, 0
		copyResampler(ch[2].resampler, ch[1].resampler)
	end
	dec.nChannelsAPI = ctl.nChannelsAPI
	dec.nChannelsInternal = nInt

	if lostFlag ~= 1 and ch[1].nFramesDecoded == 0 then
		for n = 1, nInt do
			local c = ch[n]
			for i = 1, c.nFramesPerPacket do
				c.VAD_flags[i] = ec:bitLogp(1)
			end
			c.LBRR_flag = ec:bitLogp(1)
		end
		for n = 1, nInt do
			local c = ch[n]
			c.LBRR_flags[1], c.LBRR_flags[2], c.LBRR_flags[3] = 0, 0, 0
			if c.LBRR_flag ~= 0 then
				if c.nFramesPerPacket == 1 then
					c.LBRR_flags[1] = 1
				else
					local sym = ec:icdf(LBRR_ICDF[c.nFramesPerPacket - 1], 8) + 1
					for i = 0, c.nFramesPerPacket - 1 do
						c.LBRR_flags[i + 1] = band(sym // P2[i], 1)
					end
				end
			end
		end
		if lostFlag == 0 then
			-- low-bitrate redundancy for an earlier packet: read past it
			for i = 0, ch[1].nFramesPerPacket - 1 do
				for n = 1, nInt do
					local c = ch[n]
					if c.LBRR_flags[i + 1] ~= 0 then
						if nInt == 2 and n == 1 then
							stereoDecodePred(ec, predQ13)
							if ch[2].LBRR_flags[i + 1] == 0 then
								decodeOnlyMiddle = ec:icdf(T.stereo_only_code_mid_iCDF, 8)
							end
						end
						local cond = if i > 0 and c.LBRR_flags[i] ~= 0 then CODE_CONDITIONALLY else CODE_INDEPENDENTLY
						decodeIndices(c, ec, i, true, cond)
						decodePulses(ec, pulsesLBRR, c.indices.signalType, c.indices.quantOffsetType, c.frame_length)
					end
				end
			end
		end
	end

	if nInt == 2 then
		local fi = ch[1].nFramesDecoded + 1
		if lostFlag == 0 or (lostFlag == 2 and ch[1].LBRR_flags[fi] == 1) then
			stereoDecodePred(ec, predQ13)
			if (lostFlag == 0 and ch[2].VAD_flags[fi] == 0) or (lostFlag == 2 and ch[2].LBRR_flags[fi] == 0) then
				decodeOnlyMiddle = ec:icdf(T.stereo_only_code_mid_iCDF, 8)
			else
				decodeOnlyMiddle = 0
			end
		else
			predQ13[1], predQ13[2] = stereo.predPrev[1], stereo.predPrev[2]
		end
	end

	if nInt == 2 and decodeOnlyMiddle == 0 and dec.prevDecodeOnlyMiddle == 1 then
		local c = ch[2]
		c.outBuf = zeros(MAX_FRAME_LENGTH + 160)
		c.sLPC_Q14_buf = zeros(MAX_LPC_ORDER)
		c.lagPrev = 100
		c.LastGainIndex = 10
		c.prevSignalType = TYPE_NO_VOICE_ACTIVITY
		c.first_frame_after_reset = 1
	end

	local hasSide
	if lostFlag == 0 then
		hasSide = decodeOnlyMiddle == 0
	else
		hasSide = dec.prevDecodeOnlyMiddle == 0
			or (nInt == 2 and lostFlag == 2 and ch[2].LBRR_flags[ch[2].nFramesDecoded + 1] == 1)
	end

	local tmp = dec.tmp
	local nSamplesOutDec = 0
	for n = 1, nInt do
		local c = ch[n]
		if n == 1 or hasSide then
			local frameIndex = ch[1].nFramesDecoded - (n - 1)
			local cond
			if frameIndex <= 0 then
				cond = CODE_INDEPENDENTLY
			elseif lostFlag == 2 then
				cond = if c.LBRR_flags[frameIndex] ~= 0 then CODE_CONDITIONALLY else CODE_INDEPENDENTLY
			elseif n > 1 and dec.prevDecodeOnlyMiddle ~= 0 then
				cond = CODE_INDEPENDENTLY_NO_LTP_SCALING
			else
				cond = CODE_CONDITIONALLY
			end
			nSamplesOutDec = decodeFrame(c, ec, tmp[n], 2, lostFlag, cond)
		else
			local t = tmp[n]
			for i = 3, nSamplesOutDec + 2 do
				t[i] = 0
			end
		end
		c.nFramesDecoded += 1
	end

	local apiCh = ctl.nChannelsAPI
	if apiCh == 2 and nInt == 2 then
		stereoMStoLR(stereo, tmp[1], tmp[2], predQ13, ch[1].fs_kHz, nSamplesOutDec)
	else
		local t = tmp[1]
		t[1], t[2] = stereo.sMid[1], stereo.sMid[2]
		stereo.sMid[1], stereo.sMid[2] = t[nSamplesOutDec + 1], t[nSamplesOutDec + 2]
	end

	local nSamplesOut = nSamplesOutDec * 48 // ch[1].fs_kHz
	local res = dec.res
	local scale = 1 / 32768
	for n = 1, min(apiCh, nInt) do
		resample(ch[n].resampler, res, tmp[n], 1, nSamplesOutDec)
		local y = out[n]
		for i = 1, nSamplesOut do
			y[outOff + i] = res[i] * scale
		end
	end
	if apiCh == 2 and nInt == 1 then
		local y = out[2]
		if stereoToMono then
			resample(ch[2].resampler, res, tmp[1], 1, nSamplesOutDec)
			for i = 1, nSamplesOut do
				y[outOff + i] = res[i] * scale
			end
		else
			local x = out[1]
			for i = 1, nSamplesOut do
				y[outOff + i] = x[outOff + i]
			end
		end
	end

	if ch[1].prevSignalType == TYPE_VOICED then
		local mult = { 6, 4, 3 }
		ctl.prevPitchLag = ch[1].lagPrev * mult[(ch[1].fs_kHz - 8) // 4 + 1]
	else
		ctl.prevPitchLag = 0
	end
	if lostFlag == 1 then
		for i = 1, dec.nChannelsInternal do
			ch[i].LastGainIndex = 10
		end
	else
		dec.prevDecodeOnlyMiddle = decodeOnlyMiddle
	end
	return nSamplesOut
end

return Silk
