-- Chunk walker for RIFF (little-endian: WAV, SF2) and IFF/FORM (big-endian: AIFF).
-- A chunk is {id = "fmt ", size = n, body = ByteReader, listType = "pdta"?, children = {...}?}
-- LIST chunks (RIFF) are expanded one level into .children with .listType set.

local AudioLab = script:FindFirstAncestor("AudioLab")
local ByteReader = require(AudioLab.Util.ByteReader)

local Iff = {}

local MAX_CHUNKS = 100000

-- Walk chunks in reader until its end. A final chunk whose declared size runs past
-- the end is clamped (common in files written by tools that never patch sizes).
function Iff.readChunks(reader, bigEndian, expandLists)
	local chunks = {}
	while reader:remaining() >= 8 do
		local id = reader:str(4)
		local size = bigEndian and reader:u32be() or reader:u32()
		local available = reader:remaining()
		local truncated = false
		if size > available then
			size = available
			truncated = true
		end
		local chunk = { id = id, size = size, body = reader:sub(size), truncated = truncated }
		if size % 2 == 1 and reader:remaining() > 0 then
			reader:skip(1) -- pad byte
		end
		if expandLists and id == "LIST" and size >= 4 then
			local inner = ByteReader.new(chunk.body.buf, chunk.body.base, chunk.body:size())
			chunk.listType = inner:str(4)
			chunk.children = Iff.readChunks(inner, bigEndian, false)
		end
		table.insert(chunks, chunk)
		if #chunks > MAX_CHUNKS then
			error("too many chunks; file is likely corrupt")
		end
	end
	return chunks
end

-- Open a top-level container. Returns (formType, chunks, reader).
-- RIFF: magic "RIFF" little-endian. IFF: magic "FORM" big-endian.
function Iff.open(source)
	local r = ByteReader.new(source)
	if r:size() < 12 then
		error("file too small to be a RIFF/IFF container")
	end
	local magic = r:str(4)
	local bigEndian
	if magic == "RIFF" then
		bigEndian = false
	elseif magic == "FORM" then
		bigEndian = true
	else
		error(("expected RIFF or FORM container, found %q"):format(magic))
	end
	local size = bigEndian and r:u32be() or r:u32()
	local form = r:str(4)
	local bodySize = math.min(math.max(size - 4, 0), r:remaining())
	local body = r:sub(bodySize)
	return form, Iff.readChunks(body, bigEndian, not bigEndian), bigEndian
end

function Iff.find(chunks, id)
	for _, c in ipairs(chunks) do
		if c.id == id then
			return c
		end
	end
	return nil
end

function Iff.findList(chunks, listType)
	for _, c in ipairs(chunks) do
		if c.id == "LIST" and c.listType == listType then
			return c
		end
	end
	return nil
end

-- Fresh reader over a chunk body (so callers can re-read without shared cursors).
function Iff.reader(chunk)
	return ByteReader.new(chunk.body.buf, chunk.body.base, chunk.body:size())
end

return Iff
