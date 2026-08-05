-- Two loader instances booting at once -- a double-tapped execute, or re-executing while
-- the first run is still holding on the ROBLOX loading screen -- would stack two identical
-- consoles and run every prompt and download twice (the hidden one's questions then time
-- out to their fallbacks and replay after the visible one closes). Later executions bail
-- while a boot is live; the timestamp goes stale after 180s so a boot that hard-crashed
-- can't lock the session out of ever injecting again.
if shared.UnrealLoaderBoot and os.clock() - shared.UnrealLoaderBoot < 180 then
	warn('[Unreal] loader is already running, ignoring duplicate execution')
	return
end
shared.UnrealLoaderBoot = os.clock()

local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local cloneref = cloneref or function(ref)
	return ref
end
local delfile = delfile or function(file)
	writefile(file, '')
end
-- Named differently across executors, and absent on a few. Left nil when nothing is available;
-- the one call site pcalls it and reports whether the copy actually happened.
local setclipboard = setclipboard or toclipboard or (Clipboard and Clipboard.set)

local Watermark = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.'

local function downloadFile(path, func)
	if not isfile(path) then
		-- bedwars.lua only exists in the GitLab repo (kept separate/obfuscated there), at that
		-- repo's ROOT even though it caches locally under games/; everything else lives in the
		-- GitHub repo.
		local relPath = select(1, path:gsub('Unreal/', ''))
		local isBedwars = relPath == 'games/bedwars.lua'
		-- Retried a few times: raw file hosts intermittently fail, returning an empty body that
		-- would otherwise get cached as a corrupt/empty file.
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				if isBedwars then
					return game:HttpGet('https://raw.githubusercontent.com/woahwave/Unreal/main/bedwars.lua', true)
				end
				return game:HttpGet('https://raw.githubusercontent.com/woahwave/Unreal/main/'..relPath, true)
			end)
			-- For .lua files, a compile check too: an outage can hand back the 503/error page
			-- as the body, and caching that would poison the install silently (cache-first
			-- means it would never be refetched).
			if suc and res and res ~= '' and res ~= '404: Not Found' and (not path:find('.lua') or loadstring(res) ~= nil) then
				content = res
				break
			end
			if attempt < 4 then
				task.wait(attempt)
			end
		end
		if not content then
			error('failed to download '..path..' after 4 attempts')
		end
		if path:find('.lua') then
			content = Watermark..'\n'..content
		end
		writefile(path, content)
	end
	return (func or readfile)(path)
end

-- Fetches the GitHub profiles folder listing; returns the decoded {name=,path=,type=} array, or nil on failure.
-- Pass a commit sha as `ref` to get the listing exactly as of that commit instead of branch head.
local function fetchProfilesListing(ref)
	local reqSuc, res = pcall(function()
		return game:HttpGet('https://api.github.com/repos/woahwave/Unreal/contents/profiles'..(ref and ('?ref='..ref) or ''), true)
	end)
	if not (reqSuc and res and res ~= '404: Not Found') then return nil end
	local bodySuc, body = pcall(function()
		return cloneref(game:GetService('HttpService')):JSONDecode(res)
	end)
	if not (bodySuc and body and typeof(body) == 'table') then return nil end
	return body
end

-- <GameId>.gui.txt is not a config -- it is the GUI's state file, and alongside the theme and
-- window layout it stores `Profile` (which config is equipped) and `Profiles` (the list the
-- Profiles tab shows, including ones the user made). Overwriting it wholesale during a sync
-- therefore deleted every custom profile from the list and snapped the equipped config back to
-- whatever the repo shipped. Merged instead: the repo supplies the theme/layout, the local file
-- keeps those two fields, so only the shipped configs are ever actually replaced.
local function mergeGuiState(path, incoming)
	if not path:find('%.gui%.txt$') then return incoming end
	local ok, merged = pcall(function()
		local httpService = cloneref(game:GetService('HttpService'))
		local new = httpService:JSONDecode(incoming)
		if type(new) ~= 'table' then return incoming end
		if isfile(path) then
			local old = httpService:JSONDecode(readfile(path))
			if type(old) == 'table' then
				if old.Profiles ~= nil then new.Profiles = old.Profiles end
				if old.Profile ~= nil then new.Profile = old.Profile end
			end
		end
		return httpService:JSONEncode(new)
	end)
	-- unparseable on either side: fall back to writing exactly what the host sent
	return (ok and type(merged) == 'string') and merged or incoming
end

-- Downloads every file in a profiles listing concurrently. When `commit` is given, files are
-- fetched pinned to that exact commit sha and overwritten unconditionally -- branch-path raw
-- URLs can serve CDN-cached content for up to ~5 minutes after a push, which would make a
-- "sync" quietly reinstall the old profiles. `onProgress(done, total)` is optional and only
-- feeds the console line.
local function downloadProfilesListing(body, commit, onProgress)
	local files = {}
	for _, v in body do
		if v.type == 'file' then
			table.insert(files, v)
		end
	end
	local completed, pending, total = 0, #files, #files
	local done = Instance.new('BindableEvent')
	for _, v in files do
		local relPath = ({v.path:gsub(' ', '%%20')})[1]
		task.spawn(function()
			if commit then
				pcall(function()
					for attempt = 1, 4 do
						local suc, res = pcall(function()
							return game:HttpGet('https://raw.githubusercontent.com/woahwave/Unreal/'..commit..'/'..relPath, true)
						end)
						if suc and res and res ~= '' and res ~= '404: Not Found' then
							writefile('Unreal/'..relPath, mergeGuiState('Unreal/'..relPath, res))
							break
						end
						if attempt < 4 then
							task.wait(attempt)
						end
					end
				end)
			else
				pcall(downloadFile, 'Unreal/'..relPath)
			end
			completed += 1
			pending -= 1
			if onProgress then
				onProgress(completed, total)
			end
			if pending <= 0 then
				done:Fire()
			end
		end)
	end
	if pending > 0 then
		done.Event:Wait()
	end
	done:Destroy()
end

-- Returns the sha of the most recent commit that touched profiles/ on GitHub, or nil on failure.
local function fetchProfilesCommit()
	local reqSuc, res = pcall(function()
		return game:HttpGet('https://api.github.com/repos/woahwave/Unreal/commits?path=profiles&sha=main&per_page=1', true)
	end)
	if not (reqSuc and res and res ~= '404: Not Found') then return nil end
	local bodySuc, body = pcall(function()
		return cloneref(game:GetService('HttpService')):JSONDecode(res)
	end)
	if not (bodySuc and body and typeof(body) == 'table' and body[1] and body[1].sha) then return nil end
	return body[1].sha
end

-- Keeps every cached .lua file current against the GitHub repo, using git blob shas.
-- One trees API call returns the content sha of EVERY file in the repo, so this costs two
-- API requests per session no matter how many files exist (a per-file commits lookup would
-- be one request each and die on GitHub's 60/hour unauthenticated limit).
-- Unreal/filecheck.json remembers the sha each cached file was last downloaded at; any
-- mismatch is re-downloaded pinned to the head commit (branch raw URLs can serve stale CDN
-- content for a few minutes after a push, commit-pinned ones cannot). Files whose watermark
-- line was removed are developer-owned and never touched -- exactly what the watermark has
-- always promised. bedwars.lua lives on GitLab, not in this tree, and keeps its own
-- bedwarscheck.txt system.
local function updateCachedFiles(onProgress)
	local httpService = cloneref(game:GetService('HttpService'))

	local headSuc, headSha = pcall(function()
		return httpService:JSONDecode(game:HttpGet('https://api.github.com/repos/woahwave/Unreal/commits?sha=main&per_page=1', true))[1].sha
	end)
	if not (headSuc and type(headSha) == 'string') then return end

	local treeSuc, tree = pcall(function()
		return httpService:JSONDecode(game:HttpGet('https://api.github.com/repos/woahwave/Unreal/git/trees/'..headSha..'?recursive=1', true))
	end)
	if not (treeSuc and type(tree) == 'table' and type(tree.tree) == 'table') then return end

	local manifest = {}
	pcall(function()
		if isfile('Unreal/filecheck.json') then
			local decoded = httpService:JSONDecode(readfile('Unreal/filecheck.json'))
			if type(decoded) == 'table' then
				manifest = decoded
			end
		end
	end)

	local remote = {}
	for _, v in tree.tree do
		if v.type == 'blob' and v.path:sub(-4) == '.lua' then
			remote[v.path] = v.sha
		end
	end

	-- Only files already cached get refreshed here -- everything else keeps downloading on
	-- demand, and is picked up by this pass on the session after it first appears.
	local toUpdate = {}
	for path, sha in remote do
		local localPath = 'Unreal/'..path
		if manifest[path] ~= sha and isfile(localPath) and readfile(localPath):sub(1, #Watermark) == Watermark then
			table.insert(toUpdate, path)
		end
	end

	local changed = false

	-- Files deleted from the repo: drop the cached copy too, so a removed gui/game can't keep
	-- loading from cache forever. Skipped if GitHub reports the tree listing as incomplete,
	-- since a missing entry would be indistinguishable from a deleted file.
	if not tree.truncated then
		for path in manifest do
			if not remote[path] then
				pcall(function()
					local localPath = 'Unreal/'..path
					if isfile(localPath) and readfile(localPath):sub(1, #Watermark) == Watermark then
						delfile(localPath)
					end
				end)
				manifest[path] = nil
				changed = true
			end
		end
	end

	local completed, pending, total = 0, #toUpdate, #toUpdate
	if total > 0 then
		local done = Instance.new('BindableEvent')
		for _, path in toUpdate do
			task.spawn(function()
				for attempt = 1, 4 do
					local suc, res = pcall(function()
						return game:HttpGet('https://raw.githubusercontent.com/woahwave/Unreal/'..headSha..'/'..select(1, path:gsub(' ', '%%20')), true)
					end)
					-- compile check: never overwrite a working cached file with an error page
					if suc and res and res ~= '' and res ~= '404: Not Found' and loadstring(res) ~= nil then
						pcall(writefile, 'Unreal/'..path, Watermark..'\n'..res)
						manifest[path] = remote[path]
						changed = true
						break
					end
					if attempt < 4 then
						task.wait(attempt)
					end
				end
				completed += 1
				pending -= 1
				if onProgress then
					onProgress(completed, total)
				end
				if pending <= 0 then
					done:Fire()
				end
			end)
		end
		if pending > 0 then
			done.Event:Wait()
		end
		done:Destroy()
	end

	if changed then
		pcall(writefile, 'Unreal/filecheck.json', httpService:JSONEncode(manifest))
	end
end

--[[
	Loader console
	--------------
	A fake terminal window that stands in for the executor console while Unreal boots.
	The piston face is drawn one row at a time as the boot progresses, so the art is only
	ever complete at the same moment the status flips to '> DONE'.
]]

local PistonFace = {
	'******=============******++++++=============******',
	'******=============******++++++=============******',
	'******=============******++++++=============******',
	'++++++=============++++++===================++++++',
	'++++++=============++++++===================++++++',
	'++++++=============++++++===================++++++',
	'::::::@@@@@@       ------::::::@@@@@@       ::::::',
	'::::::@@@@@@       ------::::::@@@@@@       ::::::',
	'::::::@@@@@@       ------::::::@@@@@@       ::::::',
	'::::::@@@@@@       ++++++------@@@@@@       ::::::',
	'::::::@@@@@@       ++++++------@@@@@@       ::::::',
	'::::::@@@@@@       ++++++------@@@@@@       ::::::',
	'::::::######:::::::++++++======******:::::::::::::',
	'::::::++++++=======++++++++++++=============::::::',
	'::::::++++++=======++++++++++++=============::::::',
	'::::::++++++=======++++++++++++=============::::::',
	'------++++++                         =======------',
	'------++++++                         =======------',
	'------++++++                         =======------',
	'::::::=============      ++++++++++++=======::::::',
	'::::::=============      ++++++++++++=======::::::',
	'::::::=============      ++++++++++++=======::::::',
	'::::::------:::::::------::::::------:::::::::::::',
	'::::::------:::::::------::::::------:::::::::::::',
	'::::::------:::::::------::::::------:::::::::::::'
}

-- Every offset below is authored against the base window and scaled as a whole by the
-- UIScale, so the layout can't drift apart on other resolutions.
local WindowWidth = 1000
local TitleBarHeight = 44
local ContentPadding = 26
-- Rows are packed slightly tighter than the glyph size so the 25-row face stays a sane
-- height. Text is never clipped by its own frame in Roblox, so the 2px per row overlaps
-- harmlessly.
local AsciiTextSize = 20
local AsciiLineHeight = 18

-- The rows under the art are positioned off the art itself, so a taller or shorter face
-- pushes them (and the bottom of the window) down instead of colliding with them.
local AsciiTop = TitleBarHeight + 16
local StatusY = AsciiTop + #PistonFace * AsciiLineHeight + 16
local LineY = StatusY + 32
local AnswersY = LineY + 30
local WindowHeight = AnswersY + 34 + 30 + 22 + 16

local Palette = {
	Window = Color3.fromRGB(10, 10, 10),
	TitleBar = Color3.fromRGB(38, 38, 38),
	Border = Color3.fromRGB(52, 52, 52),
	Title = Color3.fromRGB(232, 232, 232),
	Glyph = Color3.fromRGB(190, 190, 190),
	Accent = Color3.fromRGB(240, 122, 31),
	Line = Color3.fromRGB(237, 237, 237),
	Footer = Color3.fromRGB(110, 110, 110),
	ButtonIdle = Color3.fromRGB(200, 200, 200),
	ButtonBorder = Color3.fromRGB(60, 60, 60),
	Error = Color3.fromRGB(225, 80, 70)
}

-- Ascii shading: the art is one colour in a real terminal, but the piston only reads as a
-- face if the solid blocks sit brighter than the dithered background, so each glyph class
-- gets its own tone.
local AsciiShades = {
	['@'] = '#F2F2F2',
	['#'] = '#E4E4E4',
	['%'] = '#D2D2D2',
	['*'] = '#A6A6A6',
	['+'] = '#8C8C8C',
	['='] = '#6B6B6B',
	['-'] = '#5C5C5C',
	[':'] = '#4A4A4A',
	['.'] = '#4A4A4A'
}

-- Cancelling the loader has to leave nothing behind that THIS boot created, so on a fresh
-- install the whole folder is wiped. On an install that already existed before this run the
-- wipe is skipped entirely -- the folder holds the user's custom profiles, and cancelling a
-- reinject must never cost them those; only an explicit reinstall (reinstall.lua) deletes an
-- existing install. delfolder already recurses on the executors that have it; the manual walk
-- is for the ones that only ship delfile.
local freshInstall = false
local function deleteInstall()
	-- every cancel/abort path comes through here, so a cancelled boot immediately frees the
	-- duplicate-execution guard for the next manual run
	shared.UnrealLoaderBoot = nil
	if not freshInstall then return end
	pcall(function()
		if delfolder then
			delfolder('Unreal')
			return
		end
		local function purge(folder)
			for _, path in listfiles(folder) do
				if isfolder(path) then
					purge(path)
				elseif delfile then
					delfile(path)
				end
			end
		end
		purge('Unreal')
	end)
end

local function asciiRichText(line)
	local out = {}
	local runColor, runStart = nil, 1
	local function flush(stop)
		if stop < runStart then return end
		local chunk = line:sub(runStart, stop)
		table.insert(out, runColor and ('<font color="'..runColor..'">'..chunk..'</font>') or chunk)
	end
	for i = 1, #line do
		local color = AsciiShades[line:sub(i, i)]
		if i > 1 and color ~= runColor then
			flush(i - 1)
			runStart = i
		end
		runColor = color
	end
	flush(#line)
	return table.concat(out)
end

local function createConsole()
	local tweenService = cloneref(game:GetService('TweenService'))
	local inputService = cloneref(game:GetService('UserInputService'))
	local playersService = cloneref(game:GetService('Players'))

	local screen = Instance.new('ScreenGui')
	screen.Name = 'UnrealLoader'
	screen.DisplayOrder = 999999999
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	local parented = pcall(function()
		screen.Parent = (gethui and gethui()) or cloneref(game:GetService('CoreGui'))
	end)
	if not parented then
		pcall(function()
			screen.Parent = playersService.LocalPlayer:FindFirstChildOfClass('PlayerGui')
		end)
	end

	local window = Instance.new('Frame')
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.5, 0.5)
	window.Size = UDim2.fromOffset(WindowWidth, WindowHeight)
	window.BackgroundColor3 = Palette.Window
	window.BorderSizePixel = 0
	-- so minimising can roll the console up behind its own titlebar
	window.ClipsDescendants = true
	window.Parent = screen
	local windowCorner = Instance.new('UICorner')
	windowCorner.CornerRadius = UDim.new(0, 10)
	windowCorner.Parent = window
	local windowStroke = Instance.new('UIStroke')
	windowStroke.Color = Palette.Border
	windowStroke.Thickness = 1
	windowStroke.Parent = window

	-- One UIScale drives the whole window, so the console keeps its proportions from a phone up
	-- to a 4K monitor: full size at 1080p, shrunk to fit anything smaller.
	local uiscale = Instance.new('UIScale')
	uiscale.Parent = window
	local camera = workspace.CurrentCamera

	-- Window state, the way a desktop WM handles it: minimise rolls the window up into its own
	-- titlebar (there is no taskbar to minimise *to* here, so shading is the recoverable
	-- equivalent) and maximise fills the viewport, both toggling back on a second click.
	local minimized, maximized = false, false
	local restorePosition = window.Position

	local function applyWindowState(animate)
		local viewport = camera and camera.ViewportSize or Vector2.new(WindowWidth, WindowHeight)
		-- Sizes are pre-UIScale, so divide by the scale to land on the viewport once scaled.
		local width = maximized and (viewport.X / uiscale.Scale) or WindowWidth
		local height = maximized and (viewport.Y / uiscale.Scale) or WindowHeight
		local size = UDim2.fromOffset(width, minimized and TitleBarHeight or height)
		local position = maximized and UDim2.fromScale(0.5, 0.5) or restorePosition
		if animate then
			tweenService:Create(window, TweenInfo.new(0.16, Enum.EasingStyle.Quad), {Size = size, Position = position}):Play()
		else
			window.Size, window.Position = size, position
		end
	end

	local function applyScale()
		local viewport = camera and camera.ViewportSize or Vector2.new(WindowWidth, WindowHeight)
		if viewport.X <= 0 or viewport.Y <= 0 then return end
		local fit = math.min(viewport.X * 0.94 / WindowWidth, viewport.Y * 0.92 / WindowHeight)
		uiscale.Scale = math.clamp(math.min(fit, viewport.Y / 1080), 0.25, 1.4)
		-- a maximised window has to keep tracking the viewport it is filling
		applyWindowState(false)
	end
	applyScale()
	if camera then
		camera:GetPropertyChangedSignal('ViewportSize'):Connect(applyScale)
	end

	local titlebar = Instance.new('Frame')
	titlebar.Size = UDim2.new(1, 0, 0, TitleBarHeight)
	titlebar.BackgroundColor3 = Palette.TitleBar
	titlebar.BorderSizePixel = 0
	titlebar.Parent = window
	local titlebarCorner = Instance.new('UICorner')
	titlebarCorner.CornerRadius = UDim.new(0, 10)
	titlebarCorner.Parent = titlebar
	-- Squares off the bottom two corners the UICorner above rounded.
	local titlebarFill = Instance.new('Frame')
	titlebarFill.Position = UDim2.new(0, 0, 1, -10)
	titlebarFill.Size = UDim2.new(1, 0, 0, 10)
	titlebarFill.BackgroundColor3 = Palette.TitleBar
	titlebarFill.BorderSizePixel = 0
	titlebarFill.Parent = titlebar

	local icon = Instance.new('TextLabel')
	icon.Position = UDim2.fromOffset(10, 10)
	icon.Size = UDim2.fromOffset(24, 24)
	icon.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
	icon.BorderSizePixel = 0
	icon.Text = '>_'
	icon.TextColor3 = Palette.Accent
	icon.TextSize = 13
	icon.Font = Enum.Font.Code
	icon.Parent = titlebar
	local iconCorner = Instance.new('UICorner')
	iconCorner.CornerRadius = UDim.new(0, 5)
	iconCorner.Parent = icon

	local title = Instance.new('TextLabel')
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -220, 1, 0)
	title.Position = UDim2.fromOffset(110, 0)
	title.Text = './Unreal-loader'
	title.TextColor3 = Palette.Title
	title.TextSize = 18
	title.Font = Enum.Font.Code
	title.Parent = titlebar

	local closed, aborted = false, false
	local function destroy()
		if closed then return end
		closed = true
		pcall(function() screen:Destroy() end)
	end

	-- Closing the window by hand is a cancel, not a dismissal: the boot stops at the next
	-- checkpoint, and on a first install everything the run wrote is deleted so a half-finished
	-- install can't be left behind (and no config gets silently picked for you). On an existing
	-- install deleteInstall refuses to wipe, so cancelling a reinject just stops the boot.
	local function cancel()
		if aborted then return end
		aborted = true
		destroy()
		deleteInstall()
	end

	-- Chrome glyphs are drawn from thin rotated bars rather than typed: Roblox's Code font has
	-- no chevron glyphs, and a literal 'v'/'^' reads as text sitting next to the title instead
	-- of as window controls.
	local function drawGlyph(parent, kind)
		local bars = {}
		local function bar(length, x, y, rotation)
			local piece = Instance.new('Frame')
			piece.AnchorPoint = Vector2.new(0.5, 0.5)
			piece.Position = UDim2.fromOffset(x, y)
			piece.Size = UDim2.fromOffset(length, 2)
			piece.BackgroundColor3 = Palette.Glyph
			piece.BorderSizePixel = 0
			piece.Rotation = rotation
			piece.Parent = parent
			local corner = Instance.new('UICorner')
			corner.CornerRadius = UDim.new(0, 1)
			corner.Parent = piece
			table.insert(bars, piece)
		end
		-- Arms meet at the centre of the 34x34 button: a chevron is two 10px bars at +-45
		-- degrees, the close is the same two bars crossed.
		if kind == 'minimize' then
			bar(10, 13.5, 17, 45)
			bar(10, 20.5, 17, -45)
		elseif kind == 'maximize' then
			bar(10, 13.5, 17, -45)
			bar(10, 20.5, 17, 45)
		else
			bar(15, 17, 17, 45)
			bar(15, 17, 17, -45)
		end
		return bars
	end

	for index, kind in {'minimize', 'maximize', 'close'} do
		local button = Instance.new('TextButton')
		button.AnchorPoint = Vector2.new(1, 0.5)
		button.Position = UDim2.new(1, -14 - (3 - index) * 38, 0.5, 0)
		button.Size = UDim2.fromOffset(34, 34)
		button.BackgroundColor3 = Color3.new(1, 1, 1)
		button.BackgroundTransparency = 1
		button.AutoButtonColor = false
		button.Modal = true
		button.Text = ''
		button.Parent = titlebar
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = button

		local bars = drawGlyph(button, kind)
		button.MouseEnter:Connect(function()
			button.BackgroundTransparency = 0.9
			for _, piece in bars do
				piece.BackgroundColor3 = kind == 'close' and Palette.Error or Color3.new(1, 1, 1)
			end
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 1
			for _, piece in bars do
				piece.BackgroundColor3 = Palette.Glyph
			end
		end)

		button.MouseButton1Click:Connect(function()
			if kind == 'close' then
				cancel()
			elseif kind == 'minimize' then
				minimized = not minimized
				applyWindowState(true)
			else
				-- maximising an already rolled-up window unrolls it, as a WM would
				maximized = not maximized
				minimized = false
				applyWindowState(true)
			end
		end)
	end

	-- Drag by the titlebar. Offsets live in screen space (the UIScale only rescales children),
	-- so the delta can be applied straight to the window position.
	local dragging, dragStart, dragOrigin
	titlebar.InputBegan:Connect(function(input)
		-- a maximised window is pinned to the viewport; unmaximise it to move it
		if maximized then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, dragOrigin = true, input.Position, window.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	inputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			window.Position = UDim2.new(dragOrigin.X.Scale, dragOrigin.X.Offset + delta.X, dragOrigin.Y.Scale, dragOrigin.Y.Offset + delta.Y)
			-- so unmaximising and unminimising both come back to where it was left
			restorePosition = window.Position
		end
	end)

	local ascii = Instance.new('Frame')
	ascii.BackgroundTransparency = 1
	ascii.Position = UDim2.fromOffset(ContentPadding, AsciiTop)
	ascii.Size = UDim2.fromOffset(WindowWidth - ContentPadding * 2, #PistonFace * AsciiLineHeight)
	ascii.Parent = window

	local rows = {}
	for index, line in PistonFace do
		local label = Instance.new('TextLabel')
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(0, (index - 1) * AsciiLineHeight)
		label.Size = UDim2.new(1, 0, 0, AsciiLineHeight)
		label.RichText = true
		label.Text = asciiRichText(line)
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextSize = AsciiTextSize
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTransparency = 1
		label.Font = Enum.Font.Code
		label.Visible = false
		label.Parent = ascii
		rows[index] = label
	end

	local status = Instance.new('TextLabel')
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromOffset(ContentPadding, StatusY)
	status.Size = UDim2.new(1, -ContentPadding * 2, 0, 28)
	status.RichText = true
	status.TextColor3 = Palette.Line
	status.TextSize = 22
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Font = Enum.Font.Code
	status.Parent = window

	local line = Instance.new('TextLabel')
	line.BackgroundTransparency = 1
	line.Position = UDim2.fromOffset(ContentPadding, LineY)
	line.Size = UDim2.new(1, -ContentPadding * 2, 0, 24)
	line.Text = ''
	line.TextColor3 = Palette.Line
	line.TextSize = 17
	line.TextXAlignment = Enum.TextXAlignment.Left
	line.Font = Enum.Font.Code
	line.Parent = window

	-- Answer buttons sit on the row directly under the question and are reused for every
	-- prompt, so answering one question simply rewrites the line above them.
	local answers = Instance.new('Frame')
	answers.BackgroundTransparency = 1
	answers.Position = UDim2.fromOffset(ContentPadding, AnswersY)
	answers.Size = UDim2.new(1, -ContentPadding * 2, 0, 34)
	answers.Visible = false
	answers.Parent = window
	local answersLayout = Instance.new('UIListLayout')
	answersLayout.SortOrder = Enum.SortOrder.LayoutOrder
	answersLayout.FillDirection = Enum.FillDirection.Horizontal
	answersLayout.Padding = UDim.new(0, 12)
	answersLayout.Parent = answers

	-- Explains what the hovered answer actually does. It rides in the same list layout as the
	-- buttons (LayoutOrder puts it last, after however many there are) so it lands on their row
	-- with the same gap between, and a hidden child takes no space -- the row closes up around
	-- it while nothing is hovered. Ask() only clears TextButtons, so this survives each question.
	local tooltip = Instance.new('TextLabel')
	tooltip.Name = 'Tooltip'
	tooltip.LayoutOrder = 999
	tooltip.AutomaticSize = Enum.AutomaticSize.X
	tooltip.Size = UDim2.fromOffset(0, 34)
	tooltip.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	tooltip.BorderSizePixel = 0
	tooltip.Visible = false
	tooltip.Text = ''
	tooltip.TextColor3 = Palette.Line
	tooltip.TextSize = 15
	tooltip.Font = Enum.Font.Code
	tooltip.Parent = answers
	local tooltipPadding = Instance.new('UIPadding')
	tooltipPadding.PaddingLeft = UDim.new(0, 12)
	tooltipPadding.PaddingRight = UDim.new(0, 12)
	tooltipPadding.Parent = tooltip
	local tooltipCorner = Instance.new('UICorner')
	tooltipCorner.CornerRadius = UDim.new(0, 4)
	tooltipCorner.Parent = tooltip
	local tooltipStroke = Instance.new('UIStroke')
	tooltipStroke.Color = Palette.ButtonBorder
	tooltipStroke.Thickness = 1
	tooltipStroke.Parent = tooltip

	local footer = Instance.new('TextLabel')
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.BackgroundTransparency = 1
	footer.Position = UDim2.new(0, ContentPadding, 1, -16)
	footer.Size = UDim2.new(1, -ContentPadding * 2, 0, 22)
	-- Touch-only devices have no ctrl key, so point them at the titlebar button instead.
	footer.Text = (inputService.TouchEnabled and not inputService.KeyboardEnabled) and 'Tap [x] to exit' or 'Press [CTRL+C] to exit'
	footer.TextColor3 = Palette.Footer
	footer.TextSize = 17
	footer.TextXAlignment = Enum.TextXAlignment.Left
	footer.Font = Enum.Font.Code
	footer.Parent = window

	inputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.C and inputService:IsKeyDown(Enum.KeyCode.LeftControl) then
			cancel()
		end
	end)

	local revealed, revealTarget = 0, 0
	task.spawn(function()
		while not closed do
			if revealed < revealTarget then
				revealed += 1
				local row = rows[revealed]
				row.Visible = true
				tweenService:Create(row, TweenInfo.new(0.18), {TextTransparency = 0}):Play()
			end
			task.wait(0.07)
		end
	end)

	local console = {}

	function console:SetStatus(text, color)
		status.Text = '<font color="#9E9E9E">&gt;</font> <font color="'..(color or '#F07A1F')..'">'..text..'</font>'
	end

	function console:SetLine(text, color)
		line.Text = text
		line.TextColor3 = color or Palette.Line
	end

	-- alpha is how far through the boot we are; the face is drawn to match, one row at a time.
	-- Clamped upwards only: a late progress report from a background step must never pull rows
	-- back off the face (nothing here ever un-boots).
	function console:SetProgress(alpha)
		local count = math.clamp(math.floor(alpha * #PistonFace + 0.5), 0, #PistonFace)
		revealTarget = math.max(revealTarget, count)
	end

	function console:IsAborted()
		return aborted
	end

	-- Asks a question on the output line, waits for one of the buttons underneath it, then
	-- clears the line again so the next question can take its place. `fallback` is returned if
	-- the loader is closed or the timeout elapses -- a missed click must never hang injection.
	function console:Ask(question, buttons, timeoutSeconds, fallback)
		if closed then return fallback end
		self:SetLine(question)
		for _, child in answers:GetChildren() do
			if child:IsA('TextButton') then
				child:Destroy()
			end
		end

		tooltip.Visible = false

		local choice
		for index, def in buttons do
			local button = Instance.new('TextButton')
			-- keeps the buttons in the order given, ahead of the tooltip that trails them
			button.LayoutOrder = index
			button.Size = UDim2.fromOffset(132, 34)
			button.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
			button.BorderSizePixel = 0
			button.AutoButtonColor = false
			-- Frees the touch cursor so the button is tappable on phones (where input would
			-- otherwise be locked to the game).
			button.Modal = true
			button.Text = def.text
			button.TextColor3 = Palette.ButtonIdle
			button.TextSize = 17
			button.Font = Enum.Font.Code
			button.Parent = answers
			local corner = Instance.new('UICorner')
			corner.CornerRadius = UDim.new(0, 4)
			corner.Parent = button
			local stroke = Instance.new('UIStroke')
			stroke.Color = Palette.ButtonBorder
			stroke.Thickness = 1
			stroke.Parent = button
			button.MouseEnter:Connect(function()
				stroke.Color = Palette.Accent
				button.TextColor3 = Palette.Accent
				if def.tooltip then
					tooltip.Text = def.tooltip
					tooltip.Visible = true
				end
			end)
			button.MouseLeave:Connect(function()
				stroke.Color = Palette.ButtonBorder
				button.TextColor3 = Palette.ButtonIdle
				tooltip.Visible = false
			end)
			button.MouseButton1Click:Connect(function()
				choice = def.key
			end)
		end
		answers.Visible = true

		local timeout = os.clock() + (timeoutSeconds or 60)
		repeat task.wait() until choice ~= nil or closed or os.clock() > timeout
		answers.Visible = false
		for _, child in answers:GetChildren() do
			if child:IsA('TextButton') then
				child:Destroy()
			end
		end
		tooltip.Visible = false
		self:SetLine('')
		if choice == nil then
			return fallback
		end
		return choice
	end

	-- Draws whatever rows are still missing, and only once the face is whole flips the header
	-- to '> DONE' and counts the window out.
	function console:Finish(message, seconds)
		if closed then return end
		self:SetProgress(1)
		local drawn = os.clock() + 2
		repeat task.wait() until revealed >= #PistonFace or closed or os.clock() > drawn
		-- the last row is still fading in when the counter hits the end
		task.wait(0.2)
		if closed then return end
		self:SetStatus('DONE')
		seconds = seconds or 5
		local deadline = os.clock() + seconds
		task.spawn(function()
			while not closed do
				local left = math.max(0, math.ceil(deadline - os.clock()))
				self:SetLine(message..' Loader will close in '..left..'s.')
				if left <= 0 then break end
				task.wait(0.2)
			end
			destroy()
		end)
	end

	function console:Fail(err)
		if closed then return end
		self:SetStatus('FAILED', '#E15046')
		-- Executor errors carry absolute file paths that run off the right edge on a single
		-- line. Nothing is going to be asked at this point, so the output line is allowed to
		-- wrap down through the space the answer row was holding.
		line.TextWrapped = true
		line.TextYAlignment = Enum.TextYAlignment.Top
		line.Size = UDim2.new(1, -ContentPadding * 2, 0, AnswersY + 34 - LineY)
		self:SetLine(err, Palette.Error)
	end

	return console
end

-- Same surface as the console, wired to nothing. Reloads are not user-initiated -- the queued
-- teleport script, the GUI's reinject buttons -- so they run the same boot with no window over
-- the game, and every call site below stays identical instead of guarding each one.
local function createHeadlessConsole()
	local console = {}
	function console:SetStatus() end
	function console:SetLine() end
	function console:SetProgress() end
	function console:Finish() end
	function console:Fail() end
	function console:IsAborted() return false end
	-- unattended, so a question can only answer with whatever the timeout would have picked
	function console:Ask(question, buttons, timeoutSeconds, fallback)
		return fallback
	end
	return console
end

-- shared.vapereload marks a run that something else started rather than a manual execution.
-- Read once here: it is cleared after main.lua has had its look at it (see the bottom of this
-- file), because nothing else clears it and a stale true would hide the console from every
-- later manual execution in the session.
local isReload = shared.vapereload and true or false

local console = isReload and createHeadlessConsole() or createConsole()
console:SetStatus('INJECTING')
console:SetLine('Injecting into ROBLOX...')
console:SetProgress(0.08)

-- Executors known not to run Unreal correctly. Checked before anything is downloaded so
-- the run stops on the console instead of failing somewhere deep in the GUI. identifyexecutor
-- is absent on some executors, hence the pcall -- an unknown name is allowed through.
do
	local unsupported = {'xeno', 'solara'}
	local executorName = ''
	pcall(function()
		executorName = identifyexecutor and identifyexecutor() or ''
	end)
	local lowered = tostring(executorName):lower()
	for _, name in unsupported do
		if lowered:find(name, 1, true) then
			local message = 'Unsupported executor ('..tostring(executorName)..'), please look in the #supported-executors channel for more info.'
			console:SetStatus('ERROR', '#E15046')
			console:SetLine(message, Palette.Error)
			warn('[Unreal] '..message)
			-- released so a later execution on a supported executor is not locked out by the
			-- duplicate-boot guard at the top of this file
			shared.UnrealLoaderBoot = nil
			return
		end
	end
end

-- Decided before the folders are created, while 'did this run create the install' is still
-- observable. No yield separates this from the console appearing, so a cancel cannot land
-- in between and read the flag before it is set.
freshInstall = not isfolder('Unreal')
for _, folder in {'Unreal', 'Unreal/games', 'Unreal/profiles', 'Unreal/assets', 'Unreal/libraries', 'Unreal/guis'} do
	if not isfolder(folder) then
		makefolder(folder)
	end
end

-- Step 1: hold here until ROBLOX itself is ready. Everything after this touches game state
-- (or hands off to main.lua, which does), so the shared.Vape* flags the injecting loadstring
-- sets have to be in place and the place has to be loaded before we move on.
do
	local playersService = cloneref(game:GetService('Players'))
	local deadline = os.clock() + 120
	repeat task.wait() until game:IsLoaded() or console:IsAborted() or os.clock() > deadline
	console:SetProgress(0.24)
	repeat task.wait() until playersService.LocalPlayer or console:IsAborted() or os.clock() > deadline
	-- A previous injection still holding shared.vape means the old GUI is mid-teardown;
	-- main.lua uninjects it, so just let the flag settle before reading the rest of them.
	if shared.vape then
		task.wait(0.25)
	end
	console:SetProgress(0.4)
end
if console:IsAborted() then deleteInstall() return end

-- Step 1b: bring every cached .lua file up to date BEFORE any of it runs. Skipped on
-- reloads (the first manual run this session already did it, and reinjects should stay
-- fast) and for developers (running local edits is the whole point of developer mode --
-- and their watermark-stripped files would be skipped anyway).
if not isReload and not shared.UnrealDeveloper then
	console:SetLine('Checking for updates...')
	pcall(updateCachedFiles, function(completed, total)
		console:SetLine('Updating files ('..completed..'/'..total..')...')
		console:SetProgress(0.4 + 0.06 * (completed / math.max(total, 1)))
	end)
	console:SetLine('')
	if console:IsAborted() then deleteInstall() return end
end
console:SetProgress(0.46)

-- Detect the very first run (empty/near-empty profiles folder) BEFORE downloading, so we
-- know afterwards whether to show the prompts below.
local firstRunProfiles = false
pcall(function()
	firstRunProfiles = #listfiles('Unreal/profiles') < 3
end)

-- profilecheck.txt persists a prior 'No' answer, so the download prompt only asks once --
-- without it, a user who declines would get nagged again on every reinject (the profiles
-- folder stays under 3 files forever if nothing gets downloaded).
local declinedDownload = false
pcall(function()
	if isfile('Unreal/profiles/profilecheck.txt') then
		declinedDownload = readfile('Unreal/profiles/profilecheck.txt') == 'false'
	end
end)

-- Step 2: offer the shipped configs.
local wantsDownload = true
if firstRunProfiles and not declinedDownload then
	console:SetProgress(0.47)
	local ok, res = pcall(function()
		return console:Ask('Would you like to download the latest config?', {
			{text = 'Yes', key = true, tooltip = 'Downloads the Blatant and Legit configs from GitHub'},
			{text = 'No', key = false, tooltip = 'Starts on default settings and stops asking on future runs'}
		}, 60, true)
	end)
	-- checked before the answer is acted on, so cancelling mid-question never counts as a 'No'
	if console:IsAborted() then deleteInstall() return end
	wantsDownload = ok and res == true
	if not wantsDownload then
		pcall(function() writefile('Unreal/profiles/profilecheck.txt', 'false') end)
	end
end
console:SetProgress(0.53)

local downloadedConfigs = false
if firstRunProfiles and not declinedDownload and wantsDownload then
	console:SetLine('Downloading configs...')
	pcall(function()
		local body = fetchProfilesListing()
		if body then
			downloadProfilesListing(body, nil, function(completed, total)
				console:SetLine('Downloading configs ('..completed..'/'..total..')...')
				console:SetProgress(0.53 + 0.2 * (completed / math.max(total, 1)))
			end)
		end
	end)
	pcall(function()
		downloadedConfigs = #listfiles('Unreal/profiles') >= 3
	end)
	-- Record which commit this download reflects, so later sessions can tell whether profiles/
	-- has changed on GitHub since (see the sync prompt below).
	if downloadedConfigs then
		pcall(function()
			local commit = fetchProfilesCommit()
			if commit then
				writefile('Unreal/profiles/profilecommit.txt', commit)
			end
		end)
	end
end
-- Deleted again here: downloads already in flight when cancel fired can land after its wipe.
if console:IsAborted() then deleteInstall() return end

-- Step 2b: existing installs (3+ profiles). If profiles/ has changed on GitHub since the last
-- download/sync, offer to overwrite the shipped configs with the latest ones. Only the files
-- that exist in the GitHub profiles folder get redownloaded -- profiles the user made
-- themselves are left alone. Skipped on reinjects/teleports so it only ever asks once per
-- session, on the first manual execution.
if not firstRunProfiles and not declinedDownload and not isReload then
	local latestCommit, cachedCommit
	pcall(function()
		latestCommit = fetchProfilesCommit()
		cachedCommit = isfile('Unreal/profiles/profilecommit.txt') and readfile('Unreal/profiles/profilecommit.txt'):gsub('%s', '') or nil
	end)
	if latestCommit and latestCommit ~= cachedCommit then
		console:SetProgress(0.6)
		local ok, wantsSync = pcall(function()
			return console:Ask('Would you like to sync to the latest config?', {
				{text = 'Yes', key = true, tooltip = 'Replaces the shipped configs with the newer ones on GitHub'},
				{text = 'No', key = false, tooltip = 'Keeps the configs you have, asks again next session'}
			}, 60, false)
		end)
		if console:IsAborted() then deleteInstall() return end
		if ok and wantsSync == true then
			console:SetLine('Syncing configs...')
			pcall(function()
				-- If a previous instance is still injected, uninject it BEFORE overwriting:
				-- Uninject() saves the old in-memory config to disk as its first step, and
				-- main.lua would otherwise trigger it right after us -- clobbering the freshly
				-- synced profiles with the old settings. Same for its autosave loop.
				if shared.vape then
					pcall(function() shared.vape:Uninject() end)
					shared.vape = nil
				end
				-- Listing and file contents both pinned to latestCommit so a sync run right
				-- after a push can't grab a stale CDN copy of the branch head.
				local body = fetchProfilesListing(latestCommit)
				if body then
					downloadProfilesListing(body, latestCommit, function(completed, total)
						console:SetLine('Syncing configs ('..completed..'/'..total..')...')
						console:SetProgress(0.6 + 0.13 * (completed / math.max(total, 1)))
					end)
					writefile('Unreal/profiles/profilecommit.txt', latestCommit)
				end
			end)
			if console:IsAborted() then deleteInstall() return end
		end
		-- On "No"/timeout the stored commit stays stale, so the prompt returns next session
		-- until the user agrees to sync once.
	end
end
console:SetProgress(0.73)

-- Step 3: after the shipped configs finish downloading, ask which one should load by default
-- and hand it to the GUI via shared.VapeCustomProfile. main.lua's finishLoading passes this
-- straight into vape:Load as the profile to load, replacing the 'default' profile. The keys
-- match the profile file name prefixes (e.g. blatant<PlaceId>.txt) so Load can find the file.
if downloadedConfigs then
	-- No fallback: only an explicit button click may force a config. This used to
	-- default to 'blatant' -- on a timeout (user tabbed away for 120s) or on the
	-- headless console (which answers every Ask with the fallback instantly) that
	-- silently stamped 'blatant' into shared.VapeCustomProfile, overriding the
	-- profile saved in gui.txt without the user ever choosing it. With nil the
	-- type(choice) guard below skips the override and the saved profile decides.
	local ok, choice = pcall(function()
		return console:Ask('Which config would you like to load by default?', {
			{text = 'Blatant', key = 'blatant', tooltip = 'Makes Blatant your default config: everything on, obvious'},
			{text = 'Legit', key = 'legit', tooltip = 'Makes Legit your default config: toned down to look normal'}
		}, 120, nil)
	end)
	if console:IsAborted() then deleteInstall() return end
	if ok and type(choice) == 'string' then
		shared.VapeCustomProfile = choice
	end
end

console:SetProgress(0.8)
console:SetLine('Loading Unreal...')
-- Creeps the last couple of rows in while main.lua downloads and builds the GUI, so the face
-- is still one row short of finished when injection actually completes.
local injecting = true
task.spawn(function()
	local alpha = 0.8
	while injecting and alpha < 0.93 do
		task.wait(0.6)
		-- injection can finish while this thread is asleep; reporting the stale alpha here
		-- would land after Finish() has already asked for the full face.
		if not injecting then break end
		alpha += 0.02
		console:SetProgress(alpha)
	end
end)

-- pcall'd so a failure surfaces on the console line instead of leaving the window stuck on
-- 'Loading Unreal...'; warn() keeps it in the executor output too.
local ok, result = pcall(function()
	return loadstring(downloadFile('Unreal/main.lua'), 'main')()
end)
injecting = false
-- Consumed only now: main.lua reads the flag itself while loading (it suppresses the 'Finished
-- Loading' notification on a reload). Left set it would leak into the rest of the session,
-- since main.lua never clears it and the next teleport/reinject sets it again anyway.
shared.vapereload = nil
-- Boot is over (successfully or not) -- reinjects and later manual runs may proceed.
shared.UnrealLoaderBoot = nil

-- Cancelled while the GUI was already building: tear that back down too, then wipe whatever
-- the run wrote after cancel's first pass.
if console:IsAborted() then
	if shared.vape then
		pcall(function() shared.vape:Uninject() end)
	end
	shared.VapeCustomProfile = nil
	deleteInstall()
	return
end

if ok then
	console:Finish('Injected successfully.', 5)
	return result
end
warn('[Unreal] '..tostring(result))
-- Copied as well as printed: the message is long, full of executor paths, and the person
-- hitting it is usually being asked to report it. Done here rather than inside console:Fail so
-- a headless reload (which has no window to read) still leaves it on the clipboard.
local failure = 'Injection failed: '..tostring(result)
local copied = pcall(function() setclipboard(failure) end)
console:Fail(failure..(copied and '\n\n(copied to clipboard)' or ''))
