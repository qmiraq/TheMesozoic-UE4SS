-- MesozoicPteraStamina - player-only Pteranodon stamina support
-- Version: 0.1.0-alpha
-- Build marker: MESOZOIC_PTERA_STAMINA_ALPHA_V0_1_0

local MOD_NAME = "MesozoicPteraStamina"
local VERSION = "0.1.0-alpha"
local TICK_INTERVAL_MS = 1000
local PRESENCE_REFRESH_INTERVAL_MS = 15000
local HEALTH_LOG_INTERVAL_SECONDS = 60

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function safe_get(callback, fallback)
    local ok, value = pcall(callback)
    if ok and value ~= nil then return value end
    return fallback
end

local function is_valid_object(object)
    if object == nil then return false end
    local address = tonumber(safe_get(function() return object:GetAddress() end, 0)) or 0
    return address ~= 0
end

local function is_finite_number(value)
    value = tonumber(value)
    return value ~= nil and value == value and value > -math.huge and value < math.huge
end

local function resolve_mod_root()
    local fallback = "Mods/MesozoicPteraStamina"
    if debug == nil or debug.getinfo == nil then return fallback end
    local info = safe_get(function() return debug.getinfo(1, "S") end, nil)
    if info == nil or info.source == nil then return fallback end
    local source = tostring(info.source):gsub("^@", ""):gsub("\\", "/")
    return source:match("^(.*)/[Ss]cripts/main%.lua$") or fallback
end

local MOD_ROOT = resolve_mod_root()
local CONFIG_PATH = MOD_ROOT .. "/config/PteraStamina.ini"

local config = {
    enabled = true,
    recharge_percent_per_second = 0.25,
    startup_delay_seconds = 10
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function parse_boolean(value)
    value = trim(value):lower()
    if value == "true" or value == "1" or value == "yes" or value == "on" then return true end
    if value == "false" or value == "0" or value == "no" or value == "off" then return false end
    return nil
end

local function load_config()
    local file = io.open(CONFIG_PATH, "r")
    if file == nil then
        log("[CONFIG] using embedded defaults; file not found at " .. CONFIG_PATH)
        return
    end

    local section = ""
    local values = {}
    for raw_line in file:lines() do
        local line = trim(raw_line:gsub("[;#].*$", ""))
        local section_name = line:match("^%[([^%]]+)%]$")
        if section_name ~= nil then
            section = trim(section_name):lower()
        elseif line ~= "" and section == "pterastamina" then
            local key, value = line:match("^([^=]+)=(.*)$")
            if key ~= nil then values[trim(key):lower()] = trim(value) end
        end
    end
    file:close()

    local enabled = parse_boolean(values.enabled)
    if enabled ~= nil then config.enabled = enabled end

    local rate = tonumber(values.rechargepercentpersecond)
    if rate ~= nil then
        config.recharge_percent_per_second = math.max(0, math.min(100, rate))
    end

    local startup = tonumber(values.startupdelayseconds)
    if startup ~= nil then
        config.startup_delay_seconds = math.max(0, math.floor(startup))
    end
end

load_config()

local presence_registry = {}
local startup_at = os.time() + config.startup_delay_seconds
local last_health_log_at = 0
local stats = {
    ticks = 0,
    pteranodons = 0,
    modified = 0,
    already_full = 0,
    skipped_invalid = 0,
    setter_failures = 0
}

local function find_game_mode()
    if FindFirstOf == nil then return nil end
    local candidates = {
        "BP_SurvivalGameMode_C",
        "TISurvivalGameMode",
        "TIGameModeBase",
        "GameModeBase"
    }
    for _, class_name in ipairs(candidates) do
        local game_mode = safe_get(function() return FindFirstOf(class_name) end, nil)
        if is_valid_object(game_mode) then return game_mode end
    end
    return nil
end

local function live_pawn_from_controller(controller)
    if not is_valid_object(controller) then return nil end
    local pawn = safe_get(function() return controller:K2_GetPawn() end, nil)
    if not is_valid_object(pawn) then return nil end
    return pawn
end

local function controller_steam_id(controller)
    if not is_valid_object(controller) then return "" end
    local steam_id = safe_get(function() return controller:GetSteamId() end, nil)
    if steam_id == nil then return "" end
    local value = safe_get(function() return steam_id:ToString() end, nil)
    if value == nil then return "" end
    value = tostring(value)
    if value == "" then return "" end
    return value
end

local function presence_update(steam)
    steam = tostring(steam or "")
    if steam == "" then return end
    local now = os.time()
    local entry = presence_registry[steam]
    if entry == nil then
        entry = { first_seen = now, last_seen = now }
        presence_registry[steam] = entry
    else
        entry.last_seen = now
    end
end

local function register_presence_hook()
    if RegisterHook == nil then
        log("[FATAL] RegisterHook is unavailable; player heartbeat could not start")
        return false
    end

    local ok, error_message = pcall(function()
        RegisterHook("/Script/TheIsle.TIPlayerController:SetAdminCred", function(controller_parameter, _admin_parameter)
            local controller = safe_get(function() return controller_parameter:get() end, nil)
            if not is_valid_object(controller) then return end
            local steam = controller_steam_id(controller)
            if steam ~= "" then presence_update(steam) end
        end)
    end)

    if not ok then
        log("[FATAL] SetAdminCred heartbeat hook failed: " .. tostring(error_message))
        return false
    end

    log("[Presence] SetAdminCred heartbeat hook registered")
    return true
end

local function seed_from_player_array(game_mode)
    if not is_valid_object(game_mode) then return 0 end
    local world = safe_get(function() return game_mode:GetWorld() end, nil)
    if not is_valid_object(world) then return 0 end
    local game_state = safe_get(function() return world.GameState end, nil)
    if not is_valid_object(game_state) then return 0 end
    local player_array = safe_get(function() return game_state.PlayerArray end, nil)
    if player_array == nil then return 0 end

    local seeded = 0
    pcall(function()
        player_array:ForEach(function(first, second)
            local player_state = second
            if not is_valid_object(player_state) and is_valid_object(first) then player_state = first end
            if not is_valid_object(player_state) then return end
            local controller = safe_get(function() return player_state:GetOwningController() end, nil)
            if not is_valid_object(controller) then return end
            local steam = controller_steam_id(controller)
            if steam == "" then return end
            presence_update(steam)
            seeded = seeded + 1
        end)
    end)
    return seeded
end

local function refresh_presence()
    if not config.enabled or os.time() < startup_at then return end
    local game_mode = find_game_mode()
    if not is_valid_object(game_mode) then return end

    seed_from_player_array(game_mode)
    local now = os.time()
    for steam, entry in pairs(presence_registry) do
        local controller = safe_get(function()
            return game_mode:GetControllerBySteamId(steam)
        end, nil)
        if not is_valid_object(controller) then
            presence_registry[steam] = nil
        else
            entry.last_seen = now
        end
    end
end

local function is_live_pteranodon(pawn)
    if not is_valid_object(pawn) then return false end
    local full_name = tostring(safe_get(function() return pawn:GetFullName() end, "")):lower()
    if full_name:find("pteranodon", 1, true) == nil then return false end
    if full_name:find("adminpawn", 1, true) ~= nil or full_name:find("spectator", 1, true) ~= nil then
        return false
    end
    local alive = safe_get(function() return pawn:GetIsAlive() end, nil)
    local dead = safe_get(function() return pawn.bIsDead end, false)
    return alive == true and dead ~= true
end

local function apply_stamina_recharge(pawn)
    local current = tonumber(safe_get(function() return pawn:GetStamina() end, nil))
    local maximum = tonumber(safe_get(function() return pawn:GetMaxStamina() end, nil))
    if not is_finite_number(current) or not is_finite_number(maximum) or maximum <= 0 or current < 0 then
        return false, "invalid"
    end

    if current >= maximum then return false, "full" end

    local delta = maximum * (config.recharge_percent_per_second / 100.0)
    local target = math.min(maximum, current + delta)
    if target <= current then return false, "unchanged" end

    local ok = pcall(function() pawn:SetStamina(target) end)
    if not ok then return false, "setter-failed" end
    return true, "modified"
end

local function registry_count()
    local count = 0
    for _steam, _entry in pairs(presence_registry) do count = count + 1 end
    return count
end

local function maybe_log_health(now)
    if (now - last_health_log_at) < HEALTH_LOG_INTERVAL_SECONDS then return end
    last_health_log_at = now
    log(string.format(
        "[HEALTH] online=%d ticks=%d pteranodons=%d modified=%d full=%d invalid=%d setterFailures=%d rate=%.3f%%/s",
        registry_count(), stats.ticks, stats.pteranodons, stats.modified,
        stats.already_full, stats.skipped_invalid, stats.setter_failures,
        config.recharge_percent_per_second
    ))
    stats = {
        ticks = 0,
        pteranodons = 0,
        modified = 0,
        already_full = 0,
        skipped_invalid = 0,
        setter_failures = 0
    }
end

local function stamina_tick()
    if not config.enabled or os.time() < startup_at then return end
    local game_mode = find_game_mode()
    if not is_valid_object(game_mode) then return end

    stats.ticks = stats.ticks + 1
    for steam, entry in pairs(presence_registry) do
        local controller = safe_get(function()
            return game_mode:GetControllerBySteamId(steam)
        end, nil)
        if not is_valid_object(controller) then
            presence_registry[steam] = nil
        else
            entry.last_seen = os.time()
            local pawn = live_pawn_from_controller(controller)
            if is_live_pteranodon(pawn) then
                stats.pteranodons = stats.pteranodons + 1
                local changed, reason = apply_stamina_recharge(pawn)
                if changed then
                    stats.modified = stats.modified + 1
                elseif reason == "full" then
                    stats.already_full = stats.already_full + 1
                elseif reason == "setter-failed" then
                    stats.setter_failures = stats.setter_failures + 1
                elseif reason == "invalid" then
                    stats.skipped_invalid = stats.skipped_invalid + 1
                end
            end
        end
    end
    maybe_log_health(os.time())
end

local presence_hook_ok = register_presence_hook()

if not config.enabled then
    log("disabled by configuration")
elseif not presence_hook_ok then
    log("[FATAL] mod disabled because the player heartbeat hook is unavailable")
elseif LoopInGameThreadWithDelay == nil then
    log("[FATAL] LoopInGameThreadWithDelay is unavailable")
else
    LoopInGameThreadWithDelay(PRESENCE_REFRESH_INTERVAL_MS, refresh_presence)
    LoopInGameThreadWithDelay(TICK_INTERVAL_MS, stamina_tick)
    log(string.format(
        "loaded version=%s rate=%.3f%% max-stamina/second tick=%dms startupDelay=%ds playerOnly=true aiAffected=false",
        VERSION, config.recharge_percent_per_second, TICK_INTERVAL_MS,
        config.startup_delay_seconds
    ))
end
