--!native
--!optimize 2
-- Image resizing (RGBA buffers). Shrinking averages every source pixel that falls in an output pixel (area filter,
-- no shimmering on fine detail); enlarging is bilinear. Alpha is averaged with the colours weighted by it, so edges
-- of transparent PNGs don't turn dark.
--
--   Resize.fit(image, maxW, maxH?, yield?) -> image no larger than maxW x maxH (aspect kept; unchanged if it fits)
--   Resize.to(image, w, h, yield?)     -> image of exactly w x h
--   (yield = true: pause every few milliseconds on big pictures, so the game doesn't freeze)
--   Resize.flatten(image, r, g, b)     -> image with transparency composited over the colour (0..255)

local Resize = {}

-- per output index: list of (source index, weight) covering [i * scale, (i + 1) * scale)
local function contributions(srcN, dstN)
	local out = table.create(dstN)
	local scale = srcN / dstN
	for i = 0, dstN - 1 do
		local list = {}
		if scale >= 1 then
			local a, b = i * scale, (i + 1) * scale
			local j = math.floor(a)
			while j < b and j < srcN do
				local w = math.min(j + 1, b) - math.max(j, a)
				if w > 1e-9 then
					table.insert(list, j)
					table.insert(list, w / scale)
				end
				j += 1
			end
		else
			local c = (i + 0.5) * scale - 0.5
			local j = math.floor(c)
			local f = c - j
			local j0, j1 = math.clamp(j, 0, srcN - 1), math.clamp(j + 1, 0, srcN - 1)
			table.insert(list, j0)
			table.insert(list, 1 - f)
			table.insert(list, j1)
			table.insert(list, f)
		end
		out[i + 1] = list
	end
	return out
end

function Resize.to(image, w, h, yield)
	local W, H, src = image.width, image.height, image.data
	if w == W and h == H then
		return image
	end
	local lastYield = os.clock()
	local function breathe()
		if yield and os.clock() - lastYield > 0.008 then
			task.wait()
			lastYield = os.clock()
		end
	end
	local cx, cy = contributions(W, w), contributions(H, h)
	-- horizontal pass into float rows (premultiplied alpha)
	local tmp = table.create(w * H * 4, 0)
	for y = 0, H - 1 do
		local row = y * W * 4
		for x = 0, w - 1 do
			local list = cx[x + 1]
			local r, g, b, a = 0, 0, 0, 0
			for k = 1, #list, 2 do
				local p = row + list[k] * 4
				local wt = list[k + 1]
				local al = buffer.readu8(src, p + 3) * wt
				r += buffer.readu8(src, p) * al
				g += buffer.readu8(src, p + 1) * al
				b += buffer.readu8(src, p + 2) * al
				a += al
			end
			local t = (y * w + x) * 4
			tmp[t + 1], tmp[t + 2], tmp[t + 3], tmp[t + 4] = r, g, b, a
		end
		breathe()
	end
	local out = buffer.create(w * h * 4)
	for y = 0, h - 1 do
		local list = cy[y + 1]
		for x = 0, w - 1 do
			local r, g, b, a = 0, 0, 0, 0
			for k = 1, #list, 2 do
				local t = (list[k] * w + x) * 4
				local wt = list[k + 1]
				r += tmp[t + 1] * wt
				g += tmp[t + 2] * wt
				b += tmp[t + 3] * wt
				a += tmp[t + 4] * wt
			end
			local o = (y * w + x) * 4
			if a > 1e-6 then
				buffer.writeu8(out, o, math.clamp(math.floor(r / a + 0.5), 0, 255))
				buffer.writeu8(out, o + 1, math.clamp(math.floor(g / a + 0.5), 0, 255))
				buffer.writeu8(out, o + 2, math.clamp(math.floor(b / a + 0.5), 0, 255))
			end
			buffer.writeu8(out, o + 3, math.clamp(math.floor(a + 0.5), 0, 255))
		end
	end
	return { width = w, height = h, data = out, hasAlpha = image.hasAlpha }
end

function Resize.fit(image, maxW, maxH, yield)
	maxH = maxH or maxW
	local W, H = image.width, image.height
	local s = math.min(1, maxW / W, maxH / H)
	if s >= 1 then
		return image
	end
	return Resize.to(image, math.max(1, math.floor(W * s + 0.5)), math.max(1, math.floor(H * s + 0.5)), yield)
end

function Resize.flatten(image, r, g, b)
	local n = image.width * image.height
	local src = image.data
	local out = buffer.create(n * 4)
	for i = 0, n - 1 do
		local o = i * 4
		local a = buffer.readu8(src, o + 3) / 255
		buffer.writeu8(out, o, math.floor(buffer.readu8(src, o) * a + r * (1 - a) + 0.5))
		buffer.writeu8(out, o + 1, math.floor(buffer.readu8(src, o + 1) * a + g * (1 - a) + 0.5))
		buffer.writeu8(out, o + 2, math.floor(buffer.readu8(src, o + 2) * a + b * (1 - a) + 0.5))
		buffer.writeu8(out, o + 3, 255)
	end
	return { width = image.width, height = image.height, data = out, hasAlpha = false }
end

return Resize
