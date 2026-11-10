-- FrameLab settings, kept as attributes on the FrameLab folder (like AudioLab's): change them in Studio's Properties
-- panel, or from a server script with FrameLab:SetAttribute(name, value). Anything not set uses the default below.
-- Read them with Config.<name> (live). Admins: UserIds separated by commas ("123,456"); the place owner (or rank 254+
-- in the owning group) is always an admin.
local root = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("FrameLab") -- (this module lives under LabHub)

local DEFAULTS = {
	-- testing aids: import timings and progress in the output, each TV's live numbers as attributes on its SurfaceGui
	-- (Fps, WorkMs, Objects, ShownTime...), and the FrameLab viewer panel (the "FrameLab" button). Off: none of it.
	Debug = false,
	Admins = "",
	-- who gets the tools: "everyone", "admins", "owner", "list" (ToolAccessList) or "nobody" (Runtime/Server/ToolAccess)
	TVToolAccess = "everyone",
	SprayToolAccess = "everyone",
	ToolAccessList = "", -- UserIds or names, comma-separated (for "list")

	-- synced screens (TVs and any tagged "FrameLab" screen)
	ViewDistance = 120, -- clients play a screen only within this distance
	MaxPlaying = 2, -- most screens a client plays at once (the nearest)
	-- video a client keeps in memory, all its screens together (MB): the part ahead of the playhead streams in while
	-- it plays, and what has played is dropped first
	VideoCacheMB = 6,
	-- the size a client plays when a video was imported at two sizes (360p imports keep a 180p copy, 240p a 144p one):
	-- "auto" (the smaller one: redrawing the larger one's GUI objects keeps the game's frames long), "high" (the larger
	-- one; a client whose screen falls behind still steps down) or "low"
	VideoRendition = "auto",
	-- streams (HLS addresses): "auto" (each client decodes the H.264 itself on worker threads, and goes back to the
	-- server's converted copy if it falls behind), "client" or "server" (always the converted copy)
	VideoDecode = "auto",
	-- a jump on a playing TV: its playhead waits at the new spot until the picture is there, at most this long (seconds)
	SeekHold = 8,
	-- stream mode (the TV's Stream switch): the tallest MP4 / MOV / WebM it streams (lines on the short side; the server
	-- converts it as it plays, and computers decode it themselves). A taller one is imported whole instead, shrunk to fit
	StreamMaxSourceLines = 400,
	ControlPerSecond = 8, -- client control requests per player per second

	-- TV tool
	TVScale = 5, -- a set-down TV's size (the Classic PC Hat is about 1.8 studs wide; 3 = about 5.3 studs)
	
	RampImage = "rbxassetid://91938615950048",
	-- the pattern library for block pictures (Render/Patterns, Image/Blocks): 4096 + 4096 small patterns in one image
	PatternImage = "rbxassetid://106064072488154",
	-- the Labs button's picture (assets/images/labhub_icon.png uploaded as an Image); "": just the word Labs
	HubIcon = "rbxassetid://75362948591820",
	
	-- Spray Paint tool
	SprayRange = 14,
	SprayCooldown = 1.5,
	SprayMaxPerPlayer = 10, -- the oldest goes when a player sprays more
	SprayLifetime = 300, -- seconds (0 = until the player leaves)
	SprayViewDistance = 150,
	SprayMaxRendered = 24, -- most picture sprays a client draws at once (the nearest)
	SprayPictureSize = 96, -- longest side (pixels) a picture spray is drawn at (L and XL more: 16 pixels a stud, up to 192)
	SprayOriginalSize = 512, -- O sprays: longest side kept (smaller pictures stay at their own size)
	SprayOriginalPieces = 9000, -- O sprays: most GUI objects one may take (past it: a little softer, then smaller)
	SprayDetailDistance = 40, -- full detail within this many studs (more for big sprays); a cheap drawing further away
	SprayPerformanceMode = "auto", -- "auto" (on for phones), "on" or "off": fewer sprays, fewer objects each
	SprayPhonePieces = 3500, -- performance mode: most GUI objects an O spray takes up close
	SprayPhoneMaxRendered = 8, -- performance mode: most sprays drawn at once
	UrlMaxBytes = 4194304, -- largest file an admin can load from a URL
	-- pictures from the web (spray URL pictures, picture imports) only from these sites when ImageWhitelistEnabled:
	-- comma-separated host names; a name also allows its subdomains ("imgur.com" allows i.imgur.com), "*." is the same
	ImageWhitelistEnabled = false,
	ImageWhitelist = "imgur.com, upload.wikimedia.org, cdn.discordapp.com, media.discordapp.net",
	-- and never from these when ImageBlacklistEnabled (same form; checked first, so it wins over the whitelist)
	ImageBlacklistEnabled = false,
	ImageBlacklist = "",
	UrlPictureSize = 512, -- longest side kept from a URL picture (O sprays draw up to 512)

	-- in-game imports (admins: Import in the TV picker and in Spray Paint; kept while the server runs)
	ImportMaxBytes = 26214400, -- largest file downloaded (25 MB)
	ImportMaxSeconds = 300, -- longest video kept (and what the YouTube helper downloads)
	-- MP4 / MOV sources up to this many lines (1080 = 1080p), shrunk to ImportVideoQuality as they are read; a 1080p
	-- source takes several times longer to import than a 360p one
	ImportMaxVideoLines = 1080,
	-- in a running game an MP4 / MOV import is split over this many parallel workers (Actors), each encoding a part
	ImportWorkers = 4,
	-- an HLS address (.m3u8) imported in game plays as a stream: the server converts only the parts being watched, up
	-- to this many seconds of it
	StreamMaxSeconds = 7200,
	-- the size imported videos are kept at: "144p" (256x144, 60 KB/s: light enough for phones) or "240p" (426x240,
	-- 120 KB/s: sharper, about 3x the drawing and data). Admins can also pick it per import in the TV picker.
	ImportVideoQuality = "144p",
	ImportMaxPicture = 512, -- longest side of an imported picture (O sprays draw up to 512)
	-- data manager: keep a record (URL + 64x64 thumbnail) of each import in a DataStore, so later servers list them
	-- (Load imports one again). Off by default; admins can switch it on in the data manager for a server.
	LibraryDataStore = false,
	-- YouTube links: the VideoLab YouTube helper (yt-dlp on your computer or a server) downloads and shrinks them
	YouTubeHelper = "http://localhost:8787", -- its address (Studio reaches localhost; live servers need a public https one)
	YouTubeHelperKey = "", -- the helper's VIDEOLAB_KEY, if it has one

	-- data requests
	RequestsPerSecond = 30,
	CachedEntries = 6,
}

local Config = {}
Config.Defaults = DEFAULTS

local function setting(key)
	local v = root:GetAttribute(key)
	if v == nil then
		v = DEFAULTS[key]
	end
	return v
end

-- does host match a list ("a.com, b.org": each also covers its subdomains)? -> matched, the names
local function hostIn(host, list)
	local names = {}
	local hit = false
	for name in string.gmatch(string.lower(type(list) == "string" and list or ""), "[^,%s]+") do
		name = string.gsub(name, "^%*%.", "")
		table.insert(names, name)
		if host == name or string.sub(host, -(#name + 1)) == "." .. name then
			hit = true
		end
	end
	return hit, names
end

-- may a picture be fetched from this URL? -> true, or false and why
-- (ImageBlacklistEnabled / ImageBlacklist first, then ImageWhitelistEnabled / ImageWhitelist)
function Config.imageUrlAllowed(url)
	local host = string.lower(string.match(tostring(url), "^https?://([^/:?#]+)") or "")
	if setting("ImageBlacklistEnabled") == true then
		local hit = hostIn(host, setting("ImageBlacklist"))
		if hit then
			return false, ("pictures from %s aren't allowed"):format(host)
		end
	end
	if setting("ImageWhitelistEnabled") == true then
		local hit, names = hostIn(host, setting("ImageWhitelist"))
		if not hit then
			return false, ("pictures can only come from: %s"):format(#names > 0 and table.concat(names, ", ") or "(no sites listed)")
		end
	end
	return true
end

-- UserIds from the Admins attribute (entries that are names are left out; see Config.listed)
function Config.admins()
	local list = {}
	for e in string.gmatch(tostring(root:GetAttribute("Admins") or ""), "[^,%s]+") do
		if string.match(e, "^%d+$") then
			table.insert(list, tonumber(e))
		end
	end
	return list
end

-- is this player on a people list (Admins, ToolAccessList)? Entries are UserIds or usernames (any case)
function Config.listed(player, key)
	local name = string.lower(player.Name)
	for e in string.gmatch(tostring(setting(key) or ""), "[^,%s]+") do
		if tonumber(e) == player.UserId or string.lower(e) == name then
			return true
		end
	end
	return false
end

-- Studio: put every setting on the FrameLab folder (missing ones get their default) so they show in Properties
function Config.writeDefaults()
	for k, v in pairs(DEFAULTS) do
		if root:GetAttribute(k) == nil then
			root:SetAttribute(k, v)
		end
	end
end

return setmetatable(Config, {
	__index = function(_, key)
		local v = root:GetAttribute(key)
		if v ~= nil then
			return v
		end
		return DEFAULTS[key]
	end,
})
