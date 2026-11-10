-- A FrameLab import worker: Tools.ImportPool puts copies of this script in Actors under ServerScriptService (here, in
-- ReplicatedStorage, it doesn't run). Each one encodes the parts of a video it is sent (Tools.ImportJob) in parallel
-- with the others; and single parts of streams (HLS segments) for Tools.Live.
local actor = script:GetActor()
if not actor then
	return
end
local FrameLab = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("FrameLab")
local ImportJob = require(FrameLab.Tools.ImportJob)
-- (AudioLab's encoder, loaded now: a stream part's sound is encoded in parallel)
local Encoder
pcall(function()
	Encoder = require(game:GetService("ReplicatedStorage").LabHub.AudioLab.Codec.Encoder)
	Encoder.preload()
end)
local EncodingService = game:GetService("EncodingService")

-- (a job's result handed back; when it can't be sent, an error instead, so the job is never waited on forever)
local function answer(reply, id, ok, a, b)
	if ok and pcall(reply.Fire, reply, "done", id, a, b) then
		return
	end
	reply:Fire("error", id, ok and "the result couldn't be handed back" or tostring(a))
end

local files = {}
actor:BindToMessage("file", function(id, bytes)
	files[id] = bytes
end)
actor:BindToMessage("forget", function(id)
	files[id] = nil
end)
actor:BindToMessageParallel("segment", function(id, i, job, reply)
	while not files[id] do
		task.wait()
	end
	job.bytes = files[id]
	-- (a pause every ~25 ms keeps the server's frames short; the work goes on in parallel after it)
	local last = os.clock()
	local function yield()
		if os.clock() - last > 0.025 then
			task.wait()
			last = os.clock()
		end
	end
	local ok, res = pcall(ImportJob.encodeSegment, job, yield, function(framesDone)
		task.synchronize()
		reply:Fire("progress", i, framesDone)
		task.desynchronize()
		last = os.clock()
	end)
	task.synchronize()
	answer(reply, i, ok, res)
end)
-- one HLS segment (a stream's part, Tools.Live)
actor:BindToMessageParallel("ts", function(id, job, reply)
	local last = os.clock()
	local ok, parts, info = pcall(ImportJob.encodeTsSegment, job, function()
		if os.clock() - last > 0.025 then
			task.wait()
			last = os.clock()
		end
	end)
	task.synchronize()
	answer(reply, id, ok, parts, info)
end)
-- one stream part's sound (Tools.Live): an AudioLab clip and the time it starts at
actor:BindToMessageParallel("sound", function(id, job, reply)
	local last = os.clock()
	local ok, clip, start = pcall(ImportJob.tsSound, job.bytes, job.start, function()
		if os.clock() - last > 0.025 then
			task.wait()
			last = os.clock()
		end
	end, Encoder)
	task.synchronize()
	-- (packed without compression in parallel, where EncodingService can't be used: compressed now)
	if ok and clip and bit32.band(buffer.readu8(clip, 21), 1) == 0 then
		pcall(function()
			local head = 24 + buffer.readu8(clip, 7) + 4
			local payload = buffer.create(buffer.len(clip) - head)
			buffer.copy(payload, 0, clip, head)
			local z = EncodingService:CompressBuffer(payload, Enum.CompressionAlgorithm.Zstd, 6)
			local out = buffer.create(head + buffer.len(z))
			buffer.copy(out, 0, clip, 0, head)
			buffer.copy(out, head, z)
			buffer.writeu8(out, 21, bit32.bor(buffer.readu8(out, 21), 1))
			clip = out
		end)
	end
	answer(reply, id, ok, clip, start)
end)
-- one stream part as the block player's picture (Video.BlockStream), handed back piece by piece as they are made
local BlockStream
pcall(function()
	if require(FrameLab.Image.Blocks).ready() then -- (the pattern library, loaded now: the fitting runs in parallel)
		BlockStream = require(FrameLab.Video.BlockStream)
	end
end)
actor:BindToMessageParallel("blocks", function(id, job, reply)
	-- (shorter slices than an import's: a stream plays while this runs, and the server's frames wait on each slice)
	local last = os.clock()
	local ok, err = pcall(function()
		if not BlockStream then
			error("the block pattern library isn't loaded", 0)
		end
		BlockStream.encodeSegment(job, function()
			if os.clock() - last > 0.008 then
				task.wait()
				last = os.clock()
			end
		end, function(kind, a, b)
			task.synchronize()
			reply:Fire("part", id, kind, { a, b })
			task.desynchronize()
			last = os.clock()
		end, ImportJob)
	end)
	task.synchronize()
	answer(reply, id, ok, if ok then true else err)
end)
actor:SetAttribute("Ready", true)
