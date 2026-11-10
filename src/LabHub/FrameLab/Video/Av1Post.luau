--!native
--!optimize 2
-- FrameLab AV1 decoder, part 2: the in-loop filters run on a decoded frame (deblocking, CDEF, super-resolution
-- upscaling, loop restoration) and film grain synthesis on the shown copy. Driven by FrameLab.Video.Av1.

local band, bor, bxor, rshift = bit32.band, bit32.bor, bit32.bxor, bit32.rshift
local countlz = bit32.countlz
local readu8, readi8, readu16, writeu16 = buffer.readu8, buffer.readi8, buffer.readu16, buffer.writeu16
local bcopy, bcreate, blen = buffer.copy, buffer.create, buffer.len
local abs, min, max = math.abs, math.min, math.max
local tcreate = table.create

local Tab = require(script.Parent.Av1Tables)

local P2 = {}
for k = 0, 60 do
	P2[k + 1] = 2 ^ k
end

local function round2(x, n)
	if n == 0 then
		return x
	end
	return (x + P2[n]) // P2[n + 1]
end

local function floorLog2(x)
	return 31 - countlz(x)
end

local lastYield = os.clock()
local function breathe()
	if task and os.clock() - lastYield > 0.05 then
		task.wait()
		lastYield = os.clock()
	end
end

local Num4x4W = { 1, 1, 2, 2, 2, 4, 4, 4, 8, 8, 8, 16, 16, 16, 32, 32, 1, 4, 2, 8, 4, 16 }
local Num4x4H = { 1, 2, 1, 2, 4, 2, 4, 8, 4, 8, 16, 8, 16, 32, 16, 32, 4, 1, 8, 2, 16, 4 }
local BlockW, BlockH = {}, {}
for i = 1, 22 do
	BlockW[i] = Num4x4W[i] * 4
	BlockH[i] = Num4x4H[i] * 4
end
local TxW, TxH = Tab.Tx_Width, Tab.Tx_Height
local SubsampledSize = Tab.Subsampled_Size
local function planeSize(bsize, ssx, ssy)
	return SubsampledSize[bsize * 4 + ssx * 2 + ssy + 1]
end

-- the frame being filtered (set by bind)
local F, S
local planes, pstride
local MiRows, MiCols = 0, 0
local mSeg, mRef, mYMode, mDeltaLF, mLfTx, mMiSize, mSkip
local cdefIdx, cdefStride, lrUnits
local curFrame, getFrame
local ssx, ssy, NumPlanes, BitDepth, pixMax = 1, 1, 3, 8, 255

local Post = {}

function Post.bind(c)
	F, S = c.F, c.S
	planes, pstride = c.planes, c.pstride
	MiRows, MiCols = c.MiRows, c.MiCols
	mSeg, mRef, mYMode, mDeltaLF, mLfTx, mMiSize, mSkip = c.mSeg, c.mRef, c.mYMode, c.mDeltaLF, c.mLfTx, c.mMiSize, c.mSkip
	cdefIdx, cdefStride, lrUnits = c.cdefIdx, c.cdefStride, c.lrUnits
	curFrame, getFrame = c.curFrame, c.getFrame
	ssx, ssy, NumPlanes, BitDepth, pixMax = c.ssx, c.ssy, c.NumPlanes, c.BitDepth, c.pixMax
end

-- the frame store after filtering (super-resolution replaces it)
function Post.frame()
	return curFrame
end

------------------------------------------------------------------------------------------------------------------------
-- loop filter

local lvlCache = {}
local LIM, BLIM, THR = tcreate(64, 0), tcreate(64, 0), tcreate(64, 0)

local function lfLevel(row, col, plane, pass)
	local i = row * MiCols + col
	local segment = readu8(mSeg, i)
	local ref = readi8(mRef, i * 2)
	local mode = readu8(mYMode, i)
	local modeType = (mode >= 14 and mode ~= 16 and mode ~= 24) and 1 or 0
	local li = plane == 0 and pass or plane + 1
	local deltaLF = 0
	if F.delta_lf_present == 1 then
		deltaLF = F.delta_lf_multi == 0 and readi8(mDeltaLF, i * 4) or readi8(mDeltaLF, i * 4 + li)
	end
	local key = ((((deltaLF + 64) * 8 + segment) * 9 + ref + 1) * 2 + modeType) * 4 + li
	local cached = lvlCache[key]
	if cached then
		return cached
	end
	local lvl = math.clamp(deltaLF + F.loop_filter_level[li], 0, 63)
	local feature = 1 + li
	if F.segmentation_enabled == 1 and F.FeatureEnabled[segment * 8 + feature + 1] == 1 then
		lvl = math.clamp(lvl + F.FeatureData[segment * 8 + feature + 1], 0, 63)
	end
	if F.loop_filter_delta_enabled == 1 then
		local m = lvl >= 32 and 2 or 1
		if ref <= 0 then
			lvl += F.loop_filter_ref_deltas[0] * m
		else
			lvl += F.loop_filter_ref_deltas[ref] * m + F.loop_filter_mode_deltas[modeType] * m
		end
		lvl = math.clamp(lvl, 0, 63)
	end
	lvlCache[key] = lvl
	return lvl
end

-- filters the 4 samples along one edge segment; off0 = sample offset (bytes) of q0 of the first sample, along =
-- byte step to the next sample along the edge, s2 = byte step across the edge
local function filterEdge(buf, off0, along, s2, filterSize, plane, lvl, one)
	local limitBd, blimitBd, threshBd = LIM[lvl + 1], BLIM[lvl + 1], THR[lvl + 1]
	local filterLen = filterSize == 4 and 4 or (plane ~= 0 and 6 or (filterSize == 8 and 8 or 16))
	local c80 = 128 * one
	local lo, hi = -P2[BitDepth], P2[BitDepth] - 1
	for k = 0, 3 do
		local off = off0 + k * along
		local q0 = readu16(buf, off)
		local p0 = readu16(buf, off - s2)
		local q1 = readu16(buf, off + s2)
		local p1 = readu16(buf, off - 2 * s2)
		local ap1p0, aq1q0 = abs(p1 - p0), abs(q1 - q0)
		local pass = ap1p0 <= limitBd and aq1q0 <= limitBd and abs(p0 - q0) * 2 + abs(p1 - q1) // 2 <= blimitBd
		local q2, p2, q3, p3 = 0, 0, 0, 0
		if pass and filterLen >= 6 then
			q2 = readu16(buf, off + 2 * s2)
			p2 = readu16(buf, off - 3 * s2)
			pass = abs(p2 - p1) <= limitBd and abs(q2 - q1) <= limitBd
			if pass and filterLen >= 8 then
				q3 = readu16(buf, off + 3 * s2)
				p3 = readu16(buf, off - 4 * s2)
				pass = abs(p3 - p2) <= limitBd and abs(q3 - q2) <= limitBd
			end
		end
		if pass then
			local flat = false
			if filterSize >= 8 then
				flat = ap1p0 <= one and aq1q0 <= one and abs(p2 - p0) <= one and abs(q2 - q0) <= one
				if flat and filterLen >= 8 then
					flat = abs(p3 - p0) <= one and abs(q3 - q0) <= one
				end
			end
			if filterSize == 4 or not flat then
				-- narrow filter
				local hev = ap1p0 > threshBd or aq1q0 > threshBd
				local ps1, ps0, qs0, qs1 = p1 - c80, p0 - c80, q0 - c80, q1 - c80
				local filt = 0
				if hev then
					filt = ps1 - qs1
					if filt < lo then
						filt = lo
					elseif filt > hi then
						filt = hi
					end
				end
				filt += 3 * (qs0 - ps0)
				if filt < lo then
					filt = lo
				elseif filt > hi then
					filt = hi
				end
				local f1 = filt + 4
				if f1 > hi then
					f1 = hi
				end
				f1 //= 8
				local f2 = filt + 3
				if f2 > hi then
					f2 = hi
				end
				f2 //= 8
				local v = qs0 - f1
				if v < lo then
					v = lo
				elseif v > hi then
					v = hi
				end
				writeu16(buf, off, v + c80)
				v = ps0 + f2
				if v < lo then
					v = lo
				elseif v > hi then
					v = hi
				end
				writeu16(buf, off - s2, v + c80)
				if not hev then
					local f = (f1 + 1) // 2
					v = qs1 - f
					if v < lo then
						v = lo
					elseif v > hi then
						v = hi
					end
					writeu16(buf, off + s2, v + c80)
					v = ps1 + f
					if v < lo then
						v = lo
					elseif v > hi then
						v = hi
					end
					writeu16(buf, off - 2 * s2, v + c80)
				end
			elseif filterSize >= 16 then
				local q4, q5, q6 = readu16(buf, off + 4 * s2), readu16(buf, off + 5 * s2), readu16(buf, off + 6 * s2)
				local p4, p5, p6 = readu16(buf, off - 5 * s2), readu16(buf, off - 6 * s2), readu16(buf, off - 7 * s2)
				if abs(p6 - p0) <= one and abs(q6 - q0) <= one and abs(p5 - p0) <= one and abs(q5 - q0) <= one
					and abs(p4 - p0) <= one and abs(q4 - q0) <= one then
					writeu16(buf, off - 6 * s2, (p6 * 7 + p5 * 2 + p4 * 2 + p3 + p2 + p1 + p0 + q0 + 8) // 16)
					writeu16(buf, off - 5 * s2, (p6 * 5 + p5 * 2 + p4 * 2 + p3 * 2 + p2 + p1 + p0 + q0 + q1 + 8) // 16)
					writeu16(buf, off - 4 * s2, (p6 * 4 + p5 + p4 * 2 + p3 * 2 + p2 * 2 + p1 + p0 + q0 + q1 + q2 + 8) // 16)
					writeu16(buf, off - 3 * s2, (p6 * 3 + p5 + p4 + p3 * 2 + p2 * 2 + p1 * 2 + p0 + q0 + q1 + q2 + q3 + 8) // 16)
					writeu16(buf, off - 2 * s2, (p6 * 2 + p5 + p4 + p3 + p2 * 2 + p1 * 2 + p0 * 2 + q0 + q1 + q2 + q3 + q4 + 8) // 16)
					writeu16(buf, off - s2, (p6 + p5 + p4 + p3 + p2 + p1 * 2 + p0 * 2 + q0 * 2 + q1 + q2 + q3 + q4 + q5 + 8) // 16)
					writeu16(buf, off, (p5 + p4 + p3 + p2 + p1 + p0 * 2 + q0 * 2 + q1 * 2 + q2 + q3 + q4 + q5 + q6 + 8) // 16)
					writeu16(buf, off + 1 * s2, (p4 + p3 + p2 + p1 + p0 + q0 * 2 + q1 * 2 + q2 * 2 + q3 + q4 + q5 + q6 * 2 + 8) // 16)
					writeu16(buf, off + 2 * s2, (p3 + p2 + p1 + p0 + q0 + q1 * 2 + q2 * 2 + q3 * 2 + q4 + q5 + q6 * 3 + 8) // 16)
					writeu16(buf, off + 3 * s2, (p2 + p1 + p0 + q0 + q1 + q2 * 2 + q3 * 2 + q4 * 2 + q5 + q6 * 4 + 8) // 16)
					writeu16(buf, off + 4 * s2, (p1 + p0 + q0 + q1 + q2 + q3 * 2 + q4 * 2 + q5 * 2 + q6 * 5 + 8) // 16)
					writeu16(buf, off + 5 * s2, (p0 + q0 + q1 + q2 + q3 + q4 * 2 + q5 * 2 + q6 * 7 + 8) // 16)
				else
					writeu16(buf, off - 3 * s2, (p3 * 3 + p2 * 2 + p1 + p0 + q0 + 4) // 8)
					writeu16(buf, off - 2 * s2, (p3 * 2 + p2 + p1 * 2 + p0 + q0 + q1 + 4) // 8)
					writeu16(buf, off - s2, (p3 + p2 + p1 + p0 * 2 + q0 + q1 + q2 + 4) // 8)
					writeu16(buf, off, (p2 + p1 + p0 + q0 * 2 + q1 + q2 + q3 + 4) // 8)
					writeu16(buf, off + 1 * s2, (p1 + p0 + q0 + q1 * 2 + q2 + q3 * 2 + 4) // 8)
					writeu16(buf, off + 2 * s2, (p0 + q0 + q1 + q2 * 2 + q3 * 3 + 4) // 8)
				end
			elseif plane == 0 then
				writeu16(buf, off - 3 * s2, (p3 * 3 + p2 * 2 + p1 + p0 + q0 + 4) // 8)
				writeu16(buf, off - 2 * s2, (p3 * 2 + p2 + p1 * 2 + p0 + q0 + q1 + 4) // 8)
				writeu16(buf, off - s2, (p3 + p2 + p1 + p0 * 2 + q0 + q1 + q2 + 4) // 8)
				writeu16(buf, off, (p2 + p1 + p0 + q0 * 2 + q1 + q2 + q3 + 4) // 8)
				writeu16(buf, off + 1 * s2, (p1 + p0 + q0 + q1 * 2 + q2 + q3 * 2 + 4) // 8)
				writeu16(buf, off + 2 * s2, (p0 + q0 + q1 + q2 * 2 + q3 * 3 + 4) // 8)
			else
				writeu16(buf, off - 2 * s2, (p2 * 3 + p1 * 2 + p0 * 2 + q0 + 4) // 8)
				writeu16(buf, off - s2, (p2 + p1 * 2 + p0 * 2 + q0 * 2 + q1 + 4) // 8)
				writeu16(buf, off, (p1 + p0 * 2 + q0 * 2 + q1 * 2 + q2 + 4) // 8)
				writeu16(buf, off + 1 * s2, (p0 + q0 * 2 + q1 * 2 + q2 * 3 + 4) // 8)
			end
		end
	end
end

local function loopFilterFrame()
	table.clear(lvlCache)
	local sharp = F.loop_filter_sharpness
	local shift = sharp > 4 and 2 or (sharp > 0 and 1 or 0)
	local bdShift = BitDepth - 8
	local mulBd = P2[bdShift + 1]
	for lvl = 0, 63 do
		local limit
		if sharp > 0 then
			limit = math.clamp(lvl // P2[shift + 1], 1, 9 - sharp)
		else
			limit = max(1, lvl // P2[shift + 1])
		end
		LIM[lvl + 1] = limit * mulBd
		BLIM[lvl + 1] = (2 * (lvl + 2) + limit) * mulBd
		THR[lvl + 1] = (lvl // 16) * mulBd
	end
	for plane = 0, NumPlanes - 1 do
		if plane == 0 or F.loop_filter_level[1 + plane] ~= 0 then
			local sx = plane > 0 and ssx or 0
			local sy = plane > 0 and ssy or 0
			local buf, stride = planes[plane], pstride[plane]
			local lfTx = mLfTx[plane]
			local px, py = P2[sx + 1], P2[sy + 1]
			for pass = 0, 1 do
				local dx, dy = pass == 0 and 1 or 0, pass == 0 and 0 or 1
				local s2 = pass == 0 and 2 or stride * 2
				local along = pass == 0 and stride * 2 or 2
				for row0 = 0, MiRows - 1, py do
					local y = row0 * 4
					if y >= F.FrameHeight then
						break
					end
					if not (pass == 1 and y == 0) then
						local row = bor(row0, sy)
						local yP = y // py
						local prevRow = row - dy * py
						local lfRow = (row // py) * MiCols
						local lfPrevRow = (prevRow // py) * MiCols
						for col0 = 0, MiCols - 1, px do
							local x = col0 * 4
							if x >= F.FrameWidth then
								break
							end
							if not (pass == 0 and x == 0) then
								local col = bor(col0, sx)
								local xP = x // px
								local txSz = readu8(lfTx, lfRow + col // px)
								local isTxEdge
								if pass == 0 then
									isTxEdge = xP % TxW[txSz + 1] == 0
								else
									isTxEdge = yP % TxH[txSz + 1] == 0
								end
								if isTxEdge then
									local mi = row * MiCols + col
									local applyFilter = readu8(mSkip, mi) == 0 or readi8(mRef, mi * 2) <= 0
									if not applyFilter then
										local pSize = planeSize(readu8(mMiSize, mi), sx, sy)
										if pass == 0 then
											applyFilter = xP % BlockW[pSize + 1] == 0
										else
											applyFilter = yP % BlockH[pSize + 1] == 0
										end
									end
									if applyFilter then
										local prevCol = col - dx * px
										local prevTx = readu8(lfTx, lfPrevRow + prevCol // px)
										local base = pass == 0 and min(TxW[prevTx + 1], TxW[txSz + 1])
											or min(TxH[prevTx + 1], TxH[txSz + 1])
										local filterSize = plane == 0 and min(16, base) or min(8, base)
										local lvl = lfLevel(row, col, plane, pass)
										if lvl == 0 then
											lvl = lfLevel(prevRow, prevCol, plane, pass)
										end
										if lvl > 0 then
											filterEdge(buf, (yP * stride + xP) * 2, along, s2, filterSize, plane, lvl, mulBd)
										end
									end
								end
							end
						end
					end
				end
				breathe()
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- CDEF

local CdefUvDir = Tab.Cdef_Uv_Dir
local CdefDirections = Tab.Cdef_Directions
local DivTable = Tab.Div_Table
local partial = {}
for i = 0, 7 do
	partial[i] = tcreate(15, 0)
end
local cost = tcreate(8, 0)

local function cdefDirection(src, stride, x0, y0, bdShift)
	for i = 0, 7 do
		local p = partial[i]
		for j = 1, 15 do
			p[j] = 0
		end
	end
	local d = P2[bdShift + 1]
	local p0, p1, p2, p3, p4, p5, p6, p7 = partial[0], partial[1], partial[2], partial[3], partial[4], partial[5],
		partial[6], partial[7]
	for i = 0, 7 do
		local o = ((y0 + i) * stride + x0) * 2
		for j = 0, 7 do
			local x = readu16(src, o + j * 2) // d - 128
			p0[i + j + 1] += x
			p1[i + j // 2 + 1] += x
			p2[i + 1] += x
			p3[3 + i - j // 2 + 1] += x
			p4[7 + i - j + 1] += x
			p5[3 - i // 2 + j + 1] += x
			p6[j + 1] += x
			p7[i // 2 + j + 1] += x
		end
	end
	for i = 0, 7 do
		cost[i + 1] = 0
	end
	for i = 0, 7 do
		cost[3] += p2[i + 1] * p2[i + 1]
		cost[7] += p6[i + 1] * p6[i + 1]
	end
	cost[3] *= DivTable[9]
	cost[7] *= DivTable[9]
	for i = 0, 6 do
		cost[1] += (p0[i + 1] * p0[i + 1] + p0[15 - i] * p0[15 - i]) * DivTable[i + 2]
		cost[5] += (p4[i + 1] * p4[i + 1] + p4[15 - i] * p4[15 - i]) * DivTable[i + 2]
	end
	cost[1] += p0[8] * p0[8] * DivTable[9]
	cost[5] += p4[8] * p4[8] * DivTable[9]
	for i = 1, 7, 2 do
		local p = partial[i]
		local c = 0
		for j = 0, 4 do
			c += p[3 + j + 1] * p[3 + j + 1]
		end
		c *= DivTable[9]
		for j = 0, 2 do
			c += (p[j + 1] * p[j + 1] + p[10 - j + 1] * p[10 - j + 1]) * DivTable[2 * j + 3]
		end
		cost[i + 1] = c
	end
	local bestCost, yDir = 0, 0
	for i = 0, 7 do
		if cost[i + 1] > bestCost then
			bestCost = cost[i + 1]
			yDir = i
		end
	end
	local var = (bestCost - cost[(yDir + 4) % 8 + 1]) // 1024
	return yDir, var
end

local CDEF_TY, CDEF_TX, CDEF_W = tcreate(6, 0), tcreate(6, 0), { 0, 0, 2, 1, 2, 1 }

local function cdefFilter(plane, src, dst, stride, r, c, priStr, secStr, damping, dir, bdShift)
	if priStr == 0 and secStr == 0 then
		return
	end
	local sx = plane > 0 and ssx or 0
	local sy = plane > 0 and ssy or 0
	local x0 = (c * 4) // P2[sx + 1]
	local y0 = (r * 4) // P2[sy + 1]
	local w = 8 // P2[sx + 1]
	local h = 8 // P2[sy + 1]
	local priTap = band(priStr // P2[bdShift + 1], 1)
	local pt0, pt1 = priTap == 0 and 4 or 3, priTap == 0 and 2 or 3
	local priDiv = priStr > 0 and P2[max(0, damping - floorLog2(priStr)) + 1] or 1
	local secDiv = secStr > 0 and P2[max(0, damping - floorLog2(secStr)) + 1] or 1
	local maxY = (MiRows * 4) // P2[sy + 1]
	local maxX = (MiCols * 4) // P2[sx + 1]
	-- taps: (dy, dx) for primary k = 0, 1 and secondary (dir + 2, dir - 2) k = 0, 1
	local ty, tx = CDEF_TY, CDEF_TX
	local da, db, dc = dir * 4 + 1, ((dir + 2) % 8) * 4 + 1, ((dir + 6) % 8) * 4 + 1
	ty[1], tx[1] = CdefDirections[da], CdefDirections[da + 1]
	ty[2], tx[2] = CdefDirections[da + 2], CdefDirections[da + 3]
	ty[3], tx[3] = CdefDirections[db], CdefDirections[db + 1]
	ty[4], tx[4] = CdefDirections[db + 2], CdefDirections[db + 3]
	ty[5], tx[5] = CdefDirections[dc], CdefDirections[dc + 1]
	ty[6], tx[6] = CdefDirections[dc + 2], CdefDirections[dc + 3]
	local weights = CDEF_W
	weights[1], weights[2] = pt0, pt1
	local interior = x0 >= 2 and y0 >= 2 and x0 + w + 2 <= maxX and y0 + h + 2 <= maxY
	if interior then
		local o1, o2, o3, o4, o5, o6 = (ty[1] * stride + tx[1]) * 2, (ty[2] * stride + tx[2]) * 2,
			(ty[3] * stride + tx[3]) * 2, (ty[4] * stride + tx[4]) * 2, (ty[5] * stride + tx[5]) * 2,
			(ty[6] * stride + tx[6]) * 2
		for i = 0, h - 1 do
			local rowO = ((y0 + i) * stride + x0) * 2
			for j = 0, w - 1 do
				local o = rowO + j * 2
				local x = readu16(src, o)
				local sum = 0
				local mx, mn = x, x
				local p, d, ad, cv
				if priStr > 0 then
					p = readu16(src, o + o1)
					d = p - x
					ad = d < 0 and -d or d
					cv = priStr - ad // priDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv * pt0
						else
							sum += cv * pt0
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
					p = readu16(src, o - o1)
					d = p - x
					ad = d < 0 and -d or d
					cv = priStr - ad // priDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv * pt0
						else
							sum += cv * pt0
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
					p = readu16(src, o + o2)
					d = p - x
					ad = d < 0 and -d or d
					cv = priStr - ad // priDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv * pt1
						else
							sum += cv * pt1
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
					p = readu16(src, o - o2)
					d = p - x
					ad = d < 0 and -d or d
					cv = priStr - ad // priDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv * pt1
						else
							sum += cv * pt1
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
				end
				if secStr > 0 then
					p = readu16(src, o + o3)
					d = p - x
					ad = d < 0 and -d or d
					cv = secStr - ad // secDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv * 2
						else
							sum += cv * 2
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
					p = readu16(src, o - o3)
					d = p - x
					ad = d < 0 and -d or d
					cv = secStr - ad // secDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv * 2
						else
							sum += cv * 2
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
					p = readu16(src, o + o4)
					d = p - x
					ad = d < 0 and -d or d
					cv = secStr - ad // secDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv
						else
							sum += cv
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
					p = readu16(src, o - o4)
					d = p - x
					ad = d < 0 and -d or d
					cv = secStr - ad // secDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv
						else
							sum += cv
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
					p = readu16(src, o + o5)
					d = p - x
					ad = d < 0 and -d or d
					cv = secStr - ad // secDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv * 2
						else
							sum += cv * 2
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
					p = readu16(src, o - o5)
					d = p - x
					ad = d < 0 and -d or d
					cv = secStr - ad // secDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv * 2
						else
							sum += cv * 2
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
					p = readu16(src, o + o6)
					d = p - x
					ad = d < 0 and -d or d
					cv = secStr - ad // secDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv
						else
							sum += cv
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
					p = readu16(src, o - o6)
					d = p - x
					ad = d < 0 and -d or d
					cv = secStr - ad // secDiv
					if cv > 0 then
						if cv > ad then
							cv = ad
						end
						if d < 0 then
							sum -= cv
						else
							sum += cv
						end
					end
					if p > mx then
						mx = p
					elseif p < mn then
						mn = p
					end
				end
				local v = x + (8 + sum - (sum < 0 and 1 or 0)) // 16
				if v < mn then
					v = mn
				elseif v > mx then
					v = mx
				end
				writeu16(dst, o, v)
			end
		end
		return
	end
	for i = 0, h - 1 do
		local y = y0 + i
		for j = 0, w - 1 do
			local xx = x0 + j
			local o = (y * stride + xx) * 2
			local x = readu16(src, o)
			local sum = 0
			local mx, mn = x, x
			for t = 1, 6 do
				local isPri = t <= 2
				local str = isPri and priStr or secStr
				for sgn = -1, 1, 2 do
					local yy, xq = y + ty[t] * sgn, xx + tx[t] * sgn
					if yy >= 0 and yy < maxY and xq >= 0 and xq < maxX then
						local p = readu16(src, (yy * stride + xq) * 2)
						if str > 0 then
							local d = p - x
							local ad = abs(d)
							local cv = str - ad // (isPri and priDiv or secDiv)
							if cv < 0 then
								cv = 0
							elseif cv > ad then
								cv = ad
							end
							cv *= weights[t]
							if d < 0 then
								sum -= cv
							else
								sum += cv
							end
							if p > mx then
								mx = p
							end
							if p < mn then
								mn = p
							end
						end
					end
				end
			end
			local v = x + (8 + sum - (sum < 0 and 1 or 0)) // 16
			if v < mn then
				v = mn
			elseif v > mx then
				v = mx
			end
			writeu16(dst, o, v)
		end
	end
end

-- scratch frame stores for filter outputs (swapped with the frame's own planes)
local scratch = {}
local function scratchPlanes(key, sizes)
	local s = scratch[key]
	if not s or blen(s[0]) < sizes[0] or blen(s[1]) < sizes[1] then
		s = { [0] = bcreate(sizes[0]), bcreate(sizes[1]), bcreate(sizes[2]) }
		scratch[key] = s
	end
	return s
end

local function cdefFrame()
	scratch.deblocked = nil
	local bdShift = BitDepth - 8
	local src = { [0] = planes[0], planes[1], planes[2] }
	local dst = scratchPlanes("cdef", { [0] = blen(src[0]), blen(src[1]), blen(src[2]) })
	for p = 0, NumPlanes - 1 do
		bcopy(dst[p], 0, src[p], 0, blen(src[p]))
	end
	for r = 0, MiRows - 1, 2 do
		for c = 0, MiCols - 1, 2 do
			local idx = readi8(cdefIdx, (r // 16) * cdefStride + c // 16)
			if idx ~= -1 then
				local skipB = readu8(mSkip, r * MiCols + c) == 1 and readu8(mSkip, (r + 1) * MiCols + c) == 1
					and readu8(mSkip, r * MiCols + c + 1) == 1 and readu8(mSkip, (r + 1) * MiCols + c + 1) == 1
				if not skipB then
					local yDir, var = cdefDirection(src[0], pstride[0], c * 4, r * 4, bdShift)
					local priStr = F.cdef_y_pri[idx] * P2[bdShift + 1]
					local secStr = F.cdef_y_sec[idx] * P2[bdShift + 1]
					local dir = priStr == 0 and 0 or yDir
					local varStr = (var // 64) > 0 and min(floorLog2(var // 64), 12) or 0
					priStr = var ~= 0 and (priStr * (4 + varStr) + 8) // 16 or 0
					local damping = F.CdefDamping + bdShift
					cdefFilter(0, src[0], dst[0], pstride[0], r, c, priStr, secStr, damping, dir, bdShift)
					if NumPlanes > 1 then
						priStr = F.cdef_uv_pri[idx] * P2[bdShift + 1]
						secStr = F.cdef_uv_sec[idx] * P2[bdShift + 1]
						dir = priStr == 0 and 0 or CdefUvDir[ssx * 16 + ssy * 8 + yDir + 1]
						damping = F.CdefDamping + bdShift - 1
						cdefFilter(1, src[1], dst[1], pstride[1], r, c, priStr, secStr, damping, dir, bdShift)
						cdefFilter(2, src[2], dst[2], pstride[2], r, c, priStr, secStr, damping, dir, bdShift)
					end
				end
			end
		end
		breathe()
	end
	-- the filtered planes become the frame's; the deblocked ones stay available for loop restoration
	scratch.cdef = src
	scratch.deblocked = src
	for p = 0, 2 do
		planes[p] = dst[p]
		curFrame.planes[p] = dst[p]
	end
end

------------------------------------------------------------------------------------------------------------------------
-- super-resolution (horizontal upscaling)

local UpscaleFilter = Tab.Upscale_Filter

local function upscalePlanes(srcPlanes, srcStrides, dstPlanes, dstStrides)
	for plane = 0, NumPlanes - 1 do
		local sx = plane > 0 and ssx or 0
		local sy = plane > 0 and ssy or 0
		local downW = round2(F.FrameWidth, sx)
		local upW = round2(F.UpscaledWidth, sx)
		local planeH = round2(F.FrameHeight, sy)
		local stepX = (downW * 16384 + upW // 2) // upW
		local err = upW * stepX - downW * 16384
		local num = -((upW - downW) * 8192) + upW // 2
		-- C-style division (towards zero)
		local q = num >= 0 and num // upW or -((-num) // upW)
		local e2 = err >= 0 and err // 2 or -((-err) // 2)
		local initialSubpelX = band(q + 128 - e2, 16383)
		local miW = MiCols // P2[sx + 1]
		local maxX = miW * 4 - 1
		local src, ss = srcPlanes[plane], srcStrides[plane]
		local dst, ds = dstPlanes[plane], dstStrides[plane]
		for y = 0, planeH - 1 do
			local so = y * ss * 2
			local dO = y * ds * 2
			for x = 0, upW - 1 do
				local srcX = -16384 + initialSubpelX + x * stepX
				local px = srcX // 16384
				local sub = (srcX % 16384) // 256
				local sum = 0
				local fb = sub * 8
				for k = 0, 7 do
					local sxp = px + k - 3
					if sxp < 0 then
						sxp = 0
					elseif sxp > maxX then
						sxp = maxX
					end
					sum += readu16(src, so + sxp * 2) * UpscaleFilter[fb + k + 1]
				end
				local v = (sum + 64) // 128
				if v < 0 then
					v = 0
				elseif v > pixMax then
					v = pixMax
				end
				writeu16(dst, dO + x * 2, v)
			end
		end
	end
end

local function superresFrame()
	-- the frame store becomes one of upscaled width
	local wAlloc = (F.UpscaledWidth + 127) // 128 * 128 + 64
	local hAlloc = curFrame.hAlloc
	local up = getFrame(wAlloc, hAlloc)
	local upStrides = up.stride
	upscalePlanes(planes, pstride, up.planes, upStrides)
	if scratch.deblocked and F.UsesLr == 1 then
		local cw = wAlloc // P2[ssx + 1]
		local ch = hAlloc // P2[ssy + 1]
		local d = scratchPlanes("updeblocked", { [0] = wAlloc * hAlloc * 2, cw * ch * 2, cw * ch * 2 })
		upscalePlanes(scratch.deblocked, pstride, d, upStrides)
		scratch.deblocked = d
	end
	curFrame = up
	for p = 0, 2 do
		planes[p] = up.planes[p]
		pstride[p] = up.stride[p]
	end
end

------------------------------------------------------------------------------------------------------------------------
-- loop restoration

local SgrParams = Tab.Sgr_Params
local INTER = tcreate(80 * 70, 0)
local BOX_A, BOX_B = tcreate(70 * 70, 0), tcreate(70 * 70, 0)
local FLT0, FLT1 = tcreate(64 * 64, 0), tcreate(64 * 64, 0)

local function loopRestorationFrame()
	local cdefP = { [0] = planes[0], planes[1], planes[2] }
	local deb = scratch.deblocked or cdefP
	if scratch.lr == deb then
		scratch.lr = nil
	end
	local out = scratchPlanes("lr", { [0] = blen(cdefP[0]), blen(cdefP[1]), blen(cdefP[2]) })
	for p = 0, NumPlanes - 1 do
		bcopy(out[p], 0, cdefP[p], 0, blen(cdefP[p]))
	end
	local round0 = BitDepth == 12 and 5 or 3
	local round1 = BitDepth == 12 and 9 or 11
	for plane = 0, NumPlanes - 1 do
		local rtype = F.FrameRestorationType[plane]
		if rtype ~= 0 then
			local sx = plane > 0 and ssx or 0
			local sy = plane > 0 and ssy or 0
			local U = lrUnits[plane]
			local unitSize = F.LoopRestorationSize[plane]
			local planeEndX = round2(F.UpscaledWidth, sx) - 1
			local planeEndY = round2(F.FrameHeight, sy) - 1
			local stride = pstride[plane]
			local cbuf, dbuf, obuf = cdefP[plane], deb[plane], out[plane]
			local stripeH = 64 // P2[sy + 1]
			local off8 = 8 // P2[sy + 1]
			-- regions: stripes (64 luma rows, offset up by 8) x restoration units
			local y = 0
			while y <= planeEndY do
				local stripeNum = (y * P2[sy + 1] + 8) // 64
				local stripeStart = (-8 + stripeNum * 64) // P2[sy + 1]
				local stripeEnd = stripeStart + stripeH - 1
				local yEnd = min(stripeEnd, planeEndY)
				local unitRow = min(U.rows - 1, (y * P2[sy + 1] + 8) // P2[sy + 1] // unitSize)
				local h = yEnd - y + 1
				local x = 0
				while x <= planeEndX do
					local unitCol = min(U.cols - 1, x // unitSize)
					local xEnd = unitCol == U.cols - 1 and planeEndX or min(planeEndX, (unitCol + 1) * unitSize - 1)
					xEnd = min(xEnd, x + 63)
					local w = xEnd - x + 1
					local ui = unitRow * U.cols + unitCol
					local t = U.type[ui] or 0
					local function src(xx, yy)
						if xx > planeEndX then
							xx = planeEndX
						elseif xx < 0 then
							xx = 0
						end
						if yy > planeEndY then
							yy = planeEndY
						elseif yy < 0 then
							yy = 0
						end
						if yy < stripeStart then
							yy = max(stripeStart - 2, yy)
							return readu16(dbuf, (yy * stride + xx) * 2)
						elseif yy > stripeEnd then
							yy = min(stripeEnd + 2, yy)
							return readu16(dbuf, (yy * stride + xx) * 2)
						end
						return readu16(cbuf, (yy * stride + xx) * 2)
					end
					if t == 1 then
						local wf = U.wiener
						local vf, hf = {}, {}
						for pass = 0, 1 do
							local fl = pass == 0 and vf or hf
							fl[3] = 128
							for i = 0, 2 do
								local cf = wf[ui * 6 + pass * 3 + i + 1]
								fl[i] = cf
								fl[6 - i] = cf
								fl[3] -= 2 * cf
							end
						end
						local offset = P2[BitDepth + 7 - round0]
						local limit = P2[BitDepth + 9 - round0] - 1
						local r0d, r0h = P2[round0 + 1], P2[round0]
						for r = 0, h + 5 do
							for c = 0, w - 1 do
								local s = 0
								for tt = 0, 6 do
									s += hf[tt] * src(x + c + tt - 3, y + r - 3)
								end
								local v = (s + r0h) // r0d
								if v < -offset then
									v = -offset
								elseif v > limit - offset then
									v = limit - offset
								end
								INTER[r * 70 + c + 1] = v
							end
						end
						local r1d, r1h = P2[round1 + 1], P2[round1]
						for r = 0, h - 1 do
							for c = 0, w - 1 do
								local s = 0
								for tt = 0, 6 do
									s += vf[tt] * INTER[(r + tt) * 70 + c + 1]
								end
								local v = (s + r1h) // r1d
								if v < 0 then
									v = 0
								elseif v > pixMax then
									v = pixMax
								end
								writeu16(obuf, ((y + r) * stride + x + c) * 2, v)
							end
						end
					elseif t == 2 then
						local set = U.sgrSet[ui]
						for pass = 0, 1 do
							local rr = SgrParams[set * 4 + pass * 2 + 1]
							local flt = pass == 0 and FLT0 or FLT1
							if rr ~= 0 then
								local eps = SgrParams[set * 4 + pass * 2 + 2]
								local n = (2 * rr + 1) * (2 * rr + 1)
								local n2e = n * n * eps
								local s = (1048576 + n2e // 2) // n2e
								local oneOverN = (4096 + n // 2) // n
								for i = -1, h do
									for j = -1, w do
										local a, b = 0, 0
										for dy = -rr, rr do
											for dx = -rr, rr do
												local cv = src(x + j + dx, y + i + dy)
												a += cv * cv
												b += cv
											end
										end
										a = round2(a, 2 * (BitDepth - 8))
										local d = round2(b, BitDepth - 8)
										local p = max(0, a * n - d * d)
										local z = round2(p * s, 20)
										local a2
										if z >= 255 then
											a2 = 256
										elseif z == 0 then
											a2 = 1
										else
											a2 = (z * 256 + z // 2) // (z + 1)
										end
										local b2 = (256 - a2) * b * oneOverN
										BOX_A[(i + 1) * 70 + j + 2] = a2
										BOX_B[(i + 1) * 70 + j + 2] = round2(b2, 12)
									end
								end
								for i = 0, h - 1 do
									local shift = 5
									if pass == 0 and i % 2 == 1 then
										shift = 4
									end
									for j = 0, w - 1 do
										local a, b = 0, 0
										for dy = -1, 1 do
											for dx = -1, 1 do
												local wt
												if pass == 0 then
													if (i + dy) % 2 == 1 then
														wt = dx == 0 and 6 or 5
													else
														wt = 0
													end
												else
													wt = (dx == 0 or dy == 0) and 4 or 3
												end
												if wt ~= 0 then
													local k = (i + dy + 1) * 70 + j + dx + 2
													a += wt * BOX_A[k]
													b += wt * BOX_B[k]
												end
											end
										end
										local v = a * readu16(cbuf, ((y + i) * stride + x + j) * 2) + b
										flt[i * 64 + j + 1] = round2(v, 8 + shift - 4)
									end
								end
							end
						end
						local w0 = U.sgrXqd[ui * 2 + 1]
						local w1 = U.sgrXqd[ui * 2 + 2]
						local w2 = 128 - w0 - w1
						local r0 = SgrParams[set * 4 + 1]
						local r1 = SgrParams[set * 4 + 3]
						for i = 0, h - 1 do
							for j = 0, w - 1 do
								local o = ((y + i) * stride + x + j) * 2
								local u = readu16(cbuf, o) * 16
								local v = w1 * u
								v += r0 ~= 0 and w0 * FLT0[i * 64 + j + 1] or w0 * u
								v += r1 ~= 0 and w2 * FLT1[i * 64 + j + 1] or w2 * u
								local sres = round2(v, 11)
								if sres < 0 then
									sres = 0
								elseif sres > pixMax then
									sres = pixMax
								end
								writeu16(obuf, o, sres)
							end
						end
					end
					x = xEnd + 1
				end
				y = yEnd + 1
				breathe()
			end
		end
	end
	-- the restored planes become the frame's
	scratch.lr = cdefP
	for p = 0, 2 do
		planes[p] = out[p]
		curFrame.planes[p] = out[p]
	end
	scratch.deblocked = nil
end

------------------------------------------------------------------------------------------------------------------------
-- film grain synthesis (applied to the output copy only)

local Gaussian = Tab.Gaussian_Sequence
local grainPlanes = {}

local function applyFilmGrain(fr, w, h, bd, g)
	local subX, subY = fr.ssx, fr.ssy
	local numPlanes = S.NumPlanes
	local rnd = 0
	local function random(bits)
		local r = rnd
		local bit = bxor(r, rshift(r, 1), rshift(r, 3), rshift(r, 12)) % 2
		r = rshift(r, 1) + bit * 32768
		rnd = r
		return rshift(r, 16 - bits) % P2[bits + 1]
	end
	local grainCenter = 128 * P2[bd - 7]
	local grainMin = -grainCenter
	local grainMax = 256 * P2[bd - 7] - 1 - grainCenter
	local function clampG(v)
		if v < grainMin then
			return grainMin
		elseif v > grainMax then
			return grainMax
		end
		return v
	end
	-- white noise and the auto-regressive filter
	local lag = g.ar_coeff_lag
	local shiftG = 12 - bd + g.grain_scale_shift
	local arShift = g.ar_coeff_shift_minus_6 + 6
	local Luma = tcreate(73 * 82, 0)
	rnd = g.grain_seed
	for y = 0, 72 do
		for x = 0, 81 do
			local v = 0
			if g.num_y_points > 0 then
				v = Gaussian[random(11) + 1]
			end
			Luma[y * 82 + x + 1] = round2(v, shiftG)
		end
	end
	if g.num_y_points > 0 then
		for y = 3, 72 do
			for x = 3, 82 - 4 do
				local s, pos = 0, 0
				for dr = -lag, 0 do
					for dc = -lag, lag do
						if dr == 0 and dc == 0 then
							break
						end
						s += Luma[(y + dr) * 82 + x + dc + 1] * (g.ar_coeffs_y[pos] or 0)
						pos += 1
					end
				end
				local k = y * 82 + x + 1
				Luma[k] = clampG(Luma[k] + round2(s, arShift))
			end
		end
	end
	local chromaW = subX == 1 and 44 or 82
	local chromaH = subY == 1 and 38 or 73
	local Cb, Cr = tcreate(chromaW * chromaH, 0), tcreate(chromaW * chromaH, 0)
	if S.mono_chrome == 0 then
		for p = 1, 2 do
			local G = p == 1 and Cb or Cr
			rnd = bxor(g.grain_seed, p == 1 and 0xb524 or 0x49d8)
			local on = (p == 1 and g.num_cb_points or g.num_cr_points) > 0 or g.chroma_scaling_from_luma == 1
			for y = 0, chromaH - 1 do
				for x = 0, chromaW - 1 do
					local v = 0
					if on then
						v = Gaussian[random(11) + 1]
					end
					G[y * chromaW + x + 1] = round2(v, shiftG)
				end
			end
		end
		for y = 3, chromaH - 1 do
			for x = 3, chromaW - 4 do
				local s0, s1, pos = 0, 0, 0
				for dr = -lag, 0 do
					for dc = -lag, lag do
						local c0 = g.ar_coeffs_cb[pos] or 0
						local c1 = g.ar_coeffs_cr[pos] or 0
						if dr == 0 and dc == 0 then
							if g.num_y_points > 0 then
								local luma = 0
								local lumaX = (x - 3) * P2[subX + 1] + 3
								local lumaY = (y - 3) * P2[subY + 1] + 3
								for i = 0, subY do
									for j = 0, subX do
										luma += Luma[(lumaY + i) * 82 + lumaX + j + 1]
									end
								end
								luma = round2(luma, subX + subY)
								s0 += luma * c0
								s1 += luma * c1
							end
							break
						end
						local k = (y + dr) * chromaW + x + dc + 1
						s0 += Cb[k] * c0
						s1 += Cr[k] * c1
						pos += 1
					end
				end
				local k = y * chromaW + x + 1
				Cb[k] = clampG(Cb[k] + round2(s0, arShift))
				Cr[k] = clampG(Cr[k] + round2(s1, arShift))
			end
		end
	end
	-- scaling look-up tables
	local lut = {}
	for plane = 0, numPlanes - 1 do
		local xs, ys, n
		if plane == 0 or g.chroma_scaling_from_luma == 1 then
			xs, ys, n = g.point_y_value, g.point_y_scaling, g.num_y_points
		elseif plane == 1 then
			xs, ys, n = g.point_cb_value, g.point_cb_scaling, g.num_cb_points
		else
			xs, ys, n = g.point_cr_value, g.point_cr_scaling, g.num_cr_points
		end
		local t = tcreate(257, 0)
		if n > 0 then
			for x = 0, xs[0] - 1 do
				t[x + 1] = ys[0]
			end
			for i = 0, n - 2 do
				local deltaY = ys[i + 1] - ys[i]
				local deltaX = xs[i + 1] - xs[i]
				local delta = deltaY * ((65536 + deltaX // 2) // deltaX)
				for x = 0, deltaX - 1 do
					t[xs[i] + x + 1] = ys[i] + (x * delta + 32768) // 65536
				end
			end
			for x = xs[n - 1], 255 do
				t[x + 1] = ys[n - 1]
			end
		end
		lut[plane] = t
	end
	local bdShift = bd - 8
	local function scaleLut(plane, index)
		local t = lut[plane]
		local x = index // P2[bdShift + 1]
		local rem = index - x * P2[bdShift + 1]
		if bd == 8 or x == 255 then
			return t[x + 1]
		end
		local a, b = t[x + 1], t[x + 2]
		return a + round2((b - a) * rem, bdShift)
	end
	-- the output copy
	local outP = {}
	for p = 0, 2 do
		local src = fr.planes[p]
		local b = grainPlanes[p]
		if not b or blen(b) < blen(src) then
			b = bcreate(blen(src))
			grainPlanes[p] = b
		end
		bcopy(b, 0, src, 0, blen(src))
		outP[p] = b
	end
	local minValue, maxLuma, maxChroma
	if g.clip_to_restricted_range == 1 then
		minValue = 16 * P2[bdShift + 1]
		maxLuma = 235 * P2[bdShift + 1]
		maxChroma = S.matrix_coefficients == 0 and maxLuma or 240 * P2[bdShift + 1]
	else
		minValue = 0
		maxLuma = 256 * P2[bdShift + 1] - 1
		maxChroma = maxLuma
	end
	local pixMaxG = P2[bd + 1] - 1
	local scalingShift = g.grain_scaling_minus_8 + 8
	local overlap = g.overlap_flag == 1
	local ys, cs = fr.stride[0], fr.stride[1]
	local Y, U, V = outP[0], outP[1], outP[2]
	local srcY = fr.planes[0]
	-- noise stripes: [plane][i * NW + x + 1]
	local NW = w + 64
	local prev, cur = nil, nil
	local function newStripe()
		return { [0] = tcreate(34 * NW, 0), tcreate(34 * NW, 0), tcreate(34 * NW, 0) }
	end
	local lumaNum = 0
	local nStripes = ((h + 1) // 2 + 15) // 16
	for stripe = 0, nStripes - 1 do
		if not cur then
			cur = newStripe()
		end
		local y = stripe * 16
		rnd = g.grain_seed
		rnd = bxor(rnd, ((lumaNum * 37 + 178) % 256) * 256)
		rnd = bxor(rnd, (lumaNum * 173 + 105) % 256)
		local x = 0
		while x < (w + 1) // 2 do
			local rv = random(8)
			local offsetX = rv // 16
			local offsetY = rv % 16
			for plane = 0, numPlanes - 1 do
				local psx = plane > 0 and subX or 0
				local psy = plane > 0 and subY or 0
				local pox = psx == 1 and 6 + offsetX or 9 + offsetX * 2
				local poy = psy == 1 and 6 + offsetY or 9 + offsetY * 2
				local src = plane == 0 and Luma or (plane == 1 and Cb or Cr)
				local sw = plane == 0 and 82 or chromaW
				local N = cur[plane]
				for i = 0, (34 // P2[psy + 1]) - 1 do
					for j = 0, (34 // P2[psx + 1]) - 1 do
						local gv = src[(poy + i) * sw + pox + j + 1]
						if psx == 0 then
							local k = i * NW + x * 2 + j + 1
							if j < 2 and overlap and x > 0 then
								local old = N[k]
								if j == 0 then
									gv = old * 27 + gv * 17
								else
									gv = old * 17 + gv * 27
								end
								gv = clampG(round2(gv, 5))
							end
							N[k] = gv
						else
							local k = i * NW + x + j + 1
							if j == 0 and overlap and x > 0 then
								gv = clampG(round2(N[k] * 23 + gv * 22, 5))
							end
							N[k] = gv
						end
					end
				end
			end
			x += 16
		end
		-- this stripe's rows: chroma first (it reads the luma before noise)
		for plane = 1, numPlanes - 1 do
			local on = (plane == 1 and g.num_cb_points or g.num_cr_points) > 0 or g.chroma_scaling_from_luma == 1
			if on then
				local P = plane == 1 and U or V
				local N = cur[plane]
				local NP = prev and prev[plane]
				local rows = 32 // P2[subY + 1]
				local mult = plane == 1 and g.cb_mult or g.cr_mult
				local lmult = plane == 1 and g.cb_luma_mult or g.cr_luma_mult
				local offs = plane == 1 and g.cb_offset or g.cr_offset
				for i = 0, rows - 1 do
					local yy = lumaNum * rows + i
					if yy >= (h + subY) // P2[subY + 1] then
						break
					end
					for xx = 0, (w + subX) // P2[subX + 1] - 1 do
						local gv = N[i * NW + xx + 1]
						if subY == 0 then
							if i < 2 and lumaNum > 0 and overlap then
								local old = NP[(i + 32) * NW + xx + 1]
								if i == 0 then
									gv = old * 27 + gv * 17
								else
									gv = old * 17 + gv * 27
								end
								gv = clampG(round2(gv, 5))
							end
						elseif i < 1 and lumaNum > 0 and overlap then
							local old = NP[(i + 16) * NW + xx + 1]
							gv = clampG(round2(old * 23 + gv * 22, 5))
						end
						local lumaX = xx * P2[subX + 1]
						local lumaY = yy * P2[subY + 1]
						local lumaNextX = min(lumaX + 1, w - 1)
						local avgLuma
						if subX == 1 then
							avgLuma = (readu16(srcY, (lumaY * ys + lumaX) * 2) + readu16(srcY, (lumaY * ys + lumaNextX) * 2) + 1) // 2
						else
							avgLuma = readu16(srcY, (lumaY * ys + lumaX) * 2)
						end
						local o = (yy * cs + xx) * 2
						local orig = readu16(P, o)
						local merged
						if g.chroma_scaling_from_luma == 1 then
							merged = avgLuma
						else
							local combined = avgLuma * (lmult - 128) + orig * (mult - 128)
							merged = combined // 64 + (offs - 256) * P2[bdShift + 1]
							if merged < 0 then
								merged = 0
							elseif merged > pixMaxG then
								merged = pixMaxG
							end
						end
						local noise = round2(scaleLut(plane, merged) * gv, scalingShift)
						local v = orig + noise
						if v < minValue then
							v = minValue
						elseif v > maxChroma then
							v = maxChroma
						end
						writeu16(P, o, v)
					end
				end
			end
		end
		if g.num_y_points > 0 then
			local N = cur[0]
			local NP = prev and prev[0]
			for i = 0, 31 do
				local yy = lumaNum * 32 + i
				if yy >= h then
					break
				end
				for xx = 0, w - 1 do
					local gv = N[i * NW + xx + 1]
					if i < 2 and lumaNum > 0 and overlap then
						local old = NP[(i + 32) * NW + xx + 1]
						if i == 0 then
							gv = old * 27 + gv * 17
						else
							gv = old * 17 + gv * 27
						end
						gv = clampG(round2(gv, 5))
					end
					local o = (yy * ys + xx) * 2
					local orig = readu16(Y, o)
					local noise = round2(scaleLut(0, orig) * gv, scalingShift)
					local v = orig + noise
					if v < minValue then
						v = minValue
					elseif v > maxLuma then
						v = maxLuma
					end
					writeu16(Y, o, v)
				end
			end
		end
		prev, cur = cur, prev
		lumaNum += 1
		breathe()
	end
	return outP
end

Post.loopFilterFrame = loopFilterFrame
Post.cdefFrame = cdefFrame
Post.superresFrame = superresFrame
Post.loopRestorationFrame = loopRestorationFrame
Post.applyFilmGrain = applyFilmGrain

return Post
