-- pcall'd: after a teleport shared.vape can still point at the previous server's instance,
-- whose GUI and connections no longer exist. An error walking that corpse would abort main.lua
-- on line one and leave the queued re-injection doing nothing at all.
if shared.vape then pcall(function() shared.vape:Uninject() end) end

local vape
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vape then
		vape:CreateNotification('Vape', 'Failed to load : '..err, 30, 'alert')
	end
	return res
end
local queue_on_teleport = queue_on_teleport or syn and syn.queue_on_teleport
local hasQueueOnTeleport = queue_on_teleport ~= nil
queue_on_teleport = queue_on_teleport or function() end
local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local cloneref = cloneref or function(obj)
	return obj
end
local playersService = cloneref(game:GetService('Players'))

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
			content = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..content
		end
		writefile(path, content)
	end
	return (func or readfile)(path)
end

-- Standalone progress label for the prefetch phase, since it runs before the GUI framework
-- (and its own downloader label) exists yet.
local downloaderGui, downloaderLabel
local function updateDownloader(text)
	if not downloaderGui then
		downloaderGui = Instance.new('ScreenGui')
		downloaderGui.Name = 'UnrealDownloader'
		downloaderGui.ResetOnSpawn = false
		downloaderGui.Parent = cloneref(game:GetService('CoreGui'))
		downloaderLabel = Instance.new('TextLabel')
		downloaderLabel.Size = UDim2.new(1, 0, 0, 40)
		downloaderLabel.BackgroundTransparency = 1
		downloaderLabel.TextStrokeTransparency = 0
		downloaderLabel.TextSize = 20
		downloaderLabel.TextColor3 = Color3.new(1, 1, 1)
		downloaderLabel.Parent = downloaderGui
	end
	downloaderLabel.Text = text
end
local function destroyDownloader()
	if downloaderGui then
		downloaderGui:Destroy()
		downloaderGui, downloaderLabel = nil, nil
	end
end

-- Downloads every file in a repo folder concurrently instead of one HttpGet per getcustomasset call,
-- so GUI construction reads already-cached files instead of blocking on ~190 sequential round trips.
local function prefetchFolder(folder)
	local reqSuc, res = pcall(function()
		return game:HttpGet('https://api.github.com/repos/woahwave/Unreal/contents/'..folder, true)
	end)
	if not (reqSuc and res and res ~= '404: Not Found') then return end
	local bodySuc, body = pcall(function()
		return cloneref(game:GetService('HttpService')):JSONDecode(res)
	end)
	if not (bodySuc and body and typeof(body) == 'table') then return end

	local toFetch = {}
	for _, v in body do
		if v.type == 'file' and not isfile('Unreal/'..folder..'/'..v.name) then
			table.insert(toFetch, v.name)
		end
	end
	if #toFetch <= 0 then return end

	local completed, pending, total = 0, #toFetch, #toFetch
	local done = Instance.new('BindableEvent')
	updateDownloader('Downloading '..folder..' ('..completed..'/'..total..')')
	for _, name in toFetch do
		task.spawn(function()
			pcall(downloadFile, 'Unreal/'..folder..'/'..name)
			completed += 1
			pending -= 1
			-- pcall'd and after the counters: if this ever threw, the task would die
			-- before releasing the wait below and the boot would hang on a GUI error
			pcall(updateDownloader, 'Downloading '..folder..' ('..completed..'/'..total..')')
			if pending <= 0 then
				done:Fire()
			end
		end)
	end
	-- Only wait when something is still outstanding. task.spawn runs each task inline
	-- until it yields, so on executors where HttpGet does NOT yield the scheduler every
	-- download finishes inside the loop above -- done:Fire() then lands with nothing
	-- listening yet, and an unconditional Wait() blocks forever with the label frozen at
	-- total/total. Same guard the loader's downloaders already use.
	if pending > 0 then
		done.Event:Wait()
	end
	done:Destroy()
end

local function finishLoading()
	vape.Init = nil
	-- shared.VapeCustomProfile is a ONE-SHOT hint for the load that immediately follows
	-- (set by the loader's first-run config chooser, or by the teleport handler below).
	-- Capture and clear it up front: getgenv()/shared persists across a reinject, so a
	-- value left over from an earlier teleport would keep forcing that old profile and
	-- override the config you actually switched to -- that stale value was the reinject
	-- 'loads the wrong config' bug. Cleared here, a plain reinject always falls through to
	-- the profile saved in gui.txt (i.e. whatever you last switched to).
	local customProfile = shared.VapeCustomProfile
	shared.VapeCustomProfile = nil
	if customProfile == '' then customProfile = nil end
	vape:Load(nil, customProfile)
	-- Persist the applied profile to gui.txt right away so a reinject before the first
	-- autosave tick still comes back to the same config.
	if customProfile then
		pcall(function() vape:Save() end)
	end
	task.spawn(function()
		while vape.Loaded do
			vape:Save()
			for _ = 1, 10 do
				task.wait(1)
				if not vape.Loaded then break end
			end
		end
	end)

	local teleportedServers
	vape:Clean(playersService.LocalPlayer.OnTeleport:Connect(function()
		if (not teleportedServers) and (not shared.VapeIndependent) then
			teleportedServers = true
			-- Re-runs main.lua, not the loader. The loader is a full boot -- duplicate-run
			-- guard, GitHub API calls for the update check, the console window, the config
			-- prompt -- and any one of those bailing on the new server leaves the script
			-- uninjected. main.lua only needs the files the loader already cached, so it
			-- comes back reliably; the loader still runs on a manual execute.
			local teleportScript = [[
				shared.vapereload = true
				local cached = isfile and isfile('Unreal/main.lua') and readfile('Unreal/main.lua')
				if cached and cached ~= '' then
					loadstring(cached, 'main')()
				else
					loadstring(game:HttpGet('https://raw.githubusercontent.com/woahwave/Unreal/main/main.lua', true), 'main')()
				end
			]]
			if shared.UnrealDeveloper then
				teleportScript = 'shared.UnrealDeveloper = true\n'..teleportScript
			end
			if shared.VapeSmoothBoot then
				teleportScript = 'shared.VapeSmoothBoot = true\n'..teleportScript
			end
			teleportScript = 'shared.VapeCustomProfile = "'..(vape.Profile or shared.VapeCustomProfile or 'default')..'"\n'..teleportScript
			vape:Save()
			if not hasQueueOnTeleport then
				vape:CreateNotification('Vape', 'queue_on_teleport is not supported by your executor -- Vape will not re-inject automatically after this teleport (e.g. queueing into a match). You will need to re-run your loadstring manually.', 15, 'alert')
			end
			queue_on_teleport(teleportScript)
		end
	end))

	if shared.UnrealSyncResult then
		vape:CreateNotification('Vape', shared.UnrealSyncResult, 15, shared.UnrealSyncResult:find('failed') and 'alert' or nil)
		shared.UnrealSyncResult = nil
	end

	if not shared.vapereload then
		if not vape.Categories then return end
		if vape.Categories.Main.Options['GUI bind indicator'].Enabled then
			vape:CreateNotification('Finished Loading', vape.VapeButton and 'Press the button in the top right to open GUI' or 'Press '..table.concat(vape.Keybind, ' + '):upper()..' to open GUI', 5)
		end
	end
end

	if not isfile('Unreal/profiles/gui.txt') then
		writefile('Unreal/profiles/gui.txt', 'new')
	end
	local gui = readfile('Unreal/profiles/gui.txt')

	if not isfolder('Unreal/assets/'..gui) then
		makefolder('Unreal/assets/'..gui)
	end
	pcall(prefetchFolder, 'assets/'..gui)
	if gui ~= 'new' then
		pcall(prefetchFolder, 'assets/new')
	end
	destroyDownloader()
	vape = loadstring(downloadFile('Unreal/guis/'..gui..'.lua'), 'gui')()
	shared.vape = vape

if not shared.VapeIndependent then
	-- downloading doesn't need the game loaded; only wait here, right before touching game/character state
	if not game:IsLoaded() then
		repeat task.wait() until game:IsLoaded()
		-- identifyexecutor is absent on some executors (common on mobile); calling it
		-- unguarded errors here and aborts everything below, including the game script.
		local executorName = ''
		pcall(function() executorName = identifyexecutor and identifyexecutor() or '' end)
		task.wait(executorName == 'Opiumware' and 30 or 5)
	end
	-- pcall'd: an error thrown while universal.lua *executes* would otherwise propagate out of
	-- main.lua entirely, skipping the game script below and finishLoading() with it.
	pcall(function()
		loadstring(downloadFile('Unreal/games/universal.lua'), 'universal')()
	end)

	local gamePath = 'Unreal/games/'..game.PlaceId..'.lua'
	-- A cached-but-empty file is treated as missing and refetched: a truncated write from an
	-- earlier failed download reads back as "present", and loadstring('') silently does
	-- nothing -- indistinguishable from the game script never loading at all.
	local cached = isfile(gamePath) and readfile(gamePath) or nil
	if cached and cached:gsub('%s', '') ~= '' then
		-- pcall(fn, ...) rather than pcall(function() fn(...) end): '...' is only valid
		-- directly in this chunk, never inside a nested non-vararg function.
		pcall(loadstring(cached, tostring(game.PlaceId)), ...)
	elseif not shared.UnrealDeveloper then
		-- Single fetch (the old code requested this URL twice: once to probe, then again
		-- inside downloadFile) and load straight from the response, so a stale/corrupt
		-- cache file can't shadow what we just downloaded.
		local suc, res = pcall(function()
			return game:HttpGet('https://raw.githubusercontent.com/woahwave/Unreal/main/games/'..game.PlaceId..'.lua', true)
		end)
		if suc and res and res ~= '' and res ~= '404: Not Found' then
			pcall(writefile, gamePath, '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..res)
			pcall(loadstring(res, tostring(game.PlaceId)), ...)
		end
	end
	finishLoading()
else
	vape.Init = finishLoading
	return vape
end
