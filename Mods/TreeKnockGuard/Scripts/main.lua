--[[
    TreeKnockGuard — disable Evrima tree knockdown (patch 0.21.77x)

    The knockdown config lives in a TArray `TreeKnockdownSettings` on the
    level's TIWorldSettings. Emptying it disarms the mechanic. There is no
    Game.ini setting for this.

    Verified 2026-08-06 on a Win64 dedicated server, Gateway map:
      TIWorldSettings @ Gateway.Gateway:PersistentLevel.TIWorldSettings
      TreeKnockdownSettings -> TArray, 9 entries
      Lua API available: Empty() / GetArrayNum() / ForEach()

    The array is in-memory and repopulated from the packaged map on every
    level load, so this re-checks periodically instead of firing once.

    Kill switch: create <LOG_DIR>\treeknock.off to stop clearing.
]]

local MESOZOIC_TREE_KNOCK_GUARD_ALPHA_V0_1_0 = true

-- Replaced with the detected C: or D: server path by the installer.
local LOG_FILE = "C:\\TheMesozoic\\TheIsle\\Binaries\\Win64\\Mods\\TreeKnockGuard\\treeknock.log"
local OFF_FILE = "C:\\TheMesozoic\\TheIsle\\Binaries\\Win64\\Mods\\TreeKnockGuard\\treeknock.off"

local WS_CLASS    = "TIWorldSettings"
local PROP_NAME   = "TreeKnockdownSettings"
local INTERVAL_MS = 10000

local function log(msg)
    local line = string.format("%s [TreeKnockGuard] %s", os.date("%Y-%m-%d %H:%M:%S"), msg)
    print(line)
    local f = io.open(LOG_FILE, "a")
    if f == nil then return end
    pcall(function() f:write(line .. "\n") end)
    f:close()
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f == nil then return false end
    f:close()
    return true
end

-- GetAddress() reads the wrapper's stored pointer without dereferencing it,
-- so it is safe even on a freed handle. IsValid() alone is not enough.
local function is_live(obj)
    if obj == nil then return false end
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if not ok or addr == nil or addr == 0 then return false end
    local ok2, valid = pcall(function() return obj:IsValid() end)
    return ok2 and valid == true
end

local cached_ws = nil

local function get_world_settings()
    if cached_ws ~= nil and is_live(cached_ws) then return cached_ws end
    cached_ws = nil
    local ok, obj = pcall(function() return FindFirstOf(WS_CLASS) end)
    if ok and is_live(obj) then cached_ws = obj end
    return cached_ws
end

-- CRITICAL: UE4SS returns a non-nil placeholder `UObject:` for a property that
-- does not exist. Testing `~= nil` therefore matches ANY name, including typos
-- and invented ones. The only reliable discriminator is the tostring() prefix.
local function get_array(ws)
    local ok, value = pcall(function() return ws[PROP_NAME] end)
    if not ok or value == nil then return nil, "not accessible" end
    local ok_str, as_str = pcall(tostring, value)
    if not ok_str or as_str == nil then return nil, "tostring failed" end
    if as_str:sub(1, 7) ~= "TArray:" then
        return nil, "not a TArray (" .. tostring(as_str) .. ")"
    end
    return value, nil
end

local last_num = nil

local function enforce()
    local ws = get_world_settings()
    if ws == nil then return end          -- world not warm yet, retry next tick

    local arr, why = get_array(ws)
    if arr == nil then
        log("array unavailable: " .. tostring(why))
        return
    end

    local ok_n, n = pcall(function() return arr:GetArrayNum() end)
    if not ok_n or type(n) ~= "number" then
        log("GetArrayNum unavailable, skipping pass")
        return
    end

    if n == 0 then
        if last_num ~= 0 then
            log("array already empty (n=0)")
            last_num = 0
        end
        return
    end

    if file_exists(OFF_FILE) then
        if last_num ~= n then
            log(string.format("n=%d but treeknock.off present -> clearing DISABLED", n))
            last_num = n
        end
        return
    end

    local ok, err = pcall(function() arr:Empty() end)
    if not ok then
        log("Empty() threw: " .. tostring(err))
        return
    end

    local ok_a, after = pcall(function() return arr:GetArrayNum() end)
    after = ok_a and after or nil
    last_num = after
    log(string.format("CLEARED: %d -> %s", n, tostring(after)))
    if after ~= nil and after ~= 0 then
        log("!! array did not drop to 0 — Empty() did not take")
    end
end

-- UObject access MUST happen on the game thread. Do not fall back to
-- LoopAsync: it runs on a UE4SS worker and can race the engine.
if LoopInGameThreadWithDelay == nil then
    log("FATAL: LoopInGameThreadWithDelay unavailable; feature disabled")
else
    LoopInGameThreadWithDelay(INTERVAL_MS, function()
        local ok, err = pcall(enforce)
        if not ok then log("enforce threw: " .. tostring(err)) end
        return false
    end)

    log("loaded, watching " .. PROP_NAME .. " every " .. INTERVAL_MS .. "ms")
end
