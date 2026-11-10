-- A FrameLab decode worker: Video.AsyncReader puts a copy of this script in an Actor under the player's PlayerScripts
-- (here it doesn't run). It decodes FLV2 videos ahead of their players in parallel with the game and hands each picture
-- back: the whole picture, or only the bands of 8 rows that changed.
local actor = script:GetActor()
if not actor then
	return
end
local RunService = game:GetService("RunService")
local FrameLab = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("FrameLab")
local Flv2 = require(FrameLab.Video.Flv2)

local BUDGET = 0.012 -- seconds of decoding per frame, all videos together
local videos = {}

actor:BindToMessage("open", function(id, head, reply, opts)
	local v = { chunks = {}, reply = reply, gen = 0, want = -1 }
	v.r = Flv2.reader(head, {
		ChunkData = function(ci)
			local c = v.chunks[ci]
			if c then
				return c.data, 0, c.sizeA, c.sizeB
			end
			return nil
		end,
		Ready = function(ci)
			return v.chunks[ci] ~= nil
		end,
	})
	v.r.FastColour = opts.FastColour == true
	v.r.SkipDroppable = opts.SkipDroppable == true
	videos[id] = v
end)
actor:BindToMessage("chunk", function(id, ci, data, sizeA, sizeB)
	local v = videos[id]
	if v then
		v.chunks[ci] = { data = data, sizeA = sizeA, sizeB = sizeB }
	end
end)
actor:BindToMessage("drop", function(id, ci)
	local v = videos[id]
	if v then
		v.chunks[ci] = nil
	end
end)
actor:BindToMessage("want", function(id, upTo)
	local v = videos[id]
	if v then
		v.want = upTo
	end
end)
actor:BindToMessage("seek", function(id, frame, gen)
	local v = videos[id]
	if v then
		v.seekTo, v.gen = frame, gen
	end
end)
actor:BindToMessage("set", function(id, key, value)
	local v = videos[id]
	if v then
		v.r[key] = value
	end
end)
actor:BindToMessage("close", function(id)
	videos[id] = nil
end)

-- the picture of frame f: whole (a key frame, a slide, after a seek) or the changed bands of 8 rows, with the bands
-- next to them (the colour blend reaches a little past a block)
local function pack(r, f, info, whole)
	local rgba = r.rgba
	if whole or info.key or info.dx ~= 0 or info.dy ~= 0 then
		local d = buffer.create(buffer.len(rgba))
		buffer.copy(d, 0, rgba)
		return { frame = f, info = info, data = d }
	end
	local bw, bh = r.bw, r.bh
	local mark = {}
	for _, b in ipairs(info.blocks) do
		local by = b // bw
		mark[by] = true
		if by > 0 then
			mark[by - 1] = true
		end
		if by + 1 < bh then
			mark[by + 1] = true
		end
	end
	local bands = {}
	for by in pairs(mark) do
		table.insert(bands, by)
	end
	table.sort(bands)
	local rowBytes = r.pw * 32
	local d = buffer.create(#bands * rowBytes)
	for k, by in ipairs(bands) do
		buffer.copy(d, (k - 1) * rowBytes, rgba, by * rowBytes, rowBytes)
	end
	return { frame = f, info = info, data = d, bands = bands }
end

RunService.Heartbeat:ConnectParallel(function()
	local t0 = os.clock()
	local any = false
	for _, v in pairs(videos) do
		local r = v.r
		local out = {}
		if v.seekTo and r:ready(v.seekTo) then
			local f = v.seekTo
			v.seekTo = nil
			local info = r:seek(f)
			r.render()
			table.insert(out, pack(r, f, info, true))
		end
		if not v.seekTo then
			while r.frame < v.want and r.frame + 1 < r.frameCount and r:ready(r.frame + 1) and os.clock() - t0 < BUDGET do
				local info = r:advance()
				r.render()
				table.insert(out, pack(r, r.frame, info, false))
			end
		end
		if #out > 0 then
			v.out = out
			any = true
		end
	end
	if any then
		task.synchronize()
		for id, v in pairs(videos) do
			if v.out then
				v.reply:Fire(id, v.gen, v.out)
				v.out = nil
			end
		end
	end
end)
actor:SetAttribute("Ready", true)
