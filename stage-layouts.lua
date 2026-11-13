-- Stage Manager layouts: save which windows share a stage and where each window sits,
-- per display setup and per Desktop, then rebuild that after a restart.
--
-- macOS keeps no record of stage groups across a restart and has no API for them. This uses
-- the Stage Manager strip's accessibility tree: each strip button lists its windows
-- (AXWindowsIDs) and offers AXAddToStage, the same thing as Shift-clicking it.
--
-- Limit: windows cannot be moved between Desktops (hs.spaces.moveWindowToSpace is a no-op on
-- macOS 26), so a window found on the wrong Desktop is reported, not moved.
--
-- Data: ~/.config/stage-layouts/layouts.json. CLI: ../stage-layout. Loaded from ~/.hammerspoon/init.lua.

local ax = require("hs.axuielement")

local M = STAGE_LAYOUTS or {}
STAGE_LAYOUTS = M

M.dataPath = os.getenv("HOME") .. "/.config/stage-layouts/layouts.json"
M.settle = 0.8 -- seconds for a stage switch animation to finish before reading the strip again
M.launchMissing = true -- on restore, open saved apps that are not running
M.launchWait = 20 -- seconds to wait for launched apps to show a window
M.retries = 2 -- extra restore passes for windows that were not open yet
M.retryDelay = 30
M.autoRestoreOnBoot = true
M.bootDelay = 30 -- let login items open their windows first
M.autoRestoreOnScreenChange = true
M.autoRestoreOnFirstDesktopVisit = true -- after a boot, restore each Desktop the first time you visit it
M.hotkeyMods = { "ctrl", "alt", "cmd" }
M.captureKey = "s"
M.restoreKey = "r"

M.timers = M.timers or {}
local log = hs.logger.new("stagelay", "info")
M.log = log -- STAGE_LAYOUTS.log.setLogLevel("debug") to trace grouping steps

local function notify(text)
    log.i(text)
    hs.notify.new({ title = "Stage layouts", informativeText = text, withdrawAfter = 8 }):send()
end

-- ---- async plumbing: Stage Manager needs real time between steps, and blocking Hammerspoon
-- ---- (usleep) also freezes the animations we are waiting for.

local function sleep(secs)
    local co = coroutine.running()
    local t
    t = hs.timer.doAfter(secs, function()
        M.timers[t] = nil
        local ok, err = coroutine.resume(co)
        if not ok then
            M.busy = nil
            log.e(err)
        end
    end)
    M.timers[t] = true
    coroutine.yield()
end

local function runAsync(name, fn, quiet)
    if M.busy then
        if not quiet then notify(name .. " skipped: " .. M.busy .. " is still running") end
        return
    end
    M.busy = name
    local t
    t = hs.timer.doAfter(0, function()
        M.timers[t] = nil
        local co = coroutine.create(function()
            local ok, err = xpcall(fn, debug.traceback)
            M.busy = nil
            if not ok then
                log.e(err)
                notify(name .. " failed: " .. tostring(err):match("[^\n]*"))
            end
        end)
        local ok, err = coroutine.resume(co)
        if not ok then
            M.busy = nil
            log.e(err)
        end
    end)
    M.timers[t] = true
end

-- ---- storage ----

local function loadData()
    local f = io.open(M.dataPath, "r")
    if not f then return { profiles = {} } end
    local raw = f:read("a")
    f:close()
    local data = hs.json.decode(raw)
    if type(data) ~= "table" then return { profiles = {} } end
    data.profiles = data.profiles or {}
    return data
end

local function saveData(data)
    hs.fs.mkdir(M.dataPath:match("^(.*)/[^/]+$"))
    local f = assert(io.open(M.dataPath, "w"))
    f:write(hs.json.encode(data, true))
    f:close()
end

-- ---- displays and Desktops ----

-- A display setup is the set of connected screens, so the laptop alone and the laptop on
-- its monitors each get their own saved layout.
local function profileKey()
    local ids = {}
    for _, s in ipairs(hs.screen.allScreens()) do table.insert(ids, s:getUUID()) end
    table.sort(ids)
    return table.concat(ids, "+")
end

local function currentScreens()
    local screens = {}
    for _, s in ipairs(hs.screen.allScreens()) do
        screens[s:getUUID()] = { name = s:name() or "?", x = s:fullFrame().x }
    end
    return screens
end

local function isMacDisplay(name) return name:find("Built%-in") ~= nil end

-- Monitors are numbered left to right, matching how they sit on the desk.
local function screenNames(screens)
    local names, external = {}, {}
    for uuid, s in pairs(screens) do
        if isMacDisplay(s.name) then names[uuid] = "Mac Display" else table.insert(external, uuid) end
    end
    table.sort(external, function(a, b) return screens[a].x < screens[b].x end)
    for i, uuid in ipairs(external) do
        names[uuid] = (#external > 1 and "Monitor " .. i or "Monitor") .. " (" .. screens[uuid].name .. ")"
    end
    return names, #external
end

local function setupLabel(screens)
    local names, monitors = screenNames(screens)
    local hasMac = false
    for _, n in pairs(names) do hasMac = hasMac or n == "Mac Display" end
    if monitors == 0 then return "Mac Display, no monitors" end
    local m = monitors == 1 and "1 monitor" or monitors .. " monitors"
    return hasMac and "Mac Display + " .. m or m .. ", no Mac Display"
end

local function desktopLabel(screens, dkey)
    local uuid, n = dkey:match("^(.*)#(%d+)$")
    return "Desktop " .. n .. " on " .. (screenNames(screens)[uuid] or "unknown screen")
end

-- Space IDs are reassigned on restart, so a Desktop is stored by its position on its screen.
local function desktopKey(screen)
    local active = hs.spaces.activeSpaceOnScreen(screen)
    local n = 0
    for _, id in ipairs(hs.spaces.spacesForScreen(screen) or {}) do
        if hs.spaces.spaceType(id) == "user" then
            n = n + 1
            if id == active then return screen:getUUID() .. "#" .. n, n end
        end
    end
    return nil
end

-- ---- windows and the Stage Manager strip ----

-- ignore: bundle IDs of apps whose windows float over every stage (see captureNow).
local function candidateWindows(ignore)
    local list = {}
    for _, w in ipairs(hs.window.allWindows()) do
        local app = w:application()
        local bundleID = app and app:bundleID()
        -- Subrole check: panels like Wispr Flow's "Status" dialog pass isStandard but are not
        -- stage members.
        if bundleID and w:isStandard() and w:subrole() == "AXStandardWindow" and w:isVisible() and not w:isMinimized()
            and not w:isFullScreen() and bundleID ~= "org.hammerspoon.Hammerspoon"
            and not (ignore and ignore[bundleID]) then
            table.insert(list, w)
        end
    end
    return list
end

local function stripButtons()
    local wm = hs.application.find("com.apple.WindowManager")
    local found = {}
    if not wm then return found end
    local root = ax.applicationElement(wm)
    local function walk(el, depth)
        if depth > 5 then return end
        for _, child in ipairs(el:attributeValue("AXChildren") or {}) do
            local ids = child:attributeValue("AXRole") == "AXButton" and child:attributeValue("AXWindowsIDs")
            if ids then
                table.insert(found, { el = child, ids = ids })
            else
                walk(child, depth + 1)
            end
        end
    end
    walk(root, 0)
    return found
end

-- Returns stage key per window id: "strip<n>" for strip thumbnails, "active:<screen>" for the
-- stage on screen. Windows in neither are in stages that do not fit in the strip.
local function stageKeys()
    local keys = {}
    for i, b in ipairs(stripButtons()) do
        for _, id in ipairs(b.ids) do keys[id] = "strip" .. i end
    end
    for _, w in ipairs(hs.window.orderedWindows()) do
        local id = w:id()
        if not keys[id] and w:screen() then keys[id] = "active:" .. w:screen():getUUID() end
    end
    return keys
end

-- Mid-animation, the outgoing stage is still on screen and reads as part of the incoming one,
-- so only trust a reading that two consecutive samples agree on.
local function stableStageKeys()
    local function signature(keys)
        local parts = {}
        for id, key in pairs(keys) do table.insert(parts, id .. "=" .. key) end
        table.sort(parts)
        return table.concat(parts, ",")
    end
    local keys = stageKeys()
    for _ = 1, 10 do
        sleep(0.4)
        local again = stageKeys()
        if signature(again) == signature(keys) then return again end
        keys = again
    end
    log.w("stage strip did not settle; using last reading")
    return keys
end

local function focusAndSettle(w)
    w:focus()
    sleep(M.settle)
end

local function unitFrame(w)
    local sf = w:screen():frame()
    local f = w:frame()
    return { x = (f.x - sf.x) / sf.w, y = (f.y - sf.y) / sf.h, w = f.w / sf.w, h = f.h / sf.h }
end

local function applyFrame(w, saved)
    if not saved then return end -- an unsaved extra window keeps its own size
    local screen = hs.screen.find(saved.screen) or w:screen()
    local sf = screen:frame()
    local u = saved.unit
    w:setFrame(hs.geometry.rect(sf.x + u.x * sf.w, sf.y + u.y * sf.h, u.w * sf.w, u.h * sf.h), 0)
end

local function describe(w)
    local app = w:application()
    local title = w:title() or ""
    if #title > 40 then title = title:sub(1, 40) .. "..." end
    return (app and app:name() or "?") .. (title ~= "" and " '" .. title .. "'" or "")
end

-- Only the part of a window title that says which window it is, not what it shows: the text
-- after the last " - ", e.g. Chrome's profile "Alex (Work)". Tab and document names change all
-- the time and are not worth storing.
local function titleHint(title)
    return (title or ""):match(".* %- (.-)$") or ""
end

-- ---- capture ----

local function captureNow()
    local data = loadData()
    data.ignoreApps = data.ignoreApps or {}
    local wins = candidateWindows(data.ignoreApps)
    local original = hs.window.focusedWindow()

    -- Each pass records the stage key of every window. Stages beyond what the strip shows only
    -- become readable once brought on screen, so keep focusing unseen windows.
    local passes, seen = {}, {}
    local function record()
        local keys = stableStageKeys()
        table.insert(passes, keys)
        for _, w in ipairs(wins) do
            if keys[w:id()] then seen[w:id()] = true end
        end
    end
    record()
    for _, w in ipairs(wins) do
        if not seen[w:id()] then
            focusAndSettle(w)
            record()
            seen[w:id()] = true
        end
    end
    -- Floating-window detection below needs at least one stage switch.
    if #passes == 1 then
        for _, w in ipairs(wins) do
            local key = passes[1][w:id()]
            if key and key:sub(1, 5) == "strip" then
                focusAndSettle(w)
                record()
                break
            end
        end
    end
    if original then focusAndSettle(original) end

    -- A real stage is on screen in at most one pass. A window on screen in two or more floats
    -- over every stage (Wispr Flow's panel); grouping by it would merge all stages into one.
    local onScreenPasses, floating = {}, {}
    for _, keys in ipairs(passes) do
        for id, key in pairs(keys) do
            if key:sub(1, 7) == "active:" then onScreenPasses[id] = (onScreenPasses[id] or 0) + 1 end
        end
    end
    for _, w in ipairs(wins) do
        if (onScreenPasses[w:id()] or 0) >= 2 then
            floating[w:id()] = true
            data.ignoreApps[w:application():bundleID()] = w:application():name()
            log.i("ignoring " .. w:application():name() .. ": its window floats over every stage")
        end
    end

    -- A strip thumbnail lists at most 3 window IDs, so a big stage is seen in parts across
    -- passes; windows that ever shared a key belong to the same stage (union-find).
    local parent = {}
    for _, w in ipairs(wins) do parent[w:id()] = w:id() end
    local function find(id)
        while parent[id] ~= id do id = parent[id] end
        return id
    end
    for _, keys in ipairs(passes) do
        local firstWithKey = {}
        for _, w in ipairs(wins) do
            local id, key = w:id(), keys[w:id()]
            if key and not floating[id] then
                if firstWithKey[key] then
                    parent[find(id)] = find(firstWithKey[key])
                else
                    firstWithKey[key] = id
                end
            end
        end
    end
    local activeRoots = {}
    for _, w in ipairs(wins) do
        local key = passes[1][w:id()]
        if key and key:sub(1, 7) == "active:" and not floating[w:id()] then activeRoots[find(w:id())] = true end
    end
    local stages, stageOfRoot = {}, {}
    for _, w in ipairs(wins) do
        if not floating[w:id()] then
            local root = find(w:id())
            if not stageOfRoot[root] then
                stageOfRoot[root] = { windows = {}, active = activeRoots[root] or false }
                table.insert(stages, stageOfRoot[root])
            end
            table.insert(stageOfRoot[root].windows, w)
        end
    end

    local key = profileKey()
    local profile = data.profiles[key] or { desktops = {} }
    profile.label = nil -- labels are derived from screens now
    profile.screens = currentScreens()
    profile.desktops = profile.desktops or {}

    local desktops, savedWindows = {}, 0
    for _, stage in ipairs(stages) do
        local dkey = desktopKey(stage.windows[1]:screen())
        if dkey then
            if not desktops[dkey] then
                desktops[dkey] = { capturedAt = os.date("%Y-%m-%d %H:%M"), stages = {} }
            end
            local saved = { active = stage.active, windows = {} }
            for _, w in ipairs(stage.windows) do
                table.insert(saved.windows, {
                    app = w:application():name(),
                    bundleID = w:application():bundleID(),
                    hint = titleHint(w:title()),
                    screen = w:screen():getUUID(),
                    unit = unitFrame(w),
                })
                savedWindows = savedWindows + 1
            end
            table.insert(desktops[dkey].stages, saved)
        end
    end

    local labels = {}
    for dkey, d in pairs(desktops) do
        profile.desktops[dkey] = d
        table.insert(labels, desktopLabel(profile.screens, dkey) .. " (" .. #d.stages .. " stages)")
    end
    data.profiles[key] = profile
    saveData(data)
    notify("Saved " .. savedWindows .. " windows: " .. table.concat(labels, "; ") .. " | " .. setupLabel(profile.screens))
end

-- ---- restore ----

-- Windows are matched by app, preferring the same title hint (Chrome Work vs Personal).
-- Which of several same-app, same-hint windows lands in which stage is arbitrary.
local function matchWindows(savedList, current)
    local pool, claimed, match = {}, {}, {}
    for _, w in ipairs(current) do
        local b = w:application():bundleID()
        pool[b] = pool[b] or {}
        table.insert(pool[b], w)
    end
    for _, sameHintOnly in ipairs({ true, false }) do
        for i, sw in ipairs(savedList) do
            if not match[i] then
                -- Layouts saved before hints existed stored the full title.
                local hint = sw.hint or titleHint(sw.title)
                for _, w in ipairs(pool[sw.bundleID] or {}) do
                    if not claimed[w:id()] and (not sameHintOnly or titleHint(w:title()) == hint) then
                        match[i], claimed[w:id()] = w, true
                        break
                    end
                end
            end
        end
    end
    return match
end

local function launchMissingApps(desktops)
    local launched = {}
    for _, d in ipairs(desktops) do
        for _, stage in ipairs(d.stages) do
            for _, sw in ipairs(stage.windows) do
                if not launched[sw.bundleID] and not hs.application.get(sw.bundleID) then
                    launched[sw.bundleID] = true
                    hs.application.open(sw.bundleID)
                end
            end
        end
    end
    if not next(launched) then return end
    local deadline = hs.timer.secondsSinceEpoch() + M.launchWait
    repeat
        sleep(1)
        local waiting = false
        for bundleID in pairs(launched) do
            local app = hs.application.get(bundleID)
            if not app or #app:allWindows() == 0 then waiting = true end
        end
    until not waiting or hs.timer.secondsSinceEpoch() > deadline
    sleep(2)
end

-- A missing window is worth waiting for only while its app is still starting up. If the app
-- already has windows open, the saved one was most likely closed (an old Chrome tab).
-- allWindows only sees the current Desktop, so an app with no windows here counts as starting
-- only if it launched recently.
local function stillStarting(bundleID)
    local app = hs.application.get(bundleID)
    if not app then return true end
    for _, w in ipairs(app:allWindows()) do
        if w:isStandard() then return false end
    end
    -- etime is [[dd-]hh:]mm:ss
    local etime = (hs.execute("/bin/ps -o etime= -p " .. app:pid()) or ""):match("[%d:%-]+")
    if not etime then return false end
    local days, rest = etime:match("^(%d+)%-(.*)$")
    local secs = 0
    for part in (rest or etime):gmatch("%d+") do secs = secs * 60 + tonumber(part) end
    secs = secs + (tonumber(days) or 0) * 86400
    return secs < M.launchWait * 4
end

local function findButton(id)
    for _, b in ipairs(stripButtons()) do
        for _, bid in ipairs(b.ids) do
            if bid == id then return b end
        end
    end
end

-- Puts w's thumbnail onto the anchor's stage (the anchor is on screen). The thumbnail only shows
-- up once the stage switch animation ends, and an add can silently do nothing, so wait for the
-- thumbnail and check the result.
local function addToAnchorStage(w, anchor, inStage, problems)
    for attempt = 1, 2 do
        local button
        for _ = 1, 10 do
            button = findButton(w:id())
            if button then break end
            sleep(0.4)
        end
        if not button then
            table.insert(problems, "could not find " .. describe(w) .. " in the strip")
            return
        end
        local strangers = {}
        for _, id in ipairs(button.ids) do
            if not inStage[id] then
                local other = hs.window.get(id)
                table.insert(strangers, other and describe(other) or tostring(id))
            end
        end
        if #strangers > 0 then
            -- AXAddToStage moves the whole thumbnail; adding it would pull these in too.
            table.insert(problems, describe(w) .. " is grouped with " .. table.concat(strangers, ", ") .. "; drag it out, then restore again")
            return
        end
        button.el:performAction("AXAddToStage")
        sleep(M.settle)
        local keys = stableStageKeys()
        if keys[w:id()] and keys[w:id()] == keys[anchor:id()] then return end
        log.d("add attempt " .. attempt .. " did not group " .. describe(w) .. " with " .. describe(anchor))
    end
    table.insert(problems, "could not add " .. describe(w) .. " to the stage with " .. describe(anchor))
end

-- Returns the stage's anchor window (nil if none of its windows exist) and how many saved
-- windows may still appear. extras: open windows that match nothing saved but belong here.
local function buildStage(stage, matched, problems, ignore, extras)
    local ws, savedFor, inStage, missingByApp, waiting = {}, {}, {}, {}, 0
    for i, sw in ipairs(stage.windows) do
        local w = matched[i]
        if w then
            table.insert(ws, w)
            savedFor[w:id()] = sw
            inStage[w:id()] = true
        else
            missingByApp[sw.app] = (missingByApp[sw.app] or 0) + 1
            if stillStarting(sw.bundleID) then waiting = waiting + 1 end
        end
    end
    for app, n in pairs(missingByApp) do
        local saved = 0
        for _, sw in ipairs(stage.windows) do
            if sw.app == app then saved = saved + 1 end
        end
        table.insert(problems, app .. ": " .. n .. " of " .. saved .. " saved windows not open")
    end
    if #ws == 0 then return nil, waiting end
    for _, w in ipairs(extras or {}) do
        table.insert(ws, w)
        inStage[w:id()] = true
    end

    local anchor = ws[1]
    focusAndSettle(anchor)
    applyFrame(anchor, savedFor[anchor:id()])
    for i = 2, #ws do
        local w = ws[i]
        local keys = stableStageKeys()
        if not keys[w:id()] or keys[w:id()] ~= keys[anchor:id()] then
            -- Bring it on screen first so its frame lands on the right display, then return to
            -- the anchor; the window's stage is now the newest strip thumbnail.
            focusAndSettle(w)
            applyFrame(w, savedFor[w:id()])
            focusAndSettle(anchor)
            addToAnchorStage(w, anchor, inStage, problems)
        end
    end
    sleep(0.3)
    for _, w in ipairs(ws) do applyFrame(w, savedFor[w:id()]) end

    local keys = stableStageKeys()
    for _, w in ipairs(candidateWindows(ignore)) do
        if not inStage[w:id()] and keys[w:id()] == keys[anchor:id()] then
            table.insert(problems, describe(w) .. " shares a stage with " .. describe(anchor) .. " but was not saved there")
        end
    end
    return anchor, waiting
end

local function restoreNow(opts)
    opts = opts or {}
    local data = loadData()
    local profile = data.profiles[profileKey()]
    if not profile then
        if not opts.quiet then notify("Nothing saved for " .. setupLabel(currentScreens()) .. ". Save with ctrl+alt+cmd+S.") end
        return
    end
    local screens = profile.screens or currentScreens()

    local desktops, here = {}, {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local dkey = desktopKey(screen)
        local d = dkey and profile.desktops[dkey]
        if dkey then table.insert(here, desktopLabel(screens, dkey)) end
        if d and (not opts.onlyKeys or opts.onlyKeys[dkey]) then
            d.key = dkey
            table.insert(desktops, d)
        end
        if dkey and M.restoredDesktops then M.restoredDesktops[dkey] = true end
    end
    if #desktops == 0 then
        if not opts.quiet then notify("Nothing saved for " .. table.concat(here, ", ") .. " | " .. setupLabel(screens)) end
        return
    end

    if M.launchMissing and not opts.onlyStages then launchMissingApps(desktops) end

    -- waitingStages: stages with windows whose app is still starting. A retry pass touches only
    -- those, so complete stages are not flipped through again.
    local problems, activeAnchors, total, waitingStages = {}, {}, 0, {}
    for _, d in ipairs(desktops) do
        local savedList, owner = {}, {}
        for si, stage in ipairs(d.stages) do
            for wi, sw in ipairs(stage.windows) do
                table.insert(savedList, sw)
                owner[#savedList] = { si, wi }
            end
        end
        local current = candidateWindows(data.ignoreApps)
        local flat = matchWindows(savedList, current)
        local perStage, used = {}, {}
        for i, o in pairs(owner) do
            perStage[o[1]] = perStage[o[1]] or {}
            perStage[o[1]][o[2]] = flat[i]
            if flat[i] then used[flat[i]:id()] = true end
        end
        -- A window opened since the save (another Chrome window) joins the stage that holds most
        -- of its app's saved windows. Apps never saved here are left where they are.
        local homeStage = {}
        for si, stage in ipairs(d.stages) do
            local count = {}
            for _, sw in ipairs(stage.windows) do count[sw.bundleID] = (count[sw.bundleID] or 0) + 1 end
            for b, n in pairs(count) do
                if not homeStage[b] or n > homeStage[b].n then homeStage[b] = { si = si, n = n } end
            end
        end
        local extras = {}
        for _, w in ipairs(current) do
            local home = homeStage[w:application():bundleID()]
            if home and not used[w:id()] then
                extras[home.si] = extras[home.si] or {}
                table.insert(extras[home.si], w)
            end
        end
        -- Active stages last so they end up on screen.
        local order = {}
        for si, stage in ipairs(d.stages) do if not stage.active then table.insert(order, si) end end
        for si, stage in ipairs(d.stages) do if stage.active then table.insert(order, si) end end
        for _, si in ipairs(order) do
            local stageID = d.key .. "/" .. si
            if not opts.onlyStages or opts.onlyStages[stageID] then
                local anchor, waiting = buildStage(d.stages[si], perStage[si] or {}, problems, data.ignoreApps, extras[si])
                if waiting > 0 then waitingStages[stageID] = true end
                if anchor then
                    total = total + 1
                    if d.stages[si].active then table.insert(activeAnchors, anchor) end
                end
            end
        end
    end
    -- A retry rebuilds only incomplete stages; don't yank the screen to the saved active one.
    if not opts.onlyStages then
        for _, a in ipairs(activeAnchors) do focusAndSettle(a) end
    end

    local retries = opts.retries or M.retries
    local msg = "Restored " .. total .. " stages: " .. table.concat(here, ", ")
    if #problems > 0 then
        msg = msg .. ". " .. #problems .. " issue(s): " .. table.concat(problems, "; ")
        log.w(table.concat(problems, "\n"))
    end
    if next(waitingStages) and retries > 0 then
        msg = msg .. ". Trying again in " .. M.retryDelay .. "s for apps still starting."
        if M.retryTimer then M.retryTimer:stop() end
        M.retryTimer = hs.timer.doAfter(M.retryDelay, function()
            log.i("retrying restore for apps that were still starting")
            M.restore({ quiet = opts.quiet, onlyKeys = opts.onlyKeys, retries = retries - 1, onlyStages = waitingStages })
        end)
    end
    notify(msg)
end

function M.capture() runAsync("capture", captureNow) end

function M.restore(opts) runAsync("restore", function() restoreNow(opts) end, opts and opts.quiet) end

function M.list()
    local data = loadData()
    local now = currentScreens()
    local here = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local dkey = desktopKey(screen)
        if dkey then table.insert(here, desktopLabel(now, dkey)) end
    end
    local lines = { "You are on: " .. table.concat(here, ", ") .. " | " .. setupLabel(now), "" }
    if not next(data.profiles) then table.insert(lines, "Nothing saved yet.") end
    for key, p in pairs(data.profiles) do
        local screens = p.screens or (key == profileKey() and now) or {}
        table.insert(lines, (key == profileKey() and "* " or "  ") .. setupLabel(screens) .. (key == profileKey() and "  (connected now)" or ""))
        local dkeys = {}
        for dkey in pairs(p.desktops or {}) do table.insert(dkeys, dkey) end
        table.sort(dkeys, function(a, b) return desktopLabel(screens, a) < desktopLabel(screens, b) end)
        for _, dkey in ipairs(dkeys) do
            local d = p.desktops[dkey]
            local n = 0
            for _, s in ipairs(d.stages) do n = n + #s.windows end
            table.insert(lines, "    " .. desktopLabel(screens, dkey) .. ": " .. #d.stages .. " stages, " .. n .. " windows, saved " .. (d.capturedAt or "?"))
            for _, s in ipairs(d.stages) do
                local apps, seen = {}, {}
                for _, sw in ipairs(s.windows) do
                    seen[sw.app] = (seen[sw.app] or 0) + 1
                    if seen[sw.app] == 1 then table.insert(apps, sw.app) end
                end
                for i, a in ipairs(apps) do
                    if seen[a] > 1 then apps[i] = a .. " x" .. seen[a] end
                end
                table.insert(lines, "        " .. (s.active and "> " or "- ") .. table.concat(apps, ", "))
            end
        end
    end
    table.insert(lines, "")
    table.insert(lines, "> = stage that was on screen. Saved in " .. M.dataPath)
    return table.concat(lines, "\n")
end

M.status = M.list

-- ---- triggers ----

if M.captureHotkey then M.captureHotkey:delete() end
if M.restoreHotkey then M.restoreHotkey:delete() end
M.captureHotkey = hs.hotkey.bind(M.hotkeyMods, M.captureKey, M.capture)
M.restoreHotkey = hs.hotkey.bind(M.hotkeyMods, M.restoreKey, M.restore)

local function bootTime()
    local out = hs.execute("/usr/sbin/sysctl -n kern.boottime")
    return out and out:match("sec = (%d+)")
end

-- Hammerspoon reloads during the day must not rearrange windows, so automatic restores on
-- Desktop visits only happen in the session right after a boot.
local boot = bootTime()
local lastBoot = hs.settings.get("stageLayouts.lastBoot")
if boot and lastBoot ~= boot then
    hs.settings.set("stageLayouts.lastBoot", boot)
    -- No lastBoot means first install, mid-session: nothing to restore yet.
    if M.autoRestoreOnBoot and lastBoot then
        M.restoredDesktops = {}
        M.bootTimer = hs.timer.doAfter(M.bootDelay, function() M.restore({ quiet = true }) end)
    end
end

-- macOS reports a display reconfiguration for much more than plugging monitors in (wake,
-- resolution, screen sharing), so only a change in which screens are connected counts.
M.lastSetup = profileKey()
if M.screenWatcher then M.screenWatcher:stop() end
M.screenWatcher = hs.screen.watcher.new(function()
    if not M.autoRestoreOnScreenChange then return end
    -- Displays reconnect in several steps; wait for the final arrangement.
    if M.screenTimer then M.screenTimer:stop() end
    M.screenTimer = hs.timer.doAfter(5, function()
        local setup = profileKey()
        if setup == M.lastSetup then
            log.i("display reconfigured, same screens; not restoring")
            return
        end
        M.lastSetup = setup
        log.i("screens changed to " .. setupLabel(currentScreens()) .. "; restoring")
        M.restore({ quiet = true })
    end)
end)
M.screenWatcher:start()

if M.spaceWatcher then M.spaceWatcher:stop() end
M.spaceWatcher = hs.spaces.watcher.new(function()
    if not (M.autoRestoreOnFirstDesktopVisit and M.restoredDesktops) or M.busy then return end
    local fresh = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local dkey = desktopKey(screen)
        if dkey and not M.restoredDesktops[dkey] then fresh[dkey] = true end
    end
    if next(fresh) then
        log.i("first visit to a Desktop since boot; restoring it")
        if M.spaceTimer then M.spaceTimer:stop() end
        M.spaceTimer = hs.timer.doAfter(1.5, function() M.restore({ quiet = true, onlyKeys = fresh }) end)
    end
end)
M.spaceWatcher:start()

log.i("stage layouts loaded; capture ctrl+alt+cmd+S, restore ctrl+alt+cmd+R")
return M
