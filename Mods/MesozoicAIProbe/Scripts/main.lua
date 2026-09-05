-- The Mesozoic AI Probe
-- Version: 0.3.1-alpha
-- Build marker: MESOZOIC_AI_MANAGER_ALPHA_V0_3_1_CONFIRMED_EMERGENCY_DRAIN
--
-- This is deliberately not an automatic AI spawner. It provides:
--   * reflected pawn/controller function discovery (read-only)
--   * a downward terrain trace at a website-selected Gateway XY (read-only)
--   * live-pawn position capture for map calibration (read-only)
--   * explicit, paced AI group test spawns (mutating, admin-triggered)
--
-- It never caches a spawned actor for cleanup and never marks AI as always
-- relevant. A live probe AI must die through normal gameplay or be cleared by
-- the next server restart.

local MOD_NAME = "MesozoicAIProbe"
local BUILD = "0.3.1-alpha-confirmed-emergency-drain"
local POLL_MS = 1000
local MAX_COMMANDS_PER_TICK = 1
local MAX_FUNCTION_EVENTS = 240
local GROUP_SPAWN_INTERVAL_SECONDS = 1
local GROUP_SPAWN_MAX_ATTEMPTS = 3
local LIFECYCLE_SCAN_INTERVAL_SECONDS = 2
local LIFECYCLE_MISSING_CONFIRMATIONS = 2
local HERD_LIFETIME_SECONDS = 600
local HERD_COOLDOWN_MIN_SECONDS = 300
local HERD_COOLDOWN_MAX_SECONDS = 600

local SPECIES = {
    maiasaura = { name = "Maiasaura", pawn = "/Game/TheIsle/Core/Characters/Dinosaurs/Maiasaura/BP_Maiasaura.BP_Maiasaura_C", controller = "/Script/TheIsle.TIAITenontosaurusController" },
    diabloceratops = { name = "Diabloceratops", pawn = "/Game/TheIsle/Core/Characters/Dinosaurs/Diabloceratops/BP_Diabloceratops.BP_Diabloceratops_C", controller = "/Script/TheIsle.TIAIDiabloceratopsController" },
    beipiaosaurus = { name = "Beipiaosaurus", pawn = "/Game/TheIsle/Core/Characters/Dinosaurs/Beipiaosaurus/BP_Beipiaosaurus.BP_Beipiaosaurus_C", controller = "/Game/TheIsle/Core/AI/Controllers/Dinos/BP_AI_Compsognathus_Controller.BP_AI_Compsognathus_Controller_C" },
    hypsilophodon = { name = "Hypsilophodon", pawn = "/Game/TheIsle/Core/Characters/Dinosaurs/Hypsilophodon/BP_Hypsilophodon.BP_Hypsilophodon_C", controller = "/Script/TheIsle.TIAIHypsilophodon" }
}
local actor_location_numbers

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
    local unwrapped = safe_call(function() return value:get() end, nil)
    if unwrapped ~= nil then return unwrapped end
    return value
end

local function is_valid_object(object)
    if object == nil then return false end
    local address = tonumber(safe_call(function() return object:GetAddress() end, 0)) or 0
    return address ~= 0
end

local function resolve_mod_root()
    local fallback = "Mods/MesozoicAIProbe"
    if debug == nil or debug.getinfo == nil then return fallback end
    local info = safe_call(function() return debug.getinfo(1, "S") end, nil)
    if info == nil or info.source == nil then return fallback end
    local source = tostring(info.source):gsub("^@", ""):gsub("\\", "/")
    return source:match("^(.*)/[Ss]cripts/main%.lua$") or fallback
end

local MOD_ROOT = resolve_mod_root()
local SAVED_ROOT = MOD_ROOT .. "/Saved"
local COMMANDS_PATH = SAVED_ROOT .. "/commands.tsv"
local CURSOR_PATH = SAVED_ROOT .. "/command.cursor"
local EVENTS_PATH = SAVED_ROOT .. "/events.ndjson"

local command_cursor = nil
local kismet_system_library = nil
local gameplay_statics = nil
local ue_helpers_error = nil
local pending_spawns = {}
local group_jobs = {}
local next_group_spawn_epoch = 0
local active_ai = {}
local active_herds = {}
local next_lifecycle_scan_epoch = 0
local next_lifecycle_wait_event_epoch = 0
local presence_registry = {}
local emergency_stop_requested = false
local emergency_stop_id = nil
local emergency_stop_attempt = 0
local pending_zone_registrations = {}

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
    if value == nil then return "null" end
    local kind = type(value)
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        return string.format("%.17g", value)
    end
    return '"' .. json_escape(value) .. '"'
end

local EVENT_KEY_ORDER = {
    "schemaVersion", "build", "timestamp", "timestampUtc", "event", "id",
    "verb", "ok", "species", "steam", "worldX", "worldY", "worldZ",
    "x", "y", "groundZ", "growth", "placementVerified", "clearance",
    "capsuleHalfHeight", "targetZ", "actualX", "actualY", "actualZ",
    "deltaX", "deltaY", "deltaZ", "reason",
    "message", "owner", "functionName", "pawnClass", "controllerClass",
    "pawnAddress", "controllerAddress"
}

local function encode_event(event)
    local fields = {}
    for _, key in ipairs(EVENT_KEY_ORDER) do
        if event[key] ~= nil then
            fields[#fields + 1] = '"' .. key .. '":' .. json_value(event[key])
        end
    end
    return "{" .. table.concat(fields, ",") .. "}"
end

local function append_event(event)
    event.schemaVersion = 1
    event.build = BUILD
    event.timestamp = os.time()
    event.timestampUtc = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local file, open_error = io.open(EVENTS_PATH, "a")
    if file == nil then
        log("[ERROR] event-file-open-failed: " .. tostring(open_error))
        return false
    end
    file:write(encode_event(event), "\n")
    file:flush()
    file:close()
    log(string.format(
        "[EVENT] id=%s event=%s ok=%s reason=%s",
        tostring(event.id or "-"),
        tostring(event.event or "-"),
        tostring(event.ok),
        tostring(event.reason or "-")
    ))
    return true
end

local function split_tab(line)
    local values = {}
    for value in (tostring(line or "") .. "\t"):gmatch("(.-)\t") do
        values[#values + 1] = value
    end
    return values
end

local function save_cursor(value)
    local file = io.open(CURSOR_PATH, "w")
    if file == nil then return false end
    file:write(tostring(math.max(0, math.floor(tonumber(value) or 0))))
    file:flush()
    file:close()
    return true
end

local function load_cursor()
    local command_file = io.open(COMMANDS_PATH, "rb")
    if command_file == nil then
        local create = io.open(COMMANDS_PATH, "ab")
        if create ~= nil then create:close() end
        command_cursor = 0
        save_cursor(command_cursor)
        return
    end
    local end_position = tonumber(command_file:seek("end")) or 0
    command_file:close()

    local cursor_file = io.open(CURSOR_PATH, "r")
    if cursor_file == nil then
        -- First boot skips historical commands, especially old spawn requests.
        command_cursor = end_position
        save_cursor(command_cursor)
        return
    end
    local stored = tonumber(cursor_file:read("*l") or "")
    cursor_file:close()
    if stored == nil or stored < 0 or stored > end_position then
        command_cursor = end_position
    else
        command_cursor = math.floor(stored)
    end
    save_cursor(command_cursor)
end

local function find_game_mode()
    local game_mode = nil
    pcall(function() game_mode = FindFirstOf("BP_SurvivalGameMode_C") end)
    if is_valid_object(game_mode) then return game_mode end
    pcall(function() game_mode = FindFirstOf("TIGameModeBase") end)
    if is_valid_object(game_mode) then return game_mode end
    return nil
end

local function get_world()
    local game_mode = find_game_mode()
    if game_mode == nil then return nil, nil, "game-mode-not-found" end
    local world = safe_call(function() return game_mode:GetWorld() end, nil)
    if not is_valid_object(world) then return nil, nil, "world-not-found" end
    return game_mode, world, nil
end

local function get_kismet_system_library()
    if is_valid_object(kismet_system_library) then return kismet_system_library, nil end
    if ue_helpers_error ~= nil then return nil, ue_helpers_error end
    local helpers = nil
    local loaded, load_result = pcall(function() return require("UEHelpers") end)
    if loaded then helpers = load_result end
    if helpers == nil then
        ue_helpers_error = "UEHelpers-load-failed"
        return nil, ue_helpers_error
    end
    local library = safe_call(function() return helpers.GetKismetSystemLibrary() end, nil)
    if not is_valid_object(library) then
        ue_helpers_error = "KismetSystemLibrary-not-found"
        return nil, ue_helpers_error
    end
    kismet_system_library = library
    return kismet_system_library, nil
end

local function get_gameplay_statics()
    if is_valid_object(gameplay_statics) then return gameplay_statics, nil end
    local helpers = nil
    local loaded, load_result = pcall(function() return require("UEHelpers") end)
    if loaded then helpers = load_result end
    if helpers == nil then return nil, "UEHelpers-load-failed" end
    local library = safe_call(function() return helpers.GetGameplayStatics() end, nil)
    if not is_valid_object(library) then return nil, "GameplayStatics-not-found" end
    gameplay_statics = library
    return gameplay_statics, nil
end

local function vector_z(vector)
    if vector == nil then return nil end
    return tonumber(safe_call(function() return vector.Z end, nil))
end

local function trace_ground(x, y)
    local game_mode, _world, world_error = get_world()
    if game_mode == nil then return nil, world_error end
    local kismet, kismet_error = get_kismet_system_library()
    if kismet == nil then return nil, kismet_error end

    local start_location = { X = x, Y = y, Z = 1000000.0 }
    local end_location = { X = x, Y = y, Z = -1000000.0 }
    local actors_to_ignore = {}
    local out_hit = {}
    local clear_color = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }
    local was_hit = false
    local trace_ok, trace_error = pcall(function()
        was_hit = unwrap(kismet:LineTraceSingle(
            game_mode,
            start_location,
            end_location,
            0,
            false,
            actors_to_ignore,
            0,
            out_hit,
            true,
            clear_color,
            clear_color,
            0.0
        )) == true
    end)
    if not trace_ok then return nil, "line-trace-threw:" .. tostring(trace_error) end
    if not was_hit then return nil, "line-trace-no-hit" end

    local blocking_hit = safe_call(function() return out_hit.bBlockingHit == true end, nil)
    if blocking_hit == false then return nil, "line-trace-not-blocking" end
    local impact_point = safe_call(function() return out_hit.ImpactPoint end, nil)
    local ground_z = vector_z(impact_point)
    if ground_z == nil then
        local location = safe_call(function() return out_hit.Location end, nil)
        ground_z = vector_z(location)
    end
    if ground_z == nil then return nil, "line-trace-missing-impact-point" end
    if ground_z < -500000 or ground_z > 1000000 then return nil, "line-trace-z-out-of-range" end
    return ground_z, nil
end

local function function_name(function_object)
    return tostring(safe_call(function()
        return function_object:GetFName():ToString()
    end, "<unknown>"))
end

local function class_name(class_object)
    return tostring(safe_call(function()
        return class_object:GetFName():ToString()
    end, "<unknown>"))
end

local function function_is_interesting(name)
    local normalized = tostring(name or ""):lower()
    return normalized:find("call", 1, true) ~= nil or
        normalized:find("roar", 1, true) ~= nil or
        normalized:find("vocal", 1, true) ~= nil or
        normalized:find("sound", 1, true) ~= nil or
        normalized:find("broadcast", 1, true) ~= nil or
        normalized:find("emote", 1, true) ~= nil or
        normalized:find("move", 1, true) ~= nil or
        normalized:find("behav", 1, true) ~= nil
end

local function inspect_class_functions(id, role, class_object)
    if not is_valid_object(class_object) then
        append_event({
            id = id,
            verb = "inspect",
            event = "inspect-class",
            ok = false,
            owner = role,
            reason = "class-not-found"
        })
        return 0
    end
    local emitted = 0
    local current = class_object
    local depth = 0
    while is_valid_object(current) and depth < 20 and emitted < MAX_FUNCTION_EVENTS do
        local owner = role .. ":" .. class_name(current)
        pcall(function()
            current:ForEachFunction(function(function_object)
                local name = function_name(function_object)
                if function_is_interesting(name) and emitted < MAX_FUNCTION_EVENTS then
                    emitted = emitted + 1
                    append_event({
                        id = id,
                        verb = "inspect",
                        event = "function-candidate",
                        ok = true,
                        owner = owner,
                        functionName = name
                    })
                end
                return emitted >= MAX_FUNCTION_EVENTS
            end)
        end)
        current = safe_call(function() return current:GetSuperStruct() end, nil)
        depth = depth + 1
    end
    return emitted
end

local function handle_inspect(id)
    local definition = SPECIES.maiasaura
    local pawn_class = safe_call(function() return StaticFindObject(definition.pawn) end, nil)
    local controller_class = safe_call(function() return StaticFindObject(definition.controller) end, nil)
    local pawn_count = inspect_class_functions(id, "pawn", pawn_class)
    local controller_count = inspect_class_functions(id, "controller", controller_class)
    append_event({
        id = id,
        verb = "inspect",
        event = "inspect-complete",
        ok = is_valid_object(pawn_class) and is_valid_object(controller_class),
        species = "Maiasaura",
        pawnClass = definition.pawn,
        controllerClass = definition.controller,
        message = string.format("Recorded %d pawn and %d controller candidates", pawn_count, controller_count)
    })
end

local function handle_capture(id, steam)
    if tostring(steam or ""):match("^%d+$") == nil then
        append_event({
            id = id,
            verb = "capture",
            event = "capture-result",
            ok = false,
            reason = "invalid-steamid"
        })
        return
    end

    local game_mode, _world, world_error = get_world()
    if game_mode == nil then
        append_event({
            id = id,
            verb = "capture",
            event = "capture-result",
            ok = false,
            steam = tostring(steam),
            reason = world_error
        })
        return
    end

    local controller = safe_call(function()
        return game_mode:GetControllerBySteamId(tostring(steam))
    end, nil)
    local pawn = is_valid_object(controller)
        and safe_call(function() return controller:K2_GetPawn() end, nil) or nil
    local growth = is_valid_object(pawn)
        and tonumber(safe_call(function() return pawn:GetGrowth() end, nil)) or nil
    local x, y, z = nil, nil, nil
    if is_valid_object(pawn) then x, y, z = actor_location_numbers(pawn) end

    if growth == nil or x == nil or y == nil or z == nil then
        append_event({
            id = id,
            verb = "capture",
            event = "capture-result",
            ok = false,
            steam = tostring(steam),
            reason = "linked-player-not-on-a-live-dinosaur"
        })
        return
    end

    append_event({
        id = id,
        verb = "capture",
        event = "capture-result",
        ok = true,
        steam = tostring(steam),
        worldX = x,
        worldY = y,
        worldZ = z,
        growth = growth,
        message = "Captured the linked administrator's live dinosaur position"
    })
end

local function handle_trace(id, x, y)
    local ground_z, reason = trace_ground(x, y)
    append_event({
        id = id,
        verb = "trace",
        event = "trace-result",
        ok = ground_z ~= nil,
        species = "Maiasaura",
        x = x,
        y = y,
        groundZ = ground_z,
        reason = reason,
        message = ground_z ~= nil and "Ground trace found a blocking surface" or "Ground trace failed"
    })
end

local function make_same_tick_corpse(pawn)
    if not is_valid_object(pawn) then return end
    pcall(function() pawn:SetHealth(0) end)
    pcall(function() pawn.bIsDead = true end)
    pcall(function() pawn:OnRep_IsNowDead() end)
    pcall(function() pawn:ToggleServerRagdoll(true) end)
    pcall(function() pawn:ActivateDeadbody(false, 600.0) end)
    pcall(function() pawn:ForceNetUpdate() end)
end

local function apply_adult_state(pawn, growth)
    local safe_growth = tonumber(growth) or 1.0
    if safe_growth < 0.05 then safe_growth = 0.05 end
    if safe_growth > 1.0 then safe_growth = 1.0 end
    pcall(function() pawn:SetGrowth(safe_growth) end)
    pcall(function() pawn:SetHealth(pawn:GetMaxHealth()) end)
    pcall(function() pawn:SetBlood(pawn:GetMaxBlood()) end)
    pcall(function() pawn:SetStamina(pawn:GetMaxStamina()) end)
    pcall(function() pawn:SetFood(pawn:GetMaxFoodValue()) end)
    pcall(function() pawn:SetHunger(pawn:GetMaxHunger()) end)
    pcall(function() pawn:SetThirst(pawn:GetMaxThirst()) end)
    pcall(function() pawn:ForceNetUpdate() end)
    return safe_growth
end

actor_location_numbers = function(actor)
    local location = safe_call(function() return actor:K2_GetActorLocation() end, nil)
    if location == nil then return nil, nil, nil end
    return
        tonumber(safe_call(function() return location.X end, nil)),
        tonumber(safe_call(function() return location.Y end, nil)),
        tonumber(safe_call(function() return location.Z end, nil))
end

local function adult_ground_clearance(pawn)
    -- Read the grown pawn's collision capsule instead of assuming hatchling
    -- dimensions. Initial spawning/growth still happens safely at +1500;
    -- only the finished, fully-grown pawn is placed close to the terrain.
    local capsule = safe_call(function() return pawn:GetCapsuleComponent() end, nil)
    local half_height = tonumber(safe_call(function()
        return capsule:GetScaledCapsuleHalfHeight()
    end, nil))
    if half_height == nil or half_height <= 0 or half_height > 2000 then
        return 150.0, nil
    end
    return half_height + 10.0, half_height
end

local function place_grown_pawn(pawn, x, y, ground_z, rotation)
    local clearance, capsule_half_height = adult_ground_clearance(pawn)
    local target = { X = x, Y = y, Z = ground_z + clearance }
    local move_ok = pcall(function()
        local hit_result = {}
        pawn:K2_SetActorLocationAndRotation(
            target,
            rotation,
            false,
            hit_result,
            true
        )
    end)
    pcall(function() pawn:ForceNetUpdate() end)

    local actual_x, actual_y, actual_z = actor_location_numbers(pawn)
    local delta_x = actual_x ~= nil and math.abs(actual_x - x) or nil
    local delta_y = actual_y ~= nil and math.abs(actual_y - y) or nil
    local delta_z = actual_z ~= nil and math.abs(actual_z - target.Z) or nil
    local verified = move_ok and delta_x ~= nil and delta_y ~= nil and delta_z ~= nil
        and delta_x <= 100.0 and delta_y <= 100.0 and delta_z <= 150.0

    return {
        ok = verified,
        clearance = clearance,
        capsuleHalfHeight = capsule_half_height,
        targetZ = target.Z,
        actualX = actual_x,
        actualY = actual_y,
        actualZ = actual_z,
        deltaX = delta_x,
        deltaY = delta_y,
        deltaZ = delta_z
    }
end

local function handle_spawn(id, species_key, x, y, growth)
    local definition = SPECIES[species_key]
    if definition == nil then
        append_event({ id = id, verb = "spawn", event = "spawn-result", ok = false, reason = "species-not-manual-test-approved" })
        return false, "species-not-manual-test-approved"
    end
    local ground_z, trace_reason = trace_ground(x, y)
    if ground_z == nil then
        append_event({
            id = id,
            verb = "spawn",
            event = "spawn-result",
            ok = false,
            species = definition.name,
            x = x,
            y = y,
            reason = "ground-trace-failed:" .. tostring(trace_reason)
        })
        return false, "ground-trace-failed:" .. tostring(trace_reason)
    end

    local pawn_class = safe_call(function() return StaticFindObject(definition.pawn) end, nil)
    local controller_class = safe_call(function() return StaticFindObject(definition.controller) end, nil)
    if not is_valid_object(pawn_class) or not is_valid_object(controller_class) then
        append_event({
            id = id,
            verb = "spawn",
            event = "spawn-result",
            ok = false,
            species = definition.name,
            x = x,
            y = y,
            groundZ = ground_z,
            reason = "spawn-class-not-found"
        })
        return false, "spawn-class-not-found"
    end

    local _game_mode, world, world_error = get_world()
    if world == nil then
        append_event({ id = id, verb = "spawn", event = "spawn-result", ok = false, reason = world_error })
        return false, tostring(world_error)
    end

    -- Keep the hatchling well clear of terrain while possession and SetGrowth
    -- resize its capsule. Growing near the surface can trigger penetration
    -- resolution and push the adult pawn a long distance in XY.
    local spawn_location = { X = x, Y = y, Z = ground_z + 1500.0 }
    local spawn_rotation = { Pitch = 0.0, Yaw = math.random(0, 359), Roll = 0.0 }
    local pawn = nil
    local pawn_spawn_ok = pcall(function()
        pawn = world:SpawnActor(pawn_class, spawn_location, spawn_rotation)
    end)
    if not pawn_spawn_ok or not is_valid_object(pawn) then
        append_event({
            id = id,
            verb = "spawn",
            event = "spawn-result",
            ok = false,
            species = definition.name,
            x = x,
            y = y,
            groundZ = ground_z,
            reason = "pawn-spawn-failed-or-nullptr"
        })
        return false, "pawn-spawn-failed-or-nullptr"
    end

    pcall(function() pawn:SetReplicates(true) end)
    pcall(function() pawn:ForceNetUpdate() end)
    local pawn_address = tonumber(safe_call(function() return pawn:GetAddress() end, 0)) or 0

    local controller = nil
    local controller_spawn_ok = pcall(function()
        controller = world:SpawnActor(controller_class, spawn_location, spawn_rotation)
    end)
    if not controller_spawn_ok or not is_valid_object(controller) then
        make_same_tick_corpse(pawn)
        append_event({
            id = id,
            verb = "spawn",
            event = "spawn-result",
            ok = false,
            species = definition.name,
            x = x,
            y = y,
            groundZ = ground_z,
            pawnAddress = string.format("0x%X", pawn_address),
            reason = "controller-spawn-failed;fresh-pawn-converted-to-corpse"
        })
        return false, "controller-spawn-failed"
    end

    local controller_address = tonumber(safe_call(function() return controller:GetAddress() end, 0)) or 0
    local possess_ok = pcall(function() controller:Possess(pawn) end)
    local possessed_pawn = safe_call(function() return controller:K2_GetPawn() end, nil)
    local possessed_address = tonumber(safe_call(function() return possessed_pawn:GetAddress() end, 0)) or 0
    if not possess_ok or possessed_address == 0 or possessed_address ~= pawn_address then
        make_same_tick_corpse(pawn)
        pcall(function() controller:K2_DestroyActor() end)
        append_event({
            id = id,
            verb = "spawn",
            event = "spawn-result",
            ok = false,
            species = definition.name,
            x = x,
            y = y,
            groundZ = ground_z,
            pawnAddress = string.format("0x%X", pawn_address),
            controllerAddress = string.format("0x%X", controller_address),
            reason = "controller-possession-failed;fresh-pawn-converted-to-corpse"
        })
        return false, "controller-possession-failed"
    end

    local applied_growth = apply_adult_state(pawn, growth)
    local placement = place_grown_pawn(pawn, x, y, ground_z, spawn_rotation)
    append_event({
        id = id,
        verb = "spawn",
        event = "spawn-result",
        ok = true,
        species = definition.name,
        x = x,
        y = y,
        groundZ = ground_z,
        growth = applied_growth,
        placementVerified = placement.ok,
        clearance = placement.clearance,
        capsuleHalfHeight = placement.capsuleHalfHeight,
        targetZ = placement.targetZ,
        actualX = placement.actualX,
        actualY = placement.actualY,
        actualZ = placement.actualZ,
        deltaX = placement.deltaX,
        deltaY = placement.deltaY,
        deltaZ = placement.deltaZ,
        pawnClass = definition.pawn,
        controllerClass = definition.controller,
        pawnAddress = string.format("0x%X", pawn_address),
        controllerAddress = string.format("0x%X", controller_address),
        message = placement.ok
            and (definition.name .. " spawned and post-growth placement matched the selected map point")
            or (definition.name .. " spawned but post-growth placement could not be confirmed")
    })
    return true, placement.ok and "verified" or "placement-unconfirmed", pawn_address, controller_address
end

local function parse_growth_list(raw, count)
    local result = {}
    for token in tostring(raw or ""):gmatch("[^,]+") do
        local value = tonumber(token)
        if value ~= nil then result[#result + 1] = math.max(0.05, math.min(1.0, value)) end
    end
    if #result == 0 then result[1] = 1.0 end
    while #result < count do result[#result + 1] = result[#result] end
    return result
end

local function register_lifecycle_member(item, pawn_address, controller_address)
    if tostring(item.zoneId or "") == "" or tonumber(pawn_address or 0) == 0 then return end
    local herd = active_herds[item.herdId]
    if herd == nil then return end
    active_ai[tostring(pawn_address)] = {
        pawnAddress = tonumber(pawn_address),
        controllerAddress = tonumber(controller_address) or 0,
        herdId = item.herdId,
        zoneId = item.zoneId,
        speciesKey = item.speciesKey,
        centerX = item.centerX,
        centerY = item.centerY,
        spawnRadiusMeters = item.spawnRadiusMeters,
        activationRadiusMeters = item.activationRadiusMeters,
        respawnDelaySeconds = item.respawnDelaySeconds,
        growth = item.growth,
        missingScans = 0
    }
    herd.members[tostring(pawn_address)] = true
end

local function for_each_collection(collection, callback)
    collection = unwrap(collection)
    if collection == nil then return false end
    local used = false
    local wrapped_ok = pcall(function()
        collection:ForEach(function(first, second)
            local value = second
            if not is_valid_object(value) and is_valid_object(first) then value = first end
            if is_valid_object(value) then used = true; callback(value) end
        end)
    end)
    if wrapped_ok then return true end
    if type(collection) == "table" then
        for _, value in pairs(collection) do
            value = unwrap(value)
            if is_valid_object(value) then used = true; callback(value) end
        end
    end
    return used
end

local function current_species_actors(species_key)
    local definition = SPECIES[species_key]
    if definition == nil then return nil, "species-not-approved" end
    local pawn_class = safe_call(function() return StaticFindObject(definition.pawn) end, nil)
    if not is_valid_object(pawn_class) then return nil, "pawn-class-not-found" end
    local game_mode, _world, world_error = get_world()
    if game_mode == nil then return nil, world_error end
    local statics, statics_error = get_gameplay_statics()
    if statics == nil then return nil, statics_error end
    local supplied = {}
    local returned_a, returned_b = nil, nil
    local call_ok, call_error = pcall(function()
        returned_a, returned_b = statics:GetAllActorsOfClass(game_mode, pawn_class, supplied)
    end)
    if not call_ok then return nil, "GetAllActorsOfClass-failed:" .. tostring(call_error) end
    local actors = {}
    local function add(actor)
        local address = tonumber(safe_call(function() return actor:GetAddress() end, 0)) or 0
        if address ~= 0 then
            actors[tostring(address)] = {
                dead = safe_call(function() return actor.bIsDead end, false) == true,
                actor = actor
            }
        end
    end
    local enumeration_supported = false
    if for_each_collection(supplied, add) then enumeration_supported = true end
    if for_each_collection(returned_a, add) then enumeration_supported = true end
    if for_each_collection(returned_b, add) then enumeration_supported = true end
    if not enumeration_supported then return nil, "actor-array-output-unavailable" end
    return actors, nil
end

local function controller_steam_id(controller)
    if not is_valid_object(controller) then return "" end
    local steam_id = safe_call(function() return controller:GetSteamId() end, nil)
    if steam_id == nil then return "" end
    local value = safe_call(function() return steam_id:ToString() end, nil)
    if value == nil then value = tostring(steam_id) end
    value = tostring(value or "")
    return value:match("^%d+$") and value or ""
end

local function player_within_radius(center_x, center_y, radius_meters)
    local game_mode, world = get_world()
    if game_mode == nil or not is_valid_object(world) then return false, { pawns = 0 } end
    local radius_units_squared = (math.max(0, tonumber(radius_meters) or 0) * 100.0) ^ 2
    local found = false
    local seen_controllers = {}
    local seen_pawns = {}
    local pawn_count = 0
    local closest_meters = nil

    local function inspect_controller(controller)
        if not is_valid_object(controller) then return end
        local controller_address = tostring(tonumber(safe_call(function() return controller:GetAddress() end, 0)) or 0)
        if controller_address == "0" or seen_controllers[controller_address] then return end
        seen_controllers[controller_address] = true
        local steam = controller_steam_id(controller)
        if steam ~= "" then presence_registry[steam] = true end
        local pawn = is_valid_object(controller) and safe_call(function() return controller:K2_GetPawn() end, nil) or nil
        if not is_valid_object(pawn) then return end
        local pawn_address = tostring(tonumber(safe_call(function() return pawn:GetAddress() end, 0)) or 0)
        if pawn_address == "0" or seen_pawns[pawn_address] then return end
        seen_pawns[pawn_address] = true
        pawn_count = pawn_count + 1
        local location = safe_call(function() return pawn:K2_GetActorLocation() end, nil)
        local x = tonumber(safe_call(function() return location.X end, nil))
        local y = tonumber(safe_call(function() return location.Y end, nil))
        if x ~= nil and y ~= nil then
            local dx, dy = x - center_x, y - center_y
            local distance_squared = dx * dx + dy * dy
            local distance_meters = math.sqrt(distance_squared) / 100.0
            if closest_meters == nil or distance_meters < closest_meters then closest_meters = distance_meters end
            if distance_squared <= radius_units_squared then found = true end
        end
    end

    -- Primary path: the GameState player array.
    local game_state = safe_call(function() return world.GameState end, nil)
    if is_valid_object(game_state) then
        local player_array = safe_call(function() return game_state.PlayerArray end, nil)
        for_each_collection(player_array, function(player_state)
            local controller = safe_call(function() return player_state:GetOwningController() end, nil)
            inspect_controller(controller)
        end)
    end

    -- Proven EVRIMA fallback: GameMode.AllPlayerControllers is a TSet and is
    -- populated even on builds where PlayerArray does not expose controllers.
    if not found then
        local controllers = safe_call(function() return game_mode.AllPlayerControllers end, nil)
        for_each_collection(controllers, inspect_controller)
    end

    -- Production-proven fallback used by the prime-zone system: resolve a
    -- fresh controller from each known Steam ID instead of retaining wrappers.
    for steam, _ in pairs(presence_registry) do
        local controller = safe_call(function() return game_mode:GetControllerBySteamId(steam) end, nil)
        if is_valid_object(controller) then inspect_controller(controller)
        else presence_registry[steam] = nil end
    end
    return found, { pawns = pawn_count, closestMeters = closest_meters }
end

local queue_herd_members

local function random_herd_cooldown(herd)
    local minimum = math.max(60, math.floor(tonumber(herd.cooldownMinSeconds) or HERD_COOLDOWN_MIN_SECONDS))
    local maximum = math.max(minimum, math.floor(tonumber(herd.cooldownMaxSeconds) or HERD_COOLDOWN_MAX_SECONDS))
    return math.random(minimum, maximum), minimum, maximum
end

local function finish_herd(herd, reason, snapshots)
    if herd.state ~= "active" and herd.state ~= "spawning" then return end
    local despawned = 0
    local actors = snapshots and snapshots[herd.speciesKey] or nil
    for address, _ in pairs(herd.members) do
        local current = actors and actors[address] or nil
        local pawn = current and current.actor or nil
        if is_valid_object(pawn) and not current.dead then
            local controller = safe_call(function() return pawn:GetController() end, nil)
            if is_valid_object(controller) then
                pcall(function() controller:UnPossess() end)
                pcall(function() controller:K2_DestroyActor() end)
            end
            local destroyed = pcall(function() pawn:K2_DestroyActor() end)
            if destroyed then despawned = despawned + 1 end
        end
        active_ai[address] = nil
    end
    herd.members = {}
    herd.state = "cooldown"
    local minimum, maximum
    herd.cooldownSeconds, minimum, maximum = random_herd_cooldown(herd)
    herd.nextEligibleEpoch = os.time() + herd.cooldownSeconds
    append_event({ id = herd.zoneId, verb = "lifecycle", event = "herd-cycle-ended", ok = true,
        species = SPECIES[herd.speciesKey].name, reason = reason,
        message = string.format("Herd cycle ended; %d survivor(s) despawned; full herd eligible in %.1f-%.1f minutes (%ds selected)",
            despawned, minimum / 60, maximum / 60, herd.cooldownSeconds) })
end

local function emergency_drain_tick()
    if not emergency_stop_requested then return false end
    emergency_stop_attempt = emergency_stop_attempt + 1
    local species_needed = {}
    for _, record in pairs(active_ai) do species_needed[record.speciesKey] = true end
    local snapshots = {}
    local scan_failed = false
    for species_key, _ in pairs(species_needed) do
        local actors, error_message = current_species_actors(species_key)
        if actors == nil then
            scan_failed = true
            append_event({ id = emergency_stop_id, verb = "stop-all", event = "emergency-drain-retry", ok = false,
                species = SPECIES[species_key].name, reason = error_message,
                message = "Fresh actor scan unavailable; tracked AI retained for the next drain attempt" })
        else
            snapshots[species_key] = actors
        end
    end

    local remaining = 0
    local destroy_requested = 0
    for address, record in pairs(active_ai) do
        local actors = snapshots[record.speciesKey]
        if actors == nil then
            remaining = remaining + 1
        else
            local current = actors[address]
            if current == nil then
                record.missingScans = (record.missingScans or 0) + 1
                if record.missingScans >= LIFECYCLE_MISSING_CONFIRMATIONS then
                    local herd = active_herds[record.herdId]
                    if herd ~= nil then herd.members[address] = nil end
                    active_ai[address] = nil
                else
                    remaining = remaining + 1
                end
            else
                record.missingScans = 0
                local pawn = current.actor
                local controller = safe_call(function() return pawn:GetController() end, nil)
                if is_valid_object(controller) then
                    pcall(function() controller:UnPossess() end)
                    pcall(function() controller:K2_DestroyActor() end)
                end
                pcall(function() pawn:K2_DestroyActor() end)
                destroy_requested = destroy_requested + 1
                remaining = remaining + 1
            end
        end
    end

    if remaining == 0 and not scan_failed then
        active_herds = {}
        for zone_id, herd in pairs(pending_zone_registrations) do
            active_herds[zone_id] = herd
        end
        pending_zone_registrations = {}
        emergency_stop_requested = false
        append_event({ id = emergency_stop_id, verb = "stop-all", event = "emergency-drain-complete", ok = true,
            message = string.format("Emergency drain confirmed after %d scan(s); no tracked AI remain", emergency_stop_attempt) })
        emergency_stop_id = nil
        emergency_stop_attempt = 0
    elseif destroy_requested > 0 then
        append_event({ id = emergency_stop_id, verb = "stop-all", event = "emergency-drain-progress", ok = true,
            message = string.format("Destroy requested for %d tracked AI; %d awaiting disappearance confirmation", destroy_requested, remaining) })
    end
    return true
end

local function lifecycle_tick()
    local now = os.time()
    if now < next_lifecycle_scan_epoch then return end
    next_lifecycle_scan_epoch = now + LIFECYCLE_SCAN_INTERVAL_SECONDS
    if emergency_drain_tick() then return end

    local species_needed = {}
    for _, record in pairs(active_ai) do species_needed[record.speciesKey] = true end
    local snapshots = {}
    for species_key, _ in pairs(species_needed) do
        local actors, error_message = current_species_actors(species_key)
        if actors == nil then
            append_event({ verb = "lifecycle", event = "lifecycle-scan-unavailable", ok = false,
                species = SPECIES[species_key].name, reason = error_message })
        else
            snapshots[species_key] = actors
        end
    end

    for address, record in pairs(active_ai) do
        local actors = snapshots[record.speciesKey]
        if actors ~= nil then
            local current = actors[address]
            if current ~= nil and current.dead then
                active_ai[address] = nil
                local herd = active_herds[record.herdId]
                if herd ~= nil then herd.members[address] = nil end
            elseif current ~= nil then
                record.missingScans = 0
            else
                record.missingScans = (record.missingScans or 0) + 1
                if record.missingScans >= LIFECYCLE_MISSING_CONFIRMATIONS then
                    active_ai[address] = nil
                    local herd = active_herds[record.herdId]
                    if herd ~= nil then herd.members[address] = nil end
                end
            end
        end
    end

    for _, herd in pairs(active_herds) do
        local member_count = 0
        for _, _ in pairs(herd.members) do member_count = member_count + 1 end
        if herd.state == "active" and member_count == 0 then
            finish_herd(herd, "all-members-dead", snapshots)
        elseif herd.state == "active" and now >= herd.expiresEpoch then
            finish_herd(herd, "lifetime-expired", snapshots)
        elseif herd.state == "cooldown" and now >= herd.nextEligibleEpoch then
            local player_nearby, proximity = player_within_radius(herd.centerX, herd.centerY, herd.activationRadiusMeters)
            if player_nearby then
                herd.state = "spawning"
                herd.members = {}
                herd.cycle = (herd.cycle or 1) + 1
                queue_herd_members(herd, herd.zoneId .. "-cycle-" .. tostring(herd.cycle) .. "-" .. tostring(now))
                append_event({ id = herd.zoneId, verb = "lifecycle", event = "full-herd-respawn-queued", ok = true,
                    species = SPECIES[herd.speciesKey].name,
                    message = "Cooldown elapsed and a player is nearby; a complete herd was queued" })
            elseif now >= next_lifecycle_wait_event_epoch then
                next_lifecycle_wait_event_epoch = now + 30
                append_event({ id = herd.zoneId, verb = "lifecycle", event = "herd-waiting-for-player", ok = true,
                    species = SPECIES[herd.speciesKey].name,
                    message = string.format("Cooldown elapsed; waiting for a live player within %.0fm; live pawns found=%d; nearest=%s",
                        herd.activationRadiusMeters, proximity.pawns or 0,
                        proximity.closestMeters and string.format("%.1fm", proximity.closestMeters) or "unavailable") })
            end
        end
    end
end

local function handle_spawn_group(id, species_key, center_x, center_y, count, radius_meters, raw_growths, zone_id, respawn_delay, activation_radius, herd_lifetime, respawn_delay_max)
    count = math.max(1, math.min(32, math.floor(tonumber(count) or 1)))
    radius_meters = math.max(0, math.min(500, tonumber(radius_meters) or 0))
    local growths = parse_growth_list(raw_growths, count)
    local herd_id = tostring(zone_id or "")
    if herd_id == "" then herd_id = id end
    local existing = active_herds[herd_id]
    if existing ~= nil and (existing.state == "active" or existing.state == "spawning") then
        append_event({ id = id, verb = "spawn-group", event = "spawn-group-rejected", ok = false,
            species = SPECIES[species_key].name, reason = "herd-already-active",
            message = "This zone already has an active or spawning herd" })
        return
    end
    local herd = {
        herdId = herd_id, zoneId = herd_id, speciesKey = species_key,
        centerX = center_x, centerY = center_y,
        spawnRadiusMeters = radius_meters,
        activationRadiusMeters = math.max(100, tonumber(activation_radius) or 700),
        lifetimeSeconds = math.max(60, tonumber(herd_lifetime) or HERD_LIFETIME_SECONDS),
        cooldownMinSeconds = math.max(60, tonumber(respawn_delay) or HERD_COOLDOWN_MIN_SECONDS),
        cooldownMaxSeconds = math.max(60, tonumber(respawn_delay_max) or HERD_COOLDOWN_MAX_SECONDS),
        growths = growths, count = count, members = {}, state = "spawning", cycle = 1
    }
    herd.cooldownMaxSeconds = math.max(herd.cooldownMinSeconds, herd.cooldownMaxSeconds)
    active_herds[herd_id] = herd
    append_event({ id = id, verb = "spawn-group", event = "spawn-group-start", ok = true,
        species = SPECIES[species_key].name, x = center_x, y = center_y,
        message = string.format("Spawning %d AI within %.0fm; herd lifetime is %.1f minutes", count, radius_meters, herd.lifetimeSeconds / 60) })
    queue_herd_members(herd, id)
end

local function handle_register_zone(id, species_key, center_x, center_y, count, radius_meters, raw_growths, zone_id, respawn_delay, activation_radius, herd_lifetime, respawn_delay_max)
    if species_key ~= "maiasaura" then
        append_event({ id = id, verb = "register-zone", event = "zone-registration-rejected", ok = false,
            species = SPECIES[species_key] and SPECIES[species_key].name or species_key,
            reason = "species-not-production-approved" })
        return
    end
    local herd_id = tostring(zone_id or "")
    if herd_id == "" then
        append_event({ id = id, verb = "register-zone", event = "zone-registration-rejected", ok = false,
            reason = "missing-zone-id" })
        return
    end
    local growths = parse_growth_list(raw_growths, count)
    local herd = {
        herdId = herd_id, zoneId = herd_id, speciesKey = species_key,
        centerX = center_x, centerY = center_y,
        spawnRadiusMeters = math.max(0, math.min(500, tonumber(radius_meters) or 0)),
        activationRadiusMeters = math.max(100, tonumber(activation_radius) or 700),
        lifetimeSeconds = math.max(60, tonumber(herd_lifetime) or HERD_LIFETIME_SECONDS),
        cooldownMinSeconds = math.max(60, tonumber(respawn_delay) or HERD_COOLDOWN_MIN_SECONDS),
        cooldownMaxSeconds = math.max(60, tonumber(respawn_delay_max) or HERD_COOLDOWN_MAX_SECONDS),
        growths = growths, count = math.max(1, math.min(32, math.floor(tonumber(count) or 1))),
        members = {}, state = "cooldown", cycle = 0, nextEligibleEpoch = os.time()
    }
    herd.cooldownMaxSeconds = math.max(herd.cooldownMinSeconds, herd.cooldownMaxSeconds)
    if emergency_stop_requested then
        pending_zone_registrations[herd_id] = herd
    else
        active_herds[herd_id] = herd
    end
    append_event({ id = id, verb = "register-zone", event = "zone-registered", ok = true,
        species = SPECIES[species_key].name,
        message = string.format("Automatic zone registered; waiting for a live player within %.0fm", herd.activationRadiusMeters) })
end

local function handle_stop_all(id)
    pending_spawns = {}
    group_jobs = {}
    pending_zone_registrations = {}
    emergency_stop_requested = true
    emergency_stop_id = id
    emergency_stop_attempt = 0
    for _, herd in pairs(active_herds) do herd.state = "stopping" end
    local tracked = 0
    for _, _ in pairs(active_ai) do tracked = tracked + 1 end
    append_event({ id = id, verb = "stop-all", event = "emergency-drain-started", ok = true,
        message = string.format("Automatic AI stopped; drain started for %d tracked AI", tracked) })
end

queue_herd_members = function(herd, group_id)
    group_jobs[group_id] = { total = herd.count, succeeded = 0, failed = 0, herdId = herd.herdId }
    for index = 1, herd.count do
        local angle = math.random() * math.pi * 2.0
        local distance_units = math.sqrt(math.random()) * herd.spawnRadiusMeters * 100.0
        local spawn_x = herd.centerX + math.cos(angle) * distance_units
        local spawn_y = herd.centerY + math.sin(angle) * distance_units
        pending_spawns[#pending_spawns + 1] = {
            id = group_id .. "-" .. tostring(index),
            groupId = group_id,
            herdId = herd.herdId,
            index = index,
            count = herd.count,
            speciesKey = herd.speciesKey,
            x = spawn_x,
            y = spawn_y,
            centerX = herd.centerX,
            centerY = herd.centerY,
            spawnRadiusMeters = herd.spawnRadiusMeters,
            activationRadiusMeters = herd.activationRadiusMeters,
            zoneId = herd.zoneId,
            growth = herd.growths[index],
            attempt = 1
        }
    end
    append_event({ id = group_id, verb = "spawn-group", event = "spawn-group-queued", ok = true,
        species = SPECIES[herd.speciesKey].name, x = herd.centerX, y = herd.centerY,
        message = string.format("Queued %d group members for sequential spawning", herd.count) })
end

local function process_one_pending_spawn()
    if #pending_spawns == 0 then return end
    local now = os.time()
    if now < next_group_spawn_epoch then return end
    local item = table.remove(pending_spawns, 1)
    next_group_spawn_epoch = now + GROUP_SPAWN_INTERVAL_SECONDS
    local ok, reason, pawn_address, controller_address = handle_spawn(item.id, item.speciesKey, item.x, item.y, item.growth)
    if ok then register_lifecycle_member(item, pawn_address, controller_address) end
    local job = group_jobs[item.groupId]
    if job == nil then
        job = { total = item.count, succeeded = 0, failed = 0 }
        group_jobs[item.groupId] = job
    end
    if ok then
        job.succeeded = job.succeeded + 1
        append_event({ id = item.groupId, verb = "spawn-group", event = "spawn-group-progress", ok = true,
            species = SPECIES[item.speciesKey].name,
            message = string.format("Verified group member %d/%d; %d successful, %d queued", item.index, item.count, job.succeeded, #pending_spawns) })
    elseif item.attempt < GROUP_SPAWN_MAX_ATTEMPTS then
        item.attempt = item.attempt + 1
        pending_spawns[#pending_spawns + 1] = item
        append_event({ id = item.groupId, verb = "spawn-group", event = "spawn-group-retry", ok = false,
            species = SPECIES[item.speciesKey].name, reason = reason,
            message = string.format("Group member %d/%d failed attempt %d; retry queued", item.index, item.count, item.attempt - 1) })
    else
        job.failed = job.failed + 1
        append_event({ id = item.groupId, verb = "spawn-group", event = "spawn-group-member-failed", ok = false,
            species = SPECIES[item.speciesKey].name, reason = reason,
            message = string.format("Group member %d/%d failed after %d attempts", item.index, item.count, item.attempt) })
    end
    if job.succeeded + job.failed >= job.total then
        local complete_ok = job.failed == 0
        local herd = active_herds[job.herdId]
        if herd ~= nil then
            herd.state = "active"
            herd.startedEpoch = now
            herd.expiresEpoch = now + herd.lifetimeSeconds
        end
        append_event({ id = item.groupId, verb = "spawn-group", event = "spawn-group-complete", ok = complete_ok,
            species = SPECIES[item.speciesKey].name,
            reason = complete_ok and nil or "one-or-more-members-failed",
            message = string.format("Group spawn complete: %d/%d verified, %d failed; surviving herd expires in %.1f minutes", job.succeeded, job.total, job.failed, (herd and herd.lifetimeSeconds or HERD_LIFETIME_SECONDS) / 60) })
        group_jobs[item.groupId] = nil
    end
end

local function process_command(line)
    local fields = split_tab(line)
    local id = tostring(fields[1] or "")
    local verb = tostring(fields[2] or "")
    local species = tostring(fields[3] or "")
    local x = tonumber(fields[4])
    local y = tonumber(fields[5])
    local growth_raw = tostring(fields[6] or "")
    local growth = tonumber(growth_raw) or 1.0
    local group_count = tonumber(fields[7]) or 1
    local group_radius = tonumber(fields[8]) or 0
    local zone_id = tostring(fields[9] or "")
    local respawn_delay = tonumber(fields[10]) or 300
    local activation_radius = tonumber(fields[11]) or 700
    local herd_lifetime = tonumber(fields[12]) or 600
    local respawn_delay_max = tonumber(fields[13]) or 600
    if id == "" or verb == "" then return end

    if verb == "stop-all" then
        handle_stop_all(id)
        return
    end

    if verb == "inspect" then
        handle_inspect(id)
        return
    end
    if verb == "capture" then
        handle_capture(id, species)
        return
    end
    local species_key = species:lower()
    if SPECIES[species_key] == nil then
        append_event({ id = id, verb = verb, event = "command-rejected", ok = false, reason = "species-not-probe-approved" })
        return
    end
    if x == nil or y == nil then
        append_event({ id = id, verb = verb, event = "command-rejected", ok = false, reason = "invalid-coordinates" })
        return
    end
    if verb == "trace" then
        handle_trace(id, x, y)
    elseif verb == "spawn" then
        handle_spawn(id, species_key, x, y, growth)
    elseif verb == "spawn-group" then
        handle_spawn_group(id, species_key, x, y, group_count, group_radius, growth_raw, zone_id, respawn_delay, activation_radius, herd_lifetime, respawn_delay_max)
    elseif verb == "register-zone" then
        handle_register_zone(id, species_key, x, y, group_count, group_radius, growth_raw, zone_id, respawn_delay, activation_radius, herd_lifetime, respawn_delay_max)
    else
        append_event({ id = id, verb = verb, event = "command-rejected", ok = false, reason = "unknown-verb" })
    end
end

local function poll_commands()
    process_one_pending_spawn()
    lifecycle_tick()
    if command_cursor == nil then load_cursor() end
    local file = io.open(COMMANDS_PATH, "rb")
    if file == nil then return end
    local end_position = tonumber(file:seek("end")) or 0
    if command_cursor > end_position then command_cursor = end_position end
    file:seek("set", command_cursor)

    local processed = 0
    while processed < MAX_COMMANDS_PER_TICK do
        local line = file:read("*l")
        if line == nil then break end
        processed = processed + 1
        local ok, error_message = pcall(function() process_command(line) end)
        if not ok then
            append_event({
                event = "command-error",
                ok = false,
                reason = tostring(error_message)
            })
        end
        command_cursor = tonumber(file:seek()) or command_cursor
        save_cursor(command_cursor)
    end
    file:close()
end

math.randomseed(os.time())
load_cursor()
pcall(function()
    RegisterHook("/Script/TheIsle.TIPlayerController:SetAdminCred", function(controller_parameter, _admin_parameter)
        local controller = unwrap(controller_parameter)
        local steam = controller_steam_id(controller)
        if steam ~= "" then presence_registry[steam] = true end
    end)
end)
append_event({
    event = "probe-ready",
    ok = true,
    message = "AI manager loaded; historical commands skipped; Maiasaura production pilot available"
})

LoopInGameThreadWithDelay(POLL_MS, function()
    local ok, error_message = pcall(poll_commands)
    if not ok then log("[ERROR] poll failed: " .. tostring(error_message)) end
end)

log("Loaded " .. BUILD .. " (Maiasaura automatic zones require explicit website enable)")
