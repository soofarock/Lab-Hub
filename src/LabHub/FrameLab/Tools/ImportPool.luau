-- FrameLab import workers: encodes the parts of a video (Tools.ImportJob) on Actors, several at once (Parallel Luau),
-- on a running server. Each worker is a copy of Tools.ImportWorker in an Actor under ServerScriptService.
--   ImportPool.available() -> true on a running server (Studio's edit mode and clients encode in one piece)
--   ImportPool.run(bytes, jobs, workers, onProgress) -> results[i] = the parts of jobs[i] (ImportJob.encodeSegment);
--       bytes is the MP4, sent to each worker once; onProgress(framesDone) as they come in; a worker's error is raised
--   ImportPool.submit(job, workers, kind, onPart) -> parts, info   one HLS segment (ImportJob.encodeTsSegment) on the
--       next free worker; yields until it is done (nil, message when it failed). kind "sound": a stream part's sound
--       instead (job = { bytes, start }: ImportJob.tsSound -> clip, start); kind "blocks": its block picture
--       (Video.BlockStream.encodeSegment), handed over as it is made: onPart(kind, a, b) for each of its emits
local ImportPool = {}

local RunService = game:GetService("RunService")
local FrameLab = script:FindFirstAncestor("FrameLab")

local actors = {}
local fileId = 0

function ImportPool.available()
	return RunService:IsServer() and RunService:IsRunning() and FrameLab.Tools:FindFirstChild("ImportWorker") ~= nil
end

local function ensureActors(n)
	local sss = game:GetService("ServerScriptService")
	local folder = sss:FindFirstChild("FrameLabImportWorkers")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "FrameLabImportWorkers"
		folder.Parent = sss
	end
	while #actors < n do
		local a = Instance.new("Actor")
		a.Name = "Worker" .. (#actors + 1)
		local s = FrameLab.Tools.ImportWorker:Clone()
		s.Enabled = true
		s.Parent = a
		a.Parent = folder
		table.insert(actors, a)
	end
	-- (each worker says when its messages are bound)
	local t0 = os.clock()
	for i = 1, n do
		while not actors[i]:GetAttribute("Ready") do
			if os.clock() - t0 > 15 then
				return false
			end
			task.wait()
		end
	end
	return true
end

function ImportPool.run(bytes, jobs, workers, onProgress)
	workers = math.clamp(math.min(workers, #jobs), 1, 16)
	if not ensureActors(workers) then
		return nil, "the import workers didn't start"
	end
	fileId += 1
	local id = fileId
	local reply = Instance.new("BindableEvent")
	local results, failed = {}, nil
	local done, nextJob, running = {}, 1, 0
	local jobActor = {}
	local function dispatch(a)
		if failed or nextJob > #jobs then
			return
		end
		local i = nextJob
		nextJob += 1
		jobActor[i] = a
		running += 1
		a:SendMessage("segment", id, i, jobs[i], reply)
	end
	reply.Event:Connect(function(kind, i, value)
		if kind == "progress" then
			done[i] = value
			if onProgress then
				local total = 0
				for _, d in pairs(done) do
					total += d
				end
				onProgress(total)
			end
		elseif kind == "done" then
			results[i] = value
			done[i] = jobs[i].k1 - jobs[i].k0
			running -= 1
			dispatch(jobActor[i])
		elseif kind == "error" then
			failed = failed or value
			running -= 1
		end
	end)
	for k = 1, workers do
		actors[k]:SendMessage("file", id, bytes)
	end
	for k = 1, workers do
		dispatch(actors[k])
	end
	while running > 0 do
		task.wait(0.1)
	end
	for k = 1, workers do
		actors[k]:SendMessage("forget", id)
	end
	reply:Destroy()
	if failed then
		error(failed, 0)
	end
	return results
end

-- single jobs (HLS segments): one at a time on each worker, the rest wait for a free one
local submitReply, pending, nextJobId, free = nil, {}, 0, nil
function ImportPool.submit(job, workers, kind, onPart)
	workers = math.clamp(workers or 4, 1, 16)
	if not ensureActors(workers) then
		return nil, "the import workers didn't start"
	end
	if not submitReply then
		submitReply = Instance.new("BindableEvent")
		free = {}
		for i = 1, workers do
			table.insert(free, actors[i])
		end
		submitReply.Event:Connect(function(kind, id, a, b)
			local p = pending[id]
			if p and kind == "part" then
				-- (a piece of the work, as it is made)
				if p.onPart then
					task.spawn(p.onPart, a, b and b[1], b and b[2])
				end
			elseif p then
				pending[id] = nil
				table.insert(free, p.actor)
				p.result = { kind, a, b }
			end
		end)
	end
	while #free == 0 do
		task.wait(0.05)
	end
	local actor = table.remove(free, 1)
	nextJobId += 1
	local id = nextJobId
	local p = { actor = actor, onPart = onPart }
	pending[id] = p
	actor:SendMessage(kind or "ts", id, job, submitReply)
	while not p.result do
		task.wait(0.05)
	end
	if p.result[1] ~= "done" then
		return nil, tostring(p.result[2])
	end
	return p.result[2], p.result[3]
end

return ImportPool
