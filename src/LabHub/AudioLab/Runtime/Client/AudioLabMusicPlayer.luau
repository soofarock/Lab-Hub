-- Started by AudioLab.init() on the client (LabHub.start), run once in its own thread.
return function(AudioLab)
-- AudioLab music player. "Music" in the Labs menu toggles the window:
--   Now playing: title, prev / play-pause / next, loop, time | seek bar | duration, volume.
--                Loop region shown as markers on the seek bar with its times underneath.
--   Visualizer:  spectrum of the real output (AudioAnalyzer) + waveform scope drawn from the live
--                state of every playing voice (frequency and level as actually sent to the players).
--   Channels:    16 strips (meter, M = mute, S = solo), Reset clears all.  (MIDI tracks)
--   Library:     Music / Sound effects tabs, filter box, track rows.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")

local AudioLab = require(game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("AudioLab"))
local Library = AudioLab.Library
local WaveBank = AudioLab.WaveBank

local player = Players.LocalPlayer

-- theme -------------------------------------------------------------------------------------
local C = {
	bg = Color3.fromRGB(22, 25, 32), card = Color3.fromRGB(30, 34, 44), card2 = Color3.fromRGB(36, 41, 53),
	line = Color3.fromRGB(56, 63, 80), text = Color3.fromRGB(228, 233, 244), dim = Color3.fromRGB(128, 138, 160),
	accent = Color3.fromRGB(30, 170, 230), accentDark = Color3.fromRGB(20, 110, 150), loop = Color3.fromRGB(150, 125, 255),
	mute = Color3.fromRGB(235, 90, 90), solo = Color3.fromRGB(255, 205, 80), button = Color3.fromRGB(44, 50, 64),
	hot = Color3.fromRGB(60, 68, 88), scope = Color3.fromRGB(120, 230, 170),
}
local FONT = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
local BOLD = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)
local MONO = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Medium)
local CH_COLOR = {}
for i = 0, 15 do
	CH_COLOR[i] = Color3.fromHSV((i / 16 + 0.55) % 1, 0.55, 1)
end

local function make(class, props, children)
	local inst = Instance.new(class)
	for k, v in pairs(props or {}) do
		inst[k] = v
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	return inst
end
local function corner(r)
	return make("UICorner", { CornerRadius = UDim.new(0, r or 8) })
end
local function stroke(color, t)
	return make("UIStroke", { Color = color or C.line, Thickness = t or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end
local function text(props)
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or C.text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return make("TextLabel", props)
end
local function btn(label, props)
	props = props or {}
	props.Text = label
	props.AutoButtonColor = false
	props.FontFace = props.FontFace or BOLD
	props.TextSize = props.TextSize or 13
	props.TextColor3 = props.TextColor3 or C.text
	local base = props.BackgroundColor3 or C.button
	props.BackgroundColor3 = base
	local radius = props.Radius or 6
	props.Radius = nil
	local b = make("TextButton", props, { corner(radius), stroke(C.line) })
	b:SetAttribute("Base", base)
	b.MouseEnter:Connect(function()
		if not b:GetAttribute("On") then
			b.BackgroundColor3 = C.hot
		end
	end)
	b.MouseLeave:Connect(function()
		if not b:GetAttribute("On") then
			b.BackgroundColor3 = b:GetAttribute("Base")
		end
	end)
	return b
end
local function setOn(b, on, color)
	b:SetAttribute("On", on)
	b.BackgroundColor3 = on and (color or C.accent) or b:GetAttribute("Base")
end
local function fmt(t)
	t = math.max(0, t or 0)
	return string.format("%d:%02d", math.floor(t / 60), math.floor(t % 60))
end

-- window ------------------------------------------------------------------------------------
local gui = make("ScreenGui", { Name = "AudioLabPlayer", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 10, IgnoreGuiInset = false })
local W, H = 560, 660
local window = make("Frame", { Name = "Window", Size = UDim2.fromOffset(W, H), Position = UDim2.new(0.5, -W / 2, 0.5, -H / 2 + 20), BackgroundColor3 = C.bg, Visible = false, Active = true },
	{ corner(14), stroke(C.line, 1.5) })
window.Parent = gui

local header = make("Frame", { Name = "Header", Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, Active = true })
header.Parent = window
text({ Text = "AUDIOLAB", FontFace = BOLD, TextSize = 12, TextColor3 = C.dim, Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -60, 1, 0), Parent = header })
local closeB = btn("X", { Name = "Close", Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, -34, 0, 5), TextSize = 11 })
closeB.Parent = header

-- now playing card
local now = make("Frame", { Name = "NowPlaying", Size = UDim2.new(1, -24, 0, 112), Position = UDim2.fromOffset(12, 34), BackgroundColor3 = C.card }, { corner(10), stroke(C.line) })
now.Parent = window
text({ Text = "NOW PLAYING", FontFace = BOLD, TextSize = 10, TextColor3 = C.accent, Position = UDim2.fromOffset(14, 10), Size = UDim2.fromOffset(90, 14), Parent = now })
local titleL = text({ Name = "Title", Text = "Pick a track", FontFace = BOLD, TextSize = 15, Position = UDim2.fromOffset(100, 8), Size = UDim2.new(1, -114, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd })
titleL.Parent = now
local subL = text({ Name = "Subtitle", Text = "Music and sound effects from AudioLab", TextSize = 11, TextColor3 = C.dim, Position = UDim2.fromOffset(100, 27), Size = UDim2.new(1, -114, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd })
subL.Parent = now

local row = make("Frame", { Name = "Transport", Size = UDim2.new(1, -28, 0, 34), Position = UDim2.fromOffset(14, 48), BackgroundTransparency = 1 })
row.Parent = now
local prevB = btn("\u{25C0}\u{25C0}", { Name = "Prev", Size = UDim2.fromOffset(34, 32), Position = UDim2.fromOffset(0, 1), TextSize = 10 })
local playB = btn("\u{25B6}", { Name = "Play", Size = UDim2.fromOffset(40, 32), Position = UDim2.fromOffset(40, 1), BackgroundColor3 = C.accentDark, TextSize = 14 })
local nextB = btn("\u{25B6}\u{25B6}", { Name = "Next", Size = UDim2.fromOffset(34, 32), Position = UDim2.fromOffset(86, 1), TextSize = 10 })
local loopB = btn("Loop", { Name = "Loop", Size = UDim2.fromOffset(52, 32), Position = UDim2.fromOffset(126, 1), TextSize = 12 })
for _, b in ipairs({ prevB, playB, nextB, loopB }) do
	b.Parent = row
end
local timeL = text({ Name = "Time", Text = "0:00", FontFace = MONO, TextSize = 12, TextColor3 = C.text, Position = UDim2.fromOffset(186, 0), Size = UDim2.fromOffset(38, 34), TextXAlignment = Enum.TextXAlignment.Right })
timeL.Parent = row
local seek = make("Frame", { Name = "Seek", Position = UDim2.fromOffset(232, 0), Size = UDim2.new(1, -232 - 150, 1, 0), BackgroundTransparency = 1, Active = true })
seek.Parent = row
local bar = make("Frame", { Name = "Bar", Size = UDim2.new(1, 0, 0, 6), Position = UDim2.new(0, 0, 0.5, -3), BackgroundColor3 = C.line }, { corner(3) })
bar.Parent = seek
local fill = make("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.accent, BorderSizePixel = 0 }, { corner(3) })
fill.Parent = bar
local loopA = make("Frame", { Name = "LoopStart", Size = UDim2.fromOffset(2, 14), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0.5, 0), BackgroundColor3 = C.loop, BorderSizePixel = 0, Visible = false, ZIndex = 2 })
local loopZ = make("Frame", { Name = "LoopEnd", Size = UDim2.fromOffset(2, 14), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, 0, 0.5, 0), BackgroundColor3 = C.loop, BorderSizePixel = 0, Visible = false, ZIndex = 2 })
loopA.Parent = bar
loopZ.Parent = bar
local knob = make("Frame", { Size = UDim2.fromOffset(14, 14), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0.5, 0), BackgroundColor3 = C.text, ZIndex = 3 }, { corner(7) })
knob.Parent = bar
local durL = text({ Name = "Duration", Text = "0:00", FontFace = MONO, TextSize = 12, TextColor3 = C.dim, Position = UDim2.new(1, -144, 0, 0), Size = UDim2.fromOffset(38, 34) })
durL.Parent = row
text({ Text = "VOL", FontFace = BOLD, TextSize = 10, TextColor3 = C.dim, Position = UDim2.new(1, -100, 0, 0), Size = UDim2.fromOffset(26, 34), Parent = row })
local vol = make("Frame", { Name = "Volume", Position = UDim2.new(1, -72, 0, 0), Size = UDim2.fromOffset(72, 34), BackgroundTransparency = 1, Active = true })
vol.Parent = row
local volBar = make("Frame", { Size = UDim2.new(1, 0, 0, 6), Position = UDim2.new(0, 0, 0.5, -3), BackgroundColor3 = C.line }, { corner(3) })
volBar.Parent = vol
local volFill = make("Frame", { Size = UDim2.new(0.8, 0, 1, 0), BackgroundColor3 = C.text, BorderSizePixel = 0 }, { corner(3) })
volFill.Parent = volBar
local infoL = text({ Name = "Info", Text = "", TextSize = 10, TextColor3 = C.dim, Position = UDim2.fromOffset(14, 86), Size = UDim2.new(1, -28, 0, 16) })
infoL.Parent = now

-- visualizer card
local viz = make("Frame", { Name = "Visualizer", Size = UDim2.new(1, -24, 0, 120), Position = UDim2.fromOffset(12, 154), BackgroundColor3 = C.card, ClipsDescendants = true }, { corner(10), stroke(C.line) })
viz.Parent = window
text({ Text = "OUTPUT", FontFace = BOLD, TextSize = 10, TextColor3 = C.dim, Position = UDim2.fromOffset(12, 6), Size = UDim2.fromOffset(100, 12), Parent = viz })
text({ Text = "spectrum", TextSize = 10, TextColor3 = C.dim, Position = UDim2.new(1, -232, 0, 6), Size = UDim2.fromOffset(220, 12), TextXAlignment = Enum.TextXAlignment.Right, Parent = viz })
local specArea = make("Frame", { Name = "Spectrum", Position = UDim2.fromOffset(12, 22), Size = UDim2.new(1, -24, 1, -30), BackgroundTransparency = 1 })
specArea.Parent = viz
local SPEC_BARS = 56
local specBars = {}
for i = 1, SPEC_BARS do
	local b = make("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new((i - 1) / SPEC_BARS, 1, 1, 0), Size = UDim2.new(1 / SPEC_BARS, -2, 0, 0),
		BackgroundColor3 = Color3.fromHSV(0.55 - 0.25 * i / SPEC_BARS, 0.6, 0.9), BackgroundTransparency = 0.35, BorderSizePixel = 0 })
	b.Parent = specArea
	specBars[i] = { frame = b, level = 0 }
end
-- channels card
local chans = make("Frame", { Name = "Channels", Size = UDim2.new(1, -24, 0, 118), Position = UDim2.fromOffset(12, 282), BackgroundColor3 = C.card }, { corner(10), stroke(C.line) })
chans.Parent = window
text({ Text = "CHANNELS", FontFace = BOLD, TextSize = 10, TextColor3 = C.dim, Position = UDim2.fromOffset(12, 6), Size = UDim2.fromOffset(100, 12), Parent = chans })
local resetB = btn("Reset", { Name = "Reset", Size = UDim2.fromOffset(52, 18), Position = UDim2.new(1, -62, 0, 4), TextSize = 10 })
resetB.Parent = chans
local chanHint = text({ Text = "M = mute  S = solo", TextSize = 10, TextColor3 = C.dim, Position = UDim2.new(1, -190, 0, 6), Size = UDim2.fromOffset(120, 12), TextXAlignment = Enum.TextXAlignment.Right })
chanHint.Parent = chans
local noChans = text({ Text = "Sound clips have no channels", TextSize = 12, TextColor3 = C.dim, Position = UDim2.fromOffset(0, 0), Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Visible = false })
noChans.Parent = chans
local strips = {}
for ch = 0, 15 do
	local x = 12 + ch * ((W - 24 - 24) / 16)
	local wcol = (W - 24 - 24) / 16 - 4
	local strip = make("Frame", { Name = "Ch" .. (ch + 1), Position = UDim2.fromOffset(x, 24), Size = UDim2.fromOffset(wcol, 88), BackgroundTransparency = 1 })
	strip.Parent = chans
	local meter = make("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = C.card2 }, { corner(4) })
	meter.Parent = strip
	local mfill = make("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 2, 1, -2), Size = UDim2.new(1, -4, 0, 0), BackgroundColor3 = CH_COLOR[ch], BorderSizePixel = 0 }, { corner(3) })
	mfill.Parent = meter
	local num = text({ Text = tostring(ch + 1), TextSize = 10, Position = UDim2.fromOffset(0, 45), Size = UDim2.new(1, 0, 0, 12), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.dim })
	num.Parent = strip
	local mB = btn("M", { Name = "Mute", Size = UDim2.new(1, 0, 0, 13), Position = UDim2.fromOffset(0, 59), TextSize = 9, Radius = 3 })
	local sB = btn("S", { Name = "Solo", Size = UDim2.new(1, 0, 0, 13), Position = UDim2.fromOffset(0, 74), TextSize = 9, Radius = 3 })
	mB.Parent = strip
	sB.Parent = strip
	strips[ch] = { strip = strip, meter = meter, fill = mfill, num = num, mute = mB, solo = sB, level = 0 }
end

-- library card
local lib = make("Frame", { Name = "Library", Size = UDim2.new(1, -24, 1, -420), Position = UDim2.fromOffset(12, 408), BackgroundColor3 = C.card }, { corner(10), stroke(C.line) })
lib.Parent = window
local tabMusic = btn("Music", { Name = "TabMusic", Size = UDim2.fromOffset(78, 26), Position = UDim2.fromOffset(12, 10), TextSize = 12 })
local tabSfx = btn("Sound effects", { Name = "TabSfx", Size = UDim2.fromOffset(110, 26), Position = UDim2.fromOffset(96, 10), TextSize = 12 })
local tabImport = btn("Import", { Name = "TabImport", Size = UDim2.fromOffset(70, 26), Position = UDim2.fromOffset(212, 10), TextSize = 12, Visible = false })
tabMusic.Parent = lib
tabSfx.Parent = lib
tabImport.Parent = lib

-- import panel (Studio only: shown when the import server's remotes exist)
local importPanel = make("Frame", { Name = "ImportPanel", Size = UDim2.new(1, -24, 1, -50), Position = UDim2.fromOffset(12, 44), BackgroundTransparency = 1, Visible = false })
importPanel.Parent = lib
local modeMusic = btn("Music  (MIDI + SF2)", { Name = "ModeMusic", Size = UDim2.new(0.5, -4, 0, 24), Position = UDim2.fromOffset(0, 0), TextSize = 11 })
local modeSfx = btn("Sound effect  (WAV / AIFF / MP3 / FLAC / OGG)", { Name = "ModeSfx", Size = UDim2.new(0.5, -4, 0, 24), Position = UDim2.new(0.5, 4, 0, 0), TextSize = 11 })
modeMusic.Parent = importPanel
modeSfx.Parent = importPanel
local function field(name, placeholder, y)
	local box = make("TextBox", {
		Name = name, PlaceholderText = placeholder, Text = "", ClearTextOnFocus = false, FontFace = MONO, TextSize = 11,
		TextColor3 = C.text, PlaceholderColor3 = C.dim, BackgroundColor3 = C.bg, Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, y),
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	}, { corner(6), stroke(C.line), make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }) })
	box.Parent = importPanel
	return box
end
local nameBox = field("NameBox", "Name (optional)", 32)
local urlA = field("UrlA", "MIDI URL  (https://...)", 60)
local urlB = field("UrlB", "SoundFont URL  (optional, .sf2; leave empty for General MIDI)", 88)
local importB = btn("Import", { Name = "ImportButton", Size = UDim2.fromOffset(90, 26), Position = UDim2.new(1, -90, 0, 118), BackgroundColor3 = C.accentDark, TextSize = 12 })
importB.Parent = importPanel
local importHint = text({ Text = "Studio only: the server downloads the files and adds them to the library for this session.", TextSize = 10, TextColor3 = C.dim,
	Position = UDim2.fromOffset(0, 118), Size = UDim2.new(1, -100, 0, 26), TextWrapped = true })
importHint.Parent = importPanel
local importLog = text({ Name = "Log", Text = "", FontFace = MONO, TextSize = 10, TextColor3 = C.dim, Position = UDim2.fromOffset(0, 150), Size = UDim2.new(1, 0, 1, -150),
	TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
importLog.Parent = importPanel
local filterBox = make("TextBox", {
	Name = "Filter", PlaceholderText = "Filter...", Text = "", ClearTextOnFocus = false, FontFace = FONT, TextSize = 12,
	TextColor3 = C.text, PlaceholderColor3 = C.dim, BackgroundColor3 = C.bg, Size = UDim2.fromOffset(170, 26), Position = UDim2.new(1, -182, 0, 10),
	TextXAlignment = Enum.TextXAlignment.Left,
}, { corner(6), stroke(C.line), make("UIPadding", { PaddingLeft = UDim.new(0, 8) }) })
filterBox.Parent = lib
local countL = text({ Name = "Count", Text = "", TextSize = 10, TextColor3 = C.dim, Position = UDim2.fromOffset(16, 42), Size = UDim2.new(1, -32, 0, 14) })
countL.Parent = lib
local list = make("ScrollingFrame", {
	Name = "TrackList", Size = UDim2.new(1, -16, 1, -66), Position = UDim2.fromOffset(8, 60), BackgroundTransparency = 1, BorderSizePixel = 0,
	ScrollBarThickness = 4, ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar, ScrollingDirection = Enum.ScrollingDirection.Y,
}, {
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }),
	-- room for the selected row's outline so it isn't clipped
	make("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3), PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 2) }),
})
list.Parent = lib

gui.Parent = player:WaitForChild("PlayerGui")

-- state -------------------------------------------------------------------------------------
local tracks = Library.list()
local current, currentTrack = nil, nil
local analyzer = nil
local loopOn = true
local volume = 0.8
local muted, soloed = {}, {}
local tab = "midi"
local dragging, dragOffset, seekPreview = nil, Vector2.zero, nil
setOn(loopB, loopOn, C.loop)

local load -- defined below
local rows = {}
local function rebuildList()
	for _, r in ipairs(rows) do
		r:Destroy()
	end
	table.clear(rows)
	local filter = string.lower(filterBox.Text)
	local shown = 0
	for i, t in ipairs(tracks) do
		if t.kind == tab and (filter == "" or string.find(string.lower(t.title), filter, 1, true)) then
			shown += 1
			local r = btn("", { Name = "Track" .. shown, Size = UDim2.new(1, -4, 0, 46), LayoutOrder = i, BackgroundColor3 = C.card2, FontFace = FONT })
			text({ Text = t.title, TextSize = 13, Position = UDim2.fromOffset(14, 7), Size = UDim2.new(1, -28, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, Parent = r })
			local meta = t.kind == "midi" and ("MIDI  \u{00B7}  " .. (t.soundFont and ("SoundFont " .. t.soundFont) or "General MIDI instruments")) or ("Sound clip  \u{00B7}  " .. t.clip)
			text({ Text = meta, FontFace = MONO, TextSize = 10, TextColor3 = C.dim, Position = UDim2.fromOffset(14, 26), Size = UDim2.new(1, -28, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd, Parent = r })
			if currentTrack == t then
				r.UIStroke.Color = C.accent
				r:SetAttribute("Base", C.card2)
			end
			r.Parent = list
			r.Activated:Connect(function()
				load(t, true)
			end)
			table.insert(rows, r)
		end
	end
	local total = 0
	for _, t in ipairs(tracks) do
		if t.kind == tab then
			total += 1
		end
	end
	countL.Text = ("%d shown  \u{00B7}  %d %s"):format(shown, total, tab == "midi" and "music track(s)" or "sound effect(s)")
	setOn(tabMusic, tab == "midi")
	setOn(tabSfx, tab == "clip")
	setOn(tabImport, tab == "import")
	local importing = tab == "import"
	importPanel.Visible = importing
	list.Visible = not importing
	countL.Visible = not importing
	filterBox.Visible = not importing
end

local function refreshStrips()
	local info = current and current.midi and current:channels() or nil
	noChans.Visible = info == nil
	resetB.Visible = info ~= nil
	chanHint.Visible = info ~= nil
	local anySolo = next(soloed) ~= nil
	for ch = 0, 15 do
		local s = strips[ch]
		s.strip.Visible = info ~= nil
		local present = info and info[ch] ~= nil
		setOn(s.mute, muted[ch] == true, C.mute)
		setOn(s.solo, soloed[ch] == true, C.solo)
		s.solo.TextColor3 = soloed[ch] and C.bg or C.text
		local silent = muted[ch] or (anySolo and not soloed[ch])
		s.num.TextColor3 = silent and C.mute or (present and C.text or C.dim)
		s.meter.BackgroundTransparency = present and 0 or 0.6
	end
end

local function attachAnalyzer()
	if analyzer then
		analyzer:Destroy()
		analyzer = nil
	end
	if current then
		analyzer = make("AudioAnalyzer", { Name = "PlayerAnalyzer" })
		analyzer.Parent = current.engine.pool.folder
		make("Wire", { SourceInstance = current.engine.pool.output, TargetInstance = analyzer, Parent = analyzer })
	end
end

local loadTicket = 0
function load(t, autoplay)
	-- every load gets a ticket; only the latest one may become the current track (clicking again while
	-- a track is still loading must not leave the earlier one playing underneath)
	loadTicket += 1
	local ticket = loadTicket
	if current then
		-- switching to a song: the old track winds down gradually (no hitch). Switching to a sound clip: it stops at once, as
		-- the version button does (a gradual destroy leaves hundreds of players running for a while, the audio engine falls
		-- behind and a short sound effect started on top of that came out late and thinned)
		current:destroy(t.kind == "midi")
		current = nil
	end
	currentTrack = t
	table.clear(muted)
	table.clear(soloed)
	titleL.Text = t.title
	subL.Text = t.kind == "midi" and ("MIDI  \u{00B7}  " .. (t.soundFont or "General MIDI instruments")) or ("Sound clip  \u{00B7}  " .. t.clip)
	infoL.Text = "loading..."
	if t.kind ~= tab then
		tab = t.kind
	end
	rebuildList()
	task.spawn(function()
		local ok, c = pcall(Library.open, t, { Parent = SoundService, Volume = volume * (t.kind == "midi" and 1 or 1.2), Loop = loopOn })
		if not ok then
			infoL.Text = "could not load: " .. tostring(c)
			return
		end
		if ticket ~= loadTicket then
			c:destroy(true)
			return
		end
		if current then
			current:destroy(true)
		end
		current = c
		attachAnalyzer()
		refreshStrips()
		c.Ended:Connect(function()
			if current == c and not loopOn then
				local same = {}
				for _, tr in ipairs(tracks) do
					if tr.kind == t.kind then
						table.insert(same, tr)
					end
				end
				for i, tr in ipairs(same) do
					if tr == t then
						load(same[i % #same + 1], true)
						break
					end
				end
			end
		end)
		if autoplay then
			c:play()
		end
	end)
end

local function step(dir)
	local same = {}
	for _, tr in ipairs(tracks) do
		if tr.kind == tab then
			table.insert(same, tr)
		end
	end
	if #same == 0 then
		return
	end
	local idx = 0
	for i, tr in ipairs(same) do
		if tr == currentTrack then
			idx = i
		end
	end
	load(same[(idx - 1 + dir) % #same + 1], true)
end

-- controls ----------------------------------------------------------------------------------
-- versions: one button in the header switches the engine version (the sound set). If a track is loaded it restarts at the
-- same place with the same mute / solo (and keeps playing only if it was playing), so two versions can be compared on the
-- same passage. Add entries to VERSIONS to put more versions on the button.
local AudioLabRoot = game:GetService("ReplicatedStorage"):WaitForChild("LabHub"):WaitForChild("AudioLab")
local VERSIONS = {
	{ name = "Lean", attrs = { Manifest = "Lean" } },
	{ name = "Full", attrs = { Manifest = "Full" } },
}
-- your own atlas, once a pack of it is uploaded (Codec/Manifests/Atlas)
if next(require(AudioLabRoot.Codec.Manifests).Atlas.sounds) then
	table.insert(VERSIONS, { name = "Atlas", attrs = { Manifest = "Atlas" } })
end
-- (the old comparison versions only with the AudioLab folder's Debug attribute)
if AudioLabRoot:GetAttribute("Debug") == true then
	table.insert(VERSIONS, { name = "Lean, rough off (old)", attrs = { Manifest = "Lean", NoRough = true } })
	table.insert(VERSIONS, { name = "Full, rough off (old)", attrs = { Manifest = "Full", NoRough = true } })
end
local versionIdx = 1
for i, ver in ipairs(VERSIONS) do
	if ver.attrs.Manifest == AudioLabRoot:GetAttribute("Manifest") and (ver.attrs.NoRough == true) == (AudioLabRoot:GetAttribute("NoRough") == true) then
		versionIdx = i
		break
	end
end
local versionB = btn("", { Name = "Version", Size = UDim2.fromOffset(170, 24), Position = UDim2.new(1, -34 - 170 - 8, 0, 5), TextSize = 11 })
versionB.Parent = header
local function applyVersion()
	local ver = VERSIONS[versionIdx]
	local keys = {}
	for _, other in ipairs(VERSIONS) do
		for k in pairs(other.attrs) do
			keys[k] = true
		end
	end
	for k in pairs(keys) do
		AudioLabRoot:SetAttribute(k, ver.attrs[k])
	end
	versionB.Text = "Version: " .. ver.name
	setOn(versionB, versionIdx ~= 1, C.accentDark)
end
applyVersion()
versionB.Activated:Connect(function()
	versionIdx = versionIdx % #VERSIONS + 1
	applyVersion()
	local t = currentTrack
	if not t then
		return
	end
	local at = current and current:getTime() or 0
	local wasPlaying = current and current:isPlaying() or false
	local keepMuted, keepSolo = table.clone(muted), table.clone(soloed)
	-- stop the old version completely first: a gradual destroy leaves hundreds of its players running for ~20 s, and with
	-- the new version starting on top of them the audio engine falls behind (audio blocks arrive in clumps)
	if current then
		current:destroy(false)
		current = nil
		if analyzer then
			analyzer:Destroy()
			analyzer = nil
		end
	end
	load(t, false)
	task.spawn(function()
		local ticket = loadTicket
		local waited = 0
		while current == nil and loadTicket == ticket and waited < 15 do
			task.wait(0.1)
			waited += 0.1
		end
		if current == nil or loadTicket ~= ticket then
			return
		end
		for ch in pairs(keepMuted) do
			muted[ch] = true
			current:setMute(ch, true)
		end
		for ch in pairs(keepSolo) do
			soloed[ch] = true
			current:setSolo(ch, true)
		end
		refreshStrips()
		if at > 0.5 then
			current:seek(at)
		end
		if wasPlaying then
			current:play(at)
		end
	end)
end)

playB.Activated:Connect(function()
	if not current then
		if currentTrack then
			load(currentTrack, true)
		else
			step(1)
		end
		return
	end
	if current:isPlaying() then
		current:pause()
	else
		current:resume()
	end
end)
prevB.Activated:Connect(function()
	if current and current:getTime() > 3 then
		current:seek(0)
		if not current:isPlaying() then
			current:play(0)
		end
	else
		step(-1)
	end
end)
nextB.Activated:Connect(function()
	step(1)
end)
loopB.Activated:Connect(function()
	loopOn = not loopOn
	setOn(loopB, loopOn, C.loop)
	if current then
		current:setLoop(loopOn)
	end
end)
tabMusic.Activated:Connect(function()
	tab = "midi"
	rebuildList()
end)
tabSfx.Activated:Connect(function()
	tab = "clip"
	rebuildList()
end)
filterBox:GetPropertyChangedSignal("Text"):Connect(rebuildList)
resetB.Activated:Connect(function()
	for ch = 0, 15 do
		if current then
			current:setMute(ch, false)
			current:setSolo(ch, false)
		end
	end
	table.clear(muted)
	table.clear(soloed)
	refreshStrips()
end)
for ch = 0, 15 do
	local s = strips[ch]
	s.mute.Activated:Connect(function()
		muted[ch] = (not muted[ch]) or nil
		if current then
			current:setMute(ch, muted[ch] == true)
		end
		refreshStrips()
	end)
	s.solo.Activated:Connect(function()
		soloed[ch] = (not soloed[ch]) or nil
		if current then
			current:setSolo(ch, soloed[ch] == true)
		end
		refreshStrips()
	end)
end

local function fraction(frame, x)
	return math.clamp((x - frame.AbsolutePosition.X) / math.max(frame.AbsoluteSize.X, 1), 0, 1)
end
local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end
seek.InputBegan:Connect(function(input)
	if isPress(input) then
		dragging = "seek"
		seekPreview = fraction(bar, input.Position.X)
	end
end)
vol.InputBegan:Connect(function(input)
	if isPress(input) then
		dragging = "volume"
		volume = fraction(volBar, input.Position.X)
		if current then
			current:setVolume(volume * (current.midi and 1 or 1.2))
		end
	end
end)
header.InputBegan:Connect(function(input)
	if isPress(input) then
		dragging = "window"
		dragOffset = Vector2.new(input.Position.X, input.Position.Y) - window.AbsolutePosition
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if not dragging or (input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch) then
		return
	end
	if dragging == "seek" then
		seekPreview = fraction(bar, input.Position.X)
	elseif dragging == "volume" then
		volume = fraction(volBar, input.Position.X)
		if current then
			current:setVolume(volume * (current.midi and 1 or 1.2))
		end
	elseif dragging == "window" then
		local p = Vector2.new(input.Position.X, input.Position.Y) - dragOffset
		window.Position = UDim2.fromOffset(p.X, p.Y)
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if not isPress(input) then
		return
	end
	if dragging == "seek" and current and seekPreview then
		local t = seekPreview * current:getDuration()
		local wasPlaying = current:isPlaying()
		current:seek(t)
		if not wasPlaying and not current:isPaused() then
			current:play(t)
		end
	end
	dragging, seekPreview = nil, nil
end)

-- visuals -----------------------------------------------------------------------------------
local BIN_HZ = 48000 / 1024
local function specBin(i)
	-- log-spaced bands from 40 Hz to 12 kHz
	local f0 = 40 * (12000 / 40) ^ ((i - 1) / SPEC_BARS)
	local f1 = 40 * (12000 / 40) ^ (i / SPEC_BARS)
	return math.max(2, math.floor(f0 / BIN_HZ) + 1), math.max(2, math.floor(f1 / BIN_HZ) + 1)
end
local SPEC_RANGES = {}
for i = 1, SPEC_BARS do
	local a, b = specBin(i)
	SPEC_RANGES[i] = { a, math.max(a, b) }
end

RunService.RenderStepped:Connect(function(dt)
	if not window.Visible then
		return
	end
	volFill.Size = UDim2.new(volume, 0, 1, 0)
	if current then
		local duration = current:getDuration()
		local t = seekPreview and seekPreview * duration or current:getTime()
		local frac = duration > 0 and math.clamp(t / duration, 0, 1) or 0
		fill.Size = UDim2.new(frac, 0, 1, 0)
		knob.Position = UDim2.new(frac, 0, 0.5, 0)
		timeL.Text = fmt(t)
		durL.Text = fmt(duration)
		local playing = current:isPlaying()
		playB.Text = playing and "\u{2759}\u{2759}" or "\u{25B6}"
		local hasLoop = current.loopStart and current.loopEnd and duration > 0 and (current.loopStart > 0.01 or current.loopEnd < duration - 0.01)
		loopA.Visible, loopZ.Visible = hasLoop and loopOn, hasLoop and loopOn
		if hasLoop then
			loopA.Position = UDim2.new(current.loopStart / duration, 0, 0.5, 0)
			loopZ.Position = UDim2.new(current.loopEnd / duration, 0, 0.5, 0)
		end
		local state = playing and "Playing" or (current:isPaused() and "Paused" or "Stopped")
		local loopText = loopOn and (hasLoop and ("  \u{00B7}  loops back to %s at %s (purple markers)"):format(fmt(current.loopStart), fmt(current.loopEnd)) or "  \u{00B7}  repeats") or ""
		infoL.Text = state .. loopText
		for ch = 0, 15 do
			local s = strips[ch]
			s.level = math.max(current:activity(ch), s.level - dt * 2.5)
			s.fill.Size = UDim2.new(1, -4, math.clamp(s.level, 0, 1) * 0.94, 0)
		end
	else
		playB.Text = "\u{25B6}"
	end
	-- spectrum
	local spec = analyzer and analyzer:GetSpectrum() or {}
	for i = 1, SPEC_BARS do
		local r = SPEC_RANGES[i]
		local m = 0
		for k = r[1], math.min(r[2], #spec) do
			m = math.max(m, spec[k] or 0)
		end
		local db = 20 * math.log10(math.max(m, 1e-6))
		local target = math.clamp((db + 70) / 70, 0, 1)
		local b = specBars[i]
		b.level = math.max(target, b.level - dt * 1.8)
		b.frame.Size = UDim2.new(1 / SPEC_BARS, -2, b.level, 0)
	end
end)

-- import ------------------------------------------------------------------------------------
local importMode = "music"
local logLines = {}
local function logLine(msg, color)
	table.insert(logLines, msg)
	while #logLines > 4 do -- the log box fits 4 lines: keep the newest visible
		table.remove(logLines, 1)
	end
	importLog.Text = table.concat(logLines, "\n")
	importLog.TextColor3 = color or C.dim
end
local function setImportMode(mode)
	importMode = mode
	setOn(modeMusic, mode == "music")
	setOn(modeSfx, mode == "sfx")
	urlA.PlaceholderText = mode == "music" and "MIDI URL  (https://...)" or "Sound URL  (https://...  .wav / .aif / .mp3 / .flac / .ogg)"
	urlB.Visible = mode == "music"
end
setImportMode("music")
modeMusic.Activated:Connect(function()
	setImportMode("music")
end)
modeSfx.Activated:Connect(function()
	setImportMode("sfx")
end)
tabImport.Activated:Connect(function()
	tab = "import"
	rebuildList()
end)

task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("AudioLabRemotes", 15)
	if not remotes then
		return -- not in Studio (or the import server isn't installed): no import tab
	end
	local requestRemote = remotes:WaitForChild("ImportRequest")
	local statusRemote = remotes:WaitForChild("ImportStatus")
	tabImport.Visible = true
	local nextId = 0
	local busy = false
	importB.Activated:Connect(function()
		if busy then
			return
		end
		local a = string.gsub(urlA.Text, "^%s+", "")
		a = string.gsub(a, "%s+$", "")
		if a == "" then
			logLine("Paste a URL first.", C.solo)
			return
		end
		nextId += 1
		busy = true
		importB.Text = "Importing..."
		local data = { id = tostring(nextId), kind = importMode, name = nameBox.Text }
		if importMode == "music" then
			data.midiUrl = a
			data.soundFontUrl = (string.gsub(urlB.Text, "^%s*(.-)%s*$", "%1"))
		else
			data.url = a
		end
		logLine("Sending to the Studio import server...")
		requestRemote:FireServer(data)
	end)
	statusRemote.OnClientEvent:Connect(function(msg)
		if type(msg) ~= "table" then
			return
		end
		if msg.state == "progress" then
			logLine(msg.message)
		elseif msg.state == "error" then
			busy = false
			importB.Text = "Import"
			logLine("Failed: " .. tostring(msg.message), C.mute)
		elseif msg.state == "done" then
			busy = false
			importB.Text = "Import"
			logLine(msg.message, C.scope)
			-- wait for the new data to replicate, then refresh and select it
			local t0 = os.clock()
			local found
			repeat
				task.wait(0.2)
				tracks = Library.list()
				for _, tr in ipairs(tracks) do
					if tr.id == msg.track.id then
						found = tr
					end
				end
			until found or os.clock() - t0 > 8
			if found then
				tab = found.kind
				load(found, true)
			else
				logLine("Imported, but it hasn't appeared yet; reopen the tab in a moment.", C.solo)
			end
		end
	end)
end)

rebuildList()
refreshStrips()

-- the Labs menu ------------------------------------------------------------------------------
local LabHub = require(ReplicatedStorage:WaitForChild("LabHub"))
local hub = LabHub.add({ id = "music", label = "Music", order = 1, toggle = window })
closeB.Activated:Connect(function()
	hub.close()
end)

end
