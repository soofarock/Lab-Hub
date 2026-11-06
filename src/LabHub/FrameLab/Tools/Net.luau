-- FrameLab network: what the server sends to the client that asks for it, so big data doesn't replicate to everyone.
-- The server side (Runtime/Server/Media) makes the remotes in FrameLab.Remotes:
--   Media (RemoteFunction)  Media:InvokeServer(action, ...)   lists, video bytes in ranges, pictures, admin check
--   TV, Spray (RemoteEvent) the tools' requests
--
-- Client use:
--   Net.videos() -> { { name, Width, Height, Seconds, Fps, Bytes, Server }, ... }    (cached a few seconds)
--   Net.images() -> { { name, Width, Height }, ... }
--   local s = Net.openVideo(name)   streams a video's bytes in the background, the part being watched first
--       s.bytes (buffer, filled as chunks arrive), s.info, s.ready(chunkIndex), s.complete, s.failed
--       s.follow(function() -> seconds)   which part to fetch first (the playing position)
--       s.waitFor(seconds, timeout) -> true when the chunk for that time is there      s.close()
--   Net.image(key) -> image table ("lib:<name>" for a library picture, "url:<n>" for one an admin loaded from a URL)
--   Net.isAdmin() -> bool
--   Net.clip(path) -> the bytes of an in-game import's sound (AudioLab clip "video/imported/<name>"), or nil (yields;
--       the clips live in the server's memory, so only a client that plays one downloads it)

local Net = {}
local root = script:FindFirstAncestor("FrameLab")
local RunService = game:GetService("RunService")
local EncodingService = game:GetService("EncodingService")

Net.RANGE = 60 * 1024 -- bytes per request

function Net.remotes(create)
	local folder = root:FindFirstChild("Remotes")
	if not folder then
		if not create then
			folder = root:WaitForChild("Remotes")
		else
			folder = Instance.new("Folder")
			folder.Name = "Remotes"
			local media = Instance.new("RemoteFunction")
			media.Name = "Media"
			media.Parent = folder
			for _, n in ipairs({ "TV", "Spray" }) do
				local e = Instance.new("RemoteEvent")
				e.Name = n
				e.Parent = folder
			end
			folder.Parent = root
		end
	end
	return folder
end

local function invoke(action, ...)
	return Net.remotes(false):WaitForChild("Media"):InvokeServer(action, ...)
end
Net.invoke = invoke

local listCache = {}
local function cachedList(action)
	local c = listCache[action]
	if c and os.clock() - c.t < 5 then
		return c.v
	end
	local ok, v = pcall(invoke, action)
	v = ok and v or {}
	listCache[action] = { t = os.clock(), v = v }
	return v
end
function Net.videos()
	return cachedList("videos")
end
function Net.images()
	return cachedList("images")
end
function Net.forget()
	listCache = {}
end

local adminAnswer
function Net.isAdmin()
	if adminAnswer == nil then
		local ok, v = pcall(invoke, "isAdmin")
		adminAnswer = ok and v == true
	end
	return adminAnswer
end

-- the 1-based chunk byte ranges of an FLV2 video (from its header and directory)
local function flv2Chunks(head)
	local n = buffer.readu16(head, 16)
	local start = 24 + n * 16
	local list = {}
	for i = 1, n do
		local d = 24 + (i - 1) * 16
		local off = buffer.readu32(head, d)
		local size = buffer.readu32(head, d + 4) + buffer.readu32(head, d + 8)
		list[i] = { from = start + off, to = start + off + size, first = buffer.readu32(head, d + 12) }
	end
	return list
end

function Net.openVideo(name)
	local s = { info = nil, bytes = nil, complete = false, failed = nil, closed = false }
	local loaded = {}
	local chunks
	local followFn
	function s.ready(ci)
		if s.complete then
			return true
		end
		return loaded[ci] == true
	end
	function s.follow(fn)
		followFn = fn
	end
	function s.close()
		s.closed = true
	end
	local function fetch(from, to)
		local pos = from
		while pos < to do
			if s.closed then
				return false
			end
			local len = math.min(Net.RANGE, to - pos)
			-- (nil: the server's request budget for this second is used up - a sound downloading alongside - so wait and
			-- ask again; a video failed on the first refusal)
			local ok, part
			for try = 1, 20 do
				ok, part = pcall(invoke, "videoRange", name, pos, len)
				if (ok and typeof(part) == "buffer") or s.closed then
					break
				end
				task.wait(0.25 * try)
			end
			if s.closed then
				return false
			end
			if not ok or typeof(part) ~= "buffer" then
				s.failed = tostring(part)
				return false
			end
			buffer.copy(s.bytes, pos, part, 0, buffer.len(part))
			pos += len
		end
		return true
	end
	task.spawn(function()
		local ok, head
		for try = 1, 10 do
			ok, head = pcall(invoke, "videoHead", name)
			if ok and type(head) == "table" then
				break
			end
			task.wait(0.25 * try)
		end
		if not ok or type(head) ~= "table" then
			s.failed = ok and "no such video" or tostring(head)
			return
		end
		s.info = head.attrs
		s.bytes = buffer.create(head.size)
		buffer.copy(s.bytes, 0, head.head, 0, buffer.len(head.head))
		local headLen = buffer.len(head.head)
		if buffer.readstring(head.head, 0, 4) ~= "FLV2" then
			-- older streams need all their bytes before they play
			if fetch(headLen, head.size) then
				s.complete = true
			end
			return
		end
		chunks = flv2Chunks(head.head)
		s.chunks = chunks
		local fps = buffer.readu8(head.head, 5)
		-- fetch the chunk being watched first, then the ones after it (wrapping), a few ahead
		while not s.closed do
			local want = 1
			if followFn then
				local frame = math.floor(math.max(0, followFn()) * fps)
				for i, c in ipairs(chunks) do
					if c.first <= frame then
						want = i
					end
				end
			end
			local pick
			for k = 0, #chunks - 1 do
				local i = (want - 1 + k) % #chunks + 1
				if not loaded[i] then
					if k <= 3 then
						pick = i
					end
					break
				end
			end
			if pick then
				if fetch(chunks[pick].from, chunks[pick].to) then
					loaded[pick] = true
				else
					return
				end
				local all = true
				for i = 1, #chunks do
					if not loaded[i] then
						all = false
						break
					end
				end
				if all then
					s.complete = true
					return
				end
			else
				task.wait(0.25)
			end
		end
	end)
	function s.waitFor(seconds, timeout)
		local t0 = os.clock()
		while os.clock() - t0 < (timeout or 15) do
			if s.failed then
				return false
			end
			if s.complete then
				return true
			end
			if chunks and s.info then
				local frame = math.floor(math.max(0, seconds) * buffer.readu8(s.bytes, 5))
				local ci = 1
				for i, c in ipairs(chunks) do
					if c.first <= frame then
						ci = i
					end
				end
				if loaded[ci] then
					return true
				end
			end
			task.wait(0.1)
		end
		return false
	end
	return s
end

function Net.clip(path)
	if type(path) ~= "string" or string.sub(path, 1, 15) ~= "video/imported/" then
		return nil
	end
	local ok, head = pcall(invoke, "clipHead", path)
	if not ok or type(head) ~= "table" or type(head.size) ~= "number" then
		return nil
	end
	local size = head.size
	local bytes = buffer.create(size)
	-- four ranges at a time, at most ~20 requests a second (the server allows 30 a second per player, and the video
	-- streams alongside with a few), so a sound arrives close behind its picture
	local nextPos, running, failed = 0, 0, false
	local lastAsk = 0
	local function worker()
		while not failed and nextPos < size do
			local pos = nextPos
			local len = math.min(Net.RANGE, size - pos)
			nextPos += len
			local part
			for _ = 1, 8 do -- (nil: over the request budget this second; try again)
				while os.clock() - lastAsk < 0.05 do
					task.wait()
				end
				lastAsk = os.clock()
				local okR, r = pcall(invoke, "clipRange", path, pos, len)
				if okR and typeof(r) == "buffer" and buffer.len(r) == len then
					part = r
					break
				end
				task.wait(0.5)
			end
			if not part then
				failed = true
				break
			end
			buffer.copy(bytes, pos, part, 0, len)
		end
		running -= 1
	end
	for _ = 1, 4 do
		running += 1
		task.spawn(worker)
	end
	while running > 0 do
		task.wait()
	end
	if failed then
		if require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("Config")).Debug then
			warn("[FrameLab] couldn't download the sound " .. path)
		end
		return nil
	end
	return bytes
end

local imageCache = {}
function Net.image(key)
	local c = imageCache[key]
	if c then
		return c
	end
	local ok, bytes = pcall(invoke, "image", key)
	if not ok or typeof(bytes) ~= "buffer" then
		return nil
	end
	local FrameLab = require(root)
	local img = FrameLab.unpackImage(bytes)
	imageCache[key] = img
	return img
end

return Net
