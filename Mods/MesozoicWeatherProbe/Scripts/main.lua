-- MesozoicWeatherProbe - observation-only EVRIMA weather probe
-- Version: 0.2.0-alpha
-- Build marker: MESOZOIC_WEATHER_PROBE_ALPHA_V0_2_0_READ_ONLY
--
-- This mod observes native weather calls and writes primitive diagnostic data.
-- It never calls SetWeather, SetClearSky, SetRainIntensity, or any other
-- gameplay-mutating function.

local MOD_NAME = "MesozoicWeatherProbe"
local VERSION = "0.2.0-alpha-read-only"
local SCHEMA_VERSION = 2
local DRAIN_INTERVAL_MS = 1000
local WEATHER_STATE_POLL_INTERVAL_MS = 1000
local MAX_PENDING_EVENTS = 5000

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function safe_call(callback, fallback)
    local ok, value = pcall(callback)
    if ok and value ~= nil then return value end
    return fallback
end

local function unwrap(parameter)
    if parameter == nil then return nil end
    local value = safe_call(function() return parameter:get() end, nil)
    if value ~= nil then return value end
    return parameter
end

local function value_as_number(parameter)
    local value = unwrap(parameter)
    if type(value) == "number" then return value end
    return tonumber(value)
end

local function is_valid_object(object)
    if object == nil then return false end
    local address = safe_call(function() return object:GetAddress() end, nil)
    return address ~= nil and tonumber(address) ~= 0
end

local function object_from_context(context)
    local object = unwrap(context)
    if is_valid_object(object) then return object end
    return nil
end

local function object_full_name(object)
    if not is_valid_object(object) then return "<invalid>" end
    return tostring(safe_call(function() return object:GetFullName() end, "<unknown>"))
end

local function object_class_name(object)
    if not is_valid_object(object) then return "<invalid>" end
    local class_object = safe_call(function() return object:GetClass() end, nil)
    if not is_valid_object(class_object) then return "<unknown>" end
    return tostring(safe_call(function() return class_object:GetFullName() end, "<unknown>"))
end

local function object_address(object)
    if not is_valid_object(object) then return "0x0" end
    local address = tonumber(safe_call(function() return object:GetAddress() end, 0)) or 0
    return string.format("0x%X", address)
end

local function resolve_mod_root()
    local fallback = "Mods/MesozoicWeatherProbe"
    if debug == nil or debug.getinfo == nil then return fallback end
    local info = safe_call(function() return debug.getinfo(1, "S") end, nil)
    if info == nil or info.source == nil then return fallback end
    local source = tostring(info.source):gsub("^@", ""):gsub("\\", "/")
    return source:match("^(.*)/[Ss]cripts/main%.lua$") or fallback
end

local MOD_ROOT = resolve_mod_root()
local EVENT_PATH = MOD_ROOT .. "/Saved/weather_state_probe_events.ndjson"
local pending_events = {}
local event_sequence = 0
local session_id = tostring(os.time())
local last_dedup = {}
local queue_overflow_logged = false

local function json_escape(value)
    local escaped = tostring(value or "")
    escaped = escaped:gsub("\\", "\\\\")
    escaped = escaped:gsub('"', '\\"')
    escaped = escaped:gsub("\r", "\\r")
    escaped = escaped:gsub("\n", "\\n")
    escaped = escaped:gsub("\t", "\\t")
    return escaped
end

local function json_value(value)
    local kind = type(value)
    if kind == "string" then return '"' .. json_escape(value) .. '"' end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        return string.format("%.17g", value)
    end
    if kind == "boolean" then return value and "true" or "false" end
    return "null"
end

local EVENT_KEY_ORDER = {
    "schemaVersion", "build", "sessionId", "sequence", "timestamp",
    "timestampUtc", "event", "hook", "phase", "contextFullName",
    "contextClass", "contextAddress", "adminFullName", "adminClass",
    "adminAddress", "adminSteamId", "weatherFullName", "weatherClass",
    "weatherAddress", "requestedIntensity", "beforeIntensity",
    "afterIntensity", "rainIntensityValue", "randomWeatherEnabled",
    "minWeatherInterval", "maxWeatherInterval", "actorFullName",
    "actorClass", "propertyOwner", "propertyName", "propertyType",
    "propertyOffset", "previousValue", "currentValue", "snapshotKind",
    "propertiesRead", "propertiesChanged", "note"
}

local function encode_event(event)
    local fields = {}
    for _, key in ipairs(EVENT_KEY_ORDER) do
        local value = event[key]
        if value ~= nil then
            fields[#fields + 1] = '"' .. key .. '":' .. json_value(value)
        end
    end
    return "{" .. table.concat(fields, ",") .. "}"
end

local function append_line(path, line)
    local file, open_error = io.open(path, "a")
    if file == nil then return false, tostring(open_error or "open-failed") end
    file:write(line, "\n")
    file:flush()
    file:close()
    return true, nil
end

local function add_base_fields(event)
    event_sequence = event_sequence + 1
    event.schemaVersion = SCHEMA_VERSION
    event.build = VERSION
    event.sessionId = session_id
    event.sequence = event_sequence
    event.timestamp = os.time()
    event.timestampUtc = os.date("!%Y-%m-%dT%H:%M:%SZ")
    return event
end

local function queue_event(event, dedup_key)
    local now = os.time()
    if dedup_key ~= nil then
        local previous = last_dedup[dedup_key]
        if previous ~= nil and (now - previous) < 1 then return end
        last_dedup[dedup_key] = now
    end

    if #pending_events >= MAX_PENDING_EVENTS then
        if not queue_overflow_logged then
            queue_overflow_logged = true
            log("[WARNING] event queue reached its safety cap; extra duplicate activity is being dropped")
        end
        return
    end

    local captured = add_base_fields(event)
    pending_events[#pending_events + 1] = captured
    log(string.format(
        "[OBSERVED] seq=%d event=%s phase=%s requested=%s before=%s after=%s weather=%s",
        captured.sequence,
        tostring(captured.event),
        tostring(captured.phase or "-"),
        tostring(captured.requestedIntensity or "-"),
        tostring(captured.beforeIntensity or "-"),
        tostring(captured.afterIntensity or "-"),
        tostring(captured.weatherFullName or "-")
    ))
end

local function drain_events()
    if #pending_events == 0 then return end
    local batch = pending_events
    pending_events = {}
    queue_overflow_logged = false

    for index, event in ipairs(batch) do
        local written, write_error = append_line(EVENT_PATH, encode_event(event))
        if not written then
            log("[ERROR] could not write event file: " .. tostring(write_error))
            for remaining = index, #batch do
                if #pending_events < MAX_PENDING_EVENTS then
                    pending_events[#pending_events + 1] = batch[remaining]
                end
            end
            return
        end
    end
end

local function controller_fields(controller)
    if not is_valid_object(controller) then
        return {
            adminFullName = "<none>",
            adminClass = "<none>",
            adminAddress = "0x0",
            adminSteamId = ""
        }
    end
    local steam = safe_call(function()
        local steam_id = controller:GetSteamId()
        if steam_id == nil then return "" end
        return steam_id:ToString()
    end, "")
    return {
        adminFullName = object_full_name(controller),
        adminClass = object_class_name(controller),
        adminAddress = object_address(controller),
        adminSteamId = tostring(steam or "")
    }
end

local function context_fields(context_object)
    return {
        contextFullName = object_full_name(context_object),
        contextClass = object_class_name(context_object),
        contextAddress = object_address(context_object)
    }
end

local function merge_fields(target, source)
    for key, value in pairs(source or {}) do target[key] = value end
    return target
end

local function weather_actor_fields(actor)
    local fields = context_fields(actor)
    fields.beforeIntensity = value_as_number(safe_call(function()
        return actor.RainIntensityValue
    end, nil))
    fields.rainIntensityValue = value_as_number(safe_call(function()
        return actor.RainIntensityValue
    end, nil))
    fields.randomWeatherEnabled = safe_call(function()
        return actor.bRandomWeatherEnabled == true
    end, nil)
    fields.minWeatherInterval = value_as_number(safe_call(function()
        return actor.MinWeatherInterval
    end, nil))
    fields.maxWeatherInterval = value_as_number(safe_call(function()
        return actor.MaxWeatherInterval
    end, nil))
    return fields
end

-- The native weather actor only exposes the rain level directly. The actual
-- Gateway weather actor is a Blueprint subclass, so this read-only sampler
-- records its primitive Blueprint properties and writes only changes after the
-- first snapshot. UObject references are converted to names and never retained.
local weather_property_state = {}
local weather_actor_identity = nil
local weather_actor_missing_logged = false

local SUPPORTED_PROPERTY_TYPES = {
    Int8Property = true,
    Int16Property = true,
    IntProperty = true,
    Int64Property = true,
    UInt16Property = true,
    UInt32Property = true,
    UInt64Property = true,
    FloatProperty = true,
    DoubleProperty = true,
    ByteProperty = true,
    BoolProperty = true,
    NameProperty = true,
    StrProperty = true,
    TextProperty = true,
    EnumProperty = true,
    ObjectProperty = true,
    ClassProperty = true,
    WeakObjectProperty = true,
    SoftObjectProperty = true,
    ArrayProperty = true
}

local function property_type_name(property)
    return tostring(safe_call(function()
        return property:GetClass():GetFName():ToString()
    end, "<unknown>"))
end

local function property_name(property)
    return tostring(safe_call(function()
        return property:GetFName():ToString()
    end, "<unknown>"))
end

local function property_offset(property)
    return value_as_number(safe_call(function()
        return property:GetOffset_Internal()
    end, nil))
end

local function stringify_property_value(actor, property, name, kind)
    if not SUPPORTED_PROPERTY_TYPES[kind] then return nil end
    local raw = safe_call(function() return actor[name] end, nil)
    if raw == nil then return "<nil>" end

    if kind == "BoolProperty" then
        return raw == true and "true" or "false"
    end

    if kind == "Int8Property" or kind == "Int16Property" or
       kind == "IntProperty" or kind == "Int64Property" or
       kind == "UInt16Property" or kind == "UInt32Property" or
       kind == "UInt64Property" or kind == "FloatProperty" or
       kind == "DoubleProperty" or kind == "ByteProperty" then
        local number = value_as_number(raw)
        if number == nil then return tostring(raw) end
        return string.format("%.17g", number)
    end

    if kind == "EnumProperty" then
        local number = value_as_number(raw)
        if number == nil then return tostring(raw) end
        local enum_name = safe_call(function()
            return property:GetEnum():GetNameByValue(number):ToString()
        end, "<unknown>")
        return tostring(enum_name) .. "(" .. string.format("%.17g", number) .. ")"
    end

    if kind == "NameProperty" or kind == "StrProperty" or kind == "TextProperty" then
        return tostring(safe_call(function() return raw:ToString() end, raw))
    end

    if kind == "ObjectProperty" or kind == "ClassProperty" or
       kind == "WeakObjectProperty" or kind == "SoftObjectProperty" then
        local object = unwrap(raw)
        if is_valid_object(object) then return object_full_name(object) end
        return tostring(raw)
    end

    if kind == "ArrayProperty" then
        local count = value_as_number(safe_call(function() return raw:GetArrayNum() end, nil))
        if count ~= nil then return "count=" .. tostring(count) end
        return tostring(raw)
    end

    return nil
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
                    if fallback == nil and name:find("Default__", 1, true) == nil then
                        fallback = candidate
                    end
                end
            end
            if fallback ~= nil then return fallback end
        end
    end

    if FindFirstOf == nil then return nil end
    local actor = unwrap(safe_call(function() return FindFirstOf("TIWeatherActor") end, nil))
    if is_valid_object(actor) and object_full_name(actor):find("Default__", 1, true) == nil then
        return actor
    end
    return nil
end

local function sample_weather_properties()
    local actor = find_weather_actor()
    if actor == nil then
        if not weather_actor_missing_logged then
            weather_actor_missing_logged = true
            queue_event({
                event = "weather-actor-unavailable",
                phase = "poll",
                note = "FindFirstOf(TIWeatherActor) did not return a valid live actor."
            })
        end
        return
    end

    weather_actor_missing_logged = false
    local actor_name = object_full_name(actor)
    local actor_class = object_class_name(actor)
    local actor_key = actor_name .. "|" .. actor_class
    local first_snapshot = weather_actor_identity ~= actor_key
    if first_snapshot then
        weather_actor_identity = actor_key
        weather_property_state = {}
        queue_event({
            event = "weather-actor-found",
            phase = "poll",
            actorFullName = actor_name,
            actorClass = actor_class,
            snapshotKind = "initial"
        })
    end

    local owner = safe_call(function() return actor:GetClass() end, nil)
    local properties_read = 0
    local properties_changed = 0
    local owners_visited = 0

    while is_valid_object(owner) and owners_visited < 8 do
        owners_visited = owners_visited + 1
        local owner_name = object_full_name(owner)

        safe_call(function()
            owner:ForEachProperty(function(property)
                local name = property_name(property)
                local kind = property_type_name(property)
                local current = stringify_property_value(actor, property, name, kind)
                if current == nil then return end

                properties_read = properties_read + 1
                local state_key = owner_name .. "|" .. name
                local previous = weather_property_state[state_key]
                if previous == nil or previous ~= current then
                    properties_changed = properties_changed + 1
                    weather_property_state[state_key] = current
                    queue_event({
                        event = previous == nil and "weather-property-snapshot" or "weather-property-changed",
                        phase = "poll",
                        actorFullName = actor_name,
                        actorClass = actor_class,
                        propertyOwner = owner_name,
                        propertyName = name,
                        propertyType = kind,
                        propertyOffset = property_offset(property),
                        previousValue = previous,
                        currentValue = current,
                        snapshotKind = previous == nil and "initial" or "change"
                    })
                end
            end)
            return true
        end, false)

        if owner_name:find("/Script/TheIsle.TIWeatherActor", 1, true) ~= nil then break end
        owner = safe_call(function() return owner:GetSuperStruct() end, nil)
    end

    if first_snapshot then
        queue_event({
            event = "weather-property-snapshot-complete",
            phase = "poll",
            actorFullName = actor_name,
            actorClass = actor_class,
            propertiesRead = properties_read,
            propertiesChanged = properties_changed,
            snapshotKind = "initial"
        })
    end
end

local function register_hook(path, pre_callback, post_callback, label)
    local ok, pre_id, post_id = pcall(function()
        return RegisterHook(path, pre_callback, post_callback)
    end)
    if ok then
        log(string.format("[HOOK] %s registered pre=%s post=%s", label, tostring(pre_id), tostring(post_id)))
        queue_event({
            event = "hook-registered",
            hook = path,
            phase = "startup",
            note = label
        })
        return true
    end
    log(string.format("[HOOK][FAILED] %s error=%s", label, tostring(pre_id)))
    queue_event({
        event = "hook-registration-failed",
        hook = path,
        phase = "startup",
        note = label .. ": " .. tostring(pre_id)
    })
    return false
end

local set_weather_path = "/Script/TheIsle.TIGameModeBase:SetWeather"
register_hook(
    set_weather_path,
    function(context, admin_controller_parameter, weather_parameter)
        local game_mode = object_from_context(context)
        local admin_controller = unwrap(admin_controller_parameter)
        local weather = unwrap(weather_parameter)
        local event = {
            event = "set-weather-request",
            hook = set_weather_path,
            phase = "pre",
            weatherFullName = object_full_name(weather),
            weatherClass = object_class_name(weather),
            weatherAddress = object_address(weather)
        }
        merge_fields(event, context_fields(game_mode))
        merge_fields(event, controller_fields(admin_controller))
        queue_event(event, "set-weather|" .. tostring(event.weatherFullName))
        return nil
    end,
    function(context, ...)
        local game_mode = object_from_context(context)
        local event = {
            event = "set-weather-completed",
            hook = set_weather_path,
            phase = "post"
        }
        merge_fields(event, context_fields(game_mode))
        queue_event(event, "set-weather-post")
        return nil
    end,
    "TIGameModeBase:SetWeather"
)

local clear_sky_path = "/Script/TheIsle.TIGameModeBase:SetClearSky"
register_hook(
    clear_sky_path,
    function(context, admin_controller_parameter)
        local game_mode = object_from_context(context)
        local admin_controller = unwrap(admin_controller_parameter)
        local event = {
            event = "set-clear-sky-request",
            hook = clear_sky_path,
            phase = "pre"
        }
        merge_fields(event, context_fields(game_mode))
        merge_fields(event, controller_fields(admin_controller))
        queue_event(event, "set-clear-sky")
        return nil
    end,
    function(context, ...)
        local game_mode = object_from_context(context)
        local event = {
            event = "set-clear-sky-completed",
            hook = clear_sky_path,
            phase = "post"
        }
        merge_fields(event, context_fields(game_mode))
        queue_event(event, "set-clear-sky-post")
        return nil
    end,
    "TIGameModeBase:SetClearSky"
)

local rain_intensity_path = "/Script/TheIsle.TIWeatherActor:SetRainIntensity"
register_hook(
    rain_intensity_path,
    function(context, intensity_parameter)
        local weather_actor = object_from_context(context)
        local requested = value_as_number(intensity_parameter)
        local event = {
            event = "rain-intensity-request",
            hook = rain_intensity_path,
            phase = "pre",
            requestedIntensity = requested
        }
        merge_fields(event, weather_actor_fields(weather_actor))
        queue_event(
            event,
            "rain-pre|" .. tostring(event.contextFullName) .. "|" .. tostring(requested)
        )
        return nil
    end,
    function(context, ...)
        local weather_actor = object_from_context(context)
        local fields = weather_actor_fields(weather_actor)
        local event = {
            event = "rain-intensity-observed",
            hook = rain_intensity_path,
            phase = "post",
            afterIntensity = fields.beforeIntensity
        }
        fields.beforeIntensity = nil
        merge_fields(event, fields)
        queue_event(
            event,
            "rain-post|" .. tostring(event.contextFullName) .. "|" .. tostring(event.afterIntensity)
        )
        return nil
    end,
    "TIWeatherActor:SetRainIntensity"
)

queue_event({
    event = "probe-loaded",
    phase = "startup",
    note = "Observation only; native calls and live Blueprint property changes are recorded without changing gameplay."
})

if LoopInGameThreadWithDelay == nil then
    log("[FATAL] LoopInGameThreadWithDelay is unavailable; NDJSON writer cannot start")
    drain_events()
else
    LoopInGameThreadWithDelay(DRAIN_INTERVAL_MS, function()
        drain_events()
    end)
    LoopInGameThreadWithDelay(WEATHER_STATE_POLL_INTERVAL_MS, function()
        sample_weather_properties()
    end)
end

log(string.format(
    "loaded version=%s readOnly=true eventPath=%s session=%s",
    VERSION,
    EVENT_PATH,
    session_id
))
