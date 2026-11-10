--!native
--!optimize 2
-- AC-3 (Dolby Digital) decoder: every channel mode (mono, stereo, dual mono, 3/2 surround and the rest, LFE),
-- coupling, rematrixing, block switching, delta bit allocation, dynamic range control. Surround sound is mixed
-- down to stereo (the LFE channel left out), mono stays mono. Written from the ATSC A/52 standard.
-- Result: { signal = Signal, format = { codec = "ac3", sampleRate, channels (the source's), bitRate } }
--
--   local result = Ac3.decode(bytes, { Yield = task.wait?, MaxSeconds = n? })   -- an .ac3 file: frames back to back
--   local result = Ac3.decodeFrames(buf, frames, options)   -- frames = { { pos, size } } (an MP4 / MKV track's samples)
--   Ac3.isAc3(bytes)
--   options.Random: a function giving 32-bit values for the noise that fills zero-bit mantissas (default: built in)

local AudioLab = script and script:FindFirstAncestor("AudioLab")
local Signal
if AudioLab then
	Signal = require(AudioLab.DSP.Signal)
else
	Signal = { -- standalone Luau (outside Roblox)
		new = function(sampleRate, channels, length)
			local data = table.create(channels)
			for c = 1, channels do
				data[c] = buffer.create(math.max(length, 1) * 4)
			end
			return { sampleRate = sampleRate, channels = channels, length = length, data = data }
		end,
	}
end

local Ac3 = {}

local readu8 = buffer.readu8
local band, rshift, lshift = bit32.band, bit32.rshift, bit32.lshift
local max, min = math.max, math.min

local function fail(msg)
	error("AC-3: " .. msg, 0)
end

------------------------------------------------------------------------------------------------------------------------
-- tables (A/52)

local FRAME_WORDS = { -- [frmsizecod + 1] = 16-bit words per frame at 48, 44.1, 32 kHz
	{ 64, 69, 96 }, { 64, 70, 96 }, { 80, 87, 120 }, { 80, 88, 120 }, { 96, 104, 144 }, { 96, 105, 144 },
	{ 112, 121, 168 }, { 112, 122, 168 }, { 128, 139, 192 }, { 128, 140, 192 }, { 160, 174, 240 }, { 160, 175, 240 },
	{ 192, 208, 288 }, { 192, 209, 288 }, { 224, 243, 336 }, { 224, 244, 336 }, { 256, 278, 384 }, { 256, 279, 384 },
	{ 320, 348, 480 }, { 320, 349, 480 }, { 384, 417, 576 }, { 384, 418, 576 }, { 448, 487, 672 }, { 448, 488, 672 },
	{ 512, 557, 768 }, { 512, 558, 768 }, { 640, 696, 960 }, { 640, 697, 960 }, { 768, 835, 1152 }, { 768, 836, 1152 },
	{ 896, 975, 1344 }, { 896, 976, 1344 }, { 1024, 1114, 1536 }, { 1024, 1115, 1536 }, { 1152, 1253, 1728 },
	{ 1152, 1254, 1728 }, { 1280, 1393, 1920 }, { 1280, 1394, 1920 },
}
local BITRATES = { 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640 }
local RATES = { [0] = 48000, 44100, 32000 }
local FBW = { [0] = 2, 1, 2, 3, 3, 4, 4, 5 } -- full-bandwidth channels of each channel mode

local BAP_TAB = {
	0, 1, 1, 1, 1, 1, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 8, 9, 9, 9, 9, 10, 10, 10, 10, 11, 11, 11,
	11, 12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15, 15,
}
local SLOW_DECAY = { [0] = 0x0f, 0x11, 0x13, 0x15 }
local FAST_DECAY = { [0] = 0x3f, 0x53, 0x67, 0x7b }
local SLOW_GAIN = { [0] = 0x540, 0x4d8, 0x478, 0x410 }
local DB_PER_BIT = { [0] = 0x000, 0x700, 0x900, 0xb00 }
local FLOOR = { [0] = 0x2f0, 0x2b0, 0x270, 0x230, 0x1f0, 0x170, 0x0f0, -2048 }
local FAST_GAIN = { [0] = 0x080, 0x100, 0x180, 0x200, 0x280, 0x300, 0x380, 0x400 }

local BAND_START = { [0] = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
	28, 31, 34, 37, 40, 43, 46, 49, 55, 61, 67, 73, 79, 85, 97, 109, 121, 133, 157, 181, 205, 229, 253 }
local BIN_BAND = table.create(256, 0) -- [bin] = critical band (0-based both)
for b = 0, 49 do
	for k = BAND_START[b], BAND_START[b + 1] - 1 do
		BIN_BAND[k + 1] = b
	end
end
local LOG_ADD = {
	0x40, 0x3f, 0x3e, 0x3d, 0x3c, 0x3b, 0x3a, 0x39, 0x38, 0x37, 0x36, 0x35, 0x34, 0x34, 0x33, 0x32, 0x31, 0x30, 0x2f, 0x2f,
	0x2e, 0x2d, 0x2c, 0x2c, 0x2b, 0x2a, 0x29, 0x29, 0x28, 0x27, 0x26, 0x26, 0x25, 0x24, 0x24, 0x23, 0x23, 0x22, 0x21, 0x21,
	0x20, 0x20, 0x1f, 0x1e, 0x1e, 0x1d, 0x1d, 0x1c, 0x1c, 0x1b, 0x1b, 0x1a, 0x1a, 0x19, 0x19, 0x18, 0x18, 0x17, 0x17, 0x16,
	0x16, 0x15, 0x15, 0x15, 0x14, 0x14, 0x13, 0x13, 0x13, 0x12, 0x12, 0x12, 0x11, 0x11, 0x11, 0x10, 0x10, 0x10, 0x0f, 0x0f,
	0x0f, 0x0e, 0x0e, 0x0e, 0x0d, 0x0d, 0x0d, 0x0d, 0x0c, 0x0c, 0x0c, 0x0c, 0x0b, 0x0b, 0x0b, 0x0b, 0x0a, 0x0a, 0x0a, 0x0a,
	0x0a, 0x09, 0x09, 0x09, 0x09, 0x09, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x06, 0x06,
	0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
	0x04, 0x04, 0x04, 0x04, 0x04, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x02,
	0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
	0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
}
for _ = #LOG_ADD + 1, 260 do
	table.insert(LOG_ADD, 0)
end
local HTH = { -- hearing threshold [band + 1] = { 48 kHz, 44.1 kHz, 32 kHz }
	{ 0x04d0, 0x04f0, 0x0580 }, { 0x04d0, 0x04f0, 0x0580 }, { 0x0440, 0x0460, 0x04b0 }, { 0x0400, 0x0410, 0x0450 },
	{ 0x03e0, 0x03e0, 0x0420 }, { 0x03c0, 0x03d0, 0x03f0 }, { 0x03b0, 0x03c0, 0x03e0 }, { 0x03b0, 0x03b0, 0x03d0 },
	{ 0x03a0, 0x03b0, 0x03c0 }, { 0x03a0, 0x03a0, 0x03b0 }, { 0x03a0, 0x03a0, 0x03b0 }, { 0x03a0, 0x03a0, 0x03b0 },
	{ 0x03a0, 0x03a0, 0x03a0 }, { 0x0390, 0x03a0, 0x03a0 }, { 0x0390, 0x0390, 0x03a0 }, { 0x0390, 0x0390, 0x03a0 },
	{ 0x0380, 0x0390, 0x03a0 }, { 0x0380, 0x0380, 0x03a0 }, { 0x0370, 0x0380, 0x03a0 }, { 0x0370, 0x0380, 0x03a0 },
	{ 0x0360, 0x0370, 0x0390 }, { 0x0360, 0x0370, 0x0390 }, { 0x0350, 0x0360, 0x0390 }, { 0x0350, 0x0360, 0x0390 },
	{ 0x0340, 0x0350, 0x0380 }, { 0x0340, 0x0350, 0x0380 }, { 0x0330, 0x0340, 0x0380 }, { 0x0320, 0x0340, 0x0370 },
	{ 0x0310, 0x0320, 0x0360 }, { 0x0300, 0x0310, 0x0350 }, { 0x02f0, 0x0300, 0x0340 }, { 0x02f0, 0x02f0, 0x0330 },
	{ 0x02f0, 0x02f0, 0x0320 }, { 0x02f0, 0x02f0, 0x0310 }, { 0x0300, 0x02f0, 0x0300 }, { 0x0310, 0x0300, 0x02f0 },
	{ 0x0340, 0x0320, 0x02f0 }, { 0x0390, 0x0350, 0x02f0 }, { 0x03e0, 0x0390, 0x0300 }, { 0x0420, 0x03e0, 0x0310 },
	{ 0x0460, 0x0420, 0x0330 }, { 0x0490, 0x0450, 0x0350 }, { 0x04a0, 0x04a0, 0x03c0 }, { 0x0460, 0x0490, 0x0410 },
	{ 0x0440, 0x0460, 0x0470 }, { 0x0440, 0x0440, 0x04a0 }, { 0x0520, 0x0480, 0x0460 }, { 0x0800, 0x0630, 0x0440 },
	{ 0x0840, 0x0840, 0x0450 }, { 0x0840, 0x0840, 0x04e0 },
}
local QBITS = { [0] = 0, 3, 5, 7, 11, 15, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16 } -- bits per mantissa for bap 6 - 15
local REMATRIX_BANDS = { [0] = 13, 25, 37, 61, 253 }

-- the quantised value of code in levels steps, as a 24-bit fraction (C division: toward zero)
local function dequant(code, levels)
	local v = (code - levels // 2) * 16777216
	local q = v / levels
	return q < 0 and -math.floor(-q) or math.floor(q)
end
local BAP3 = table.create(7)
for i = 0, 6 do
	BAP3[i + 1] = dequant(i, 7)
end
local BAP5 = table.create(15)
for i = 0, 14 do
	BAP5[i + 1] = dequant(i, 15)
end
-- grouped mantissas: 3 in 5 bits (bap 1), 3 in 7 bits (bap 2), 2 in 7 bits (bap 4)
local G1, G2, G4 = table.create(96), table.create(384), table.create(256)
for i = 0, 31 do
	local a, b, c = i // 9, (i % 9) // 3, i % 3
	G1[i * 3 + 1], G1[i * 3 + 2], G1[i * 3 + 3] = dequant(a, 3), dequant(b, 3), dequant(c, 3)
end
for i = 0, 127 do
	G2[i * 3 + 1], G2[i * 3 + 2], G2[i * 3 + 3] = dequant(i // 25, 5), dequant((i % 25) // 5, 5), dequant(i % 5, 5)
	G4[i * 2 + 1], G4[i * 2 + 2] = dequant(i // 11, 11), dequant(i % 11, 11)
end

-- mix levels
local GAIN_LEVELS = { [0] = math.sqrt(2), 1.1892071150027209, 1, 0.8408964152537145, math.sqrt(0.5), 0.5946035575013605, 0.5, 0,
	0.3535533905932738 }
local CENTER_LEVELS = { [0] = 4, 5, 6, 5 }
local SURROUND_LEVELS = { [0] = 4, 6, 7, 6 }
local DEFAULT_MIX = { -- [channel mode][fbw channel] = { left level, right level } (indices into GAIN_LEVELS)
	[0] = { { 2, 7 }, { 7, 2 } }, { { 4, 4 } }, { { 2, 7 }, { 7, 2 } }, { { 2, 7 }, { 5, 5 }, { 7, 2 } },
	{ { 2, 7 }, { 7, 2 }, { 6, 6 } }, { { 2, 7 }, { 5, 5 }, { 7, 2 }, { 8, 8 } }, { { 2, 7 }, { 7, 2 }, { 6, 7 }, { 7, 6 } },
	{ { 2, 7 }, { 5, 5 }, { 7, 2 }, { 6, 7 }, { 7, 6 } },
}

-- the 512-sample Kaiser-Bessel-derived window (alpha 5), its first half
local WINDOW = table.create(256, 0)
do
	local function i0(x)
		local s, t = 1, 1
		for k = 1, 60 do
			t *= (x / (2 * k)) ^ 2
			s += t
			if t < s * 1e-17 then
				break
			end
		end
		return s
	end
	local n = 256
	local alpha2 = 4 * (5 * math.pi / n) ^ 2
	local temp = {}
	local scale = 0
	for i = 0, n // 2 do
		temp[i] = i0(math.sqrt(i * (n - i) * alpha2))
		scale += temp[i] * ((i > 0 and i < n // 2) and 2 or 1)
	end
	scale = 1 / (scale + 1)
	local sum = 0
	for i = 0, n // 2 do
		sum += temp[i]
		WINDOW[i + 1] = math.sqrt(sum * scale)
	end
	for i = n // 2 + 1, n - 1 do
		sum += temp[n - i]
		WINDOW[i + 1] = math.sqrt(sum * scale)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- the inverse MDCT, half output (the middle half of the 2N samples; the window and overlap rebuild the rest)

local imdctPlans = {}
local function plan(n2) -- n2 coefficients
	local p = imdctPlans[n2]
	if p then
		return p
	end
	local n = 2 * n2
	local n4 = n2 // 2
	p = { n2 = n2, n4 = n4, cos = table.create(n4), sin = table.create(n4), rev = table.create(n4) }
	for i = 0, n4 - 1 do
		local a = 2 * math.pi * (i + 1 / 8) / n
		p.cos[i + 1] = -math.cos(a)
		p.sin[i + 1] = -math.sin(a)
	end
	local bits = 0
	while lshift(1, bits) < n4 do
		bits += 1
	end
	for i = 0, n4 - 1 do
		local r, v = 0, i
		for _ = 1, bits do
			r = r * 2 + v % 2
			v //= 2
		end
		p.rev[i + 1] = r
	end
	-- twiddles for the complex FFT of n4 points
	p.wr, p.wi = table.create(n4), table.create(n4)
	for i = 0, n4 - 1 do
		p.wr[i + 1] = math.cos(2 * math.pi * i / n4)
		p.wi[i + 1] = math.sin(2 * math.pi * i / n4)
	end
	imdctPlans[n2] = p
	return p
end

local ZR, ZI = table.create(128, 0), table.create(128, 0)

-- X[1 .. n2] (or its even / odd half: input index i0 + step * k) -> out[1 .. n2]
local function imdctHalf(X, i0: number, step: number, n2: number, out)
	local p = plan(n2)
	local n4 = p.n4
	local n8 = n4 // 2
	local tc, ts, rev = p.cos, p.sin, p.rev
	-- pre-rotation
	for k = 0, n4 - 1 do
		local j = rev[k + 1] + 1
		local a = X[i0 + step * (n2 - 1 - 2 * k)] -- in2
		local b = X[i0 + step * (2 * k)] -- in1
		local c, s = tc[k + 1], ts[k + 1]
		ZR[j] = a * c - b * s
		ZI[j] = a * s + b * c
	end
	-- complex FFT (radix 2, in place, bit-reversed input)
	local wr, wi = p.wr, p.wi
	local size = 2
	while size <= n4 do
		local half = size // 2
		local stepw = n4 // size
		for start = 0, n4 - 1, size do
			for k = 0, half - 1 do
				local a = start + k + 1
				local b = a + half
				local cr, ci = wr[k * stepw + 1], wi[k * stepw + 1]
				local br, bi = ZR[b] * cr - ZI[b] * ci, ZR[b] * ci + ZI[b] * cr
				local ar, ai = ZR[a], ZI[a]
				ZR[a], ZI[a] = ar + br, ai + bi
				ZR[b], ZI[b] = ar - br, ai - bi
			end
		end
		size *= 2
	end
	-- post-rotation, written as n2 reals: out[2k + 1] = re, out[2k + 2] = im of element k
	for k = 0, n8 - 1 do
		local a = n8 - k -- (1-based n8 - k - 1)
		local b = n8 + k + 1
		local ar, ai = ZR[a], ZI[a]
		local br, bi = ZR[b], ZI[b]
		local ca, sa = tc[a], ts[a]
		local cb, sb = tc[b], ts[b]
		-- (r0, i1) = (z[a].im, z[a].re) * (tsin[a], tcos[a]); (r1, i0) = (z[b].im, z[b].re) * (tsin[b], tcos[b])
		local r0 = ai * sa - ar * ca
		local i1 = ai * ca + ar * sa
		local r1 = bi * sb - br * cb
		local i0v = bi * cb + br * sb
		out[2 * (a - 1) + 1], out[2 * (a - 1) + 2] = r0, i0v
		out[2 * (b - 1) + 1], out[2 * (b - 1) + 2] = r1, i1
	end
end

------------------------------------------------------------------------------------------------------------------------
-- bits (most significant first)

local B: buffer, bitPos, bitEnd = buffer.create(1), 0, 0

local POW2 = table.create(33, 0)
for i = 0, 32 do
	POW2[i + 1] = 2 ^ i
end

local function getBits(n: number): number
	local v = 0
	while n > 0 do
		local byte = bitPos // 8
		local avail = 8 - bitPos % 8
		local take = min(n, avail)
		local b = 0
		if byte < bitEnd then
			b = readu8(B, byte)
		end
		v = v * POW2[take + 1] + band(rshift(b, avail - take), POW2[take + 1] - 1)
		bitPos += take
		n -= take
	end
	return v
end

local function getSigned(n: number): number
	local v = getBits(n)
	if v >= POW2[n] then
		v -= POW2[n + 1]
	end
	return v
end

------------------------------------------------------------------------------------------------------------------------
-- the decoder

local function newState()
	local st = { ch = {} }
	for c = 0, 6 do
		st.ch[c] = {
			dexps = table.create(256, 0), psd = table.create(256, 0), bandPsd = table.create(50, 0), mask = table.create(50, 0),
			bap = table.create(256, 0), coeffs = table.create(256, 0), delay = table.create(128, 0), half = table.create(256, 0),
			startFreq = 0, endFreq = 0, expStr = 0, snr = 0, fastGain = 0, dbaMode = 0, dbaN = 0, dbaOff = {}, dbaLen = {},
			dbaVal = {}, cplCoords = table.create(18, 0), inCpl = false, blkSw = false, dither = false,
		}
	end
	st.cplBandStruct = table.create(18, 0)
	st.cplBandSizes = table.create(18, 0)
	st.phase = table.create(18, false)
	st.remat = table.create(4, false)
	st.seed = 1
	return st
end

-- excitation, masking curve and delta bit allocation, then the bit allocation pointers of channel c
local function bitAlloc(st, c, isLfe, stages)
	local k = st.ch[c]
	local start, stop = k.startFreq, k.endFreq
	local dexps, psd, bpsd, mask, bap = k.dexps, k.psd, k.bandPsd, k.mask, k.bap
	if stages > 2 then
		for bin = start, stop - 1 do
			psd[bin + 1] = 3072 - dexps[bin + 1] * 128
		end
		local bin = start
		local lastSingle = min(stop, 28)
		while bin < lastSingle do
			bpsd[bin + 1] = psd[bin + 1]
			bin += 1
		end
		if bin < stop then
			local bnd = BIN_BAND[bin + 1]
			repeat
				local v = psd[bin + 1]
				bin += 1
				local bandEnd = min(BAND_START[bnd + 1], stop)
				while bin < bandEnd do
					local p = psd[bin + 1]
					local m = max(v, p)
					local adr = min(m - (v + p + 1) // 2, 255)
					v = m + LOG_ADD[adr + 1]
					bin += 1
				end
				bpsd[bnd + 1] = v
				bnd += 1
			until stop <= BAND_START[bnd]
		end
	end
	if stages > 1 then
		local excite = st.excite
		local fastGain, slowGain, fastDecay, slowDecay = k.fastGain, st.slowGain, st.fastDecay, st.slowDecay
		local bandStart = BIN_BAND[start + 1]
		local bandEnd = BIN_BAND[stop] + 1
		local fastleak, slowleak, lowcomp = 0, 0, 0
		local begin
		local function lowcomp1(a, b0, b1, cc)
			if b0 + 256 == b1 then
				return cc
			elseif b0 > b1 then
				return max(a - 64, 0)
			end
			return a
		end
		if bandStart == 0 then
			lowcomp = lowcomp1(lowcomp, bpsd[1], bpsd[2], 384)
			excite[1] = bpsd[1] - fastGain - lowcomp
			lowcomp = lowcomp1(lowcomp, bpsd[2], bpsd[3], 384)
			excite[2] = bpsd[2] - fastGain - lowcomp
			begin = 7
			for b = 2, 6 do
				if not (isLfe and b == 6) then
					lowcomp = lowcomp1(lowcomp, bpsd[b + 1], bpsd[b + 2], 384)
				end
				fastleak = bpsd[b + 1] - fastGain
				slowleak = bpsd[b + 1] - slowGain
				excite[b + 1] = fastleak - lowcomp
				if not (isLfe and b == 6) then
					if bpsd[b + 1] <= bpsd[b + 2] then
						begin = b + 1
						break
					end
				end
			end
			local end1 = min(bandEnd, 22)
			for b = begin, end1 - 1 do
				if not (isLfe and b == 6) then
					if b < 7 then
						lowcomp = lowcomp1(lowcomp, bpsd[b + 1], bpsd[b + 2], 384)
					elseif b < 20 then
						lowcomp = lowcomp1(lowcomp, bpsd[b + 1], bpsd[b + 2], 320)
					else
						lowcomp = max(lowcomp - 128, 0)
					end
				end
				fastleak = max(fastleak - fastDecay, bpsd[b + 1] - fastGain)
				slowleak = max(slowleak - slowDecay, bpsd[b + 1] - slowGain)
				excite[b + 1] = max(fastleak - lowcomp, slowleak)
			end
			begin = 22
		else
			-- the coupling channel
			begin = bandStart
			fastleak = st.cplFastLeak * 256 + 768
			slowleak = st.cplSlowLeak * 256 + 768
		end
		for b = begin, bandEnd - 1 do
			fastleak = max(fastleak - fastDecay, bpsd[b + 1] - fastGain)
			slowleak = max(slowleak - slowDecay, bpsd[b + 1] - slowGain)
			excite[b + 1] = max(fastleak, slowleak)
		end
		local hth = st.srCode + 1
		local dbpb = st.dbPerBit
		for b = bandStart, bandEnd - 1 do
			local tmp = dbpb - bpsd[b + 1]
			if tmp > 0 then
				excite[b + 1] += tmp // 4
			end
			mask[b + 1] = max(HTH[rshift(b, st.srShift) + 1][hth], excite[b + 1])
		end
		if k.dbaMode == 0 or k.dbaMode == 1 then -- (reuse, new)
			local b = bandStart
			for seg = 1, k.dbaN do
				b += k.dbaOff[seg]
				if b >= 50 or k.dbaLen[seg] > 50 - b then
					fail("broken delta bit allocation")
				end
				local v = k.dbaVal[seg]
				local delta = (v >= 4 and (v - 3) or (v - 4)) * 128
				for _ = 1, k.dbaLen[seg] do
					mask[b + 1] += delta
					b += 1
				end
			end
		end
	end
	if stages > 0 then
		local snr, floor = k.snr, st.floor
		if snr == -960 then
			for bin = 0, 255 do
				bap[bin + 1] = 0
			end
			return
		end
		local bin = start
		while bin < min(stop, 28) do
			local m = band(max(mask[bin + 1] - snr - floor, 0), 0x1FE0) + floor
			local adr = math.clamp((psd[bin + 1] - m) // 32, 0, 63)
			bap[bin + 1] = BAP_TAB[adr + 1]
			bin += 1
		end
		if bin < stop then
			local bnd = BIN_BAND[bin + 1]
			repeat
				local m = band(max(mask[bnd + 1] - snr - floor, 0), 0x1FE0) + floor
				bnd += 1
				local bandEnd = min(BAND_START[bnd], stop)
				while bin < bandEnd do
					local adr = math.clamp((psd[bin + 1] - m) // 32, 0, 63)
					bap[bin + 1] = BAP_TAB[adr + 1]
					bin += 1
				end
			until stop <= BAND_START[bnd]
		end
	end
end

-- exponents: the absolute first one, then groups of three differences in 7 bits
local function decodeExponents(st, k, strategy, ngrps, absexp, first)
	local gsize = strategy == 3 and 4 or strategy
	local dexps = k.dexps
	local prev = absexp
	local j = first
	for _ = 1, ngrps do
		local acc = getBits(7)
		if acc >= 125 then
			fail("broken exponents")
		end
		local d = { acc // 25, (acc % 25) // 5, acc % 5 }
		for t = 1, 3 do
			prev += d[t] - 2
			if prev < 0 or prev > 24 then
				fail("broken exponents")
			end
			for _ = 1, gsize do
				dexps[j + 1] = prev
				j += 1
			end
		end
	end
end

-- mantissas of channel c into its coefficients (24-bit fixed point values times 2^-exponent)
local function decodeMantissas(st, c, mg)
	local k = st.ch[c]
	local bap, dexps, coeffs = k.bap, k.dexps, k.coeffs
	local dither = c == 0 or k.dither
	for f = k.startFreq, k.endFreq - 1 do
		local b = bap[f + 1]
		local mant
		if b == 0 then
			if dither then
				local r
				if st.random then
					r = st.random()
				else
					st.seed = (st.seed * 1103515245 + 12345) % 4294967296
					r = st.seed
				end
				mant = (r // 256) * 181 // 256 - 5931008
			else
				mant = 0
			end
		elseif b == 1 then
			if mg.n1 > 0 then
				mg.n1 -= 1
				mant = mg.g1[2 - mg.n1]
			else
				local v = getBits(5) * 3
				mant = G1[v + 1]
				mg.g1[1], mg.g1[2] = G1[v + 2], G1[v + 3]
				mg.n1 = 2
			end
		elseif b == 2 then
			if mg.n2 > 0 then
				mg.n2 -= 1
				mant = mg.g2[2 - mg.n2]
			else
				local v = getBits(7) * 3
				mant = G2[v + 1]
				mg.g2[1], mg.g2[2] = G2[v + 2], G2[v + 3]
				mg.n2 = 2
			end
		elseif b == 3 then
			mant = BAP3[getBits(3) + 1]
		elseif b == 4 then
			if mg.n4 > 0 then
				mg.n4 = 0
				mant = mg.g4
			else
				local v = getBits(7) * 2
				mant = G4[v + 1]
				mg.g4 = G4[v + 2]
				mg.n4 = 1
			end
		elseif b == 5 then
			mant = BAP5[getBits(4) + 1]
		else
			local q = QBITS[b]
			mant = getSigned(q) * 2 ^ (24 - q)
		end
		coeffs[f + 1] = mant * 2 ^ -dexps[f + 1]
	end
end

-- one frame at pos (its syncword); out(channelSamples) gets 6 blocks of 256 samples per output channel
local function decodeFrame(st, buf: buffer, pos: number, size: number, emit)
	B, bitPos, bitEnd = buf, pos * 8, pos + size
	if getBits(16) ~= 0x0B77 then
		fail("lost sync")
	end
	local bsid = band(rshift(readu8(buf, pos + 5), 3), 31)
	if bsid > 10 then
		fail(bsid <= 16 and "the sound is E-AC-3 (Dolby Digital Plus), which AudioLab can't read; AC-3 works"
			or "unknown bitstream version")
	end
	getBits(16) -- crc1
	local fscod = getBits(2)
	if fscod == 3 then
		fail("reserved sample rate")
	end
	local frmsizecod = getBits(6)
	if frmsizecod > 37 then
		fail("reserved frame size")
	end
	getBits(5) -- bsid
	getBits(3) -- bsmod
	local acmod = getBits(3)
	local cmix, smix = 5, 6
	if acmod == 2 then
		getBits(2) -- dsurmod
	else
		if acmod % 2 == 1 and acmod ~= 1 then
			cmix = CENTER_LEVELS[getBits(2)]
		end
		if acmod >= 4 then
			smix = SURROUND_LEVELS[getBits(2)]
		end
	end
	local lfeon = getBits(1) == 1
	for _ = 1, acmod == 0 and 2 or 1 do
		getBits(5) -- dialnorm
		if getBits(1) == 1 then
			getBits(8) -- compr
		end
		if getBits(1) == 1 then
			getBits(8) -- langcod
		end
		if getBits(1) == 1 then
			getBits(7) -- mixlevel, roomtyp
		end
	end
	getBits(2) -- copyrightb, origbs
	if bsid ~= 6 then
		if getBits(1) == 1 then
			getBits(14)
		end
		if getBits(1) == 1 then
			getBits(14)
		end
	else
		if getBits(1) == 1 then
			getBits(2)
			getBits(3)
			getBits(3)
			cmix = getBits(3)
			smix = math.clamp(getBits(3), 3, 7)
		end
		if getBits(1) == 1 then
			getBits(14)
		end
	end
	if getBits(1) == 1 then
		bitPos += 8 * (getBits(6) + 1) -- (additional information)
	end
	local srShift = max(bsid, 8) - 8
	local rate = RATES[fscod] // 2 ^ srShift
	local fbw = FBW[acmod]
	local nch = fbw + (lfeon and 1 or 0)
	local lfeCh = lfeon and fbw + 1 or -1
	if st.rate and (st.rate ~= rate or st.acmod ~= acmod or st.lfeon ~= lfeon) then
		fail("the stream changes its sample rate or channels part way")
	end
	st.rate, st.acmod, st.lfeon, st.fbw, st.nch = rate, acmod, lfeon, fbw, nch
	st.srCode, st.srShift = fscod, srShift
	st.bitRate = BITRATES[frmsizecod // 2 + 1] * 1000 // 2 ^ srShift
	st.cmix, st.smix = cmix, smix
	if lfeon then
		local k = st.ch[lfeCh]
		k.startFreq, k.endFreq, k.inCpl = 0, 7, false
	end
	st.excite = st.excite or table.create(50, 0)
	local CH = st.ch
	for blk = 0, 5 do
		local stages = table.create(7, 0)
		-- block switch and dither flags
		for c = 1, fbw do
			CH[c].blkSw = getBits(1) == 1
		end
		for c = 1, fbw do
			CH[c].dither = getBits(1) == 1
		end
		-- dynamic range
		for i = (acmod == 0 and 1 or 0), 0, -1 do
			if getBits(1) == 1 then
				local r = getBits(8)
				local e = r // 32
				if e >= 4 then
					e -= 8
				end
				st.dynrng[i] = 2 ^ (e - 5) * (32 + r % 32)
			elseif blk == 0 then
				st.dynrng[i] = 1
			end
		end
		-- coupling strategy
		if getBits(1) == 1 then
			for c = 0, 6 do
				stages[c + 1] = 3
			end
			st.cplInUse = getBits(1) == 1
			if st.cplInUse then
				if acmod < 2 then
					fail("coupling in a mono stream")
				end
				for c = 1, fbw do
					CH[c].inCpl = getBits(1) == 1
				end
				if acmod == 2 then
					st.phaseInUse = getBits(1) == 1
				end
				local cs = getBits(4)
				local ce = getBits(4) + 3
				if cs >= ce then
					fail("broken coupling range")
				end
				CH[0].startFreq = cs * 12 + 37
				CH[0].endFreq = ce * 12 + 37
				local nsub = ce - cs
				local struct = st.cplBandStruct
				for s = 1, nsub - 1 do
					struct[s] = getBits(1)
				end
				local sizes = st.cplBandSizes
				local nb = nsub
				sizes[1] = 12
				local b = 1
				for s = 1, nsub - 1 do
					if struct[s] == 1 then
						nb -= 1
						sizes[b] += 12
					else
						b += 1
						sizes[b] = 12
					end
				end
				st.nCplBands = nb
			else
				for c = 1, fbw do
					CH[c].inCpl = false
				end
				st.phaseInUse = false
			end
		elseif blk == 0 then
			fail("no coupling strategy in block 0")
		end
		local cpl = st.cplInUse
		-- coupling coordinates
		if cpl then
			local any = false
			for c = 1, fbw do
				local k = CH[c]
				if k.inCpl then
					if getBits(1) == 1 then
						any = true
						local master = 3 * getBits(2)
						for bnd = 1, st.nCplBands do
							local e = getBits(4)
							local m = getBits(4)
							local v
							if e == 15 then
								v = m * 2 ^ 22
							else
								v = (m + 16) * 2 ^ 21
							end
							k.cplCoords[bnd] = v // 2 ^ (e + master)
						end
					elseif blk == 0 then
						fail("no coupling coordinates in block 0")
					end
				end
			end
			if acmod == 2 and any then
				for bnd = 1, st.nCplBands do
					st.phase[bnd] = st.phaseInUse and getBits(1) == 1
				end
			end
		end
		-- rematrixing
		if acmod == 2 then
			if getBits(1) == 1 then
				local n = 4
				if cpl and CH[0].startFreq <= 61 then
					n -= 1 + (CH[0].startFreq == 37 and 1 or 0)
				end
				st.nRemat = n
				for b = 1, n do
					st.remat[b] = getBits(1) == 1
				end
			elseif blk == 0 then
				st.nRemat = 0
			end
		end
		-- exponent strategies
		for c = cpl and 0 or 1, nch do
			local k = CH[c]
			k.expStr = getBits(c == lfeCh and 1 or 2)
			if k.expStr ~= 0 then
				stages[c + 1] = 3
			end
		end
		-- bandwidths
		local ngrps = {}
		for c = 1, fbw do
			local k = CH[c]
			k.startFreq = 0
			if k.expStr ~= 0 then
				local prev = k.endFreq
				if k.inCpl then
					k.endFreq = CH[0].startFreq
				else
					local code = getBits(6)
					if code > 60 then
						fail("broken bandwidth")
					end
					k.endFreq = code * 3 + 73
				end
				local gs = 3 * 2 ^ (k.expStr - 1)
				ngrps[c] = (k.endFreq + gs - 4) // gs
				if blk > 0 and k.endFreq ~= prev then
					for t = 1, 7 do
						stages[t] = 3
					end
				end
			end
		end
		if cpl and CH[0].expStr ~= 0 then
			ngrps[0] = (CH[0].endFreq - CH[0].startFreq) // (3 * 2 ^ (CH[0].expStr - 1))
		end
		if lfeon then
			ngrps[lfeCh] = 2
		end
		-- exponents
		for c = cpl and 0 or 1, nch do
			local k = CH[c]
			if k.expStr ~= 0 then
				local abs = getBits(4)
				if c == 0 then
					abs *= 2
				end
				k.dexps[1] = abs
				decodeExponents(st, k, k.expStr, ngrps[c], abs, k.startFreq + (c > 0 and 1 or 0))
				if c ~= 0 and c ~= lfeCh then
					getBits(2) -- gainrng
				end
			end
		end
		-- bit allocation parameters
		if getBits(1) == 1 then
			st.slowDecay = SLOW_DECAY[getBits(2)] // 2 ^ srShift
			st.fastDecay = FAST_DECAY[getBits(2)] // 2 ^ srShift
			st.slowGain = SLOW_GAIN[getBits(2)]
			st.dbPerBit = DB_PER_BIT[getBits(2)]
			st.floor = FLOOR[getBits(3)]
			for c = cpl and 0 or 1, nch do
				stages[c + 1] = max(stages[c + 1], 2)
			end
		elseif blk == 0 then
			fail("no bit allocation parameters in block 0")
		end
		-- SNR offsets and fast gains
		if getBits(1) == 1 then
			local csnr = (getBits(6) - 15) * 16
			for c = cpl and 0 or 1, nch do
				local k = CH[c]
				local snr = (csnr + getBits(4)) * 4
				if blk > 0 and k.snr ~= snr then
					stages[c + 1] = max(stages[c + 1], 1)
				end
				k.snr = snr
				local fg = FAST_GAIN[getBits(3)]
				if blk > 0 and fg ~= k.fastGain then
					stages[c + 1] = max(stages[c + 1], 2)
				end
				k.fastGain = fg
			end
		elseif blk == 0 then
			fail("no SNR offsets in block 0")
		end
		-- coupling leak
		if cpl then
			if getBits(1) == 1 then
				local fl, sl = getBits(3), getBits(3)
				if blk > 0 and (fl ~= st.cplFastLeak or sl ~= st.cplSlowLeak) then
					stages[1] = max(stages[1], 2)
				end
				st.cplFastLeak, st.cplSlowLeak = fl, sl
			elseif blk == 0 then
				fail("no coupling leak in block 0")
			end
		end
		-- delta bit allocation
		if getBits(1) == 1 then
			for c = cpl and 0 or 1, fbw do
				CH[c].dbaMode = getBits(2)
				if CH[c].dbaMode == 3 then
					fail("reserved delta bit allocation mode")
				end
				stages[c + 1] = max(stages[c + 1], 2)
			end
			for c = cpl and 0 or 1, fbw do
				local k = CH[c]
				if k.dbaMode == 1 then
					k.dbaN = getBits(3) + 1
					for seg = 1, k.dbaN do
						k.dbaOff[seg] = getBits(5)
						k.dbaLen[seg] = getBits(4)
						k.dbaVal[seg] = getBits(3)
					end
					stages[c + 1] = max(stages[c + 1], 2)
				end
			end
		elseif blk == 0 then
			for c = 0, nch do
				CH[c].dbaMode = 2 -- (none)
			end
		end
		for c = cpl and 0 or 1, nch do
			if stages[c + 1] > 0 then
				bitAlloc(st, c, c == lfeCh, stages[c + 1])
			end
		end
		-- skipped data
		if getBits(1) == 1 then
			local n = getBits(9)
			bitPos += 8 * n
		end
		-- mantissas (the coupling channel's come after the first coupled channel's)
		local mg = st.mg
		mg.n1, mg.n2, mg.n4 = 0, 0, 0
		local gotCpl = false
		for c = 1, nch do
			local k = CH[c]
			decodeMantissas(st, c, mg)
			local stop
			if k.inCpl and cpl then
				if not gotCpl then
					decodeMantissas(st, 0, mg)
					gotCpl = true
					-- uncouple: each coupled channel = the coupling channel x its coordinate
					local K0 = CH[0]
					local bin = K0.startFreq
					for bnd = 1, st.nCplBands do
						local bandEnd = bin + st.cplBandSizes[bnd]
						for cc = 1, fbw do
							local kc = CH[cc]
							if kc.inCpl then
								local coord = kc.cplCoords[bnd] / 8388608
								local flip = cc == 2 and st.phase[bnd]
								for f = bin, bandEnd - 1 do
									local v = K0.coeffs[f + 1] * coord
									kc.coeffs[f + 1] = flip and -v or v
								end
							end
						end
						bin = bandEnd
					end
				end
				stop = CH[0].endFreq
			else
				stop = k.endFreq
			end
			for f = stop, 255 do
				k.coeffs[f + 1] = 0
			end
		end
		-- (coupled channels without dither: no noise where the coupling channel has no bits)
		if cpl then
			for c = 1, fbw do
				local k = CH[c]
				if k.inCpl and not k.dither then
					for f = CH[0].startFreq, CH[0].endFreq - 1 do
						if CH[0].bap[f + 1] == 0 then
							k.coeffs[f + 1] = 0
						end
					end
				end
			end
		end
		-- rematrixing
		if acmod == 2 then
			local stop = min(CH[1].endFreq, CH[2].endFreq)
			local a, b = CH[1].coeffs, CH[2].coeffs
			for bnd = 0, st.nRemat - 1 do
				if st.remat[bnd + 1] then
					for f = REMATRIX_BANDS[bnd], min(stop, REMATRIX_BANDS[bnd + 1]) - 1 do
						local x, y = a[f + 1], b[f + 1]
						a[f + 1], b[f + 1] = x + y, x - y
					end
				end
			end
		end
		-- transform each channel to 256 samples
		local outs = st.blockOut
		for c = 1, nch do
			local k = CH[c]
			local gain = st.dynrng[(acmod == 0 and c <= 2) and (2 - c) or 0] / 4194304
			local X, half, delay = k.coeffs, k.half, k.delay
			for f = 1, 256 do
				X[f] *= gain
			end
			local o = outs[c]
			if k.blkSw then
				imdctHalf(X, 1, 2, 128, half)
				for i = 0, 127 do
					local j = 255 - i
					local s0, s1 = delay[i + 1], half[128 - i]
					local wi, wj = WINDOW[i + 1], WINDOW[j + 1]
					o[i + 1] = s0 * wj - s1 * wi
					o[j + 1] = s0 * wi + s1 * wj
				end
				imdctHalf(X, 2, 2, 128, half)
				for i = 1, 128 do
					delay[i] = half[i]
				end
			else
				imdctHalf(X, 1, 1, 256, half)
				for i = 0, 127 do
					local j = 255 - i
					local s0, s1 = delay[i + 1], half[128 - i]
					local wi, wj = WINDOW[i + 1], WINDOW[j + 1]
					o[i + 1] = s0 * wj - s1 * wi
					o[j + 1] = s0 * wi + s1 * wj
				end
				for i = 1, 128 do
					delay[i] = half[128 + i]
				end
			end
		end
		emit(outs)
	end
end

-- the stereo (or mono) mix of the frame's channels
local function mixer(st)
	local acmod = st.acmod
	if acmod == 1 then
		return 1, { { 1 } }
	elseif acmod == 0 or acmod == 2 then
		return 2, { { 1, 0 }, { 0, 1 } }
	end
	local fbw = st.fbw
	local L, R = {}, {}
	for c = 1, fbw do
		local d = DEFAULT_MIX[acmod][c]
		L[c], R[c] = GAIN_LEVELS[d[1]], GAIN_LEVELS[d[2]]
	end
	if acmod % 2 == 1 then
		L[2], R[2] = GAIN_LEVELS[st.cmix], GAIN_LEVELS[st.cmix]
	end
	if acmod == 4 or acmod == 5 then
		local s = acmod - 2 + 1
		L[s], R[s] = GAIN_LEVELS[st.smix] * math.sqrt(0.5), GAIN_LEVELS[st.smix] * math.sqrt(0.5)
	elseif acmod == 6 or acmod == 7 then
		local s = acmod - 4 + 1
		L[s], R[s + 1] = GAIN_LEVELS[st.smix], GAIN_LEVELS[st.smix]
	end
	local nl, nr = 0, 0
	for c = 1, fbw do
		nl += L[c]
		nr += R[c]
	end
	local m = {}
	for c = 1, fbw do
		m[c] = { L[c] / nl, R[c] / nr }
	end
	return 2, m
end

local function isSync(buf, p)
	return p + 6 <= buffer.len(buf) and readu8(buf, p) == 0x0B and readu8(buf, p + 1) == 0x77
end

function Ac3.isAc3(bytes)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not isSync(buf, 0) then
		return false
	end
	local fscod = rshift(readu8(buf, 4), 6)
	local code = band(readu8(buf, 4), 63)
	if fscod == 3 or code > 37 then
		return false
	end
	-- (a second frame right after the first)
	local size = FRAME_WORDS[code + 1][fscod + 1] * 2
	return buffer.len(buf) < size + 2 or isSync(buf, size)
end

local function frameSize(buf, p)
	local fscod = rshift(readu8(buf, p + 4), 6)
	local code = band(readu8(buf, p + 4), 63)
	if fscod == 3 or code > 37 then
		return nil
	end
	return FRAME_WORDS[code + 1][fscod + 1] * 2
end

-- frames: { { pos, size } } holding one or more AC-3 frames each
function Ac3.decodeFrames(bytes, frames, options)
	options = options or {}
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local yield = options.Yield
	local st = newState()
	st.dynrng = { [0] = 1, 1 }
	st.mg = { n1 = 0, n2 = 0, n4 = 0, g1 = { 0, 0 }, g2 = { 0, 0 }, g4 = 0 }
	st.blockOut = {}
	for c = 1, 6 do
		st.blockOut[c] = table.create(256, 0)
	end
	st.cplFastLeak, st.cplSlowLeak = 0, 0
	-- the frame list (each sample may hold several frames)
	local list = {}
	for _, f in ipairs(frames) do
		local p, stop = f.pos or f[1], (f.pos or f[1]) + (f.size or f[2])
		while p + 6 <= stop do
			if isSync(buf, p) then
				local sz = frameSize(buf, p)
				if not sz or p + sz > stop then
					break
				end
				table.insert(list, { p, sz })
				p += sz
			else
				p += 1
			end
		end
	end
	if #list == 0 then
		fail("no frames")
	end
	-- the first frame sets the layout
	local outCh, mix
	local total = #list * 1536
	local maxSamples = math.huge
	local sig
	local written = 0
	local lastYield = os.clock()
	local function emit(outs)
		if written >= total or written >= maxSamples then
			return
		end
		local n = math.min(256, total - written, maxSamples - written)
		for oc = 1, outCh do
			local d = sig.data[oc]
			for i = 0, n - 1 do
				local v = 0
				for c = 1, st.fbw do
					local g = mix[c][oc]
					if g ~= 0 then
						v += outs[c][i + 1] * g
					end
				end
				buffer.writef32(d, (written + i) * 4, v)
			end
		end
		written += n
	end
	for i, f in ipairs(list) do
		if i == 1 then
			-- (peek the header for the layout)
			decodeFrame(st, buf, f[1], f[2], function() end)
			outCh, mix = mixer(st)
			if options.MaxSeconds then
				maxSamples = math.floor(options.MaxSeconds * st.rate)
			end
			sig = Signal.new(st.rate, outCh, math.min(total, maxSamples))
			-- start over: the first frame's samples (with the delay line now primed as a fresh decoder's)
			local fresh = newState()
			fresh.dynrng, fresh.mg, fresh.blockOut = st.dynrng, st.mg, st.blockOut
			fresh.cplFastLeak, fresh.cplSlowLeak = 0, 0
			st = fresh
			st.random = options.Random
			st.dynrng[0], st.dynrng[1] = 1, 1
		end
		local ok, err = pcall(decodeFrame, st, buf, f[1], f[2], emit)
		if not ok then
			if i == 1 then
				error(err, 0)
			end
			-- a broken frame: its time is left silent
			written = math.min(written + 1536, sig.length)
		end
		if written >= sig.length then
			break
		end
		if yield and os.clock() - lastYield > 0.012 then
			yield()
			lastYield = os.clock()
		end
	end
	sig.length = written
	return { signal = sig, format = { codec = "ac3", sampleRate = st.rate, channels = st.nch, bitRate = st.bitRate } }
end

function Ac3.decode(bytes, options)
	local buf = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	-- (skip anything before the first frame)
	local p = 0
	local len = buffer.len(buf)
	while p + 6 <= len and not isSync(buf, p) do
		p += 1
	end
	return Ac3.decodeFrames(buf, { { p, len - p } }, options)
end

return Ac3
