--!native
--!optimize 2
-- HEIF still pictures (ISO base media "meta" items): HEIC (H.265 / HEVC, Video.Hevc) - the iPhone photo format - and
-- AVIF (AV1, Video.Av1 when present). The primary picture is decoded - one coded image, or a grid of tiles - then
-- cropped (clap), turned and mirrored (irot / imir) and box-filtered down to MaxSize while it is put together, so a
-- 12-megapixel photo never needs a full-size RGBA copy. A transparency (alpha) picture stored with it is applied.
--
--   Heif.isHeif(bytes) -> true for HEIC / HEIF / AVIF files (by their ftyp brands)
--   Heif.brand(bytes) -> "heic" / "avif" / "heif" (an HEIF file of another kind), or nil
--   local info = Heif.parse(bytes) -> { brand, codec ("hvc1" / "av01" / "grid"), width, height (the picture as shown,
--       after turning), tiles (number of coded images) }
--   local image = Heif.decode(bytes, { MaxSize = longest side (default: full size), Yield = true })
--       -> { width, height, data = RGBA buffer, hasAlpha (a transparency picture with see-through parts),
--       sourceWidth, sourceHeight }

local Heif = {}

local readu8, readu32 = buffer.readu8, buffer.readu32
local band, rshift = bit32.band, bit32.rshift

local function fail(msg)
	error("HEIF: " .. msg, 0)
end

local function be16(b, o)
	return readu8(b, o) * 256 + readu8(b, o + 1)
end
local function be32(b, o)
	return readu8(b, o) * 16777216 + readu8(b, o + 1) * 65536 + readu8(b, o + 2) * 256 + readu8(b, o + 3)
end
-- an unsigned big-endian number of n bytes (0, 4 or 8)
local function beN(b, o, n)
	if n == 0 then
		return 0
	elseif n == 4 then
		return be32(b, o)
	elseif n == 8 then
		return be32(b, o) * 4294967296 + be32(b, o + 4)
	elseif n == 2 then
		return be16(b, o)
	end
	fail("damaged data (bad field size)")
	return 0
end

local BRANDS = { heic = "heic", heix = "heic", hevc = "heic", hevx = "heic", heim = "heic", heis = "heic", mif1 = "heif",
	msf1 = "heif", avif = "avif", avis = "avif" }

-- the file's kind ("heic" / "avif" / "heif") from its ftyp box, or nil
local function brandOf(b)
	if buffer.len(b) < 16 or buffer.readstring(b, 4, 4) ~= "ftyp" then
		return nil
	end
	local size = be32(b, 0)
	local major = BRANDS[buffer.readstring(b, 8, 4)]
	local found = nil
	for o = 16, math.min(size, buffer.len(b)) - 4, 4 do
		local k = BRANDS[buffer.readstring(b, o, 4)]
		if k == "heic" or k == "avif" then
			found = found or k
		end
	end
	if major == "heif" then
		return found or "heif"
	end
	return major or found
end

function Heif.isHeif(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return brandOf(b) ~= nil
end

function Heif.brand(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return brandOf(b)
end

-- boxes in [pos, stop): fn(type, payload start, payload end)
local function boxes(b, pos, stop, fn)
	while pos + 8 <= stop do
		local size = be32(b, pos)
		local t = buffer.readstring(b, pos + 4, 4)
		local head = 8
		if size == 1 then
			if pos + 16 > stop then
				break
			end
			size = beN(b, pos + 8, 8)
			head = 16
		elseif size == 0 then
			size = stop - pos
		end
		if size < head then
			fail("damaged data (a box is too small)")
		end
		if fn(t, pos + head, math.min(pos + size, stop)) == false then
			return
		end
		pos += size
	end
end

-- the items of the file's meta box
local function readMeta(b)
	local len = buffer.len(b)
	local meta
	boxes(b, 0, len, function(t, p, q)
		if t == "meta" then
			meta = { p + 4, q }
			return false
		end
		return nil
	end)
	if not meta then
		fail("the file has no picture description (meta box)")
	end
	local items = {}
	local function item(id)
		local it = items[id]
		if not it then
			it = { id = id, props = {}, refs = {} }
			items[id] = it
		end
		return it
	end
	local props = {}
	local idat
	local primary
	boxes(b, meta[1], meta[2], function(t, p, q)
		local v = readu8(b, p)
		if t == "pitm" then
			primary = v == 0 and be16(b, p + 4) or be32(b, p + 4)
		elseif t == "iinf" then
			local o = p + 4 + (v == 0 and 2 or 4)
			boxes(b, o, q, function(t2, p2, q2)
				if t2 == "infe" then
					local iv = readu8(b, p2)
					if iv >= 2 then
						local id = iv == 2 and be16(b, p2 + 4) or be32(b, p2 + 4)
						local to = p2 + 4 + (iv == 2 and 2 or 4) + 2
						local it = item(id)
						it.type = buffer.readstring(b, to, 4)
						it.hidden = band(readu8(b, p2 + 3), 1) == 1
					end
				end
				return nil
			end)
		elseif t == "iloc" then
			local o = p + 4
			local s1, s2 = readu8(b, o), readu8(b, o + 1)
			local offSize, lenSize, baseSize = rshift(s1, 4), band(s1, 15), rshift(s2, 4)
			local idxSize = (v == 1 or v == 2) and band(s2, 15) or 0
			o += 2
			local count
			if v < 2 then
				count = be16(b, o)
				o += 2
			else
				count = be32(b, o)
				o += 4
			end
			for _ = 1, count do
				local id
				if v < 2 then
					id = be16(b, o)
					o += 2
				else
					id = be32(b, o)
					o += 4
				end
				local method = 0
				if v == 1 or v == 2 then
					method = band(be16(b, o), 15)
					o += 2
				end
				o += 2 -- data reference index
				local base = beN(b, o, baseSize)
				o += baseSize
				local n = be16(b, o)
				o += 2
				local it = item(id)
				it.extents = {}
				it.method = method
				for _ = 1, n do
					o += idxSize
					local eo = beN(b, o, offSize)
					o += offSize
					local el = beN(b, o, lenSize)
					o += lenSize
					table.insert(it.extents, { base + eo, el })
				end
			end
		elseif t == "iref" then
			boxes(b, p + 4, q, function(t2, p2, q2)
				local o = p2
				local from
				if v == 0 then
					from = be16(b, o)
					o += 2
				else
					from = be32(b, o)
					o += 4
				end
				local n = be16(b, o)
				o += 2
				local list = {}
				for _ = 1, n do
					if v == 0 then
						table.insert(list, be16(b, o))
						o += 2
					else
						table.insert(list, be32(b, o))
						o += 4
					end
				end
				item(from).refs[t2] = list
				return nil
			end)
		elseif t == "iprp" then
			boxes(b, p, q, function(t2, p2, q2)
				if t2 == "ipco" then
					boxes(b, p2, q2, function(t3, p3, q3)
						table.insert(props, { type = t3, p = p3, q = q3 })
						return nil
					end)
				elseif t2 == "ipma" then
					local pv, flags = readu8(b, p2), readu8(b, p2 + 3)
					local n = be32(b, p2 + 4)
					local o = p2 + 8
					for _ = 1, n do
						local id
						if pv < 1 then
							id = be16(b, o)
							o += 2
						else
							id = be32(b, o)
							o += 4
						end
						local na = readu8(b, o)
						o += 1
						local it = item(id)
						for _ = 1, na do
							local idx
							if band(flags, 1) == 1 then
								idx = band(be16(b, o), 0x7FFF)
								o += 2
							else
								idx = band(readu8(b, o), 0x7F)
								o += 1
							end
							if idx > 0 then
								table.insert(it.props, idx)
							end
						end
					end
				end
				return nil
			end)
		elseif t == "idat" then
			idat = { p, q }
		end
		return nil
	end)
	if not primary or not items[primary] then
		fail("the file names no main picture")
	end
	return items, props, idat, primary
end

-- the first property of a kind associated with an item: its { type, p, q }
local function prop(props, it, kind)
	for _, idx in ipairs(it.props) do
		local pr = props[idx]
		if pr and pr.type == kind then
			return pr
		end
	end
	return nil
end

-- an item's bytes (its extents, one after another)
local function itemData(b, it, idat)
	if not it.extents or #it.extents == 0 then
		fail("a picture part has no data")
	end
	local len = buffer.len(b)
	local base, stop = 0, len
	if it.method == 1 then
		if not idat then
			fail("damaged data (missing idat)")
		end
		base, stop = idat[1], idat[2]
	elseif it.method ~= 0 then
		fail("damaged data (unsupported item location)")
	end
	local total = 0
	for _, e in ipairs(it.extents) do
		local l = e[2] == 0 and (stop - base - e[1]) or e[2]
		if base + e[1] + l > stop or l < 0 then
			fail("the file is cut off (a picture part is missing)")
		end
		total += l
	end
	local out = buffer.create(total)
	local o = 0
	for _, e in ipairs(it.extents) do
		local l = e[2] == 0 and (stop - base - e[1]) or e[2]
		buffer.copy(out, o, b, base + e[1], l)
		o += l
	end
	return out
end

local function payload(b, pr)
	local n = pr.q - pr.p
	local out = buffer.create(n)
	buffer.copy(out, 0, b, pr.p, n)
	return out
end

-- the picture's layout: coded tiles and the transforms to apply
local function layout(b)
	local brand = brandOf(b)
	local items, props, idat, primary = readMeta(b)
	local main = items[primary]
	local L = { brand = brand, codec = main.type, tiles = {}, transforms = {}, idat = idat }
	local function sizeOf(it)
		local ispe = prop(props, it, "ispe")
		if ispe then
			return be32(b, ispe.p + 4), be32(b, ispe.p + 8)
		end
		return nil, nil
	end
	-- an item's coded tiles: { tiles = { { item, x, y, config } }, codec, width, height }
	local function picture(it)
		local P = { tiles = {} }
		if it.type == "grid" then
			local g = itemData(b, it, idat)
			local flags = readu8(g, 1)
			local rows, cols = readu8(g, 2) + 1, readu8(g, 3) + 1
			if band(flags, 1) == 1 then
				P.width, P.height = be32(g, 4), be32(g, 8)
			else
				P.width, P.height = be16(g, 4), be16(g, 6)
			end
			local list = it.refs.dimg
			if not list or #list < rows * cols then
				fail("damaged data (the picture's grid lacks tiles)")
			end
			local tw, th = sizeOf(items[list[1]])
			if not tw then
				fail("damaged data (tile size missing)")
			end
			for r = 0, rows - 1 do
				for c = 0, cols - 1 do
					local t = items[list[r * cols + c + 1]]
					if not t then
						fail("damaged data (a tile is missing)")
					end
					table.insert(P.tiles, { item = t, x = c * tw, y = r * th })
				end
			end
			P.codec = items[list[1]].type
		elseif it.type == "hvc1" or it.type == "av01" then
			P.width, P.height = sizeOf(it)
			P.tiles[1] = { item = it, x = 0, y = 0 }
			P.codec = it.type
		else
			return nil
		end
		-- the coded tiles' setup
		for _, t in ipairs(P.tiles) do
			local cfg = prop(props, t.item, P.codec == "av01" and "av1C" or "hvcC")
			if not cfg then
				fail("damaged data (a tile's decoder setup is missing)")
			end
			t.config = cfg
		end
		return P
	end
	local P = picture(main)
	if not P then
		fail(("the main picture is of a kind that isn't read (%q)"):format(tostring(main.type)))
	end
	L.tiles, L.tileCodec, L.width, L.height = P.tiles, P.codec, P.width, P.height
	-- a transparency (alpha) picture: an auxiliary item for the main one
	for _, it in pairs(items) do
		local aux = it.refs.auxl
		local auxC = prop(props, it, "auxC")
		if aux and auxC and table.find(aux, primary) then
			local urn = buffer.readstring(b, auxC.p + 4, math.max(0, auxC.q - auxC.p - 4))
			if string.find(urn, "alpha", 1, true) then
				L.alpha = picture(it)
				break
			end
		end
	end
	-- colour (nclx) and the transforms, in their order
	for _, idx in ipairs(main.props) do
		local pr = props[idx]
		if pr then
			if pr.type == "colr" and buffer.readstring(b, pr.p, 4) == "nclx" then
				L.matrix = be16(b, pr.p + 8)
				L.fullRange = band(readu8(b, pr.p + 10), 0x80) ~= 0
			elseif pr.type == "irot" then
				table.insert(L.transforms, { "rot", band(readu8(b, pr.p), 3) })
			elseif pr.type == "imir" then
				table.insert(L.transforms, { "mir", band(readu8(b, pr.p), 1) })
			elseif pr.type == "clap" then
				local function frac(o)
					local d = be32(b, o + 4)
					local n = be32(b, o)
					if n >= 2147483648 then
						n -= 4294967296
					end
					return d ~= 0 and n / d or 0
				end
				table.insert(L.transforms, { "clap", frac(pr.p), frac(pr.p + 8), frac(pr.p + 16), frac(pr.p + 24) })
			end
		end
	end
	return L, props
end

function Heif.parse(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local L = layout(b)
	local w, h = L.width or 0, L.height or 0
	for _, t in ipairs(L.transforms) do
		if t[1] == "rot" and t[2] % 2 == 1 then
			w, h = h, w
		elseif t[1] == "clap" then
			w, h = math.floor(t[2] + 0.5), math.floor(t[3] + 0.5)
		end
	end
	return { brand = L.brand, codec = L.codec, width = w, height = h, tiles = #L.tiles }
end

-- a decoder for the tiles' codec: new(config buffer) -> object with :picture(data) -> pic (Y, U, V, ys, cs, yo, co) and
-- width, height, cropX, cropY, fullRange, bt709 fields
local function codecFor(kind)
	local Video = script.Parent.Parent:FindFirstChild("Video")
	if kind == "hvc1" then
		local Hevc = require(Video.Hevc)
		return function(cfg)
			local dec = Hevc.new(cfg)
			return dec, function(data)
				local pic = dec:decodeSample(data, 0, buffer.len(data))
				if not pic then
					fail("a tile didn't decode")
				end
				return pic
			end
		end
	elseif kind == "av01" then
		local mod = Video and Video:FindFirstChild("Av1")
		if not mod then
			fail("AV1 pictures (AVIF) can't be read here")
		end
		local Av1 = require(mod)
		return function(cfg)
			local dec = Av1.new(cfg)
			dec.fullChroma = true
			return dec, function(data)
				local pic = dec:decodeSample(data, 0, buffer.len(data))
				if not pic then
					fail("a tile didn't decode")
				end
				return pic
			end
		end
	end
	fail(("pictures coded as %q can't be read"):format(tostring(kind)))
	return nil :: any
end

-- turn / mirror an RGBA image
local function rotate(img, quarter)
	-- quarter turns anticlockwise
	local w, h, d = img.width, img.height, img.data
	if quarter == 0 then
		return img
	end
	local nw, nh = w, h
	if quarter % 2 == 1 then
		nw, nh = h, w
	end
	local out = buffer.create(nw * nh * 4)
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local nx, ny
			if quarter == 1 then
				nx, ny = y, w - 1 - x
			elseif quarter == 2 then
				nx, ny = w - 1 - x, h - 1 - y
			else
				nx, ny = h - 1 - y, x
			end
			buffer.writeu32(out, (ny * nw + nx) * 4, readu32(d, (y * w + x) * 4))
		end
	end
	return { width = nw, height = nh, data = out, hasAlpha = img.hasAlpha }
end
local function mirror(img, axis)
	-- axis 0: about the vertical axis (left and right swap); 1: about the horizontal axis (top and bottom swap)
	local w, h, d = img.width, img.height, img.data
	local out = buffer.create(w * h * 4)
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local sx, sy = x, y
			if axis == 0 then
				sx = w - 1 - x
			else
				sy = h - 1 - y
			end
			buffer.writeu32(out, (y * w + x) * 4, readu32(d, (sy * w + sx) * 4))
		end
	end
	return { width = w, height = h, data = out, hasAlpha = img.hasAlpha }
end

function Heif.decode(bytes, opts)
	opts = opts or {}
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local L = layout(b)
	local yieldOn = opts.Yield and task ~= nil
	local lastYield = os.clock()
	local function breathe()
		if yieldOn and os.clock() - lastYield > 0.03 then
			task.wait()
			lastYield = os.clock()
		end
	end
	local newDecoder = codecFor(L.tileCodec)
	-- the first tile gives the size when the file doesn't
	local decoders = {}
	local function decodeTile(t)
		local key = t.config
		local entry = decoders[key]
		if not entry then
			local dec, run = newDecoder(payload(b, t.config))
			entry = { dec = dec, run = run }
			decoders[key] = entry
		end
		local pic = entry.run(itemData(b, t.item, L.idat))
		return entry.dec, pic
	end
	local firstDec, firstPic = decodeTile(L.tiles[1])
	local W, H = L.width or firstDec.width, L.height or firstDec.height
	if #L.tiles == 1 then
		W, H = math.min(W, firstDec.width), math.min(H, firstDec.height)
	end
	if W <= 0 or H <= 0 then
		fail("the picture has no size")
	end
	-- the region kept (clean aperture), in coded picture pixels
	local rx0, ry0, rw, rh = 0, 0, W, H
	for _, t in ipairs(L.transforms) do
		if t[1] == "clap" then
			local cw, ch = math.floor(t[2] + 0.5), math.floor(t[3] + 0.5)
			if cw > 0 and ch > 0 and cw <= W and ch <= H then
				rx0 = math.clamp(math.floor((W - 1) / 2 + t[4] - (cw - 1) / 2 + 0.5), 0, W - cw)
				ry0 = math.clamp(math.floor((H - 1) / 2 + t[5] - (ch - 1) / 2 + 0.5), 0, H - ch)
				rw, rh = cw, ch
			end
		end
	end
	-- output size: the longest side at most MaxSize
	local maxSize = opts.MaxSize or math.max(rw, rh)
	local s = math.min(1, maxSize / math.max(rw, rh))
	local ow, oh = math.max(1, math.floor(rw * s + 0.5)), math.max(1, math.floor(rh * s + 0.5))
	local n = ow * oh
	local SY, SU, SV, CY = table.create(n, 0), table.create(n, 0), table.create(n, 0), table.create(n, 0)
	-- picture column / row -> output column / row (+1), or 0 outside the kept region
	local mapX, mapY = table.create(W + 2, 0), table.create(H + 2, 0)
	for x = 0, W - 1 do
		local rx = x - rx0
		mapX[x + 1] = (rx >= 0 and rx < rw) and (rx * ow // rw + 1) or 0
	end
	for y = 0, H - 1 do
		local ry = y - ry0
		mapY[y + 1] = (ry >= 0 and ry < rh) and (ry * oh // rh + 1) or 0
	end
	local matrix, fullRange = L.matrix, L.fullRange
	local function add(dec, pic, tx, ty)
		if matrix == nil then
			matrix = dec.matrix or (dec.bt709 and 1 or 6)
			if matrix == 2 then
				matrix = 6
			end
		end
		if fullRange == nil then
			fullRange = dec.fullRange
		end
		local tw = math.min(dec.width, W - tx)
		local th = math.min(dec.height, H - ty)
		local Y, U, V = pic.Y, pic.U, pic.V
		local ys, cs = pic.ys, pic.cs
		local sx, sy = dec.chromaShiftX or 1, dec.chromaShiftY or 1
		local yo = pic.yo + (dec.cropY or 0) * ys + (dec.cropX or 0)
		local co = pic.co + ((dec.cropY or 0) // 2 ^ sy) * cs + (dec.cropX or 0) // 2 ^ sx
		for y = 0, th - 1 do
			local my = mapY[ty + y + 1]
			if my > 0 then
				local row = (my - 1) * ow
				local r = yo + y * ys
				local rc = co + (y // 2 ^ sy) * cs
				for x = 0, tw - 1 do
					local mx = mapX[tx + x + 1]
					if mx > 0 then
						local k = row + mx
						local c = rc + x // 2 ^ sx
						SY[k] += readu8(Y, r + x)
						SU[k] += readu8(U, c)
						SV[k] += readu8(V, c)
						CY[k] += 1
					end
				end
			end
			if y % 32 == 31 then
				breathe()
			end
		end
	end
	add(firstDec, firstPic, L.tiles[1].x, L.tiles[1].y)
	for i = 2, #L.tiles do
		local t = L.tiles[i]
		if t.x < W and t.y < H then
			local dec, pic = decodeTile(t)
			add(dec, pic, t.x, t.y)
		end
		breathe()
	end
	-- transparency
	local SA, CA
	if L.alpha then
		SA, CA = table.create(n, 0), table.create(n, 0)
		local A = L.alpha
		local alphaDecoder = codecFor(A.codec)
		local adecs = {}
		for _, t in ipairs(A.tiles) do
			local entry = adecs[t.config]
			if not entry then
				local dec, run = alphaDecoder(payload(b, t.config))
				entry = { dec = dec, run = run }
				adecs[t.config] = entry
			end
			local pic = entry.run(itemData(b, t.item, L.idat))
			local dec = entry.dec
			local aw, ah = A.width or dec.width, A.height or dec.height
			local tw = math.min(dec.width, aw - t.x)
			local th = math.min(dec.height, ah - t.y)
			local Yp, ys = pic.Y, pic.ys
			local yo = pic.yo + (dec.cropY or 0) * ys + (dec.cropX or 0)
			local full = dec.fullRange
			for y = 0, th - 1 do
				-- (an alpha picture of another size is scaled onto the colour one)
				local py = (t.y + y) * H // ah
				local my = mapY[py + 1]
				if my > 0 then
					local row = (my - 1) * ow
					local r = yo + y * ys
					for x = 0, tw - 1 do
						local mx = mapX[(t.x + x) * W // aw + 1]
						if mx > 0 then
							local v = readu8(Yp, r + x)
							if not full then
								v = math.clamp((v - 16) * 255 / 219, 0, 255)
							end
							SA[row + mx] += v
							CA[row + mx] += 1
						end
					end
				end
				if y % 32 == 31 then
					breathe()
				end
			end
		end
	end
	-- to RGBA
	local kr, kb = 0.299, 0.114
	if matrix == 1 then
		kr, kb = 0.2126, 0.0722
	elseif matrix == 9 or matrix == 10 then
		kr, kb = 0.2627, 0.0593
	end
	local kg = 1 - kr - kb
	local ys0, yscale, cscale = 16, 255 / 219, 255 / 224
	if fullRange then
		ys0, yscale, cscale = 0, 1, 1
	end
	local rv, bu = 2 * (1 - kr) * cscale, 2 * (1 - kb) * cscale
	local gu, gv = 2 * (1 - kb) * kb / kg * cscale, 2 * (1 - kr) * kr / kg * cscale
	local identity = matrix == 0 -- (GBR: the planes hold green, blue, red)
	local out = buffer.create(n * 4)
	local hasAlpha = false
	for k = 1, n do
		local cy = CY[k]
		local Yv = cy > 0 and SY[k] / cy or 0
		local Uv = cy > 0 and SU[k] / cy or 128
		local Vv = cy > 0 and SV[k] / cy or 128
		local r, g, bl
		if identity then
			g, bl, r = Yv, Uv, Vv
		else
			local yy = (Yv - ys0) * yscale
			local u, v = Uv - 128, Vv - 128
			r = yy + rv * v
			g = yy - gu * u - gv * v
			bl = yy + bu * u
		end
		local a = 255
		if SA and CA[k] > 0 then
			a = math.clamp(math.floor(SA[k] / CA[k] + 0.5), 0, 255)
			if a < 255 then
				hasAlpha = true
			end
		end
		buffer.writeu32(out, (k - 1) * 4, math.clamp(math.floor(r + 0.5), 0, 255) + 256 * math.clamp(math.floor(g + 0.5), 0, 255)
			+ 65536 * math.clamp(math.floor(bl + 0.5), 0, 255) + 16777216 * a)
	end
	local img = { width = ow, height = oh, data = out, hasAlpha = hasAlpha }
	local sw, sh = rw, rh
	for _, t in ipairs(L.transforms) do
		if t[1] == "rot" then
			img = rotate(img, t[2])
			if t[2] % 2 == 1 then
				sw, sh = sh, sw
			end
		elseif t[1] == "mir" then
			img = mirror(img, t[2])
		end
	end
	img.sourceWidth, img.sourceHeight = sw, sh
	return img
end

return Heif
