-- MesozoicWeatherController - custom EVRIMA weather state machine
-- Version: 0.1.5-alpha
-- Build marker: MESOZOIC_WEATHER_CONTROLLER_ALPHA_V0_1_5

local MOD_NAME = "MesozoicWeatherController"
local VERSION = "0.1.5-alpha"
local TICK_INTERVAL_MS = 1000
local NATIVE_GUARD_INTERVAL_SECONDS = 5
local RETRY_DELAY_SECONDS = 30
local VERIFY_DELAY_SECONDS = 5

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function safe_call(callback, fallback)
    local ok, value = pcall(callback)
    if ok and value ~= nil then return value end
    return fallback
end

local function unwrap(value)
    if value == nil then return nil end
    local inner = safe_call(function() return value:get() end, nil)
    if inner ~= nil then return inner end
    return value
end

local function is_valid_object(object)
    if object == nil then return false end
    local address = tonumber(safe_call(function() return object:GetAddress() end, 0)) or 0
    return address ~= 0
end

local function object_full_name(object)
    if not is_valid_object(object) then return "<invalid>" end
    return tostring(safe_call(function() return object:GetFullName() end, "<unknown>"))
end

local function resolve_mod_root()
    local fallback = "Mods/MesozoicWeatherController"
    if debug == nil or debug.getinfo == nil then return fallback end
    local info = safe_call(function() return debug.getinfo(1, "S") end, nil)
    if info == nil or info.source == nil then return fallback end
    local source = tostring(info.source):gsub("^@", ""):gsub("\\", "/")
    return source:match("^(.*)/[Ss]cripts/main%.lua$") or fallback
end

local MOD_ROOT = resolve_mod_root()
local CONFIG_PATH = MOD_ROOT .. "/config/WeatherController.ini"
local EVENT_PATH = MOD_ROOT .. "/Saved/weather_controller_events.ndjson"
local STATUS_PATH = MOD_ROOT .. "/Saved/weather_controller_status.json"

local config = {
    enabled = true,
    clear_min_minutes = 10,
    clear_max_minutes = 15,
    stage_min_minutes = 3,
    stage_max_minutes = 6,
    transition_duration_seconds = 2,
    startup_delay_seconds = 20
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
        elseif line ~= "" and section == "weathercontroller" then
            local key, value = line:match("^([^=]+)=(.*)$")
            if key ~= nil then values[trim(key):lower()] = trim(value) end
        end
    end
    file:close()

    local enabled = parse_boolean(values.enabled)
    if enabled ~= nil then config.enabled = enabled end

    local numeric_keys = {
        clearminminutes = "clear_min_minutes",
        clearmaxminutes = "clear_max_minutes",
        stageminminutes = "stage_min_minutes",
        stagemaxminutes = "stage_max_minutes",
        transitiondurationseconds = "transition_duration_seconds",
        startupdelayseconds = "startup_delay_seconds"
    }
    for key, field in pairs(numeric_keys) do
        local parsed = tonumber(values[key])
        if parsed ~= nil then config[field] = parsed end
    end

    config.clear_min_minutes = math.max(1, math.floor(config.clear_min_minutes))
    config.clear_max_minutes = math.max(config.clear_min_minutes, math.floor(config.clear_max_minutes))
    config.stage_min_minutes = math.max(1, math.floor(config.stage_min_minutes))
    config.stage_max_minutes = math.max(config.stage_min_minutes, math.floor(config.stage_max_minutes))
    config.transition_duration_seconds = math.max(0, math.min(60, config.transition_duration_seconds))
    config.startup_delay_seconds = math.max(5, math.floor(config.startup_delay_seconds))
end

load_config()

local PRESETS = {
    clear = {
        label = "Clear Sky",
        intensity = 0,
        path = "/Game/UltraDynamicSky/Blueprints/Weather_Effects/Weather_Presets/Clear_Skies.Clear_Skies"
    },
    cloudy = {
        label = "Cloudy",
        intensity = 0,
        path = "/Game/TheIsle/Maps/Developer/Biomes2Assets/Other/Sky/Weather/Cloudy_Island.Cloudy_Island"
    },
    foggy = {
        label = "Foggy",
        intensity = 0,
        path = "/Game/TheIsle/Maps/Developer/Biomes2Assets/Other/Sky/Weather/Foggy_Island.Foggy_Island"
    },
    light_rain = {
        label = "Light Rain",
        intensity = 1,
        path = "/Game/TheIsle/Maps/Developer/Biomes2Assets/Other/Sky/Weather/Rain_Light_Island.Rain_Light_Island"
    },
    rain = {
        label = "Rain",
        intensity = 2,
        path = "/Game/TheIsle/Maps/Developer/Biomes2Assets/Other/Sky/Weather/Rain_Island.Rain_Island"
    },
    rain_extension = {
        label = "Rain Extension",
        intensity = 2,
        path = "/Game/TheIsle/Maps/Developer/Biomes2Assets/Other/Sky/Weather/Rain_Island.Rain_Island"
    }
}

local function json_escape(value)
    local escaped = tostring(value or "")
    escaped = escaped:gsub("\\", "\\\\"):gsub('"', '\\"')
    escaped = escaped:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
    return escaped
end

local function json_value(value)
    local kind = type(value)
    if kind == "string" then return '"' .. json_escape(value) .. '"' end
    if kind == "number" then return string.format("%.17g", value) end
    if kind == "boolean" then return value and "true" or "false" end
    return "null"
end

local EVENT_KEYS = {
    "schemaVersion", "build", "timestamp", "timestampUtc", "event", "phase",
    "weather", "presetPath", "intensity", "delaySeconds", "nextActionAt",
    "nextActionUtc", "roll", "success", "reason", "actualWeather",
    "actualIntensity", "transitionMethod", "transitionActive",
    "transitionTimer", "note"
}

local function encode_object(values)
    local fields = {}
    for _, key in ipairs(EVENT_KEYS) do
        if values[key] ~= nil then
            fields[#fields + 1] = '"' .. key .. '":' .. json_value(values[key])
        end
    end
    return "{" .. table.concat(fields, ",") .. "}"
end

local function append_event(values)
    values.schemaVersion = 1
    values.build = VERSION
    values.timestamp = os.time()
    values.timestampUtc = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local file, error_message = io.open(EVENT_PATH, "a")
    if file == nil then
        log("[ERROR] event log open failed: " .. tostring(error_message))
        return false
    end
    file:write(encode_object(values), "\n")
    file:flush()
    file:close()
    return true
end

local phase = "startup"
local current_weather = "unknown"
local next_action_at = 0
local retry_transition = nil
local pending_verification = nil
local next_native_guard_at = 0
local initialized = false
local startup_at = os.time() + config.startup_delay_seconds

local function utc_from_epoch(epoch)
    if epoch == nil or epoch <= 0 then return "" end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

local function write_status(note)
    local values = {
        schemaVersion = 1,
        build = VERSION,
        timestamp = os.time(),
        timestampUtc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        event = "status",
        phase = phase,
        weather = current_weather,
        nextActionAt = next_action_at,
        nextActionUtc = utc_from_epoch(next_action_at),
        note = note or ""
    }
    local file, error_message = io.open(STATUS_PATH, "w")
    if file == nil then
        log("[ERROR] status write failed: " .. tostring(error_message))
        return
    end
    file:write(encode_object(values), "\n")
    file:flush()
    file:close()
end

local function find_weather_actor()
    if FindAllOf ~= nil then
        local actors = safe_call(function() return FindAllOf("TIWeatherActor") end, nil)
        if type(actors) == "table" then
            local fallback = nil
            for _, candidate in ipairs(actors) do
                candidate = unwrap(candidate)
                if is_valid_object(candidate) then
                    local name = object_full_name(candidate)
                    if name:find("PersistentLevel", 1, true) ~= nil then return candidate end
                    if fallback == nil and name:find("Default__", 1, true) == nil then fallback = candidate end
                end
            end
            if fallback ~= nil then return fallback end
        end
    end

    if FindFirstOf == nil then return nil end
    local actor = unwrap(safe_call(function() return FindFirstOf("TIWeatherActor") end, nil))
    if is_valid_object(actor) and object_full_name(actor):find("Default__", 1, true) == nil then return actor end
    return nil
end

local function find_preset(path)
    local preset = nil
    if StaticFindObject ~= nil then
        preset = unwrap(safe_call(function() return StaticFindObject(path) end, nil))
    end
    if not is_valid_object(preset) and FindObject ~= nil then
        preset = unwrap(safe_call(function() return FindObject(nil, nil, path, false) end, nil))
    end
    if is_valid_object(preset) then return preset end

    -- StaticFindObject and FindObject only see assets that are already resident
    -- in UObject memory. Presets are not guaranteed to be preloaded by Gateway,
    -- so request the package on demand and then resolve its object.
    -- UE4SS LoadAsset expects the package path without the trailing .ObjectName.
    if LoadAsset ~= nil then
        local asset_path = tostring(path):gsub("%.[^%./]+$", "")
        local loaded = nil
        local load_ok, load_error = pcall(function()
            loaded = LoadAsset(asset_path)
        end)
        loaded = unwrap(loaded)
        if is_valid_object(loaded) then return loaded end
        if not load_ok then
            log(string.format(
                "[PRESET_LOAD] asset=%s failed=%s",
                asset_path,
                tostring(load_error)
            ))
        end

        if StaticFindObject ~= nil then
            preset = unwrap(safe_call(function() return StaticFindObject(path) end, nil))
        end
        if not is_valid_object(preset) and FindObject ~= nil then
            preset = unwrap(safe_call(function() return FindObject(nil, nil, path, false) end, nil))
        end
        if is_valid_object(preset) then
            log("[PRESET_LOAD] loaded on demand: " .. asset_path)
            return preset
        end
    end

    return nil
end

local function current_actor_weather(actor)
    local weather = unwrap(safe_call(function() return actor.Weather end, nil))
    return object_full_name(weather)
end

local function current_actor_intensity(actor)
    return tonumber(safe_call(function() return actor.RainIntensityValue end, nil))
end

local function current_transition_active(actor)
    return safe_call(function() return actor["Transition Active"] == true end, false)
end

local function current_transition_timer(actor)
    return tonumber(safe_call(function() return actor["Transition Timer"] end, nil))
end

local function disable_native_random(actor, reason)
    if not is_valid_object(actor) then return false end
    local before = safe_call(function() return actor.bRandomWeatherEnabled == true end, nil)
    local ok, error_message = pcall(function()
        -- The Isle's native scheduler uses the inherited flag. UDW's own random
        -- variation has a separate runtime state, so force that back to static
        -- as well. Change Weather also selects static mode, but the guard keeps
        -- both layers disabled if the game reinitializes either one.
        actor.bRandomWeatherEnabled = false
        actor["Begin Play Weather is Random"] = false
        actor["Random Weather Variation State"] = 0
    end)
    local after = safe_call(function() return actor.bRandomWeatherEnabled == false end, false)
    if (not ok) or (not after) then
        append_event({
            event = "native-random-disable-failed",
            phase = phase,
            success = false,
            reason = reason,
            note = tostring(error_message or "verification-failed")
        })
        return false
    end
    if before == true then
        log("[GUARD] native random weather disabled reason=" .. tostring(reason))
        append_event({ event = "native-random-disabled", phase = phase, success = true, reason = reason })
    end
    return true
end

local function invoke_change_weather(actor, preset, duration)
    -- UDW exposes this Blueprint function with a spaced display name in some
    -- builds and a compact reflected name in others. Use the real function
    -- whenever it is available so the transition state is replicated to
    -- clients, rather than only changing the server-side Weather pointer.
    local names = { "Change Weather", "ChangeWeather" }
    local last_error = "function-unavailable"
    for _, name in ipairs(names) do
        local callback = safe_call(function() return actor[name] end, nil)
        if callback ~= nil then
            local ok, error_message = pcall(callback, actor, preset, duration)
            if ok then return true, "native:" .. name end
            last_error = tostring(error_message)
        end
    end
    return false, last_error
end

local function start_transition_fallback(actor, preset, duration)
    -- Compatibility path for builds that do not expose the Blueprint function
    -- to UE4SS. These are the exact transition fields observed while using the
    -- in-game weather panel; setting Weather alone does not start a transition.
    local ok, error_message = pcall(function()
        actor["Transition Duration"] = duration
        actor["Transition Timer"] = 0
        actor["Transition Alpha"] = 0
        actor.Weather = preset
        actor["Transition Active"] = true
        if actor.ForceNetUpdate ~= nil then actor:ForceNetUpdate() end
    end)
    if ok then return true, "observed-fields" end
    return false, tostring(error_message)
end

local function apply_weather(weather_key, reason, verification_attempt)
    local target = PRESETS[weather_key]
    if target == nil then return false, "unknown-weather-key" end

    local actor = find_weather_actor()
    if not is_valid_object(actor) then return false, "weather-actor-unavailable" end
    local preset = find_preset(target.path)
    if not is_valid_object(preset) then return false, "preset-unavailable:" .. target.path end

    disable_native_random(actor, "weather-change")

    local native_ok, transition_method = invoke_change_weather(
        actor,
        preset,
        config.transition_duration_seconds
    )
    if native_ok then
        local native_weather = current_actor_weather(actor)
        local native_active = current_transition_active(actor)
        if native_weather:find(target.path, 1, true) == nil and not native_active then
            native_ok = false
            transition_method = transition_method .. ":no-state-change"
        end
    end
    if not native_ok then
        local fallback_ok, fallback_method = start_transition_fallback(
            actor,
            preset,
            config.transition_duration_seconds
        )
        if not fallback_ok then
            return false, "weather-transition-failed:native=" .. tostring(transition_method) ..
                ";fallback=" .. tostring(fallback_method)
        end
        transition_method = fallback_method
    end

    local intensity_ok, intensity_error = pcall(function()
        actor:SetRainIntensity(target.intensity)
    end)
    if not intensity_ok then
        return false, "rain-intensity-write-failed:" .. tostring(intensity_error)
    end

    disable_native_random(actor, "post-weather-change")

    local actual_weather = current_actor_weather(actor)
    local actual_intensity = current_actor_intensity(actor)
    local transition_active = current_transition_active(actor)
    local transition_timer = current_transition_timer(actor)
    local weather_ok = actual_weather:find(target.path, 1, true) ~= nil or transition_active
    local intensity_ok = actual_intensity == nil or actual_intensity == target.intensity
    local success = weather_ok and intensity_ok

    append_event({
        event = "weather-change",
        phase = phase,
        weather = target.label,
        presetPath = target.path,
        intensity = target.intensity,
        success = success,
        reason = reason,
        actualWeather = actual_weather,
        actualIntensity = actual_intensity,
        transitionMethod = transition_method,
        transitionActive = transition_active,
        transitionTimer = transition_timer,
        note = verification_attempt and "verification-retry" or ""
    })

    if not success then
        return false, "immediate-verification-failed"
    end

    current_weather = weather_key
    pending_verification = {
        weather_key = weather_key,
        due_at = os.time() + VERIFY_DELAY_SECONDS,
        attempts = verification_attempt and 2 or 1
    }
    log(string.format(
        "[WEATHER] %s reason=%s intensity=%d transition=%.1fs method=%s active=%s",
        target.label, tostring(reason), target.intensity, config.transition_duration_seconds,
        tostring(transition_method), tostring(transition_active)
    ))
    return true, "ok"
end

local function random_seconds(minimum_minutes, maximum_minutes)
    return math.random(math.floor(minimum_minutes * 60), math.floor(maximum_minutes * 60))
end

local function clear_delay()
    return random_seconds(config.clear_min_minutes, config.clear_max_minutes)
end

local function stage_delay()
    return random_seconds(config.stage_min_minutes, config.stage_max_minutes)
end

local function schedule_phase(new_phase, delay_seconds, reason)
    phase = new_phase
    next_action_at = os.time() + delay_seconds
    append_event({
        event = "phase-scheduled",
        phase = phase,
        weather = current_weather,
        delaySeconds = delay_seconds,
        nextActionAt = next_action_at,
        nextActionUtc = utc_from_epoch(next_action_at),
        reason = reason,
        success = true
    })
    write_status(reason)
    log(string.format(
        "[SCHEDULE] phase=%s weather=%s delay=%ds next=%s reason=%s",
        phase, current_weather, delay_seconds, utc_from_epoch(next_action_at), tostring(reason)
    ))
end

local function transition_to(weather_key, new_phase, delay_seconds, reason)
    local ok, error_message = apply_weather(weather_key, reason, false)
    if ok then
        retry_transition = nil
        schedule_phase(new_phase, delay_seconds, reason)
        return true
    end

    retry_transition = {
        weather_key = weather_key,
        new_phase = new_phase,
        delay_seconds = delay_seconds,
        reason = reason
    }
    next_action_at = os.time() + RETRY_DELAY_SECONDS
    append_event({
        event = "transition-deferred",
        phase = phase,
        weather = weather_key,
        delaySeconds = RETRY_DELAY_SECONDS,
        nextActionAt = next_action_at,
        nextActionUtc = utc_from_epoch(next_action_at),
        success = false,
        reason = error_message
    })
    write_status(error_message)
    log("[RETRY] target=" .. weather_key .. " reason=" .. tostring(error_message))
    return false
end

local function retry_deferred_transition()
    local retry = retry_transition
    if retry == nil then return false end
    return transition_to(
        retry.weather_key,
        retry.new_phase,
        retry.delay_seconds,
        retry.reason
    )
end

local function verify_pending_weather(now)
    local verification = pending_verification
    if verification == nil or now < verification.due_at then return end
    pending_verification = nil

    local target = PRESETS[verification.weather_key]
    local actor = find_weather_actor()
    local actual_weather = is_valid_object(actor) and current_actor_weather(actor) or "<actor-unavailable>"
    local actual_intensity = is_valid_object(actor) and current_actor_intensity(actor) or nil
    local transition_active = is_valid_object(actor) and current_transition_active(actor) or false
    local transition_timer = is_valid_object(actor) and current_transition_timer(actor) or nil
    local success = is_valid_object(actor) and
        actual_weather:find(target.path, 1, true) ~= nil and
        (actual_intensity == nil or actual_intensity == target.intensity)

    append_event({
        event = "weather-verified",
        phase = phase,
        weather = target.label,
        presetPath = target.path,
        intensity = target.intensity,
        actualWeather = actual_weather,
        actualIntensity = actual_intensity,
        transitionActive = transition_active,
        transitionTimer = transition_timer,
        success = success,
        note = "attempt=" .. tostring(verification.attempts)
    })

    if success then return end
    if verification.attempts < 2 then
        log("[VERIFY] retrying target=" .. verification.weather_key)
        apply_weather(verification.weather_key, "verification-retry", true)
    else
        log("[VERIFY][FAILED] target=" .. verification.weather_key .. " actual=" .. actual_weather)
    end
end

local function advance_phase()
    if retry_transition ~= nil then
        retry_deferred_transition()
        return
    end

    if phase == "clear" then
        local roll = math.random(1, 2)
        append_event({ event = "weather-roll", phase = phase, roll = roll, note = "1=remain-clear,2=cloudy" })
        if roll == 1 then
            schedule_phase("clear", clear_delay(), "clear-roll-remain-clear")
        else
            transition_to("cloudy", "cloudy_decision", stage_delay(), "clear-roll-cloudy")
        end
        return
    end

    if phase == "cloudy_decision" then
        local roll = math.random(1, 3)
        append_event({ event = "weather-roll", phase = phase, roll = roll, note = "1=clear,2=foggy,3=light-rain" })
        if roll == 1 then
            transition_to("clear", "clear", clear_delay(), "cloudy-roll-clear")
        elseif roll == 2 then
            transition_to("foggy", "foggy", stage_delay(), "cloudy-roll-foggy")
        else
            transition_to("light_rain", "light_decision", stage_delay(), "cloudy-roll-light-rain")
        end
        return
    end

    if phase == "foggy" then
        transition_to("cloudy", "cloudy_recovery", stage_delay(), "foggy-recovery-cloudy")
        return
    end

    if phase == "cloudy_recovery" then
        transition_to("clear", "clear", clear_delay(), "cloudy-recovery-clear")
        return
    end

    if phase == "light_decision" then
        local roll = math.random(1, 3)
        append_event({ event = "weather-roll", phase = phase, roll = roll, note = "1=cloudy,2-3=rain" })
        if roll == 1 then
            transition_to("cloudy", "cloudy_recovery", stage_delay(), "light-rain-roll-cloudy")
        else
            transition_to("rain", "rain_decision", stage_delay(), "light-rain-roll-rain")
        end
        return
    end

    if phase == "rain_decision" then
        local roll = math.random(1, 2)
        append_event({ event = "weather-roll", phase = phase, roll = roll, note = "1=light-rain,2=rain-extension" })
        if roll == 1 then
            transition_to("light_rain", "light_recovery", stage_delay(), "rain-roll-light-rain")
        else
            transition_to("rain_extension", "rain_extension", stage_delay(), "rain-roll-extension")
        end
        return
    end

    if phase == "rain_extension" then
        transition_to("light_rain", "light_recovery", stage_delay(), "rain-extension-recovery-light-rain")
        return
    end

    if phase == "light_recovery" then
        transition_to("cloudy", "cloudy_recovery", stage_delay(), "light-rain-recovery-cloudy")
        return
    end

    log("[ERROR] unknown phase=" .. tostring(phase) .. "; recovering to Clear Sky")
    transition_to("clear", "clear", clear_delay(), "unknown-phase-recovery")
end

local function guard_native_random(now)
    if now < next_native_guard_at then return end
    next_native_guard_at = now + NATIVE_GUARD_INTERVAL_SECONDS
    local actor = find_weather_actor()
    if not is_valid_object(actor) then return end
    disable_native_random(actor, "periodic-guard")

    -- A pending native random-weather timer can survive a flag change. Detect
    -- any preset drift and immediately restore the state-machine's weather.
    if initialized and pending_verification == nil and PRESETS[current_weather] ~= nil then
        local expected = PRESETS[current_weather]
        local actual = current_actor_weather(actor)
        if actual:find(expected.path, 1, true) == nil then
            append_event({
                event = "native-weather-drift",
                phase = phase,
                weather = expected.label,
                presetPath = expected.path,
                actualWeather = actual,
                success = false,
                reason = "periodic-guard"
            })
            apply_weather(current_weather, "native-drift-correction", false)
        end
    end
end

local function controller_tick()
    if not config.enabled then return end
    local now = os.time()
    guard_native_random(now)
    verify_pending_weather(now)

    if not initialized then
        if now < startup_at then return end
        if retry_transition ~= nil and now < next_action_at then return end
        local started = false
        if retry_transition ~= nil then
            started = retry_deferred_transition()
        else
            started = transition_to("clear", "clear", clear_delay(), "startup-clear")
        end
        if started then
            initialized = true
            append_event({ event = "controller-started", phase = phase, weather = current_weather, success = true })
        end
        return
    end

    if now >= next_action_at then advance_phase() end
end

math.randomseed(os.time())
math.random()
math.random()
math.random()

append_event({
    event = "controller-loaded",
    phase = phase,
    success = config.enabled,
    note = string.format(
        "enabled=%s clear=%d-%dm stage=%d-%dm transition=%.1fs",
        tostring(config.enabled), config.clear_min_minutes, config.clear_max_minutes,
        config.stage_min_minutes, config.stage_max_minutes, config.transition_duration_seconds
    )
})

if not config.enabled then
    log("disabled by configuration")
elseif LoopInGameThreadWithDelay == nil then
    log("[FATAL] LoopInGameThreadWithDelay is unavailable")
    append_event({ event = "controller-failed", phase = phase, success = false, reason = "timer-api-unavailable" })
else
    LoopInGameThreadWithDelay(TICK_INTERVAL_MS, controller_tick)
    log(string.format(
        "loaded version=%s clearRoll=50/50 cloudyRoll=1/3 each stage=%d-%dm clear=%d-%dm",
        VERSION, config.stage_min_minutes, config.stage_max_minutes,
        config.clear_min_minutes, config.clear_max_minutes
    ))
end
