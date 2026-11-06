--!native
--!optimize 2
-- TGA decoder: colour-mapped, true-colour and greyscale images, raw or run-length encoded, 8 / 15 / 16 / 24 / 32 bits,
-- any origin corner.
--
--   local image = Tga.decode(bytes)   -> { width, height, data = RGBA buffer, hasAlpha }
--   Tga.isTga(bytes)   (TGA has no signature: this checks that the header makes sense)

local Tga = {}

function Tga.isTga(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if buffer.len(b) < 18 then
		return false
	end
	local cmapType, imgType = buffer.readu8(b, 1), buffer.readu8(b, 2)
	local bpp = buffer.readu8(b, 16)
	local okType = imgType == 1 or imgType == 2 or imgType == 3 or imgType == 9 or imgType == 10 or imgType == 11
	return okType and cmapType <= 1 and (bpp == 8 or bpp == 15 or bpp == 16 or bpp == 24 or bpp == 32)
		and buffer.readu16(b, 12) > 0 and buffer.readu16(b, 14) > 0
end

function Tga.decode(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not Tga.isTga(b) then
		error("TGA: not a TGA file")
	end
	local idLen, cmapType, imgType = buffer.readu8(b, 0), buffer.readu8(b, 1), buffer.readu8(b, 2)
	local cmapFirst, cmapLen, cmapBits = buffer.readu16(b, 3), buffer.readu16(b, 5), buffer.readu8(b, 7)
	local W, H = buffer.readu16(b, 12), buffer.readu16(b, 14)
	local bpp, desc = buffer.readu8(b, 16), buffer.readu8(b, 17)
	local alphaBits = bit32.band(desc, 15)
	local rightToLeft = bit32.band(desc, 0x10) ~= 0
	local topDown = bit32.band(desc, 0x20) ~= 0
	local p = 18 + idLen
	local function px16(v)
		local r, g, bl = bit32.band(bit32.rshift(v, 10), 31), bit32.band(bit32.rshift(v, 5), 31), bit32.band(v, 31)
		return math.floor(r * 255 / 31 + 0.5), math.floor(g * 255 / 31 + 0.5), math.floor(bl * 255 / 31 + 0.5)
	end
	local cmap
	if cmapType == 1 then
		local entry = (cmapBits + 7) // 8
		cmap = {}
		for i = 0, cmapLen - 1 do
			local q = p + i * entry
			local r, g, bl, a = 0, 0, 0, 255
			if cmapBits == 24 or cmapBits == 32 then
				bl, g, r = buffer.readu8(b, q), buffer.readu8(b, q + 1), buffer.readu8(b, q + 2)
				if cmapBits == 32 then
					a = buffer.readu8(b, q + 3)
				end
			else
				r, g, bl = px16(buffer.readu16(b, q))
			end
			cmap[cmapFirst + i] = { r, g, bl, a }
		end
		p += cmapLen * entry
	end
	local bytesPP = (bpp + 7) // 8
	local useAlpha = (bpp == 32) and alphaBits > 0 or (bpp == 32 and alphaBits == 0 and false)
	local hasAlpha = false
	local out = buffer.create(W * H * 4)
	local base = bit32.band(imgType, 7) -- 1 colour-mapped, 2 true-colour, 3 grey
	local rle = imgType >= 9
	local function readPixel(q)
		local r, g, bl, a = 0, 0, 0, 255
		if base == 1 then
			local i = (bpp == 8) and buffer.readu8(b, q) or buffer.readu16(b, q)
			local c = cmap and cmap[i]
			if c then
				r, g, bl, a = c[1], c[2], c[3], c[4]
			end
		elseif base == 3 then
			r = buffer.readu8(b, q)
			g, bl = r, r
			if bpp == 16 then
				a = buffer.readu8(b, q + 1)
			end
		elseif bpp == 24 or bpp == 32 then
			bl, g, r = buffer.readu8(b, q), buffer.readu8(b, q + 1), buffer.readu8(b, q + 2)
			if bpp == 32 and alphaBits > 0 then
				a = buffer.readu8(b, q + 3)
			end
		else
			r, g, bl = px16(buffer.readu16(b, q))
		end
		return r, g, bl, a
	end
	local n = W * H
	local i = 0
	local function store(r, g, bl, a)
		local x, y = i % W, i // W
		if rightToLeft then
			x = W - 1 - x
		end
		if not topDown then
			y = H - 1 - y
		end
		local o = (y * W + x) * 4
		buffer.writeu8(out, o, r)
		buffer.writeu8(out, o + 1, g)
		buffer.writeu8(out, o + 2, bl)
		buffer.writeu8(out, o + 3, a)
		if a < 255 then
			hasAlpha = true
		end
		i += 1
	end
	local len = buffer.len(b)
	while i < n and p < len do
		if rle then
			local h = buffer.readu8(b, p)
			p += 1
			local count = bit32.band(h, 127) + 1
			if h >= 128 then
				local r, g, bl, a = readPixel(p)
				p += bytesPP
				for _ = 1, count do
					if i >= n then
						break
					end
					store(r, g, bl, a)
				end
			else
				for _ = 1, count do
					if i >= n then
						break
					end
					store(readPixel(p))
					p += bytesPP
				end
			end
		else
			store(readPixel(p))
			p += bytesPP
		end
	end
	-- a 32-bit file that says "no alpha" (or whose alpha is all zero) is opaque
	if hasAlpha and bpp == 32 then
		local any = false
		for k = 0, n - 1 do
			if buffer.readu8(out, k * 4 + 3) > 0 then
				any = true
				break
			end
		end
		if not any then
			for k = 0, n - 1 do
				buffer.writeu8(out, k * 4 + 3, 255)
			end
			hasAlpha = false
		end
	end
	return { width = W, height = H, data = out, hasAlpha = hasAlpha }
end

return Tga
