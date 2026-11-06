--!native
--!optimize 2
-- PNG decoder: every standard colour type (grey, RGB, palette, grey + alpha, RGBA) and bit depth (1, 2, 4, 8, 16),
-- all five row filters, Adam7 interlacing, palette and tRNS transparency. 16-bit samples keep their high byte.
--
--   local image = Png.decode(bytes)   -- bytes: buffer or string
--   image.width, image.height, image.data (buffer, RGBA 8-bit, row-major), image.hasAlpha
--   Png.isPng(bytes)

local Inflate
if script then
	Inflate = require(script.Parent.Inflate)
else
	Inflate = require("./Inflate") -- standalone Luau (outside Roblox)
end

local Png = {}

local SIGNATURE = "\137PNG\r\n\26\n"

function Png.isPng(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return buffer.len(b) >= 8 and buffer.readstring(b, 0, 8) == SIGNATURE
end

local function be32(b, o)
	return buffer.readu8(b, o) * 16777216 + buffer.readu8(b, o + 1) * 65536 + buffer.readu8(b, o + 2) * 256 + buffer.readu8(b, o + 3)
end

local CHANNELS = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }

-- undo the row filters of one (sub)image in place; rows are (1 + rowBytes) long starting at `base`
local function unfilter(raw, base, rows, rowBytes, bpp)
	local stride = rowBytes + 1
	for y = 0, rows - 1 do
		local r = base + y * stride
		local ft = buffer.readu8(raw, r)
		local cur = r + 1
		local prev = r + 1 - stride -- previous row's data (only read when y > 0)
		if ft == 0 then
			-- none
		elseif ft == 1 then
			for i = bpp, rowBytes - 1 do
				buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + buffer.readu8(raw, cur + i - bpp)) % 256)
			end
		elseif ft == 2 then
			if y > 0 then
				for i = 0, rowBytes - 1 do
					buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + buffer.readu8(raw, prev + i)) % 256)
				end
			end
		elseif ft == 3 then
			for i = 0, rowBytes - 1 do
				local left = i >= bpp and buffer.readu8(raw, cur + i - bpp) or 0
				local up = y > 0 and buffer.readu8(raw, prev + i) or 0
				buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + (left + up) // 2) % 256)
			end
		elseif ft == 4 then
			for i = 0, rowBytes - 1 do
				local a = i >= bpp and buffer.readu8(raw, cur + i - bpp) or 0
				local b = y > 0 and buffer.readu8(raw, prev + i) or 0
				local c = (y > 0 and i >= bpp) and buffer.readu8(raw, prev + i - bpp) or 0
				local p = a + b - c
				local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
				local pred
				if pa <= pb and pa <= pc then
					pred = a
				elseif pb <= pc then
					pred = b
				else
					pred = c
				end
				buffer.writeu8(raw, cur + i, (buffer.readu8(raw, cur + i) + pred) % 256)
			end
		else
			error("PNG: bad filter type " .. ft)
		end
	end
end

local ADAM7 = { -- x0, y0, dx, dy
	{ 0, 0, 8, 8 }, { 4, 0, 8, 8 }, { 0, 4, 4, 8 }, { 2, 0, 4, 4 }, { 0, 2, 2, 4 }, { 1, 0, 2, 2 }, { 0, 1, 1, 2 },
}

function Png.decode(bytes, options)
	local yield = options and options.Yield == true
	local lastYield = os.clock()
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	if not Png.isPng(b) then
		error("PNG: not a PNG file")
	end
	local len = buffer.len(b)
	local pos = 8
	local width, height, depth, ctype, interlace
	local palette, paletteN = nil, 0
	local trns = nil
	local idat = {}
	local idatLen = 0
	while pos + 8 <= len do
		local clen = be32(b, pos)
		local kind = buffer.readstring(b, pos + 4, 4)
		local data = pos + 8
		if data + clen > len then
			error("PNG: truncated chunk " .. kind)
		end
		if kind == "IHDR" then
			width, height = be32(b, data), be32(b, data + 4)
			depth, ctype = buffer.readu8(b, data + 8), buffer.readu8(b, data + 9)
			interlace = buffer.readu8(b, data + 12)
			if not CHANNELS[ctype] then
				error("PNG: bad colour type " .. ctype)
			end
		elseif kind == "PLTE" then
			paletteN = clen // 3
			palette = buffer.create(256 * 4)
			buffer.fill(palette, 0, 255)
			for i = 0, paletteN - 1 do
				buffer.writeu8(palette, i * 4, buffer.readu8(b, data + i * 3))
				buffer.writeu8(palette, i * 4 + 1, buffer.readu8(b, data + i * 3 + 1))
				buffer.writeu8(palette, i * 4 + 2, buffer.readu8(b, data + i * 3 + 2))
			end
		elseif kind == "tRNS" then
			trns = { at = data, len = clen }
		elseif kind == "IDAT" then
			table.insert(idat, { data, clen })
			idatLen += clen
		elseif kind == "IEND" then
			break
		end
		pos = data + clen + 4 -- skip CRC
	end
	if not width then
		error("PNG: no IHDR")
	end
	if #idat == 0 then
		error("PNG: no image data")
	end
	local ch = CHANNELS[ctype]
	local bitsPP = ch * depth
	local bpp = math.max(1, bitsPP // 8)
	-- palette alpha / colour key
	local hasAlpha = ctype == 4 or ctype == 6
	local keyR, keyG, keyB, keyGrey
	if trns then
		if ctype == 3 and palette then
			for i = 0, math.min(trns.len, 256) - 1 do
				buffer.writeu8(palette, i * 4 + 3, buffer.readu8(b, trns.at + i))
			end
			hasAlpha = true
		elseif ctype == 0 and trns.len >= 2 then
			keyGrey = buffer.readu8(b, trns.at) * 256 + buffer.readu8(b, trns.at + 1)
			hasAlpha = true
		elseif ctype == 2 and trns.len >= 6 then
			keyR = buffer.readu8(b, trns.at) * 256 + buffer.readu8(b, trns.at + 1)
			keyG = buffer.readu8(b, trns.at + 2) * 256 + buffer.readu8(b, trns.at + 3)
			keyB = buffer.readu8(b, trns.at + 4) * 256 + buffer.readu8(b, trns.at + 5)
			hasAlpha = true
		end
	end
	if ctype == 3 and not palette then
		error("PNG: palette image without PLTE")
	end

	-- concatenate IDAT and inflate
	local z = buffer.create(idatLen)
	local o = 0
	for _, c in ipairs(idat) do
		buffer.copy(z, o, b, c[1], c[2])
		o += c[2]
	end
	local passes = {}
	local expected = 0
	if interlace == 1 then
		for p = 1, 7 do
			local a = ADAM7[p]
			local pw = width > a[1] and (width - a[1] + a[3] - 1) // a[3] or 0
			local ph = height > a[2] and (height - a[2] + a[4] - 1) // a[4] or 0
			local rowBytes = (pw * bitsPP + 7) // 8
			passes[p] = { w = pw, h = ph, rowBytes = rowBytes, base = expected, a = a }
			if pw > 0 and ph > 0 then
				expected += ph * (rowBytes + 1)
			end
		end
	else
		local rowBytes = (width * bitsPP + 7) // 8
		passes[1] = { w = width, h = height, rowBytes = rowBytes, base = 0, a = { 0, 0, 1, 1 } }
		expected = height * (rowBytes + 1)
	end
	local raw, rawLen = Inflate.zlib(z, 0, expected)
	if rawLen < expected then
		error(("PNG: image data too short (%d of %d bytes)"):format(rawLen, expected))
	end

	local out = buffer.create(width * height * 4)
	local scale = depth < 8 and (255 // (2 ^ depth - 1)) or 1
	for _, ps in ipairs(passes) do
		local pw, ph = ps.w, ps.h
		if pw > 0 and ph > 0 then
			unfilter(raw, ps.base, ph, ps.rowBytes, bpp)
			local x0, y0, dx, dy = ps.a[1], ps.a[2], ps.a[3], ps.a[4]
			local stride = ps.rowBytes + 1
			for y = 0, ph - 1 do
				local row = ps.base + y * stride + 1
				local oy = (y0 + y * dy) * width
				for x = 0, pw - 1 do
					local r, g, bl, al = 0, 0, 0, 255
					if depth == 8 then
						local s = row + x * ch
						if ctype == 0 then
							r = buffer.readu8(raw, s)
							g, bl = r, r
							if keyGrey and r == keyGrey then
								al = 0
							end
						elseif ctype == 2 then
							r, g, bl = buffer.readu8(raw, s), buffer.readu8(raw, s + 1), buffer.readu8(raw, s + 2)
							if keyR and r == keyR and g == keyG and bl == keyB then
								al = 0
							end
						elseif ctype == 3 then
							local i = buffer.readu8(raw, s) * 4
							r, g, bl, al = buffer.readu8(palette, i), buffer.readu8(palette, i + 1), buffer.readu8(palette, i + 2), buffer.readu8(palette, i + 3)
						elseif ctype == 4 then
							r = buffer.readu8(raw, s)
							g, bl, al = r, r, buffer.readu8(raw, s + 1)
						else
							r, g, bl, al = buffer.readu8(raw, s), buffer.readu8(raw, s + 1), buffer.readu8(raw, s + 2), buffer.readu8(raw, s + 3)
						end
					elseif depth == 16 then
						local s = row + x * ch * 2
						local function v(k)
							return buffer.readu8(raw, s + k * 2) * 256 + buffer.readu8(raw, s + k * 2 + 1)
						end
						if ctype == 0 then
							local gv = v(0)
							r = gv // 256
							g, bl = r, r
							if keyGrey and gv == keyGrey then
								al = 0
							end
						elseif ctype == 2 then
							local rv, gv, bv = v(0), v(1), v(2)
							r, g, bl = rv // 256, gv // 256, bv // 256
							if keyR and rv == keyR and gv == keyG and bv == keyB then
								al = 0
							end
						elseif ctype == 4 then
							r = v(0) // 256
							g, bl, al = r, r, v(1) // 256
						else
							r, g, bl, al = v(0) // 256, v(1) // 256, v(2) // 256, v(3) // 256
						end
					else
						-- 1, 2 or 4 bits per sample: grey or palette, packed MSB first
						local bit = x * depth
						local byte = buffer.readu8(raw, row + bit // 8)
						local shift = 8 - depth - bit % 8
						local val = bit32.band(bit32.rshift(byte, shift), 2 ^ depth - 1)
						if ctype == 3 then
							local i = val * 4
							r, g, bl, al = buffer.readu8(palette, i), buffer.readu8(palette, i + 1), buffer.readu8(palette, i + 2), buffer.readu8(palette, i + 3)
						else
							r = val * scale
							g, bl = r, r
							if keyGrey and val == keyGrey then
								al = 0
							end
						end
					end
					local op = (oy + x0 + x * dx) * 4
					buffer.writeu8(out, op, r)
					buffer.writeu8(out, op + 1, g)
					buffer.writeu8(out, op + 2, bl)
					buffer.writeu8(out, op + 3, al)
				end
				if yield and os.clock() - lastYield > 0.008 then
					task.wait() -- options.Yield: a big picture doesn't freeze the game
					lastYield = os.clock()
				end
			end
		end
	end
	return { width = width, height = height, data = out, hasAlpha = hasAlpha }
end

return Png
