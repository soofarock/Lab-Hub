--!native
--!optimize 2
-- Radix-2 complex FFT (in place, 1-indexed Lua arrays), windows, and STFT helpers.
--
--   FFT.transform(re, im, inverse?)      in-place; #re must be a power of two; inverse scales by 1/N
--   FFT.window(name, n)                   cached array: "hann" | "hamming" | "blackman" | "rect"
--   FFT.windowStats(name, n)              { sum, sumSq } for amplitude / power normalization
--   FFT.magnitudes(re, im)                array of |X[k]| for k = 0..N/2 (length N/2+1)
--   FFT.frame(signal, center, n, window, re, im)   fill re/im with a windowed frame centred on a sample
--   FFT.stft(signal, n, hop, windowName, fn)       fn(frameIndex, re, im, centerSample) per frame
--   FFT.nextPow2(x), FFT.binToHz(bin, n, rate), FFT.hzToBin(hz, n, rate)

local FFT = {}

local plans = {}

local function plan(n)
	local p = plans[n]
	if p then
		return p
	end
	if n < 2 or bit32.band(n, n - 1) ~= 0 then
		error("FFT size must be a power of two >= 2, got " .. tostring(n))
	end
	local bits = 0
	while bit32.lshift(1, bits) < n do
		bits += 1
	end
	local rev = table.create(n)
	for i = 0, n - 1 do
		local r, x = 0, i
		for _ = 1, bits do
			r = r * 2 + bit32.band(x, 1)
			x = bit32.rshift(x, 1)
		end
		rev[i + 1] = r + 1
	end
	local half = n // 2
	local cosT, sinT = table.create(half), table.create(half)
	for k = 0, half - 1 do
		local a = 2 * math.pi * k / n
		cosT[k + 1] = math.cos(a)
		sinT[k + 1] = -math.sin(a)
	end
	p = { n = n, rev = rev, cos = cosT, sin = sinT }
	plans[n] = p
	return p
end

function FFT.transform(re, im, inverse)
	local n = #re
	local p = plan(n)
	local rev = p.rev
	for i = 1, n do
		local j = rev[i]
		if j > i then
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		end
	end
	local cosT, sinT = p.cos, p.sin
	local sign = inverse and -1 or 1
	local size = 2
	while size <= n do
		local half = size // 2
		local step = n // size
		for start = 1, n, size do
			local k = 1
			for j = start, start + half - 1 do
				local wr = cosT[k]
				local wi = sinT[k] * sign
				local l = j + half
				local xr, xi = re[l], im[l]
				local tr = xr * wr - xi * wi
				local ti = xr * wi + xi * wr
				local ur, ui = re[j], im[j]
				re[l] = ur - tr
				im[l] = ui - ti
				re[j] = ur + tr
				im[j] = ui + ti
				k += step
			end
		end
		size *= 2
	end
	if inverse then
		local inv = 1 / n
		for i = 1, n do
			re[i] *= inv
			im[i] *= inv
		end
	end
end

local windows = {}
local stats = {}

function FFT.window(name, n)
	name = name or "hann"
	local key = name .. ":" .. n
	local w = windows[key]
	if w then
		return w
	end
	w = table.create(n)
	for i = 0, n - 1 do
		local x = 2 * math.pi * i / n -- periodic form (correct for STFT / spectral analysis)
		if name == "hann" then
			w[i + 1] = 0.5 - 0.5 * math.cos(x)
		elseif name == "hamming" then
			w[i + 1] = 0.54 - 0.46 * math.cos(x)
		elseif name == "blackman" then
			w[i + 1] = 0.42 - 0.5 * math.cos(x) + 0.08 * math.cos(2 * x)
		elseif name == "rect" then
			w[i + 1] = 1
		else
			error("unknown window " .. tostring(name))
		end
	end
	windows[key] = w
	return w
end

function FFT.windowStats(name, n)
	name = name or "hann"
	local key = name .. ":" .. n
	local s = stats[key]
	if s then
		return s
	end
	local w = FFT.window(name, n)
	local sum, sumSq = 0, 0
	for i = 1, n do
		sum += w[i]
		sumSq += w[i] * w[i]
	end
	s = { sum = sum, sumSq = sumSq }
	stats[key] = s
	return s
end

function FFT.magnitudes(re, im, out)
	local half = #re // 2
	out = out or table.create(half + 1)
	for k = 1, half + 1 do
		local a, b = re[k], im[k]
		out[k] = math.sqrt(a * a + b * b)
	end
	return out
end

-- Fill re/im (length n) with signal samples centred on `center` (0-based sample index),
-- multiplied by window array w. Samples outside the signal are zero.
function FFT.frame(signal, center, n, w, re, im, channel)
	local src = signal.data[channel or 1]
	local len = signal.length
	local start = center - n // 2
	for i = 1, n do
		local idx = start + i - 1
		local v = 0
		if idx >= 0 and idx < len then
			v = buffer.readf32(src, idx * 4)
		end
		re[i] = v * w[i]
		im[i] = 0
	end
end

-- Short-time Fourier transform. Frames are centred at round(k * hop), k = 0..count-1,
-- covering the whole signal. fn(k, re, im, center) receives the transformed frame;
-- re/im are reused between calls, so copy anything you keep. Returns frame count.
function FFT.stft(signal, n, hop, windowName, fn)
	local w = FFT.window(windowName or "hann", n)
	local re, im = table.create(n, 0), table.create(n, 0)
	local count = math.max(1, math.floor(signal.length / hop) + 1)
	for k = 0, count - 1 do
		local center = math.floor(k * hop + 0.5)
		FFT.frame(signal, center, n, w, re, im)
		FFT.transform(re, im, false)
		fn(k, re, im, center)
	end
	return count
end

function FFT.nextPow2(x)
	local n = 1
	while n < x do
		n *= 2
	end
	return n
end

function FFT.binToHz(bin, n, rate)
	return bin * rate / n
end

function FFT.hzToBin(hz, n, rate)
	return hz * n / rate
end

return FFT
