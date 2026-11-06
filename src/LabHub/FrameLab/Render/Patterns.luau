--!native
--!optimize 2
-- The pattern library for block pictures (Image.Blocks): 4096 patterns of 8 x 8 and 4096 of 4 x 4 pixels, each a
-- mix amount 0..1 per pixel, learned (k-means) from many pictures' blocks. One uploaded image holds them all
-- (Config.PatternImage: white, the pattern in the alpha); a block is drawn as ONE ImageLabel: background colour A,
-- the pattern's slice of that image tinted colour B -> pixel = A + pattern x (B - A).
-- The values for matching come from Render.PatternData (two modules: base64 of zlib-packed 4-bit values), arranged
-- as a tree (64 groups x 64 patterns) so a block is matched in ~12k steps instead of 260k.
--
--   Patterns.ready() -> true when the data and the image are set
--   Patterns.match(BS, a) -> index 0..4095   (a: BS*BS mix amounts 0..15)
--   Patterns.value(BS, index, k) -> 0..15    (pixel k, 1-based)
--   Patterns.rect(BS, index) -> ImageRectOffset (Vector2); ImageRectSize = Vector2.new(BS, BS)
--   Patterns.image() -> the atlas image id

local Patterns = {}

local root = script:FindFirstAncestor("FrameLab")
local readu8 = buffer.readu8

-- layout of the unpacked values: [tops 8: 64x64][leaves 8: 4096x64][tops 4: 64x16][leaves 4: 4096x16]
local OFF = {
	[8] = { top = 0, leaf = 64 * 64, n = 64 },
	[4] = { top = 64 * 64 + 4096 * 64, leaf = 64 * 64 + 4096 * 64 + 64 * 16, n = 16 },
}
local TOTAL = 64 * 64 + 4096 * 64 + 64 * 16 + 4096 * 16
-- atlas layout (pixels): 8x8 patterns in 12-pixel cells (2 of padding) 64 a row from (0, 0); 4x4 patterns in 8-pixel
-- cells, 32 a row from (768, 0)
local LAYOUT = { [8] = { cell = 12, x0 = 0, cols = 64 }, [4] = { cell = 8, x0 = 768, cols = 32 } }

local data -- buffer of TOTAL values 0..15, or false when missing

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64decode(s)
	local ok, out = pcall(function()
		return game:GetService("EncodingService"):Base64Decode(buffer.fromstring(s))
	end)
	if ok and typeof(out) == "buffer" then
		return out
	end
	local map = {}
	for i = 1, 64 do
		map[string.byte(B64, i)] = i - 1
	end
	local n = #s
	local pad = (string.sub(s, -2) == "==") and 2 or ((string.sub(s, -1) == "=") and 1 or 0)
	local len = (n // 4) * 3 - pad
	local b = buffer.create(len)
	local o = 0
	for i = 1, n, 4 do
		local c1, c2, c3, c4 = string.byte(s, i, i + 3)
		local v = (map[c1] or 0) * 262144 + (map[c2] or 0) * 4096 + (map[c3] or 0) * 64 + (map[c4] or 0)
		if o < len then buffer.writeu8(b, o, v // 65536) end
		if o + 1 < len then buffer.writeu8(b, o + 1, (v // 256) % 256) end
		if o + 2 < len then buffer.writeu8(b, o + 2, v % 256) end
		o += 3
	end
	return b
end

local function load()
	if data ~= nil then
		return data
	end
	data = false
	local folder = script.Parent:FindFirstChild("PatternData")
	if not folder or not folder:FindFirstChild("PatternData1") or not folder:FindFirstChild("PatternData2") then
		return data
	end
	local ok, err = pcall(function()
		local s = require(folder.PatternData1) .. require(folder.PatternData2)
		local z = b64decode(s)
		local Inflate = require(root.Formats.Inflate)
		local packed, len = Inflate.zlib(z, 0, TOTAL // 2)
		assert(len == TOTAL // 2, "pattern data: wrong size " .. tostring(len))
		local out = buffer.create(TOTAL)
		for i = 0, len - 1 do
			local v = readu8(packed, i)
			buffer.writeu8(out, i * 2, v // 16)
			buffer.writeu8(out, i * 2 + 1, v % 16)
		end
		data = out
	end)
	if not ok then
		warn("[FrameLab] pattern library: " .. tostring(err))
		data = false
	end
	return data
end

function Patterns.image()
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config"))
	local v = Config.PatternImage
	return (type(v) == "string" and v ~= "") and v or nil
end

function Patterns.ready()
	return Patterns.image() ~= nil and load() ~= false
end

-- nearest pattern to a (BS*BS values 0..15): the 2 nearest groups, then their 64 patterns each
function Patterns.match(BS, a)
	local d = load()
	local o = OFF[BS]
	local n = o.n
	local b1, b2, d1, d2 = 0, 0, math.huge, math.huge
	for g = 0, 63 do
		local base = o.top + g * n
		local s = 0
		for k = 1, n do
			local e = a[k] - readu8(d, base + k - 1)
			s += e * e
		end
		if s < d1 then
			b2, d2 = b1, d1
			b1, d1 = g, s
		elseif s < d2 then
			b2, d2 = g, s
		end
	end
	local best, bd = 0, math.huge
	for pass = 1, 2 do
		local g = pass == 1 and b1 or b2
		for j = 0, 63 do
			local idx = g * 64 + j
			local base = o.leaf + idx * n
			local s = 0
			for k = 1, n do
				local e = a[k] - readu8(d, base + k - 1)
				s += e * e
				if s >= bd then
					break
				end
			end
			if s < bd then
				best, bd = idx, s
			end
		end
	end
	return best
end

function Patterns.value(BS, idx, k)
	local o = OFF[BS]
	return readu8(data, o.leaf + idx * o.n + k - 1)
end

function Patterns.rect(BS, idx)
	local L = LAYOUT[BS]
	local pad = (L.cell - BS) // 2
	return Vector2.new(L.x0 + (idx % L.cols) * L.cell + pad, (idx // L.cols) * L.cell + pad)
end

return Patterns
