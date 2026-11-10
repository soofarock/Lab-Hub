-- A FrameLab block fitter: Video.DirectReader puts copies of this script in Actors under the player's PlayerScripts (here
-- it doesn't run). Each one works out the 8 x 8 blocks (Image.Blocks) of one horizontal stripe of every picture of a
-- stream this client decodes, in parallel with the others and with the game, and hands back only the blocks that
-- change: the screen then just sets them (Video.Player). It keeps what its stripe shows, so a block whose picture
-- still fits stays as it is, and one whose shape still fits only gets new colours.
local actor = script:GetActor()
if not actor then
	return
end
local FrameLab = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("FrameLab")
local Blocks = require(FrameLab.Image.Blocks)
if not Blocks.ready() then -- (loads the pattern library now, before any work in parallel)
	actor:SetAttribute("Ready", false)
	return
end
local fit, errorOf, recolor = Blocks.fitBlock, Blocks.errorOf, Blocks.recolor
local readu8 = buffer.readu8

local FULL_CHECK = 12 -- every this many pictures every block is checked (slow drifts the change test misses)

local states = {} -- reader id -> { gen, idx, col, subs, splits, prev, n }

-- one picture's stripe: data holds its pixel rows (rows x pw x 4, from picture row y0); cells (cols x crows) from
-- cell row cr0. Returns the changed blocks: { ci, idx, ar, ag, ab, br, bg, bb } or { ci, -2, fits } (four 4 x 4)
local function work(st, key, data, W, H, pw, y0, cr0, crows, cols, o)
	local skip, split, maxSplits = o.Skip, o.Split, o.MaxSplits
	local out = {}
	local prev = st.prev
	st.n += 1
	local full = key or not prev or st.n % FULL_CHECK == 0
	for r = 0, crows - 1 do
		for c = 0, cols - 1 do
			local ly = r * 8
			local x0 = c * 8
			local check = full
			if not check then
				-- (changed since the last picture: sampled, every other pixel each way)
				local s = 0
				for yy = 0, 7, 2 do
					local ob = ((ly + yy) * pw + x0) * 4
					for xx = 0, 28, 8 do
						s += math.abs(readu8(data, ob + xx) - readu8(prev, ob + xx))
							+ math.abs(readu8(data, ob + xx + 1) - readu8(prev, ob + xx + 1))
							+ math.abs(readu8(data, ob + xx + 2) - readu8(prev, ob + xx + 2))
					end
				end
				check = s > 48
			end
			if check then
				local ci = (cr0 + r) * cols + c + 1
				local cur = st.idx[ci]
				local curErr = math.huge
				if not key then
					if cur == -2 then
						local fits, se = st.subs[ci], 0
						for q = 1, 4 do
							local f = fits[q]
							local e = errorOf(data, W, H, x0 + ((q - 1) % 2) * 4, ly + ((q - 1) // 2) * 4, 4, pw, f[1], f[2], f[3], f[4], f[5], f[6], f[7])
							se += e * e
						end
						curErr = math.sqrt(se / 4)
					elseif cur ~= nil then
						local k = st.col[ci]
						curErr = errorOf(data, W, H, x0, ly, 8, pw, cur, k[1], k[2], k[3], k[4], k[5], k[6])
					end
				end
				if curErr > skip then
					local done = false
					-- (the same shape, new colours)
					if cur ~= nil and cur ~= -2 and not key then
						local ar, ag, ab, br, bg, bb, e = recolor(data, W, H, x0, ly, 8, pw, cur)
						if e <= skip then
							done = true
							st.col[ci] = { ar, ag, ab, br, bg, bb }
							table.insert(out, { ci, cur, ar, ag, ab, br, bg, bb })
						end
					end
					if not done then
						local kind, ar, ag, ab, br, bg, bb, pidx, e = fit(data, W, H, x0, ly, 8, pw)
						local fits, e4
						if e > split and (cur == -2 or st.splits < maxSplits) then
							fits, e4 = {}, 0
							for q = 1, 4 do
								local k2, r1, g1, b1, r2, g2, b2, i2, eq = fit(data, W, H, x0 + ((q - 1) % 2) * 4, ly + ((q - 1) // 2) * 4, 4, pw)
								fits[q] = { k2 == "flat" and -1 or i2, r1, g1, b1, r2, g2, b2 }
								e4 += eq * eq
							end
							e4 = math.sqrt(e4 / 4)
						end
						if fits and e4 + 1.5 < e then
							if e4 + 1 < curErr then
								if cur ~= -2 then
									st.splits += 1
								end
								st.idx[ci], st.subs[ci] = -2, fits
								table.insert(out, { ci, -2, fits })
							end
						elseif e + 1 < curErr then
							if cur == -2 then
								st.splits -= 1
							end
							local idx = kind == "flat" and -1 or pidx
							st.idx[ci], st.col[ci] = idx, { ar, ag, ab, br, bg, bb }
							table.insert(out, { ci, idx, ar, ag, ab, br, bg, bb })
						end
					end
				end
			end
		end
	end
	st.prev = data
	return out
end

-- a picture's stripe. key: a whole new picture (after a jump, or the first): every block is fitted afresh
actor:BindToMessageParallel("stripe", function(id, gen, frame, key, data, W, H, pw, y0, cr0, crows, cols, o, reply)
	local st = states[id]
	if not st or st.gen ~= gen then
		st = { gen = gen, idx = {}, col = {}, subs = {}, splits = 0, n = 0 }
		states[id] = st
		key = true
	end
	local ok, out = pcall(work, st, key, data, W, math.max(1, H - y0), pw, y0, cr0, crows, cols, o)
	task.synchronize()
	reply:Fire(id, gen, frame, cr0, ok and out or {}, not ok and tostring(out) or nil)
end)
actor:BindToMessage("forget", function(id)
	states[id] = nil
end)
actor:SetAttribute("Ready", true)
