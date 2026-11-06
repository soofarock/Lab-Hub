--!native
--!optimize 2
-- BMP decoder: 1 / 4 / 8-bit palette (also RLE4 / RLE8), 16-bit (555 / 565 / bit fields), 24-bit, 32-bit (with alpha
-- when the file has an alpha mask or real alpha values), bottom-up and top-down.
--
--   local image = Bmp.decode(bytes)   -> { width, height, data = RGBA buffer, hasAlpha }
--   Bmp.isBmp(bytes)

local Bmp = {}

function Bmp.isBmp(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return buffer.len(b) >= 26 and buffer.readstring(b, 0, 2) == "BM"
end

local function maskInfo(m)
	if m == 0 then
		return 0, 0
	end
	local shift = 0
	while bit32.band(m, 1) == 0 do
		m = bit32.rshift(m, 1)
		shift += 1
	end
	local bits = 0
	while bit32.band(m, 1) == 1 do
		m = bit32.rshift(m, 1)
		bits += 1
	end
	return shift, bits
end

function Bmp.decode(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not Bmp.isBmp(b) then
		error("BMP: not a BMP file")
	end
	local dataOff = buffer.readu32(b, 10)
	local hsize = buffer.readu32(b, 14)
	local W, H, bpp, comp, nColors
	if hsize == 12 then -- OS/2 core header
		W, H = buffer.readu16(b, 18), buffer.readi16(b, 20)
		bpp, comp, nColors = buffer.readu16(b, 24), 0, 0
	else
		W, H = buffer.readi32(b, 18), buffer.readi32(b, 22)
		bpp, comp = buffer.readu16(b, 28), buffer.readu32(b, 30)
		nColors = buffer.readu32(b, 46)
	end
	local topDown = H < 0
	H = math.abs(H)
	if W <= 0 or H == 0 then
		error("BMP: bad size")
	end
	-- channel masks (bit fields), default per depth
	local rm, gm, bm, am = 0, 0, 0, 0
	if comp == 3 or comp == 6 then
		if hsize >= 52 then
			rm, gm, bm = buffer.readu32(b, 54), buffer.readu32(b, 58), buffer.readu32(b, 62)
			am = hsize >= 56 and buffer.readu32(b, 66) or 0
		else
			-- BITMAPINFOHEADER + masks right after it
			rm, gm, bm = buffer.readu32(b, 14 + hsize), buffer.readu32(b, 18 + hsize), buffer.readu32(b, 22 + hsize)
			if comp == 6 then
				am = buffer.readu32(b, 26 + hsize)
			end
		end
	elseif bpp == 16 then
		rm, gm, bm = 0x7C00, 0x03E0, 0x001F
	elseif bpp == 32 then
		rm, gm, bm = 0x00FF0000, 0x0000FF00, 0x000000FF
		am = (hsize >= 56) and buffer.readu32(b, 66) or 0
	end
	-- palette
	local palette
	if bpp <= 8 then
		local entry = (hsize == 12) and 3 or 4
		local n = (nColors > 0) and nColors or 2 ^ bpp
		palette = buffer.create(256 * 4)
		local p0 = 14 + hsize
		for i = 0, math.min(n, 256) - 1 do
			local p = p0 + i * entry
			if p + 2 < buffer.len(b) then
				buffer.writeu8(palette, i * 4, buffer.readu8(b, p + 2))
				buffer.writeu8(palette, i * 4 + 1, buffer.readu8(b, p + 1))
				buffer.writeu8(palette, i * 4 + 2, buffer.readu8(b, p))
				buffer.writeu8(palette, i * 4 + 3, 255)
			end
		end
	end
	local out = buffer.create(W * H * 4)
	local function put(x, y, r, g, bl, a)
		local yy = topDown and y or (H - 1 - y)
		local o = (yy * W + x) * 4
		buffer.writeu8(out, o, r)
		buffer.writeu8(out, o + 1, g)
		buffer.writeu8(out, o + 2, bl)
		buffer.writeu8(out, o + 3, a)
	end
	local hasAlpha = false
	if comp == 1 or comp == 2 then
		-- RLE8 / RLE4 (rows in file order, bottom-up)
		buffer.fill(out, 0, 0)
		local p, x, y = dataOff, 0, 0
		local len = buffer.len(b)
		local function idx(i)
			local q = i * 4
			put(x, y, buffer.readu8(palette, q), buffer.readu8(palette, q + 1), buffer.readu8(palette, q + 2), 255)
		end
		while p + 1 < len and y < H do
			local n, v = buffer.readu8(b, p), buffer.readu8(b, p + 1)
			p += 2
			if n > 0 then
				for k = 0, n - 1 do
					if x < W then
						if comp == 1 then
							idx(v)
						else
							idx((k % 2 == 0) and bit32.rshift(v, 4) or bit32.band(v, 15))
						end
					end
					x += 1
				end
			elseif v == 0 then
				x, y = 0, y + 1
			elseif v == 1 then
				break
			elseif v == 2 then
				x += buffer.readu8(b, p)
				y += buffer.readu8(b, p + 1)
				p += 2
			else
				for k = 0, v - 1 do
					local val
					if comp == 1 then
						val = buffer.readu8(b, p + k)
					else
						local byte = buffer.readu8(b, p + k // 2)
						val = (k % 2 == 0) and bit32.rshift(byte, 4) or bit32.band(byte, 15)
					end
					if x < W then
						idx(val)
					end
					x += 1
				end
				local used = (comp == 1) and v or math.ceil(v / 2)
				p += used + (used % 2) -- absolute runs are padded to 16 bits
			end
		end
		return { width = W, height = H, data = out, hasAlpha = true }
	end
	if comp ~= 0 and comp ~= 3 and comp ~= 6 then
		error(("BMP: compression type %d isn't supported"):format(comp))
	end
	local stride = (W * bpp + 31) // 32 * 4
	local rs, rb = maskInfo(rm)
	local gs, gb = maskInfo(gm)
	local bs, bb = maskInfo(bm)
	local as, ab = maskInfo(am)
	local function scale(v, bits)
		if bits == 0 then
			return 255
		elseif bits >= 8 then
			return bit32.rshift(v, bits - 8)
		end
		return math.floor(v * 255 / (2 ^ bits - 1) + 0.5)
	end
	local anyAlpha = false
	for y = 0, H - 1 do
		local row = dataOff + y * stride
		for x = 0, W - 1 do
			if bpp <= 8 then
				local bit = x * bpp
				local byte = buffer.readu8(b, row + bit // 8)
				local i = bit32.band(bit32.rshift(byte, 8 - bpp - bit % 8), 2 ^ bpp - 1) * 4
				put(x, y, buffer.readu8(palette, i), buffer.readu8(palette, i + 1), buffer.readu8(palette, i + 2), 255)
			elseif bpp == 24 then
				local p = row + x * 3
				put(x, y, buffer.readu8(b, p + 2), buffer.readu8(b, p + 1), buffer.readu8(b, p), 255)
			else
				local v = (bpp == 16) and buffer.readu16(b, row + x * 2) or buffer.readu32(b, row + x * 4)
				local a = 255
				if ab > 0 then
					a = scale(bit32.band(bit32.rshift(v, as), 2 ^ ab - 1), ab)
					if a ~= 0 then
						anyAlpha = true
					end
				end
				put(x, y, scale(bit32.band(bit32.rshift(v, rs), 2 ^ rb - 1), rb), scale(bit32.band(bit32.rshift(v, gs), 2 ^ gb - 1), gb),
					scale(bit32.band(bit32.rshift(v, bs), 2 ^ bb - 1), bb), a)
			end
		end
	end
	if ab > 0 then
		if anyAlpha then
			hasAlpha = true
		else
			-- an alpha mask whose values are all 0 means "no alpha" (common in 32-bit files)
			for i = 0, W * H - 1 do
				buffer.writeu8(out, i * 4 + 3, 255)
			end
		end
	end
	return { width = W, height = H, data = out, hasAlpha = hasAlpha }
end

return Bmp
