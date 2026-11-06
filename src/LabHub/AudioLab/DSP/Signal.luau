--!native
--!optimize 2
-- PCM container shared by every module: one f32 buffer per channel, samples in -1..1.
--   signal = { sampleRate = 16000, channels = 1, length = frames, data = { buffer, ... } }

local Signal = {}

function Signal.new(sampleRate, channels, length)
	assert(sampleRate > 0 and channels >= 1 and length >= 0, "invalid signal shape")
	local data = table.create(channels)
	for c = 1, channels do
		data[c] = buffer.create(math.max(length, 1) * 4)
	end
	return { sampleRate = sampleRate, channels = channels, length = length, data = data }
end

function Signal.get(signal, channel, index) -- index 0-based
	return buffer.readf32(signal.data[channel], index * 4)
end

function Signal.set(signal, channel, index, value)
	buffer.writef32(signal.data[channel], index * 4, value)
end

function Signal.duration(signal)
	return signal.length / signal.sampleRate
end

-- Average all channels into a new mono signal (returns the input if already mono).
function Signal.toMono(signal)
	if signal.channels == 1 then
		return signal
	end
	local out = Signal.new(signal.sampleRate, 1, signal.length)
	local dst = out.data[1]
	local inv = 1 / signal.channels
	for i = 0, signal.length - 1 do
		local s = 0
		for c = 1, signal.channels do
			s += buffer.readf32(signal.data[c], i * 4)
		end
		buffer.writef32(dst, i * 4, s * inv)
	end
	return out
end

-- Build a mono signal from a Lua array (0-based values in arr[1..n]).
function Signal.fromArray(arr, sampleRate)
	local out = Signal.new(sampleRate, 1, #arr)
	local dst = out.data[1]
	for i = 1, #arr do
		buffer.writef32(dst, (i - 1) * 4, arr[i])
	end
	return out
end

function Signal.toArray(signal, channel)
	local src = signal.data[channel or 1]
	local arr = table.create(signal.length)
	for i = 0, signal.length - 1 do
		arr[i + 1] = buffer.readf32(src, i * 4)
	end
	return arr
end

-- Generate a mono signal from fn(t_seconds) -> value.
function Signal.generate(sampleRate, seconds, fn)
	local n = math.floor(sampleRate * seconds + 0.5)
	local out = Signal.new(sampleRate, 1, n)
	local dst = out.data[1]
	for i = 0, n - 1 do
		buffer.writef32(dst, i * 4, fn(i / sampleRate))
	end
	return out
end

function Signal.peak(signal)
	local p = 0
	for c = 1, signal.channels do
		local d = signal.data[c]
		for i = 0, signal.length - 1 do
			local v = math.abs(buffer.readf32(d, i * 4))
			if v > p then
				p = v
			end
		end
	end
	return p
end

function Signal.rms(signal, channel)
	local d = signal.data[channel or 1]
	local s = 0
	for i = 0, signal.length - 1 do
		local v = buffer.readf32(d, i * 4)
		s += v * v
	end
	return math.sqrt(s / math.max(signal.length, 1))
end

return Signal
