--!native
--!optimize 2
-- A video picture as a fixed grid of 8 x 8 blocks (the block player, Video.Player with Blocks): one ImageLabel per
-- block, background colour A, a pattern from the library (Render.Patterns) tinted B. A new video frame only changes
-- the properties of the blocks that changed (pattern slice, two colours): no objects made or destroyed, no UIGradients
-- (no ~1000 limit, no white strips, no sideways streaks). Same outside as Render.Canvas where the player needs it:
-- Frame, Board, used, gradients, objects(), setOffset(), destroy().

local BlockGrid = {}
BlockGrid.__index = BlockGrid

local FrameLab = script:FindFirstAncestor("FrameLab")
local Patterns = require(FrameLab.Render.Patterns)

local fromRGB = Color3.fromRGB
local BS = 8

function BlockGrid.new(parent, width, height, options)
	options = options or {}
	local self = setmetatable({}, BlockGrid)
	self.width, self.height = width, height
	self.cols, self.rows = (width + BS - 1) // BS, (height + BS - 1) // BS
	local frame = Instance.new("Frame")
	frame.Name = "FrameLabBlocks"
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Size = options.Size or UDim2.fromScale(1, 1)
	frame.Position = options.Position or UDim2.fromScale(0.5, 0.5)
	frame.AnchorPoint = options.AnchorPoint or Vector2.new(0.5, 0.5)
	frame.ZIndex = options.ZIndex or 1
	frame.BackgroundTransparency = options.Background and 0 or 1
	if options.Background then
		frame.BackgroundColor3 = options.Background
	end
	if options.KeepAspect ~= false then
		local ar = Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = width / height
		ar.Parent = frame
	end
	local board = Instance.new("Frame")
	board.Name = "Board"
	board.BackgroundTransparency = 1
	board.BorderSizePixel = 0
	board.Size = UDim2.fromScale(1, 1)
	board.ZIndex = frame.ZIndex
	board.Parent = frame
	self.Frame, self.Board = frame, board
	self.cells = {}
	self.idx = {} -- per cell: pattern index (-1: one colour, -2: split in four 4x4), or nil before its first drawing
	self.col = {} -- per cell: { ar, ag, ab, br, bg, bb }
	self.st = {} -- per cell: its label's drawn state
	self.subs = {} -- per cell: its four 4x4 sub-block labels (made the first time it splits)
	self.splits = 0
	self.used, self.gradients, self.static = 0, 0, false
	self.image = Patterns.image()
	frame.Parent = parent
	return self
end

-- make the cells (a chunk at a time when perYield is given)
function BlockGrid:build(perYield)
	local W, H = self.width, self.height
	local z = self.Frame.ZIndex
	local n = self.cols * self.rows
	for i = #self.cells + 1, n do
		local c, r = (i - 1) % self.cols, (i - 1) // self.cols
		local l = Instance.new("ImageLabel")
		l.BorderSizePixel = 0
		l.ZIndex = z
		l.Image = self.image
		l.ImageRectSize = Vector2.new(BS, BS)
		l.ImageTransparency = 1
		l.BackgroundColor3 = Color3.new(0, 0, 0)
		l.Position = UDim2.fromScale(c * BS / W, r * BS / H)
		l.Size = UDim2.new(BS / W, 1, BS / H, 1)
		l.Parent = self.Board
		self.cells[i] = l
		if perYield and i % perYield == 0 then
			task.wait()
		end
	end
	self.used = n
end

-- one label's look: st = { idx, c = { ar, ag, ab, br, bg, bb } } (only changed properties are written)
local function paint(l, st, size, idx, ar, ag, ab, br, bg, bb)
	local old = st.idx
	local c = st.c
	ar, ag, ab = math.floor(ar + 0.5), math.floor(ag + 0.5), math.floor(ab + 0.5)
	if c[1] ~= ar or c[2] ~= ag or c[3] ~= ab then
		l.BackgroundColor3 = fromRGB(ar, ag, ab)
		c[1], c[2], c[3] = ar, ag, ab
	end
	if idx < 0 then
		if old == nil or old >= 0 then
			l.ImageTransparency = 1
		end
	else
		br, bg, bb = math.floor(br + 0.5), math.floor(bg + 0.5), math.floor(bb + 0.5)
		if old == nil or old < 0 then
			l.ImageTransparency = 0
		end
		if old ~= idx then
			l.ImageRectOffset = Patterns.rect(size, idx)
		end
		if c[4] ~= br or c[5] ~= bg or c[6] ~= bb then
			l.ImageColor3 = fromRGB(br, bg, bb)
			c[4], c[5], c[6] = br, bg, bb
		end
	end
	st.idx = idx
end

local function stateOf(self, i)
	local st = self.st[i]
	if not st then
		st = { idx = nil, c = { -1, -1, -1, -1, -1, -1 } }
		self.st[i] = st
		self.col[i] = st.c
	end
	return st
end

-- the cell's own label again (its four 4x4 sub-blocks hidden)
local function unsplit(self, i)
	local sub = self.subs[i]
	if sub and sub.on then
		sub.on = false
		for q = 1, 4 do
			sub[q].Visible = false
		end
		self.cells[i].BackgroundTransparency = 0
		local st = stateOf(self, i)
		st.idx = nil -- (redraw the image state from scratch)
		st.c[1] = -1
		self.splits -= 1
	end
end

-- draw cell i (1-based): pattern idx (-1: one colour A)
function BlockGrid:set(i, idx, ar, ag, ab, br, bg, bb)
	unsplit(self, i)
	paint(self.cells[i], stateOf(self, i), BS, idx, ar, ag, ab, br, bg, bb)
	self.idx[i] = idx
end

-- draw cell i as four 4x4 blocks: fits[q] = { idx, ar, ag, ab, br, bg, bb } (q: 1 top left, 2 top right, 3, 4)
function BlockGrid:setSplit(i, fits)
	local l = self.cells[i]
	local sub = self.subs[i]
	if not sub then
		sub = { on = false, st = {} }
		for q = 1, 4 do
			local s = Instance.new("ImageLabel")
			s.BorderSizePixel = 0
			s.ZIndex = l.ZIndex
			s.Image = self.image
			s.ImageRectSize = Vector2.new(4, 4)
			s.ImageTransparency = 1
			s.Position = UDim2.fromScale(((q - 1) % 2) * 0.5, ((q - 1) // 2) * 0.5)
			s.Size = UDim2.new(0.5, 1, 0.5, 1)
			s.Visible = false
			s.Parent = l
			sub[q] = s
			sub.st[q] = { idx = nil, c = { -1, -1, -1, -1, -1, -1 } }
		end
		self.subs[i] = sub
	end
	if not sub.on then
		sub.on = true
		self.splits += 1
		l.BackgroundTransparency = 1
		l.ImageTransparency = 1
		stateOf(self, i).idx = -1
		for q = 1, 4 do
			sub[q].Visible = true
		end
	end
	for q = 1, 4 do
		local f = fits[q]
		paint(sub[q], sub.st[q], 4, f[1], f[2], f[3], f[4], f[5], f[6], f[7])
	end
	self.idx[i] = -2 -- split
	self.subFits = self.subFits or {}
	self.subFits[i] = fits
end

function BlockGrid:objects()
	return #self.cells + 4 * self.splits, { grad = 0, shared = 0, shared1 = 0, pieces = self.splits, flat = 0, blocks = #self.cells }
end

function BlockGrid:count()
	return #self.cells, 0
end

function BlockGrid:setOffset() end
function BlockGrid:prewarm() end

function BlockGrid:destroy()
	self.Frame:Destroy()
	self.cells = {}
end

return BlockGrid
