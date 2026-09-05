-- DinoStorage - validated two-phase parking and inventory capture
-- Version: 0.12.20-alpha-prime-growth-order
--
-- Capture is read-only. A separate commit command is accepted only for the same
-- still-live pawn after the bot has validated and persisted the snapshot. The
-- commit removes that pawn with SetHealth(0). No game-save or respawn API is used.

local MOD_NAME = "DinoStorage"
local MOD_VERSION = "0.12.20-alpha-prime-growth-order"
local SNAPSHOT_SCHEMA_VERSION = 1
local POLL_INTERVAL_MS = 250
local PARKED_CORPSE_GROWTH = 0.01
local FULL_GROWTH_PRIME_RECONCILE_MIN = 0.999
local GROWTH_VERIFY_TOLERANCE = 0.005

local function resolve_mod_root_from_script()
    local fallback = "Mods/DinoStorage"
    if debug == nil or debug.getinfo == nil then return fallback end

    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    if not ok or info == nil or info.source == nil then return fallback end

    local source = tostring(info.source):gsub("^@", ""):gsub("\\", "/")
    local root = source:match("^(.*)/[Ss]cripts/main%.lua$")
    if root == nil or root == "" then return fallback end
    return root
end

local MOD_ROOT = resolve_mod_root_from_script()
local SAVED_ROOT = MOD_ROOT .. "/Saved"
local COMMAND_PATH = MOD_ROOT .. "/dino_storage_commands.ndjson"
local RESULT_PATH = MOD_ROOT .. "/dino_storage_results.ndjson"
local CURSOR_PATH = MOD_ROOT .. "/dino_storage_commands.offset"
local ADMIN_EVENT_PATH = MOD_ROOT .. "/admin_events.ndjson"
local ACTIVITY_SNAPSHOT_PATH = MOD_ROOT .. "/activity_snapshot.json"
local POPULATION_SNAPSHOT_PATH = MOD_ROOT .. "/population_snapshot.json"
local MODS_ROOT = MOD_ROOT:match("^(.*)/[^/]+$") or "Mods"
local SPATIAL_CHAT_QUEUE = MODS_ROOT .. "/HerbivoreChat/queue"
local PRIME_RESTORE_COMMAND_PATH = MODS_ROOT .. "/miniEniac/prime_restore_commands.ndjson"
local command_offset = 0
local bridge_loaded = false
local object_dump_completed = false
local pending_captures = {}
local active_restores = {}
local admin_presence = {}
local pending_presence_logins = {}
local pending_join_welcomes = {}
local recent_chat = {}
local recent_damage = {}
local recent_admin_slays = {}
local recent_self_slays = {}
local pending_chat_self_slays = {}
local recent_player_chat_commands = {}
local chat_self_slay_counter = 0
local safe_logout_started = {}
local SAFE_LOGOUT_MIN_SECONDS = 50
local SAFE_LOGOUT_MAX_SECONDS = 110
local suppressed_deaths = {}
local DEATH_COMBAT_WINDOW_SECONDS = 20
local CHAT_DEDUP_SECONDS = 3
local SNAPSHOT_REFRESH_SECONDS = 30
local PRESENCE_SUMMARY_REFRESH_SECONDS = 2
local LOGIN_SAVE_WAIT_SECONDS = 12
local JOIN_WELCOME_DINO_SETTLE_SECONDS = 3
local ACTIVITY_SNAPSHOT_INTERVAL_SECONDS = 30
local last_activity_snapshot = 0
local POPULATION_HEARTBEAT_SECONDS = 10
local last_population_signature = nil
local last_population_write = 0
local JOIN_WELCOME_SENDER = "The Mesozoic"
local JOIN_WELCOME_MESSAGE = table.concat({
    "Welcome to The Mesozoic!",
    "",
    "Make sure you join our discord at .gg/themesozoic to get access to all our features!",
    "Also make sure you always have your F2 running to report any rulebreaks or bugs you may encounter.",
    "",
    "Supported chat commands: !slay, !hp, !prime, !primelist",
    "",
    "Happy playing Islander!"
}, "\n")

local MUTATION_FIELDS = {
    "MutationSlot1", "MutationSlot2", "MutationSlot3", "MutationSlot4",
    "ParentMutationSlot1", "ParentMutationSlot2", "ParentMutationSlot3", "ParentMutationSlot4",
    "ElderMutationSlot1A", "ElderMutationSlot1B",
    "ElderMutationSlot2A", "ElderMutationSlot2B",
    "ElderMutationSlot3A", "ElderMutationSlot3B",
    "ElderMutationSlot4A", "ElderMutationSlot4B"
}

local SKIN_COLOR_FIELDS = {
    "BodyColor", "MarkingsColor", "FlankColor", "UnderbellyColor",
    "Detail1Color", "EyesColor", "MaleDisplayColor", "TeethColor",
    "MouthColor", "ClawsColor"
}

local PRIME_TASK_NAMES = {
    "Visit a Sanctuary as a Juvenile",
    "Get Nested In",
    "Get Perfect Diet",
    "Visit Mass Migration Zone",
    "Visit 2 Migration Zones",
    "Visit 4 Patrol Zones",
    "Never be infertile",
    "Never get muscle spasms",
    "Raise children to subadult",
    "Species task"
}

local function log(message)
    print(string.format("[%s]%s\n", MOD_NAME, tostring(message)))
end

local function safe_get(fn, fallback)
    local ok, value = pcall(fn)
    if not ok or value == nil then return fallback end
    return value
end

local function is_valid_object(obj)
    if obj == nil then return false end
    local address = safe_get(function() return obj:GetAddress() end, nil)
    if address ~= nil and tonumber(address) == 0 then return false end
    local valid = safe_get(function()
        if obj.IsValid ~= nil then return obj:IsValid() end
        return true
    end, false)
    return valid == true
end

local function object_full_name(obj)
    if not is_valid_object(obj) then return "" end
    return tostring(safe_get(function() return obj:GetFullName() end, "") or "")
end

local function json_escape(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    value = value:gsub("\r", "\\r")
    value = value:gsub("\n", "\\n")
    value = value:gsub("\t", "\\t")
    return value
end

local function json_string(value)
    return '"' .. json_escape(value) .. '"'
end

local function json_bool(value)
    return value == true and "true" or "false"
end

local function json_number(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return "null"
    end
    return string.format("%.17g", number)
end

local function json_string_array(values)
    local encoded = {}
    for _, value in ipairs(values or {}) do
        encoded[#encoded + 1] = json_string(value)
    end
    return "[" .. table.concat(encoded, ",") .. "]"
end

local function json_integer_array(values)
    local encoded = {}
    for _, value in ipairs(values or {}) do
        encoded[#encoded + 1] = tostring(math.floor(tonumber(value) or 0))
    end
    return "[" .. table.concat(encoded, ",") .. "]"
end

local function json_unescape(value)
    value = tostring(value or "")
    value = value:gsub("\\n", "\n")
    value = value:gsub("\\r", "\r")
    value = value:gsub("\\t", "\t")
    value = value:gsub('\\"', '"')
    value = value:gsub("\\\\", "\\")
    return value
end

local function json_get_string(line, key)
    if type(line) ~= "string" or type(key) ~= "string" then return nil end
    local escaped_key = key:gsub("([^%w])", "%%%1")
    local raw = line:match('"' .. escaped_key .. '"%s*:%s*"([^"]*)"')
    if raw == nil then return nil end
    return json_unescape(raw)
end

local function json_get_number(body, key)
    if type(body) ~= "string" or type(key) ~= "string" then return nil end
    local escaped_key = key:gsub("([^%w])", "%%%1")
    local raw = body:match('"' .. escaped_key .. '"%s*:%s*([^,%}%]%s]+)')
    return raw ~= nil and tonumber(raw) or nil
end

local function json_get_bool(body, key)
    if type(body) ~= "string" or type(key) ~= "string" then return nil end
    local escaped_key = key:gsub("([^%w])", "%%%1")
    local raw = body:match('"' .. escaped_key .. '"%s*:%s*(%a+)')
    if raw == "true" then return true end
    if raw == "false" then return false end
    return nil
end

local function json_get_string_array(body, key)
    local values = {}
    if type(body) ~= "string" or type(key) ~= "string" then return values end
    local escaped_key = key:gsub("([^%w])", "%%%1")
    local block = body:match('"' .. escaped_key .. '"%s*:%s*%[(.-)%]')
    if block == nil then return values end
    for raw in block:gmatch('"([^"]*)"') do
        values[#values + 1] = json_unescape(raw)
    end
    return values
end

local function read_customizer_color(customizer, field)
    local color = safe_get(function() return customizer[field] end, nil)
    if color == nil then return nil end
    local value = {
        R = tonumber(safe_get(function() return color.R end, nil)),
        G = tonumber(safe_get(function() return color.G end, nil)),
        B = tonumber(safe_get(function() return color.B end, nil)),
        A = tonumber(safe_get(function() return color.A end, 1.0)) or 1.0
    }
    if value.R == nil or value.G == nil or value.B == nil then return nil end
    return value
end

local function read_text_file(path)
    local file = io.open(path, "rb")
    if file == nil then return nil end
    local body = file:read("*a")
    file:close()
    return body
end

local function json_scalar(value)
    if type(value) == "number" then return json_number(value) end
    if type(value) == "boolean" then return json_bool(value) end
    return json_string(value)
end

local function append_admin_event(event_type, fields)
    local parts = {
        '"ts":' .. tostring(os.time()),
        '"type":' .. json_string(event_type)
    }
    for key, value in pairs(fields or {}) do
        parts[#parts + 1] = json_string(key) .. ":" .. json_scalar(value)
    end
    local file = io.open(ADMIN_EVENT_PATH, "ab")
    if file == nil then
        log(string.format("[AdminLogs][WRITE_FAILED] type=%s path=%s", tostring(event_type), ADMIN_EVENT_PATH))
        return false
    end
    local ok = safe_get(function()
        file:write("{" .. table.concat(parts, ",") .. "}\n")
        file:flush()
        return true
    end, false)
    file:close()
    return ok
end

local function unwrap_hook_param(param)
    if param == nil then return nil end
    local value = nil
    pcall(function() value = param:get() end)
    if value ~= nil then return value end
    return param
end

local function ue_value_string(value)
    if value == nil then return "" end
    if type(value) == "string" then return value end
    local text = safe_get(function() return value:ToString() end, nil)
    if text ~= nil then return tostring(text) end
    text = safe_get(function() return tostring(value) end, "")
    if text:find("^UObject") then return "" end
    return text
end

local function hook_value_string(param)
    local value = unwrap_hook_param(param)
    if value == nil then value = param end
    return ue_value_string(value)
end

local function hook_number(param)
    local value = unwrap_hook_param(param)
    local number = tonumber(value)
    if number ~= nil then return number end
    number = tonumber(safe_get(function() return value.Value end, nil))
    if number ~= nil then return number end
    return tonumber(tostring(value or ""):match("(%d+)"))
end

-- UE4SS enum hook parameters use the same wrapper shapes as numeric values.
-- Keep the separate name at call sites so enum intent remains explicit.
local enum_number = hook_number

local function get_controller_steam_id(controller)
    if not is_valid_object(controller) then return "" end
    local steam_id = safe_get(function() return controller:GetSteamId() end, nil)
    local value = ue_value_string(steam_id)
    if value ~= "" then return value end
    return ue_value_string(safe_get(function() return controller.SteamId end, nil))
end

local function get_controller_name(controller, fallback)
    fallback = tostring(fallback or "Unknown")
    if not is_valid_object(controller) then return fallback end
    local player_state = safe_get(function() return controller.PlayerState end, nil)
    if is_valid_object(player_state) then
        local name = ue_value_string(safe_get(function() return player_state:GetPlayerName() end, nil))
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" then return name end
    end
    return fallback
end

local function get_pawn_controller(pawn)
    if not is_valid_object(pawn) then return nil end
    local controller = safe_get(function() return pawn:GetController() end, nil)
    if is_valid_object(controller) then return controller end
    return nil
end

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

local function get_live_player(steam)
    local game_mode = find_game_mode()
    if not is_valid_object(game_mode) then
        return nil, nil, nil, "game-mode-unavailable"
    end

    local controller = safe_get(function()
        return game_mode:GetControllerBySteamId(tostring(steam))
    end, nil)
    if not is_valid_object(controller) then
        return game_mode, nil, nil, "player-not-online"
    end

    local pawn = safe_get(function() return controller:K2_GetPawn() end, nil)
    if not is_valid_object(pawn) then
        return game_mode, controller, nil, "player-has-no-live-pawn"
    end

    local full_name = object_full_name(pawn):lower()
    if full_name:find("adminpawn", 1, true) or full_name:find("spectator", 1, true) then
        return game_mode, controller, pawn, "spectator-pawn-not-allowed"
    end

    return game_mode, controller, pawn, nil
end

local function make_text(message)
    if FText == nil then return tostring(message or "") end
    local ok, text = pcall(function() return FText(tostring(message or "")) end)
    if ok and text ~= nil then return text end
    return tostring(message or "")
end

local function notify_player(steam, message)
    local game_mode = find_game_mode()
    if not is_valid_object(game_mode) then return false, "game-mode-unavailable" end

    local controller = safe_get(function()
        return game_mode:GetControllerBySteamId(tostring(steam))
    end, nil)
    if not is_valid_object(controller) then return false, "player-not-online" end

    local ok, error_message = pcall(function()
        controller:ClientShowNotification(make_text(message))
    end)
    if not ok then return false, "notification-call-failed:" .. tostring(error_message) end
    return true, nil
end

local function clean_species(class_value, pawn)
    local species = tostring(class_value or "")
    if species == "" then species = object_full_name(pawn) end
    species = species:gsub(".*[/%.]", "")
    species = species:gsub("^BP_", "")
    species = species:gsub("_C.*$", "")
    species = species:gsub("Character.*$", "")
    if species == "" then return "Unknown" end
    return species
end

local function fname_to_string(value)
    if value == nil then return "" end
    local text = safe_get(function() return value:ToString() end, nil)
    if type(text) ~= "string" or text == "" or text == "None" then return "" end
    return text
end

local function capture_fname_array(array_wrapper)
    local values = {}
    if array_wrapper == nil then return values end

    local count = tonumber(safe_get(function() return #array_wrapper end, nil))
    if count ~= nil then
        for index = 1, count do
            local text = fname_to_string(safe_get(function() return array_wrapper[index] end, nil))
            if text ~= "" then values[#values + 1] = text end
        end
        return values
    end

    count = tonumber(safe_get(function() return array_wrapper:GetArrayNum() end, nil))
    if count ~= nil then
        for index = 0, count - 1 do
            local text = fname_to_string(safe_get(function() return array_wrapper[index] end, nil))
            if text ~= "" then values[#values + 1] = text end
        end
    end
    return values
end

local function capture_state(pawn, steam)
    local state = { steam = tostring(steam), capturedAt = os.time() }

    local class_object = safe_get(function() return pawn:GetClass() end, nil)
    state.classPath = object_full_name(class_object)
    if state.classPath == "" then return nil, "class-read-failed" end
    state.classPath = state.classPath:gsub("^BlueprintGeneratedClass%s+", "")
    state.species = clean_species(state.classPath, pawn)

    state.growth = tonumber(safe_get(function() return pawn:GetGrowth() end, nil))
    if state.growth == nil then return nil, "growth-read-failed" end

    local location = safe_get(function() return pawn:K2_GetActorLocation() end, nil)
    state.location = {
        x = location ~= nil and tonumber(safe_get(function() return location.X end, nil)) or nil,
        y = location ~= nil and tonumber(safe_get(function() return location.Y end, nil)) or nil,
        z = location ~= nil and tonumber(safe_get(function() return location.Z end, nil)) or nil
    }
    if state.location.x == nil or state.location.y == nil or state.location.z == nil then
        return nil, "location-read-failed"
    end

    local rotation = safe_get(function() return pawn:K2_GetActorRotation() end, nil)
    state.rotation = {
        pitch = rotation ~= nil and tonumber(safe_get(function() return rotation.Pitch end, nil)) or nil,
        yaw = rotation ~= nil and tonumber(safe_get(function() return rotation.Yaw end, nil)) or nil,
        roll = rotation ~= nil and tonumber(safe_get(function() return rotation.Roll end, nil)) or nil
    }
    if state.rotation.pitch == nil or state.rotation.yaw == nil or state.rotation.roll == nil then
        return nil, "rotation-read-failed"
    end

    local vital_readers = {
        health = function() return pawn:GetHealth() end,
        hunger = function() return pawn:GetHunger() end,
        thirst = function() return pawn:GetThirst() end,
        blood = function() return pawn:GetBlood() end,
        stamina = function() return pawn:GetStamina() end,
        oxygen = function() return pawn:GetOxygen() end,
        lockedDamage = function() return pawn:GetLockedDamage() end,
        food = function() return pawn:GetFoodValue() end,
        rottenValue = function() return pawn:GetRottenValue() end,
        waterLevel = function() return pawn:GetWaterLevel() end,
        maxHealth = function() return pawn:GetMaxHealth() end,
        maxBlood = function() return pawn:GetMaxBlood() end,
        maxHunger = function() return pawn:GetMaxHunger() end,
        maxFoodValue = function() return pawn:GetMaxFoodValue() end,
        maxThirst = function() return pawn:GetMaxThirst() end,
        maxStamina = function() return pawn:GetMaxStamina() end
    }
    for field, reader in pairs(vital_readers) do
        state[field] = tonumber(safe_get(reader, nil))
        if state[field] == nil then return nil, field .. "-read-failed" end
    end

    state.isFemale = safe_get(function() return pawn:IsFemale() end, nil)
    if state.isFemale == nil then return nil, "sex-read-failed" end

    local customizer = safe_get(function() return pawn.CustomizerData end, nil)
    if customizer == nil then return nil, "skin-customizer-read-failed" end
    state.skin = {
        patternIndex = tonumber(safe_get(function() return customizer.PatternIndex end, nil)),
        skinVariation = tonumber(safe_get(function() return customizer.SkinVariation end, nil)),
        themeIndex = tonumber(safe_get(function() return customizer.ThemeIndex end, nil)),
        isFemale = safe_get(function() return customizer.bIsFemale end, state.isFemale) == true,
        colors = {}
    }
    for _, field in ipairs(SKIN_COLOR_FIELDS) do
        local color = read_customizer_color(customizer, field)
        if color == nil then return nil, "skin-color-read-failed:" .. field end
        state.skin.colors[field] = color
    end
    state.isFemale = state.skin.isFemale

    local nutrients = safe_get(function() return pawn.NutrientsStruct end, nil)
    if nutrients == nil then return nil, "nutrients-read-failed" end
    state.nutrients = {
        carbValue = tonumber(safe_get(function() return nutrients.CarbValue end, nil)),
        proteinValue = tonumber(safe_get(function() return nutrients.ProteinValue end, nil)),
        lipidValue = tonumber(safe_get(function() return nutrients.LipidValue end, nil))
    }
    if state.nutrients.carbValue == nil or state.nutrients.proteinValue == nil or state.nutrients.lipidValue == nil then
        return nil, "primary-nutrients-read-failed"
    end

    local mutation_data = safe_get(function() return pawn.ReplicatedMutationsData end, nil)
    if mutation_data == nil then return nil, "mutations-read-failed" end
    state.mutations = {}
    state.mutationCount = 0
    for _, field in ipairs(MUTATION_FIELDS) do
        local value = safe_get(function() return mutation_data[field] end, nil)
        local text = fname_to_string(value)
        state.mutations[field] = text
        if text ~= "" then state.mutationCount = state.mutationCount + 1 end
    end

    state.elderStacks = tonumber(safe_get(function() return pawn:GetElderReplicationStacks() end, nil))
    if state.elderStacks == nil then return nil, "elder-stacks-read-failed" end
    state.elderStacks = math.floor(state.elderStacks)

    local requirements = safe_get(function() return pawn.MutationsRequirementsData end, nil)
    local unlocks = requirements ~= nil and safe_get(function() return requirements.UnlockRequiredMutations end, nil) or nil
    state.unlockRequiredMutations = capture_fname_array(unlocks)

    local prime_data = safe_get(function() return pawn:GetEligiblePrimeElderData() end, nil)
    if prime_data == nil then
        prime_data = safe_get(function() return pawn.EligiblePrimeElderData end, nil)
    end
    if prime_data == nil then return nil, "prime-data-read-failed" end

    state.primeData = { conditions = {}, completed = {}, completedCount = 0 }
    for index = 1, 10 do
        local field = "bPrimeCondition" .. tostring(index)
        local complete = safe_get(function() return prime_data[field] end, nil)
        if type(complete) ~= "boolean" then
            return nil, "prime-condition-" .. tostring(index) .. "-read-failed"
        end
        state.primeData.conditions[index] = complete
        if complete then
            state.primeData.completedCount = state.primeData.completedCount + 1
            state.primeData.completed[#state.primeData.completed + 1] = index
        end
    end
    state.primeData.eligible = safe_get(function() return prime_data.bIsEligiblePrime end, nil)
    if type(state.primeData.eligible) ~= "boolean" then return nil, "prime-eligible-read-failed" end
    state.isPrime = safe_get(function() return pawn:GetIsEligiblePrimeElder() end, nil)
    if state.isPrime == nil then state.isPrime = state.primeData.eligible end

    return state, nil
end

local function serialize_state(state)
    local mutation_lines = {}
    for _, field in ipairs(MUTATION_FIELDS) do
        mutation_lines[#mutation_lines + 1] = string.format('    "%s": %s', field, json_string(state.mutations[field]))
    end

    local condition_lines = {}
    local task_lines = {}
    for index = 1, 10 do
        condition_lines[#condition_lines + 1] = string.format(
            '      "cond%d": %s', index, json_bool(state.primeData.conditions[index])
        )
        task_lines[#task_lines + 1] = string.format(
            '      {"number":%d,"name":%s,"complete":%s}',
            index, json_string(PRIME_TASK_NAMES[index]), json_bool(state.primeData.conditions[index])
        )
    end

    local skin_lines = {
        string.format('    "skinCaptured": %s', json_bool(state.skin ~= nil)),
        string.format('    "patternIndex": %s', json_number(state.skin and state.skin.patternIndex)),
        string.format('    "skinVariation": %s', json_number(state.skin and state.skin.skinVariation)),
        string.format('    "themeIndex": %s', json_number(state.skin and state.skin.themeIndex)),
        string.format('    "skinIsFemale": %s', json_bool(state.skin and state.skin.isFemale))
    }
    for _, field in ipairs(SKIN_COLOR_FIELDS) do
        local color = state.skin and state.skin.colors and state.skin.colors[field] or nil
        skin_lines[#skin_lines + 1] = string.format('    "%sR": %s', field, json_number(color and color.R))
        skin_lines[#skin_lines + 1] = string.format('    "%sG": %s', field, json_number(color and color.G))
        skin_lines[#skin_lines + 1] = string.format('    "%sB": %s', field, json_number(color and color.B))
        skin_lines[#skin_lines + 1] = string.format('    "%sA": %s', field, json_number(color and color.A))
    end

    local lines = {
        "{",
        string.format('  "version": %d,', SNAPSHOT_SCHEMA_VERSION),
        string.format('  "captureMode": %s,', json_string(state.captureMode or "read-only-probe")),
        string.format('  "capturedAt": %d,', state.capturedAt),
        string.format('  "steam": %s,', json_string(state.steam)),
        string.format('  "species": %s,', json_string(state.species)),
        string.format('  "classPath": %s,', json_string(state.classPath)),
        string.format('  "growth": %s,', json_number(state.growth)),
        string.format('  "health": %s,', json_number(state.health)),
        string.format('  "stamina": %s,', json_number(state.stamina)),
        string.format('  "hunger": %s,', json_number(state.hunger)),
        string.format('  "thirst": %s,', json_number(state.thirst)),
        string.format('  "oxygen": %s,', json_number(state.oxygen)),
        string.format('  "blood": %s,', json_number(state.blood)),
        string.format('  "lockedDamage": %s,', json_number(state.lockedDamage)),
        string.format('  "food": %s,', json_number(state.food)),
        string.format('  "waterLevel": %s,', json_number(state.waterLevel)),
        string.format('  "rottenValue": %s,', json_number(state.rottenValue)),
        string.format('  "maxHealth": %s,', json_number(state.maxHealth)),
        string.format('  "maxBlood": %s,', json_number(state.maxBlood)),
        string.format('  "maxHunger": %s,', json_number(state.maxHunger)),
        string.format('  "maxFoodValue": %s,', json_number(state.maxFoodValue)),
        string.format('  "maxThirst": %s,', json_number(state.maxThirst)),
        string.format('  "maxStamina": %s,', json_number(state.maxStamina)),
        string.format('  "isFemale": %s,', json_bool(state.isFemale)),
        string.format('  "isPrime": %s,', json_bool(state.isPrime)),
        '  "generatedShop": false,',
        '  "currentLocationOnly": false,',
        '  "preserveCurrentSkin": false,',
        '  "forceMale": false,',
        '  "forceFemale": false,',
        string.format('  "elderStacks": %d,', state.elderStacks),
        string.format('  "unlockRequiredMutations": %s,', json_string_array(state.unlockRequiredMutations)),
        "  \"nutrients\": {",
        string.format('    "carbValue": %s,', json_number(state.nutrients.carbValue)),
        string.format('    "proteinValue": %s,', json_number(state.nutrients.proteinValue)),
        string.format('    "lipidValue": %s', json_number(state.nutrients.lipidValue)),
        "  },",
        "  \"skin\": {",
        table.concat(skin_lines, ",\n"),
        "  },",
        "  \"primeData\": {",
        string.format('    "eligible": %s,', json_bool(state.primeData.eligible)),
        string.format('    "completedCount": %d,', state.primeData.completedCount),
        string.format('    "completedTaskNumbers": %s,', json_integer_array(state.primeData.completed)),
        "    \"conditions\": {",
        table.concat(condition_lines, ",\n"),
        "    },",
        "    \"tasks\": [",
        table.concat(task_lines, ",\n"),
        "    ]",
        "  },",
        "  \"mutations\": {",
        table.concat(mutation_lines, ",\n"),
        "  },",
        string.format('  "location": {"x":%s,"y":%s,"z":%s},',
            json_number(state.location.x), json_number(state.location.y), json_number(state.location.z)),
        string.format('  "rotation": {"pitch":%s,"yaw":%s,"roll":%s}',
            json_number(state.rotation.pitch), json_number(state.rotation.yaw), json_number(state.rotation.roll)),
        "}",
        ""
    }
    return table.concat(lines, "\n")
end

local function write_atomic(path, content, command_id)
    local temp_path = path .. "." .. tostring(command_id) .. ".tmp"
    local backup_path = path .. ".bak"
    local file = io.open(temp_path, "wb")
    if file == nil then return false, "snapshot-temp-open-failed" end

    local wrote = safe_get(function()
        file:write(content)
        file:flush()
        return true
    end, false)
    file:close()
    if not wrote then
        os.remove(temp_path)
        return false, "snapshot-temp-write-failed"
    end

    local old_file = io.open(path, "rb")
    local had_old = old_file ~= nil
    if old_file ~= nil then old_file:close() end
    os.remove(backup_path)
    if had_old then
        local backed_up = os.rename(path, backup_path)
        if backed_up == nil then
            os.remove(temp_path)
            return false, "snapshot-backup-failed"
        end
    end

    local renamed = os.rename(temp_path, path)
    if renamed == nil then
        if had_old then os.rename(backup_path, path) end
        os.remove(temp_path)
        return false, "snapshot-rename-failed"
    end
    os.remove(backup_path)
    return true, nil
end

local function state_event_fields(state)
    if state == nil then return {} end
    return {
        species = tostring(state.species or ""),
        growth = tonumber(state.growth) or 0,
        sex = state.isFemale == true and "Female" or "Male",
        prime = state.isPrime == true
    }
end

local function capture_presence_summary(pawn)
    if not is_valid_object(pawn) then return nil end
    local class_object = safe_get(function() return pawn:GetClass() end, nil)
    local class_path = object_full_name(class_object):gsub("^BlueprintGeneratedClass%s+", "")
    if class_path == "" then return nil end
    local growth = tonumber(safe_get(function() return pawn:GetGrowth() end, nil))
    local is_female = safe_get(function() return pawn:IsFemale() end, nil)
    if growth == nil or type(is_female) ~= "boolean" then return nil end
    return {
        species = clean_species(class_path, pawn),
        growth = growth,
        isFemale = is_female
    }
end

local function merge_fields(target, source)
    for key, value in pairs(source or {}) do target[key] = value end
    return target
end

local function persist_last_known_snapshot(steam, state)
    if state == nil then return false end
    local previous_mode = state.captureMode
    local previous_time = state.capturedAt
    state.captureMode = "last-known-player-history"
    state.capturedAt = os.time()
    local serialized = serialize_state(state)
    state.captureMode = previous_mode
    state.capturedAt = previous_time
    local path = SAVED_ROOT .. "/last_known_" .. tostring(steam) .. ".json"
    local written = write_atomic(path, serialized, "last-known")
    return written == true
end

local function emit_presence(event_name, steam, name, entry, logout_type)
    local fields = {
        event = event_name,
        steam = tostring(steam or ""),
        name = tostring(name or "Unknown")
    }
    if entry ~= nil then
        local state = entry.last_summary or entry.last_state
        merge_fields(fields, state_event_fields(state))
        fields.saveFound = state ~= nil
    else
        fields.saveFound = false
    end
    if logout_type ~= nil then
        fields.logoutType = tostring(logout_type)
        if entry ~= nil and entry.last_state ~= nil then
            persist_last_known_snapshot(steam, entry.last_state)
        end
    end
    append_admin_event("presence", fields)
end

local function classify_logout(steam, now)
    local started = tonumber(safe_logout_started[steam]) or 0
    if started <= 0 then return "Hardlogged" end
    local elapsed = math.max(0, (tonumber(now) or os.time()) - started)
    if elapsed >= SAFE_LOGOUT_MIN_SECONDS and elapsed <= SAFE_LOGOUT_MAX_SECONDS then
        return "Safelogged"
    end
    return "Hardlogged"
end

local function emit_death(steam, entry, state, pawn_address)
    local now = os.time()
    local snapshot = state or entry.last_state
    local snapshot_file = ""
    if snapshot ~= nil then
        persist_last_known_snapshot(steam, snapshot)
        snapshot.captureMode = "death-log"
        snapshot.capturedAt = now
        snapshot_file = string.format("death_%s_%d.json", tostring(steam), now)
        local path = SAVED_ROOT .. "/" .. snapshot_file
        local written = write_atomic(path, serialize_state(snapshot), "death")
        if not written then snapshot_file = "" end
    end

    local cause = "natural"
    local killer_steam = ""
    local killer_name = ""
    local killer_species = ""
    local killer_growth = nil
    local admin_slay = recent_admin_slays[tostring(steam)]
    if admin_slay ~= nil and now - (tonumber(admin_slay.ts) or 0) <= DEATH_COMBAT_WINDOW_SECONDS then
        cause = "admin-slay"
        killer_steam = tostring(admin_slay.steam or "")
        killer_name = tostring(admin_slay.name or "")
    elseif recent_self_slays[tostring(steam)] ~= nil
        and now - (tonumber(recent_self_slays[tostring(steam)]) or 0)
            <= DEATH_COMBAT_WINDOW_SECONDS then
        cause = "self-slay"
    else
        local damage = recent_damage[tonumber(pawn_address) or 0]
        if damage ~= nil and now - (tonumber(damage.ts) or 0) <= DEATH_COMBAT_WINDOW_SECONDS then
            cause = "player"
            killer_steam = tostring(damage.steam or "")
            killer_name = tostring(damage.name or "")
            killer_species = tostring(damage.species or "")
            killer_growth = tonumber(damage.growth)
        end
    end

    local fields = {
        victimSteam = tostring(steam),
        victimName = tostring(entry.name or "Unknown"),
        cause = cause,
        killerSteam = killer_steam,
        killerName = killer_name,
        killerSpecies = killer_species,
        killerGrowth = killer_growth,
        snapshotFile = snapshot_file
    }
    merge_fields(fields, state_event_fields(snapshot))
    append_admin_event("death", fields)
end

local join_welcome_counter = 0

local function hex_encode(value)
    return (tostring(value or ""):gsub(".", function(character)
        return string.format("%02X", string.byte(character))
    end))
end

local function is_actual_dino_pawn(pawn)
    if not is_valid_object(pawn) then return false end
    local full_name = object_full_name(pawn):lower()
    if full_name:find("adminpawn", 1, true)
        or full_name:find("spectator", 1, true) then
        return false
    end
    return capture_presence_summary(pawn) ~= nil
end

local function write_activity_snapshot(game_mode, now)
    if not is_valid_object(game_mode) then return false, "game-mode-unavailable" end

    local players = {}
    for steam, _entry in pairs(admin_presence) do
        local controller = safe_get(function()
            return game_mode:GetControllerBySteamId(tostring(steam))
        end, nil)
        local pawn = nil
        if is_valid_object(controller) then
            pawn = safe_get(function() return controller:K2_GetPawn() end, nil)
        end

        if is_actual_dino_pawn(pawn) then
            local health = tonumber(safe_get(function() return pawn:GetHealth() end, nil))
            local summary = capture_presence_summary(pawn)
            local location = safe_get(function() return pawn:K2_GetActorLocation() end, nil)
            local x = location ~= nil
                and tonumber(safe_get(function() return location.X end, nil)) or nil
            local y = location ~= nil
                and tonumber(safe_get(function() return location.Y end, nil)) or nil
            if health ~= nil and health > 0 and summary ~= nil and x ~= nil and y ~= nil then
                players[#players + 1] = string.format(
                    '{"species":%s,"x":%s,"y":%s}',
                    json_string(summary.species), json_number(x), json_number(y)
                )
            end
        end
    end

    local payload = string.format(
        '{"updatedAt":%d,"players":[%s]}\n',
        tonumber(now) or os.time(), table.concat(players, ",")
    )
    return write_atomic(ACTIVITY_SNAPSHOT_PATH, payload, "activity-snapshot")
end

local function write_population_snapshot(game_mode, now)
    if not is_valid_object(game_mode) then return false, "game-mode-unavailable" end

    local counts = {}
    local total = 0
    for steam, entry in pairs(admin_presence) do
        local controller = safe_get(function()
            return game_mode:GetControllerBySteamId(tostring(steam))
        end, nil)
        local pawn = nil
        if is_valid_object(controller) then
            pawn = safe_get(function() return controller:K2_GetPawn() end, nil)
        end
        if is_actual_dino_pawn(pawn) then
            local health = tonumber(safe_get(function() return pawn:GetHealth() end, nil))
            local summary = entry ~= nil and entry.last_summary or nil
            local species = summary ~= nil and tostring(summary.species or "") or ""
            if health ~= nil and health > 0 and species ~= "" and species ~= "Unknown" then
                counts[species] = (tonumber(counts[species]) or 0) + 1
                total = total + 1
            end
        end
    end

    local names = {}
    for species, _count in pairs(counts) do names[#names + 1] = species end
    table.sort(names, function(left, right)
        return tostring(left):lower() < tostring(right):lower()
    end)
    local signature_parts = {}
    local json_parts = {}
    for _, species in ipairs(names) do
        local count = tonumber(counts[species]) or 0
        signature_parts[#signature_parts + 1] = tostring(species) .. "=" .. tostring(count)
        json_parts[#json_parts + 1] = json_string(species) .. ":" .. tostring(count)
    end
    local signature = table.concat(signature_parts, "|")
    if signature == last_population_signature
        and now - last_population_write < POPULATION_HEARTBEAT_SECONDS then
        return true, "unchanged"
    end

    local payload = string.format(
        '{"updatedAt":%d,"total":%d,"counts":{%s}}\n',
        tonumber(now) or os.time(), total, table.concat(json_parts, ",")
    )
    local written, reason = write_atomic(
        POPULATION_SNAPSHOT_PATH, payload, "population-snapshot"
    )
    if written then
        last_population_signature = signature
        last_population_write = now
    end
    return written, reason
end

local function write_private_spatial_welcome(controller)
    if not is_valid_object(controller) then return false, "invalid-controller" end
    local target_full_name = tostring(safe_get(function()
        return controller:GetFullName()
    end, "") or "")
    if target_full_name == "" then return false, "target-name-empty" end

    join_welcome_counter = join_welcome_counter + 1
    local base_name = string.format(
        "welcome-%d-%06d",
        os.time(),
        join_welcome_counter % 1000000
    )
    local temporary_path = SPATIAL_CHAT_QUEUE .. "/" .. base_name .. ".tmp"
    local final_path = SPATIAL_CHAT_QUEUE .. "/" .. base_name .. ".hchat"
    local file, open_error = io.open(temporary_path, "wb")
    if file == nil then return false, "queue-open-failed:" .. tostring(open_error) end

    file:write("version=2\n")
    file:write("created=", tostring(os.time()), "\n")
    file:write("mode=0\n")
    file:write("admin=1\n")
    file:write("dev=0\n")
    file:write("target=", hex_encode(target_full_name), "\n")
    file:write("sender=", hex_encode(JOIN_WELCOME_SENDER), "\n")
    file:write("body=", hex_encode(JOIN_WELCOME_MESSAGE), "\n")
    file:write("steam=", hex_encode("0"), "\n")
    file:flush()
    file:close()

    local renamed, rename_error = os.rename(temporary_path, final_path)
    if not renamed then
        os.remove(temporary_path)
        return false, "queue-rename-failed:" .. tostring(rename_error)
    end
    return true, nil
end

local function admin_event_tick()
    local now = os.time()
    local game_mode = find_game_mode()
    if not is_valid_object(game_mode) then return end

    for steam, queued in pairs(pending_join_welcomes) do
        local controller = safe_get(function()
            return game_mode:GetControllerBySteamId(steam)
        end, nil)
        local pawn = nil
        if is_valid_object(controller) then
            pawn = safe_get(function() return controller:K2_GetPawn() end, nil)
        end

        if is_actual_dino_pawn(pawn) then
            if queued.dino_ready_at == nil then
                queued.dino_ready_at = now
            elseif now - tonumber(queued.dino_ready_at)
                >= JOIN_WELCOME_DINO_SETTLE_SECONDS then
                local sent, reason = write_private_spatial_welcome(controller)
                if sent then
                    log("[Welcome][SENT] steam=" .. tostring(steam) .. " target=private-spatial")
                    pending_join_welcomes[steam] = nil
                else
                    queued.last_error = tostring(reason)
                end
            end
        else
            queued.dino_ready_at = nil
        end
    end

    for steam, queued in pairs(pending_presence_logins) do
        local controller = safe_get(function() return game_mode:GetControllerBySteamId(steam) end, nil)
        local entry = admin_presence[steam]
        if entry ~= nil and is_valid_object(controller) then
            entry.name = get_controller_name(controller, queued.name)
            local pawn = safe_get(function() return controller:K2_GetPawn() end, nil)
            if is_valid_object(pawn) then
                entry.last_summary = capture_presence_summary(pawn)
                entry.last_summary_capture = now
                if entry.last_summary ~= nil then
                    local state = capture_state(pawn, steam)
                    if state ~= nil then
                        entry.last_state = state
                        entry.last_capture = now
                    end
                    emit_presence("login", steam, entry.name, entry)
                    pending_presence_logins[steam] = nil
                end
            end
            if pending_presence_logins[steam] ~= nil
                and now - (tonumber(queued.ts) or now) >= LOGIN_SAVE_WAIT_SECONDS then
                emit_presence("login", steam, entry.name, entry)
                pending_presence_logins[steam] = nil
            end
        elseif now - (tonumber(queued.ts) or now) >= LOGIN_SAVE_WAIT_SECONDS then
            emit_presence("login", steam, queued.name, entry)
            pending_presence_logins[steam] = nil
        end
    end

    for steam, entry in pairs(admin_presence) do
        local controller = safe_get(function() return game_mode:GetControllerBySteamId(steam) end, nil)
        if not is_valid_object(controller) then
            entry.misses = (tonumber(entry.misses) or 0) + 1
            if entry.misses >= 15 then
                emit_presence("logout", steam, entry.name, entry, classify_logout(steam, now))
                admin_presence[steam] = nil
                pending_presence_logins[steam] = nil
                pending_join_welcomes[steam] = nil
                safe_logout_started[steam] = nil
            end
        else
            entry.misses = 0
            entry.last_seen = now
            local safe_started = tonumber(safe_logout_started[steam]) or 0
            if safe_started > 0 and now - safe_started > SAFE_LOGOUT_MAX_SECONDS then
                -- The player cancelled the safelog and remained online.
                safe_logout_started[steam] = nil
            end
            entry.name = get_controller_name(controller, entry.name)
            local pawn = safe_get(function() return controller:K2_GetPawn() end, nil)
            if is_valid_object(pawn) then
                local pawn_address = tonumber(safe_get(function() return pawn:GetAddress() end, nil)) or 0
                local pawn_name = object_full_name(pawn):lower()
                local spectator = pawn_name:find("adminpawn", 1, true) ~= nil
                    or pawn_name:find("spectator", 1, true) ~= nil
                if pawn_address ~= 0 and not spectator then
                    local health = tonumber(safe_get(function() return pawn:GetHealth() end, nil))
                    if now - (tonumber(entry.last_summary_capture) or 0)
                        >= PRESENCE_SUMMARY_REFRESH_SECONDS then
                        local summary = capture_presence_summary(pawn)
                        entry.last_summary = summary
                        entry.last_summary_capture = now
                    end
                    if entry.pawn_address ~= pawn_address then
                        entry.pawn_address = pawn_address
                        entry.last_health = health
                        entry.dead_logged = false
                        entry.last_state = nil
                        entry.last_capture = 0
                    end
                    if health ~= nil and health > 0 then
                        if entry.last_health == nil or entry.last_health <= 0 then
                            entry.dead_logged = false
                        end
                        if now - (tonumber(entry.last_capture) or 0) >= SNAPSHOT_REFRESH_SECONDS then
                            local state = capture_state(pawn, steam)
                            if state ~= nil then
                                entry.last_state = state
                                entry.last_capture = now
                            end
                        end
                    elseif health ~= nil and health <= 0
                        and (tonumber(entry.last_health) or 0) > 0
                        and entry.dead_logged ~= true then
                        local suppressed_until = tonumber(suppressed_deaths[steam]) or 0
                        if now > suppressed_until then
                            local state = capture_state(pawn, steam)
                            emit_death(steam, entry, state, pawn_address)
                        end
                        entry.dead_logged = true
                    end
                    entry.last_health = health
                end
            end
        end
    end

    for key, timestamp in pairs(recent_chat) do
        if now - (tonumber(timestamp) or 0) > 30 then recent_chat[key] = nil end
    end
    for address, damage in pairs(recent_damage) do
        if now - (tonumber(damage.ts) or 0) > 30 then recent_damage[address] = nil end
    end
    for steam, slay in pairs(recent_admin_slays) do
        if now - (tonumber(slay.ts) or 0) > 30 then recent_admin_slays[steam] = nil end
    end
    for steam, timestamp in pairs(recent_self_slays) do
        if now - (tonumber(timestamp) or 0) > 30 then
            recent_self_slays[steam] = nil
        end
    end
    for steam, timestamp in pairs(suppressed_deaths) do
        if now > (tonumber(timestamp) or 0) then suppressed_deaths[steam] = nil end
    end

    if now - last_activity_snapshot >= ACTIVITY_SNAPSHOT_INTERVAL_SECONDS then
        local written, reason = write_activity_snapshot(game_mode, now)
        last_activity_snapshot = now
        if not written then
            log("[ActivityMap][SNAPSHOT_FAILED] reason=" .. tostring(reason))
        end
    end

    local population_written, population_reason = write_population_snapshot(game_mode, now)
    if not population_written then
        log("[PopulationControl][SNAPSHOT_FAILED] reason=" .. tostring(population_reason))
    end
end

local function register_admin_log_hooks()
    if RegisterHook == nil then
        log("[AdminLogs][FATAL] RegisterHook unavailable")
        return
    end

    local function register(path, callback, label)
        local ok, error_message = pcall(function() RegisterHook(path, callback) end)
        if ok then
            log("[AdminLogs][HOOK] registered " .. tostring(label))
        else
            log("[AdminLogs][HOOK_FAILED] " .. tostring(label) .. " reason=" .. tostring(error_message))
        end
    end

    register(
        "/Script/TheIsle.TIPlayerController:SetAdminCred",
        function(controller_param, _admin_param)
            local controller = unwrap_hook_param(controller_param)
            if not is_valid_object(controller) then return end
            local steam = get_controller_steam_id(controller)
            if steam == "" then return end
            if admin_presence[steam] == nil then
                local name = get_controller_name(controller, "Unknown")
                admin_presence[steam] = {
                    name = name,
                    first_seen = os.time(),
                    last_seen = os.time(),
                    misses = 0
                }
                pending_presence_logins[steam] = { name = name, ts = os.time() }
                pending_join_welcomes[steam] = {}
            else
                admin_presence[steam].last_seen = os.time()
            end
        end,
        "player-login"
    )

    register(
        "/Script/TheIsle.TIPlayerController:PrepareSafeLogout",
        function(controller_param)
            local controller = unwrap_hook_param(controller_param)
            local steam = get_controller_steam_id(controller)
            if steam ~= "" then safe_logout_started[steam] = os.time() end
        end,
        "safe-logout-start"
    )

    register(
        "/Game/TheIsle/Core/GameModes/BP_SurvivalGameMode.BP_SurvivalGameMode_C:K2_OnLogout",
        function(_game_mode_param, controller_param)
            local controller = unwrap_hook_param(controller_param)
            local steam = get_controller_steam_id(controller)
            if steam == "" then return end
            local entry = admin_presence[steam]
            local name = get_controller_name(controller, entry and entry.name or "Unknown")
            local logout_type = classify_logout(steam, os.time())
            emit_presence("logout", steam, name, entry, logout_type)
            admin_presence[steam] = nil
            pending_presence_logins[steam] = nil
            pending_join_welcomes[steam] = nil
            safe_logout_started[steam] = nil
        end,
        "player-logout"
    )

    register(
        "/Script/TheIsle.TIPlayerController:GetChatMessage",
        function(_receiver_param, text_param, sender_param, mode_param, no_filter_param)
            local controller = unwrap_hook_param(sender_param)
            if not is_valid_object(controller) then return end
            local steam = get_controller_steam_id(controller)
            if steam == "" then return end
            local message = hook_value_string(text_param):gsub("^%s+", ""):gsub("%s+$", "")
            if message == "" then
                message = hook_value_string(no_filter_param):gsub("^%s+", ""):gsub("%s+$", "")
            end
            if message == "" then return end
            local command = message:lower()
            local mode = hook_number(mode_param)
            if command == "!slay" then
                if mode ~= 0 then return end
                local now = os.time()
                local last_seen = tonumber(recent_player_chat_commands[steam .. "|!slay"]) or 0
                if now - last_seen >= CHAT_DEDUP_SECONDS then
                    recent_player_chat_commands[steam .. "|!slay"] = now
                    pending_chat_self_slays[#pending_chat_self_slays + 1] = {
                        steam = tostring(steam),
                        queued_at = now
                    }
                    log(string.format("[InGameCommand][QUEUE] command=!slay steam=%s", tostring(steam)))
                end
                return
            end

            if mode ~= 1 then return end
            local key = steam .. "|" .. message
            local now = os.time()
            if now - (tonumber(recent_chat[key]) or 0) < CHAT_DEDUP_SECONDS then return end
            recent_chat[key] = now
            append_admin_event("global_chat", {
                steam = steam,
                name = get_controller_name(controller, "Unknown"),
                message = message
            })
        end,
        "global-chat"
    )

    register(
        "/Script/TheIsle.TICharacterBase:ApplyDamage",
        function(attacker_param, target_param)
            local attacker = unwrap_hook_param(attacker_param)
            local target = unwrap_hook_param(target_param)
            if not is_valid_object(attacker) or not is_valid_object(target) then return end
            local target_address = tonumber(safe_get(function() return target:GetAddress() end, nil)) or 0
            local controller = get_pawn_controller(attacker)
            local steam = get_controller_steam_id(controller)
            if target_address == 0 or steam == "" then return end
            local attacker_summary = capture_presence_summary(attacker)
            recent_damage[target_address] = {
                steam = steam,
                name = get_controller_name(controller, "Unknown"),
                species = attacker_summary and attacker_summary.species or "",
                growth = attacker_summary and attacker_summary.growth or nil,
                ts = os.time()
            }
        end,
        "damage-attribution"
    )

    local function admin_action(
        controller_param,
        action,
        target_steam_param,
        target_name_param,
        percent_param
    )
        local controller = unwrap_hook_param(controller_param)
        if not is_valid_object(controller) then return end
        local admin_steam = get_controller_steam_id(controller)
        if admin_steam == "" then return end
        local target_steam = hook_value_string(target_steam_param)
        local target_name = hook_value_string(target_name_param)
        local admin_name = get_controller_name(controller, "Unknown")
        local fields = {
            action = action,
            adminSteam = admin_steam,
            adminName = admin_name,
            targetSteam = target_steam,
            targetName = target_name
        }
        local percent = hook_number(percent_param)
        if percent ~= nil then fields.percent = percent end
        append_admin_event("admin_action", fields)
        if action == "slay" and target_steam ~= "" then
            recent_admin_slays[target_steam] = {
                steam = admin_steam,
                name = admin_name,
                ts = os.time()
            }
        end
    end

    register(
        "/Script/TheIsle.TIPlayerController:AskServerForSpectator",
        function(controller_param) admin_action(controller_param, "enter_specmode") end,
        "enter-specmode"
    )
    register(
        "/Script/TheIsle.TIPlayerController:AskServerToReturnFromSpectator",
        function(controller_param) admin_action(controller_param, "exit_specmode") end,
        "exit-specmode"
    )
    register(
        "/Script/TheIsle.TIPlayerController:ServerTeleportToTarget",
        function(controller_param, steam_param, name_param)
            admin_action(controller_param, "teleport_to_player", steam_param, name_param)
        end,
        "teleport-to-player"
    )
    register(
        "/Script/TheIsle.TIPlayerController:ServerTeleportToMe",
        function(controller_param, steam_param, name_param)
            admin_action(controller_param, "bring_player", steam_param, name_param)
        end,
        "bring-player"
    )
    register(
        "/Script/TheIsle.TIPlayerController:ServerSlay",
        function(controller_param, steam_param, name_param)
            admin_action(controller_param, "slay", steam_param, name_param)
        end,
        "slay-player"
    )
    register(
        "/Script/TheIsle.TIPlayerController:ServerHeal",
        function(controller_param, steam_param, name_param)
            admin_action(controller_param, "heal", steam_param, name_param)
        end,
        "heal-player"
    )
    register(
        "/Script/TheIsle.TIPlayerController:ServerGrow",
        function(controller_param, steam_param, name_param, percent_param)
            admin_action(controller_param, "grow", steam_param, name_param, percent_param)
        end,
        "grow-player"
    )
end

local function parse_restore_state(body)
    if type(body) ~= "string" or body == "" then return nil, "restore-json-empty" end
    local state = {
        species = json_get_string(body, "species"),
        classPath = json_get_string(body, "classPath"),
        isPrime = json_get_bool(body, "isPrime"),
        isFemale = json_get_bool(body, "isFemale"),
        unlockRequiredMutations = json_get_string_array(body, "unlockRequiredMutations"),
        mutations = {},
        primeConditions = {},
        location = {},
        rotation = {}
    }
    if state.species == nil or state.species == "" or state.classPath == nil or state.classPath == "" then
        return nil, "restore-class-missing"
    end
    if state.isPrime == nil then return nil, "restore-prime-state-missing" end
    if state.isFemale == nil then return nil, "restore-sex-state-missing" end
    state.generatedShop = json_get_bool(body, "generatedShop") == true
    state.percentageBackedSnapshot =
        json_get_bool(body, "percentageBackedSnapshot") == true
    state.requestedHungerPercent =
        json_get_number(body, "requestedHungerPercent")
    state.requestedThirstPercent =
        json_get_number(body, "requestedThirstPercent")
    state.requestedCarbPercent =
        json_get_number(body, "requestedCarbPercent")
    state.requestedProteinPercent =
        json_get_number(body, "requestedProteinPercent")
    state.requestedLipidPercent =
        json_get_number(body, "requestedLipidPercent")
    if state.percentageBackedSnapshot then
        local requested = {
            state.requestedHungerPercent,
            state.requestedThirstPercent,
            state.requestedCarbPercent,
            state.requestedProteinPercent,
            state.requestedLipidPercent
        }
        for _, value in ipairs(requested) do
            if value == nil or value < 0 or value > 100 then
                return nil, "restore-percentage-snapshot-fields-invalid"
            end
        end
    end
    state.currentLocationOnly = json_get_bool(body, "currentLocationOnly") == true
    state.preserveCurrentSkin = json_get_bool(body, "preserveCurrentSkin") == true
    state.forceMale = json_get_bool(body, "forceMale") == true
    state.forceFemale = json_get_bool(body, "forceFemale") == true
    if state.forceMale and state.forceFemale then
        return nil, "restore-conflicting-forced-gender"
    end

    local skin_captured = json_get_bool(body, "skinCaptured") == true
    if not state.preserveCurrentSkin and skin_captured then
        state.skin = {
            patternIndex = json_get_number(body, "patternIndex"),
            skinVariation = json_get_number(body, "skinVariation"),
            themeIndex = json_get_number(body, "themeIndex"),
            isFemale = json_get_bool(body, "skinIsFemale"),
            colors = {}
        }
        if state.skin.isFemale == nil then return nil, "restore-skin-sex-missing" end
        for _, field in ipairs(SKIN_COLOR_FIELDS) do
            local color = {
                R = json_get_number(body, field .. "R"),
                G = json_get_number(body, field .. "G"),
                B = json_get_number(body, field .. "B"),
                A = json_get_number(body, field .. "A")
            }
            if color.R == nil or color.G == nil or color.B == nil or color.A == nil then
                return nil, "restore-skin-color-missing:" .. field
            end
            state.skin.colors[field] = color
        end
    end

    local number_fields = {
        "growth", "health", "stamina", "hunger", "thirst", "oxygen", "blood",
        "lockedDamage", "food", "rottenValue", "maxHunger", "maxFoodValue",
        "maxThirst", "maxStamina", "maxHealth", "maxBlood", "elderStacks",
        "carbValue", "proteinValue", "lipidValue"
    }
    for _, field in ipairs(number_fields) do
        state[field] = json_get_number(body, field)
        if state[field] == nil then return nil, "restore-field-missing:" .. field end
    end
    state.elderStacks = math.floor(state.elderStacks)
    state.generatedHungerFraction = json_get_number(body, "generatedHungerFraction")
    state.generatedThirstFraction = json_get_number(body, "generatedThirstFraction")
    if state.generatedHungerFraction == nil then state.generatedHungerFraction = 1.0 end
    if state.generatedThirstFraction == nil then state.generatedThirstFraction = 1.0 end
    if state.generatedHungerFraction < 0 or state.generatedHungerFraction > 1
        or state.generatedThirstFraction < 0 or state.generatedThirstFraction > 1 then
        return nil, "restore-generated-needs-fraction-invalid"
    end
    if state.generatedShop then
        state.generatedCarbPercent = json_get_number(body, "carb")
        state.generatedProteinPercent = json_get_number(body, "protein")
        state.generatedLipidPercent = json_get_number(body, "lipid")
        if state.generatedCarbPercent == nil then state.generatedCarbPercent = state.carbValue * 100 end
        if state.generatedProteinPercent == nil then state.generatedProteinPercent = state.proteinValue * 100 end
        if state.generatedLipidPercent == nil then state.generatedLipidPercent = state.lipidValue * 100 end
        if state.generatedCarbPercent < 0 or state.generatedCarbPercent > 100
            or state.generatedProteinPercent < 0 or state.generatedProteinPercent > 100
            or state.generatedLipidPercent < 0 or state.generatedLipidPercent > 100 then
            return nil, "restore-generated-nutrient-percent-invalid"
        end
    end

    state.location.x = json_get_number(body, "x")
    state.location.y = json_get_number(body, "y")
    state.location.z = json_get_number(body, "z")
    state.rotation.pitch = json_get_number(body, "pitch")
    state.rotation.yaw = json_get_number(body, "yaw")
    state.rotation.roll = json_get_number(body, "roll")
    if state.location.x == nil or state.location.y == nil or state.location.z == nil
        or state.rotation.pitch == nil or state.rotation.yaw == nil or state.rotation.roll == nil then
        return nil, "restore-transform-missing"
    end

    for index = 1, 10 do
        local value = json_get_bool(body, "cond" .. tostring(index))
        if value == nil then return nil, "restore-prime-condition-missing:" .. tostring(index) end
        state.primeConditions[index] = value
    end
    for _, field in ipairs(MUTATION_FIELDS) do
        local value = json_get_string(body, field)
        if value == nil then return nil, "restore-mutation-field-missing:" .. field end
        state.mutations[field] = value
    end
    return state, nil
end

local function normalize_restore_snapshot(pawn, state)
    local explicit_percentage_snapshot =
        state.percentageBackedSnapshot == true
    local existing_maxima = {
        tonumber(state.maxHealth) or 0,
        tonumber(state.maxBlood) or 0,
        tonumber(state.maxStamina) or 0,
        tonumber(state.maxHunger) or 0,
        tonumber(state.maxFoodValue) or 0,
        tonumber(state.maxThirst) or 0
    }
    local complete = true
    for _, value in ipairs(existing_maxima) do
        if value <= 0 then
            complete = false
            break
        end
    end
    local ratio_snapshot = complete
        and (tonumber(state.maxHealth) or 0) <= 1.000001
        and (tonumber(state.maxBlood) or 0) <= 1.000001
        and (tonumber(state.maxStamina) or 0) <= 1.000001
        and (tonumber(state.maxHunger) or 0) <= 1.000001
        and (tonumber(state.maxFoodValue) or 0) <= 1.000001
        and (tonumber(state.maxThirst) or 0) <= 1.000001
    local percentage_snapshot =
        explicit_percentage_snapshot or ratio_snapshot or state.generatedShop
    if complete and not percentage_snapshot then return true, nil end
    if not percentage_snapshot then
        return false, "restore-snapshot-maxima-invalid"
    end

    local old = {
        health = tonumber(state.health) or 0,
        maxHealth = tonumber(state.maxHealth) or 0,
        blood = tonumber(state.blood) or 0,
        maxBlood = tonumber(state.maxBlood) or 0,
        stamina = tonumber(state.stamina) or 0,
        maxStamina = tonumber(state.maxStamina) or 0,
        hunger = tonumber(state.hunger) or 0,
        maxHunger = tonumber(state.maxHunger) or 0,
        food = tonumber(state.food) or 0,
        maxFoodValue = tonumber(state.maxFoodValue) or 0,
        thirst = tonumber(state.thirst) or 0,
        maxThirst = tonumber(state.maxThirst) or 0,
        carbValue = tonumber(state.carbValue) or 0,
        proteinValue = tonumber(state.proteinValue) or 0,
        lipidValue = tonumber(state.lipidValue) or 0
    }
    local function fraction(value, maximum, fallback)
        if maximum > 0 then return math.max(0, value / maximum) end
        return math.max(0, tonumber(fallback) or 0)
    end

    -- These rows were created from administrator/shop percentage choices
    -- rather than a captured live dinosaur. Preserve the requested percentages
    -- so the final settled phase can use the game's own native setters.
    state.percentageBackedSnapshot = true
    state.requestedHungerPercent = state.requestedHungerPercent
        or fraction(
            old.hunger,
            old.maxHunger,
            state.generatedHungerFraction
        ) * 100
    state.requestedThirstPercent = state.requestedThirstPercent
        or fraction(
            old.thirst,
            old.maxThirst,
            state.generatedThirstFraction
        ) * 100
    state.requestedCarbPercent = state.requestedCarbPercent
        or fraction(
            old.carbValue,
            old.maxHunger,
            (tonumber(state.generatedCarbPercent) or 0) / 100
        ) * 100
    state.requestedProteinPercent = state.requestedProteinPercent
        or fraction(
            old.proteinValue,
            old.maxHunger,
            (tonumber(state.generatedProteinPercent) or 0) / 100
        ) * 100
    state.requestedLipidPercent = state.requestedLipidPercent
        or fraction(
            old.lipidValue,
            old.maxHunger,
            (tonumber(state.generatedLipidPercent) or 0) / 100
        ) * 100

    local maxima = {
        maxHealth = tonumber(safe_get(function() return pawn:GetMaxHealth() end, nil)),
        maxBlood = tonumber(safe_get(function() return pawn:GetMaxBlood() end, nil)),
        maxStamina = tonumber(safe_get(function() return pawn:GetMaxStamina() end, nil)),
        maxHunger = tonumber(safe_get(function() return pawn:GetMaxHunger() end, nil)),
        maxFoodValue = tonumber(safe_get(function() return pawn:GetMaxFoodValue() end, nil)),
        maxThirst = tonumber(safe_get(function() return pawn:GetMaxThirst() end, nil))
    }
    for name, value in pairs(maxima) do
        if value == nil or value <= 0 then
            return false, "restore-legacy-ratio-" .. name .. "-failed"
        end
        state[name] = value
    end

    -- Administrator and shop snapshots store percentages with maxima of 1.0;
    -- legacy shop rows used zero maxima plus explicit percentage fields.
    -- Expand either representation only after the native Grow recalculation
    -- has settled, then every later phase uses the same absolute snapshot
    -- fields as a parked dino.
    state.health = state.maxHealth
        * fraction(old.health, old.maxHealth, 1.0)
    state.blood = state.maxBlood
        * fraction(old.blood, old.maxBlood, 1.0)
    state.stamina = state.maxStamina
        * fraction(old.stamina, old.maxStamina, 1.0)
    state.hunger = state.maxHunger
        * fraction(old.hunger, old.maxHunger, state.generatedHungerFraction)
    state.food = state.maxFoodValue
        * fraction(old.food, old.maxFoodValue, state.generatedHungerFraction)
    state.thirst = state.maxThirst
        * fraction(old.thirst, old.maxThirst, state.generatedThirstFraction)
    state.lockedDamage = 0
    local healthy_rotten = tonumber(state.generatedHealthyRottenValue)
    if healthy_rotten == nil or healthy_rotten <= 0 then
        healthy_rotten = tonumber(safe_get(function()
            return pawn:GetRottenValue()
        end, nil))
    end
    if healthy_rotten == nil or healthy_rotten <= 0 then healthy_rotten = 1800 end
    state.rottenValue = healthy_rotten
    state.oxygen = 1000
    state.carbValue = state.maxHunger * fraction(
        old.carbValue,
        old.maxHunger,
        (tonumber(state.generatedCarbPercent) or 0) / 100
    )
    state.proteinValue = state.maxHunger * fraction(
        old.proteinValue,
        old.maxHunger,
        (tonumber(state.generatedProteinPercent) or 0) / 100
    )
    state.lipidValue = state.maxHunger * fraction(
        old.lipidValue,
        old.maxHunger,
        (tonumber(state.generatedLipidPercent) or 0) / 100
    )
    log(string.format(
        "[Restore][NORMALIZE] expanded percentage snapshot after growth settled explicit=%s ratio=%s generatedShop=%s requested=%.3f/%.3f/%.3f/%.3f/%.3f",
        tostring(explicit_percentage_snapshot),
        tostring(ratio_snapshot),
        tostring(state.generatedShop),
        tonumber(state.requestedHungerPercent) or -1,
        tonumber(state.requestedThirstPercent) or -1,
        tonumber(state.requestedCarbPercent) or -1,
        tonumber(state.requestedProteinPercent) or -1,
        tonumber(state.requestedLipidPercent) or -1
    ))
    return true, nil
end

local function apply_max_vitals(pawn, state)
    -- Percentage-backed administrator/shop rows have no captured species
    -- maxima. SetGrowth owns those values. Writing an early live reading back
    -- later can pin a large dinosaur to its juvenile capacity.
    if state.percentageBackedSnapshot then return true, nil end

    local calls = {
        { "max-hunger", function() pawn:SetMaxHunger(state.maxHunger) end },
        { "max-food", function() pawn:SetMaxFood(state.maxFoodValue) end },
        { "max-thirst", function() pawn:SetMaxThirst(state.maxThirst) end },
        { "max-stamina", function() pawn:SetMaxStamina(state.maxStamina) end }
    }
    for _, call in ipairs(calls) do
        local ok, error_message = pcall(call[2])
        if not ok then
            return false, "restore-" .. call[1] .. "-failed:" .. tostring(error_message)
        end
    end
    return true, nil
end

local function apply_vitals(pawn, state, game_mode, controller, steam)
    local function scaled_value(value, captured_maximum, live_maximum)
        local current = tonumber(value) or 0
        local captured_max = tonumber(captured_maximum) or 0
        local live_max = tonumber(live_maximum) or 0
        if captured_max > 0 and live_max > 0 then
            return math.max(0, (current / captured_max) * live_max)
        end
        return current
    end
    local live_max_health = tonumber(safe_get(function() return pawn:GetMaxHealth() end, 0)) or 0
    local live_max_blood = tonumber(safe_get(function() return pawn:GetMaxBlood() end, 0)) or 0
    local live_max_stamina = tonumber(safe_get(function() return pawn:GetMaxStamina() end, 0)) or 0
    local live_max_hunger = tonumber(safe_get(function() return pawn:GetMaxHunger() end, 0)) or 0
    local live_max_food = tonumber(safe_get(function() return pawn:GetMaxFoodValue() end, 0)) or 0
    local live_max_thirst = tonumber(safe_get(function() return pawn:GetMaxThirst() end, 0)) or 0
    local calls = {
        { "locked-damage", function() pawn:SetLockedDamage(state.lockedDamage) end },
        { "food", function()
            pawn:SetFood(scaled_value(state.food, state.maxFoodValue, live_max_food))
        end },
        { "rotten", function() pawn:SetRottenValue(state.rottenValue) end },
        { "thirst", function()
            pawn:SetThirst(scaled_value(state.thirst, state.maxThirst, live_max_thirst))
        end },
        { "oxygen", function() pawn:SetOxygen(state.oxygen) end },
        { "blood", function()
            pawn:SetBlood(scaled_value(state.blood, state.maxBlood, live_max_blood))
        end },
        { "stamina", function()
            pawn:SetStamina(scaled_value(state.stamina, state.maxStamina, live_max_stamina))
        end },
        { "health", function()
            pawn:SetHealth(scaled_value(state.health, state.maxHealth, live_max_health))
        end },
        -- Hunger must remain the final vital write. SetNutrientsStruct and
        -- several GAS-backed stat writes can otherwise replace it.
        { "hunger", function()
            pawn:SetHunger(scaled_value(state.hunger, state.maxHunger, live_max_hunger))
        end }
    }
    for _, call in ipairs(calls) do
        local ok, error_message = pcall(call[2])
        if not ok then return false, "restore-" .. call[1] .. "-failed:" .. tostring(error_message) end
    end
    return true, nil
end

local function apply_nutrients(game_mode, controller, pawn, steam, state)
    local nutrients = safe_get(function() return pawn.NutrientsStruct end, nil)
    if nutrients == nil then return false, "restore-nutrients-unavailable" end
    local captured_capacity = tonumber(state.maxHunger) or 0
    local live_capacity = tonumber(safe_get(function() return pawn:GetMaxHunger() end, 0)) or 0
    local function scaled_nutrient(value)
        local current = tonumber(value) or 0
        if captured_capacity > 0 and live_capacity > 0 then
            return math.max(0, (current / captured_capacity) * live_capacity)
        end
        return current
    end
    local ok, error_message = pcall(function()
        nutrients.CarbValue = scaled_nutrient(state.carbValue)
        nutrients.ProteinValue = scaled_nutrient(state.proteinValue)
        nutrients.LipidValue = scaled_nutrient(state.lipidValue)
        pawn:SetNutrientsStruct(nutrients, true)
    end)
    if not ok then return false, "restore-nutrients-failed:" .. tostring(error_message) end
    return true, nil
end

local function refresh_percentage_snapshot_from_live(pawn, state)
    local maxima = {
        maxHealth = tonumber(safe_get(function() return pawn:GetMaxHealth() end, nil)),
        maxBlood = tonumber(safe_get(function() return pawn:GetMaxBlood() end, nil)),
        maxStamina = tonumber(safe_get(function() return pawn:GetMaxStamina() end, nil)),
        maxHunger = tonumber(safe_get(function() return pawn:GetMaxHunger() end, nil)),
        maxFoodValue =
            tonumber(safe_get(function() return pawn:GetMaxFoodValue() end, nil)),
        maxThirst = tonumber(safe_get(function() return pawn:GetMaxThirst() end, nil))
    }
    for name, value in pairs(maxima) do
        if value == nil or value <= 0 then
            return false, "restore-final-live-" .. name .. "-invalid"
        end
        state[name] = value
    end

    local hunger_fraction =
        math.max(0, (tonumber(state.requestedHungerPercent) or 0) / 100)
    local thirst_fraction =
        math.max(0, (tonumber(state.requestedThirstPercent) or 0) / 100)
    local carb_fraction =
        math.max(0, (tonumber(state.requestedCarbPercent) or 0) / 100)
    local protein_fraction =
        math.max(0, (tonumber(state.requestedProteinPercent) or 0) / 100)
    local lipid_fraction =
        math.max(0, (tonumber(state.requestedLipidPercent) or 0) / 100)
    state.health = state.maxHealth
    state.blood = state.maxBlood
    state.stamina = state.maxStamina
    state.hunger = state.maxHunger * hunger_fraction
    state.food = state.maxFoodValue * hunger_fraction
    state.thirst = state.maxThirst * thirst_fraction
    state.carbValue = state.maxHunger * carb_fraction
    state.proteinValue = state.maxHunger * protein_fraction
    state.lipidValue = state.maxHunger * lipid_fraction
    log(string.format(
        "[Restore][FINAL_LIVE_CAPACITY] maxHealth=%.3f maxBlood=%.3f maxStamina=%.3f maxHunger=%.3f maxFood=%.3f maxThirst=%.3f",
        state.maxHealth,
        state.maxBlood,
        state.maxStamina,
        state.maxHunger,
        state.maxFoodValue,
        state.maxThirst
    ))
    return true, nil
end

local function reconcile_final_needs(pawn, steam, state, phase)
    local live_food_max =
        tonumber(safe_get(function() return pawn:GetMaxFoodValue() end, 0)) or 0
    local live_hunger_max =
        tonumber(safe_get(function() return pawn:GetMaxHunger() end, 0)) or 0
    local live_thirst_max =
        tonumber(safe_get(function() return pawn:GetMaxThirst() end, 0)) or 0
    local captured_food_max = tonumber(state.maxFoodValue) or 0
    local captured_hunger_max = tonumber(state.maxHunger) or 0
    local captured_thirst_max = tonumber(state.maxThirst) or 0
    if live_food_max <= 0 or captured_food_max <= 0 then
        return false, "restore-final-food-capacity-invalid"
    end
    if live_hunger_max <= 0 or captured_hunger_max <= 0 then
        return false, "restore-final-hunger-capacity-invalid"
    end
    if live_thirst_max <= 0 or captured_thirst_max <= 0 then
        return false, "restore-final-thirst-capacity-invalid"
    end

    local final_food = math.max(
        0,
        ((tonumber(state.food) or 0) / captured_food_max) * live_food_max
    )
    local final_hunger = math.max(
        0,
        ((tonumber(state.hunger) or 0) / captured_hunger_max) * live_hunger_max
    )
    local final_thirst = math.max(
        0,
        ((tonumber(state.thirst) or 0) / captured_thirst_max) * live_thirst_max
    )

    -- Obtain and write a fresh NutrientsStruct only within this tick. The
    -- wrapper is never retained across a deferred boundary. Nutrients precede
    -- the separate GAS-backed FoodValue and Hunger writes.
    local nutrients_ok, nutrients_error =
        apply_nutrients(nil, nil, pawn, steam, state)
    if not nutrients_ok then return false, nutrients_error end
    local calls = {
        { "exact-thirst", function() pawn:SetThirst(final_thirst) end },
        { "exact-food", function() pawn:SetFood(final_food) end },
        { "exact-hunger", function() pawn:SetHunger(final_hunger) end }
    }
    for _, call in ipairs(calls) do
        local ok, error_message = pcall(call[2])
        if not ok then
            return false,
                "restore-" .. call[1] .. "-failed:" .. tostring(error_message)
        end
    end
    pcall(function() pawn:ForceNetUpdate() end)
    log(string.format(
        "[Restore][NEEDS_RECONCILE] phase=%s steam=%s food=%.3f/%.3f hunger=%.3f/%.3f thirst=%.3f/%.3f nutrients-before-food-hunger=true",
        tostring(phase or "final"),
        tostring(steam),
        final_food,
        live_food_max,
        final_hunger,
        live_hunger_max,
        final_thirst,
        live_thirst_max
    ))
    return true, nil
end

local function apply_final_needs(game_mode, controller, pawn, steam, state)
    if state.percentageBackedSnapshot then
        local refreshed, refresh_error =
            refresh_percentage_snapshot_from_live(pawn, state)
        if not refreshed then return false, refresh_error end
        local vitals_ok, vitals_error =
            apply_vitals(pawn, state, game_mode, controller, steam)
        if not vitals_ok then return false, vitals_error end

        local target_name = get_controller_name(controller, tostring(steam))
        local calls = {
            {
                "native-carb",
                function()
                    game_mode:SetNutrientSlotValue(
                        controller,
                        tostring(steam),
                        target_name,
                        true,
                        false,
                        false,
                        state.requestedCarbPercent
                    )
                end
            },
            {
                "native-protein",
                function()
                    game_mode:SetNutrientSlotValue(
                        controller,
                        tostring(steam),
                        target_name,
                        false,
                        true,
                        false,
                        state.requestedProteinPercent
                    )
                end
            },
            {
                "native-lipid",
                function()
                    game_mode:SetNutrientSlotValue(
                        controller,
                        tostring(steam),
                        target_name,
                        false,
                        false,
                        true,
                        state.requestedLipidPercent
                    )
                end
            },
            {
                "native-thirst",
                function()
                    game_mode:SetThirst(
                        controller,
                        tostring(steam),
                        target_name,
                        state.requestedThirstPercent
                    )
                end
            },
            -- Keep the native command for game-owned side effects. A direct
            -- live-capacity reconciliation follows because Hunger and
            -- FoodValue are separate GAS attributes.
            {
                "native-hunger",
                function()
                    game_mode:SetHunger(
                        controller,
                        tostring(steam),
                        target_name,
                        state.requestedHungerPercent
                    )
                end
            }
        }
        for _, call in ipairs(calls) do
            local ok, error_message = pcall(call[2])
            if not ok then
                return false,
                    "restore-" .. call[1] .. "-failed:"
                        .. tostring(error_message)
            end
        end
        local reconciled, reconcile_error =
            reconcile_final_needs(pawn, steam, state, "native-percentage")
        if not reconciled then return false, reconcile_error end
        local live_nutrients =
            safe_get(function() return pawn.NutrientsStruct end, nil)
        log(string.format(
            "[Restore][FINAL_NATIVE_NEEDS] steam=%s hungerPct=%.3f thirstPct=%.3f nutrientPct=%.3f/%.3f/%.3f liveHunger=%.3f/%.3f liveFood=%.3f/%.3f liveNutrients=%.3f/%.3f/%.3f",
            tostring(steam),
            tonumber(state.requestedHungerPercent) or -1,
            tonumber(state.requestedThirstPercent) or -1,
            tonumber(state.requestedCarbPercent) or -1,
            tonumber(state.requestedProteinPercent) or -1,
            tonumber(state.requestedLipidPercent) or -1,
            tonumber(safe_get(function() return pawn:GetHunger() end, nil)) or -1,
            tonumber(safe_get(function() return pawn:GetMaxHunger() end, nil)) or -1,
            tonumber(safe_get(function() return pawn:GetFoodValue() end, nil)) or -1,
            tonumber(safe_get(function() return pawn:GetMaxFoodValue() end, nil)) or -1,
            tonumber(live_nutrients ~= nil and safe_get(
                function() return live_nutrients.CarbValue end,
                nil
            ) or nil) or -1,
            tonumber(live_nutrients ~= nil and safe_get(
                function() return live_nutrients.ProteinValue end,
                nil
            ) or nil) or -1,
            tonumber(live_nutrients ~= nil and safe_get(
                function() return live_nutrients.LipidValue end,
                nil
            ) or nil) or -1
        ))
        return true, nil
    end

    local maxima_ok, maxima_error = apply_max_vitals(pawn, state)
    if not maxima_ok then return false, maxima_error end

    -- Native Grow can refill GAS-backed current values even after the growth
    -- ratio itself has settled. Reapply every captured current vital after the
    -- last growth write, including thirst, health, blood, and stamina. The
    -- nutrient pass follows, then both FoodValue and Hunger are repeated
    -- because that pass can replace either GAS-backed current value.
    local vitals_ok, vitals_error =
        apply_vitals(pawn, state, game_mode, controller, steam)
    if not vitals_ok then return false, vitals_error end

    return reconcile_final_needs(pawn, steam, state, "captured-snapshot")
end

local function apply_skin_state(pawn, state)
    if state.preserveCurrentSkin and not state.forceMale and not state.forceFemale then return true, nil end
    local customizer = safe_get(function() return pawn.CustomizerData end, nil)
    if customizer == nil then return false, "restore-skin-customizer-unavailable" end

    local failures = {}
    if not state.preserveCurrentSkin then
        if state.skin ~= nil and state.skin.colors ~= nil then
            for _, field in ipairs(SKIN_COLOR_FIELDS) do
                local color = state.skin.colors[field]
                local ok, error_message = pcall(function()
                    customizer[field].R = color.R
                    customizer[field].G = color.G
                    customizer[field].B = color.B
                    customizer[field].A = color.A
                end)
                if not ok then failures[#failures + 1] = field .. ":" .. tostring(error_message) end
            end
            if state.skin.patternIndex ~= nil and state.skin.patternIndex >= 0 and state.skin.patternIndex <= 255 then
                local ok, error_message = pcall(function()
                    customizer.PatternIndex = math.floor(state.skin.patternIndex)
                end)
                if not ok then failures[#failures + 1] = "PatternIndex:" .. tostring(error_message) end
            end
            if state.skin.skinVariation ~= nil then
                local ok, error_message = pcall(function()
                    customizer.SkinVariation = math.floor(state.skin.skinVariation)
                end)
                if not ok then failures[#failures + 1] = "SkinVariation:" .. tostring(error_message) end
            end
            if state.skin.themeIndex ~= nil then
                pcall(function() customizer.ThemeIndex = math.floor(state.skin.themeIndex) end)
            end
        end
    end

    local target_female = nil
    if state.forceMale then
        target_female = false
    elseif state.forceFemale then
        target_female = true
    elseif state.skin ~= nil then
        target_female = state.skin.isFemale
    end
    if target_female == nil then target_female = state.isFemale end
    if target_female ~= nil then
        local ok, error_message = pcall(function() customizer.bIsFemale = target_female == true end)
        if not ok then failures[#failures + 1] = "bIsFemale:" .. tostring(error_message) end
    end
    local net_ok, net_error = pcall(function() pawn:ForceNetUpdate() end)
    if not net_ok then failures[#failures + 1] = "ForceNetUpdate:" .. tostring(net_error) end
    if #failures > 0 then return false, "restore-skin-failed:" .. table.concat(failures, "|") end
    return true, nil
end

local function apply_prime_data(pawn, state)
    local prime = safe_get(function() return pawn:GetEligiblePrimeElderData() end, nil)
    if prime == nil then prime = safe_get(function() return pawn.EligiblePrimeElderData end, nil) end
    if prime == nil then return false, "restore-prime-data-unavailable" end
    -- EVRIMA keeps a volatile/server eligibility flag separately from the
    -- EligiblePrimeElderData struct. The native setter must run first because
    -- it may rebuild the struct; the exact captured struct is therefore the
    -- final writer. This replaces the accidental manual-grow recalculation.
    local server_ok, server_error = pcall(function()
        pawn:ServerSetPrimeEligible(state.isPrime == true)
    end)
    if not server_ok then
        return false, "restore-prime-server-eligibility-failed:" .. tostring(server_error)
    end

    local ok, error_message = pcall(function()
        for index = 1, 10 do
            prime["bPrimeCondition" .. tostring(index)] = state.primeConditions[index]
        end
        prime.bIsEligiblePrime = state.isPrime
        pawn:SetEligiblePrimeElderData(prime)
    end)
    if not ok then return false, "restore-prime-data-failed:" .. tostring(error_message) end
    return true, nil
end

local function queue_prime_restore_handoff(command_id, steam, pawn, state)
    local file = io.open(PRIME_RESTORE_COMMAND_PATH, "ab")
    if file == nil then
        return false, "restore-prime-handoff-open-failed"
    end

    local fields = {
        '"id":' .. json_string(command_id),
        '"verb":"prime.restore"',
        '"steam":' .. json_string(steam),
        '"species":' .. json_string(state.species or ""),
        '"pawnAddress":' .. json_string(tostring(tonumber(safe_get(function()
            return pawn:GetAddress()
        end, 0)) or 0)),
        '"eligible":' .. json_bool(state.isPrime == true),
        '"captureSkin":' .. json_bool(state.skin ~= nil)
    }
    for index = 1, 10 do
        fields[#fields + 1] = '"cond' .. tostring(index) .. '":'
            .. json_bool(state.primeConditions[index] == true)
    end
    fields[#fields + 1] = '"ts":' .. tostring(os.time())

    local ok = safe_get(function()
        file:write("{" .. table.concat(fields, ",") .. "}\n")
        file:flush()
        return true
    end, false)
    file:close()
    if not ok then return false, "restore-prime-handoff-write-failed" end
    return true, nil
end

local function apply_final_prime_data(pawn, state)
    local condition7_source = "snapshot"
    local saved_condition7 = state.primeConditions[7] == true

    -- Condition 7 is native-owned and naturally changes when a dinosaur
    -- becomes infertile at full growth. At effectively 100% growth, the live
    -- post-Grow value is authoritative so an expected game transition cannot
    -- become a false restore failure. Every other Prime condition still comes
    -- from the parked snapshot.
    -- Generated percentage-backed Prime dinosaurs are explicitly granted with
    -- all ten conditions complete. Preserve that authoritative grant instead
    -- of replacing Task 7 with the temporary post-transform native default.
    local preserve_generated_prime = state.percentageBackedSnapshot == true
        and state.isPrime == true
    if not preserve_generated_prime
        and (tonumber(state.growth) or 0) >= FULL_GROWTH_PRIME_RECONCILE_MIN then
        local live_prime =
            safe_get(function() return pawn:GetEligiblePrimeElderData() end, nil)
        if live_prime == nil then
            live_prime =
                safe_get(function() return pawn.EligiblePrimeElderData end, nil)
        end
        if live_prime == nil then
            return false, "restore-final-prime-data-unavailable"
        end
        local live_condition7 =
            safe_get(function() return live_prime.bPrimeCondition7 end, nil)
        if type(live_condition7) ~= "boolean" then
            return false, "restore-final-prime-condition7-unavailable"
        end
        state.primeConditions[7] = live_condition7
        condition7_source = "live-full-growth"
        log(string.format(
            "[Restore][PRIME_CONDITION7_RECONCILED] growth=%.6f saved=%s live=%s source=%s",
            tonumber(state.growth) or 0,
            tostring(saved_condition7),
            tostring(live_condition7),
            condition7_source
        ))
    elseif preserve_generated_prime then
        condition7_source = "generated-prime-snapshot"
    end

    local applied, reason = apply_prime_data(pawn, state)
    if not applied then return false, reason end
    return true, nil, condition7_source
end

local function valid_fname_text(value)
    if type(value) ~= "string" then return false end
    if value:find('["\\]') or value:find("[%c]") or value:find("FNameUserdata", 1, true) then return false end
    return true
end

local function merge_mutation_unlocks(pawn, state)
    if #state.unlockRequiredMutations == 0 then return true, nil end
    local requirements = safe_get(function() return pawn.MutationsRequirementsData end, nil)
    if requirements == nil then return false, "restore-mutation-requirements-unavailable" end
    local array = safe_get(function() return requirements.UnlockRequiredMutations end, nil)
    if array == nil then return false, "restore-mutation-unlocks-unavailable" end

    local count = tonumber(safe_get(function() return #array end, 0)) or 0
    local existing = {}
    for index = 1, count do
        local text = fname_to_string(safe_get(function() return array[index] end, nil))
        if text ~= "" then existing[text] = true end
    end
    local added = 0
    for _, name in ipairs(state.unlockRequiredMutations) do
        if not valid_fname_text(name) then return false, "restore-invalid-unlock-name" end
        if name ~= "" and name ~= "None" and not existing[name] then
            local ok = pcall(function() array[count + added + 1] = FName(name) end)
            if not ok then return false, "restore-unlock-write-failed" end
            added = added + 1
            existing[name] = true
        end
    end
    if added > 0 then
        local ok, error_message = pcall(function() pawn:SetMutationRequirementsData(requirements) end)
        if not ok then return false, "restore-unlock-push-failed:" .. tostring(error_message) end
    end
    return true, nil
end

local function apply_mutation_fields(pawn, state, include_active)
    local mutations = safe_get(function() return pawn.ReplicatedMutationsData end, nil)
    if mutations == nil then return false, "restore-mutation-data-unavailable" end
    local first_index = include_active and 1 or 5
    for index = first_index, #MUTATION_FIELDS do
        local field = MUTATION_FIELDS[index]
        local value = state.mutations[field]
        if not valid_fname_text(value) then return false, "restore-invalid-mutation-name:" .. field end
        local name = (value == "" or value == "None") and "None" or value
        local ok_fname, fname = pcall(function() return FName(name) end)
        if not ok_fname or fname == nil or type(fname) == "string" then
            return false, "restore-fname-create-failed:" .. field
        end
        local ok_write = pcall(function() mutations[field] = fname end)
        if not ok_write then return false, "restore-mutation-write-failed:" .. field end
    end
    local ok, error_message = pcall(function() pawn:SetReplicatedMutationsData(mutations, true) end)
    if not ok then return false, "restore-mutation-push-failed:" .. tostring(error_message) end
    return true, nil
end

local function apply_transform(pawn, state)
    local location = safe_get(function() return pawn:K2_GetActorLocation() end, nil)
    local rotation = safe_get(function() return pawn:K2_GetActorRotation() end, nil)
    if location == nil or rotation == nil then return false, "restore-transform-struct-unavailable" end
    local ok_write = pcall(function()
        location.X = state.location.x
        location.Y = state.location.y
        location.Z = state.location.z
        rotation.Pitch = state.rotation.pitch
        rotation.Yaw = state.rotation.yaw
        rotation.Roll = state.rotation.roll
    end)
    if not ok_write then return false, "restore-transform-write-failed" end
    local function at_target()
        local actual = safe_get(function() return pawn:K2_GetActorLocation() end, nil)
        local x = actual ~= nil and tonumber(safe_get(function() return actual.X end, nil)) or nil
        local y = actual ~= nil and tonumber(safe_get(function() return actual.Y end, nil)) or nil
        local z = actual ~= nil and tonumber(safe_get(function() return actual.Z end, nil)) or nil
        return x ~= nil and y ~= nil and z ~= nil
            and math.abs(x - state.location.x) <= 100
            and math.abs(y - state.location.y) <= 100
            and math.abs(z - state.location.z) <= 100
    end

    local ok, teleported = pcall(function() return pawn:K2_TeleportTo(location, rotation) end)
    if ok and (teleported == true or at_target()) then return true, nil end

    local fallback_ok, moved = pcall(function()
        local hit_result = {}
        return pawn:K2_SetActorLocationAndRotation(
            location,
            rotation,
            false,
            hit_result,
            true
        )
    end)
    if fallback_ok and (moved == true or at_target()) then
        log("[Restore][LOCATION] K2_TeleportTo was blocked; no-sweep actor-location fallback succeeded")
        return true, nil
    end
    return false, "restore-location-apply-failed"
end

local function apply_growth_stage(
    game_mode,
    controller,
    pawn,
    steam,
    phase,
    state
)
    local target_growth =
        math.max(0, math.min(1, tonumber(state.growth) or 0))
    local target_percent =
        target_growth * 100
    local target_name = get_controller_name(controller, tostring(steam))

    -- Prime eligibility and its ten-condition structure both participate in
    -- EVRIMA's growth-derived stat calculation. Stage the complete captured
    -- structure immediately before every authorized growth attempt. The Grow
    -- call may rebuild it, so the existing final Prime phase remains required.
    local prime_ok, prime_error = apply_prime_data(pawn, state)
    if not prime_ok then
        return false, "restore-prime-pre-growth-failed:" .. tostring(prime_error)
    end

    -- Use one native Grow operation as the growth write. Calling SetGrowth
    -- immediately before Grow applies the same visible transition twice and
    -- can make remote clients see the dinosaur jitter or jump. A guarded
    -- caller may invoke this function once more only when repeated,
    -- authoritative reads prove the first operation made no change.
    local grow_ok, grow_error = pcall(function()
        game_mode:Grow(
            controller,
            tostring(steam),
            target_name,
            target_percent
        )
    end)
    if not grow_ok then
        return false,
            "restore-native-grow-failed:" .. tostring(grow_error)
    end
    pcall(function() pawn:ForceNetUpdate() end)
    log(string.format(
        "[Restore][GROWTH_STAGE] phase=%s steam=%s target=%.6f targetPct=%.3f direct=false native=true",
        tostring(phase),
        tostring(steam),
        target_growth,
        target_percent
    ))
    return true, nil
end

local function apply_post_growth_restore(
    game_mode,
    controller,
    pawn,
    steam,
    state
)
    local applied, reason
    applied, reason = normalize_restore_snapshot(pawn, state)
    if not applied then return false, reason end
    applied, reason = apply_max_vitals(pawn, state)
    if not applied then return false, reason end
    applied, reason = apply_vitals(pawn, state, game_mode, controller, steam)
    if not applied then return false, reason end
    applied, reason = apply_prime_data(pawn, state)
    if not applied then return false, reason end
    applied, reason = merge_mutation_unlocks(pawn, state)
    if not applied then return false, reason end
    -- Parent and elder slots are safe in the bulk phase. Active Slot1-4 fields
    -- are intentionally deferred until the engine has settled.
    applied, reason = apply_mutation_fields(pawn, state, false)
    if not applied then return false, reason end
    applied, reason = apply_nutrients(game_mode, controller, pawn, steam, state)
    if not applied then return false, reason end
    -- Nutrients are POD state; GAS-backed currents remain the final writes.
    applied, reason = apply_max_vitals(pawn, state)
    if not applied then return false, reason end
    applied, reason = apply_vitals(pawn, state, game_mode, controller, steam)
    if not applied then return false, reason end
    pcall(function() pawn:ForceNetUpdate() end)
    return true, nil
end

local function apply_deferred_restore(
    game_mode,
    controller,
    pawn,
    steam,
    state,
    include_transform
)
    local applied, reason
    applied, reason = merge_mutation_unlocks(pawn, state)
    if not applied then return false, reason end
    -- Write every slot directly into the live replicated struct. This is the
    -- documented v021+ path and deliberately never calls SetSlotN APIs.
    applied, reason = apply_mutation_fields(pawn, state, true)
    if not applied then return false, reason end

    applied, reason = apply_nutrients(game_mode, controller, pawn, steam, state)
    if not applied then return false, reason end
    -- First defensive max/current pass after mutation staging.
    applied, reason = apply_max_vitals(pawn, state)
    if not applied then return false, reason end
    applied, reason = apply_vitals(pawn, state, game_mode, controller, steam)
    if not applied then return false, reason end

    -- The lineage tier is applied only after all mutation slot data is pushed.
    local ok_stacks, stacks_error = pcall(function()
        pawn:SetElderReplicationStacks(state.elderStacks)
    end)
    if not ok_stacks then return false, "restore-elder-stacks-failed:" .. tostring(stacks_error) end

    applied, reason = apply_skin_state(pawn, state)
    if not applied then return false, reason end
    if include_transform then
        applied, reason = apply_transform(pawn, state)
        if not applied then return false, reason end
    end

    -- This is the last bulk pass. The common pipeline performs one final
    -- native Grow recalculation afterward, waits for species capacities to
    -- settle, and then writes final needs.
    applied, reason = apply_max_vitals(pawn, state)
    if not applied then return false, reason end
    applied, reason = apply_nutrients(game_mode, controller, pawn, steam, state)
    if not applied then return false, reason end
    applied, reason = apply_vitals(pawn, state, game_mode, controller, steam)
    if not applied then return false, reason end
    pcall(function() pawn:ForceNetUpdate() end)
    return true, nil
end

local function verify_restore(pawn, state, verify_location)
    local growth = tonumber(safe_get(function() return pawn:GetGrowth() end, nil))
    if growth == nil
        or math.abs(growth - state.growth) > GROWTH_VERIFY_TOLERANCE then
        return false, "verify-growth-mismatch"
    end
    local maximum_checks = {
        { "max-hunger", safe_get(function() return pawn:GetMaxHunger() end, nil), state.maxHunger },
        { "max-food", safe_get(function() return pawn:GetMaxFoodValue() end, nil), state.maxFoodValue },
        { "max-thirst", safe_get(function() return pawn:GetMaxThirst() end, nil), state.maxThirst },
        { "max-stamina", safe_get(function() return pawn:GetMaxStamina() end, nil), state.maxStamina }
    }
    for _, check in ipairs(maximum_checks) do
        local actual = tonumber(check[2])
        local expected = tonumber(check[3])
        local tolerance = math.max(0.01, math.abs(expected or 0) * 0.001)
        if actual == nil or expected == nil or math.abs(actual - expected) > tolerance then
            return false, "verify-" .. check[1] .. "-mismatch"
        end
    end
    local stacks = tonumber(safe_get(function() return pawn:GetElderReplicationStacks() end, 0)) or 0
    if math.floor(stacks) ~= state.elderStacks then return false, "verify-elder-stacks-mismatch" end
    local mutation_data = safe_get(function() return pawn.ReplicatedMutationsData end, nil)
    if mutation_data == nil then return false, "verify-mutations-unavailable" end
    for _, field in ipairs(MUTATION_FIELDS) do
        local actual = fname_to_string(safe_get(function() return mutation_data[field] end, nil))
        local expected = state.mutations[field]
        if expected == "None" then expected = "" end
        if actual ~= expected then return false, "verify-mutation-mismatch:" .. field end
    end

    local prime = safe_get(function() return pawn:GetEligiblePrimeElderData() end, nil)
    if prime == nil then prime = safe_get(function() return pawn.EligiblePrimeElderData end, nil) end
    if prime == nil then return false, "verify-prime-data-unavailable" end
    local prime_eligible = safe_get(function() return prime.bIsEligiblePrime end, nil)
    if prime_eligible ~= state.isPrime then
        return false, "verify-prime-eligibility-mismatch"
    end
    local cached_prime_eligible = safe_get(function()
        return pawn:GetIsEligiblePrimeElder()
    end, nil)
    if cached_prime_eligible ~= state.isPrime then
        return false, "verify-prime-server-eligibility-mismatch"
    end
    for index = 1, 10 do
        local actual_condition = safe_get(function()
            return prime["bPrimeCondition" .. tostring(index)]
        end, nil)
        if actual_condition ~= state.primeConditions[index] then
            return false, "verify-prime-condition-mismatch:" .. tostring(index)
        end
    end

    if #state.unlockRequiredMutations > 0 then
        local requirements = safe_get(function() return pawn.MutationsRequirementsData end, nil)
        local unlocks = requirements ~= nil
            and safe_get(function() return requirements.UnlockRequiredMutations end, nil)
            or nil
        if unlocks == nil then return false, "verify-mutation-unlocks-unavailable" end
        local present = {}
        local unlock_count = tonumber(safe_get(function() return #unlocks end, 0)) or 0
        for index = 1, unlock_count do
            local name = fname_to_string(safe_get(function() return unlocks[index] end, nil))
            if name ~= "" then present[name] = true end
        end
        for _, expected_unlock in ipairs(state.unlockRequiredMutations) do
            if expected_unlock ~= "" and expected_unlock ~= "None"
                and not present[expected_unlock] then
                return false, "verify-mutation-unlock-missing:" .. expected_unlock
            end
        end
    end

    local is_alive = safe_get(function() return pawn:GetIsAlive() end, nil)
    local is_dead = safe_get(function() return pawn.bIsDead end, nil)
    if is_alive ~= true or is_dead == true then
        return false, "verify-death-state:alive="
            .. tostring(is_alive) .. ",dead=" .. tostring(is_dead)
    end
    local function ratio_matches(
        actual,
        live_maximum,
        captured,
        captured_maximum,
        tolerance
    )
        actual = tonumber(actual)
        live_maximum = tonumber(live_maximum)
        captured = tonumber(captured)
        captured_maximum = tonumber(captured_maximum)
        if actual == nil or live_maximum == nil or live_maximum <= 0
            or captured == nil or captured_maximum == nil or captured_maximum <= 0 then
            return false
        end
        return math.abs(
            (actual / live_maximum) - (captured / captured_maximum)
        ) <= (tonumber(tolerance) or 0.05)
    end
    local ratio_checks = {
        {
            "health",
            safe_get(function() return pawn:GetHealth() end, nil),
            safe_get(function() return pawn:GetMaxHealth() end, nil),
            state.health,
            state.maxHealth
        },
        {
            "blood",
            safe_get(function() return pawn:GetBlood() end, nil),
            safe_get(function() return pawn:GetMaxBlood() end, nil),
            state.blood,
            state.maxBlood
        },
        {
            "stamina",
            safe_get(function() return pawn:GetStamina() end, nil),
            safe_get(function() return pawn:GetMaxStamina() end, nil),
            state.stamina,
            state.maxStamina
        },
        {
            "hunger",
            safe_get(function() return pawn:GetHunger() end, nil),
            safe_get(function() return pawn:GetMaxHunger() end, nil),
            state.hunger,
            state.maxHunger
        },
        {
            "food",
            safe_get(function() return pawn:GetFoodValue() end, nil),
            safe_get(function() return pawn:GetMaxFoodValue() end, nil),
            state.food,
            state.maxFoodValue
        },
        {
            "thirst",
            safe_get(function() return pawn:GetThirst() end, nil),
            safe_get(function() return pawn:GetMaxThirst() end, nil),
            state.thirst,
            state.maxThirst
        }
    }
    for _, check in ipairs(ratio_checks) do
        if not ratio_matches(check[2], check[3], check[4], check[5], 0.01) then
            return false, "verify-" .. check[1] .. "-ratio-mismatch"
        end
    end
    local nutrients = safe_get(function() return pawn.NutrientsStruct end, nil)
    if nutrients == nil then return false, "verify-nutrients-unavailable" end
    local live_hunger_capacity =
        safe_get(function() return pawn:GetMaxHunger() end, nil)
    local nutrient_checks = {
        {
            "carb",
            safe_get(function() return nutrients.CarbValue end, nil),
            state.carbValue
        },
        {
            "protein",
            safe_get(function() return nutrients.ProteinValue end, nil),
            state.proteinValue
        },
        {
            "lipid",
            safe_get(function() return nutrients.LipidValue end, nil),
            state.lipidValue
        }
    }
    for _, check in ipairs(nutrient_checks) do
        if not ratio_matches(
            check[2],
            live_hunger_capacity,
            check[3],
            state.maxHunger,
            0.05
        ) then
            return false, "verify-" .. check[1] .. "-ratio-mismatch"
        end
    end
    if verify_location then
        local location = safe_get(function() return pawn:K2_GetActorLocation() end, nil)
        local x = location ~= nil and tonumber(safe_get(function() return location.X end, nil)) or nil
        local y = location ~= nil and tonumber(safe_get(function() return location.Y end, nil)) or nil
        local z = location ~= nil and tonumber(safe_get(function() return location.Z end, nil)) or nil
        if x == nil or y == nil or z == nil
            or math.abs(x - state.location.x) > 100
            or math.abs(y - state.location.y) > 100
            or math.abs(z - state.location.z) > 100 then
            return false, "verify-location-mismatch"
        end
    end
    return true, nil
end

local function append_result(command_id, verb, ok, steam, state, snapshot_file, snapshot_bytes, reason, capture_id, parked, details)
    local file = io.open(RESULT_PATH, "ab")
    if file == nil then
        log(string.format("[Bridge][RESULT] write-failed id=%s path=%s", tostring(command_id), RESULT_PATH))
        return false
    end

    state = state or {}
    details = details or {}
    local prime = state.primeData or {}
    local changed = parked == true or details.dinosaurModified == true
    local line = string.format(
        '{"id":%s,"verb":%s,"operationType":"two-phase-json-parking","ok":%s,"steam":%s,"captureId":%s,"species":%s,"growth":%s,"classPath":%s,"snapshotFile":%s,"snapshotBytes":%d,"mutationCount":%d,"questUnlockCount":%d,"elderStacks":%d,"primeEligible":%s,"primeTaskCount":%d,"primeTasksCompleted":%s,"parked":%s,"reason":%s,"message":%s,"requirement":%s,"currentPercent":%s,"requiredPercent":%s,"nutrientCarbPercent":%s,"nutrientProteinPercent":%s,"nutrientLipidPercent":%s,"destructiveOperations":%s,"gameSaveCalls":false,"dinosaurModified":%s,"ts":%d}\n',
        json_string(command_id), json_string(verb or ""), json_bool(ok), json_string(steam),
        json_string(capture_id or ""),
        json_string(state.species or ""), json_number(state.growth or 0),
        json_string(state.classPath or ""), json_string(snapshot_file or ""),
        math.floor(tonumber(snapshot_bytes) or 0), math.floor(tonumber(state.mutationCount) or 0),
        #(state.unlockRequiredMutations or {}), math.floor(tonumber(state.elderStacks) or 0),
        json_bool(prime.eligible), math.floor(tonumber(prime.completedCount) or 0),
        json_integer_array(prime.completed or {}), json_bool(parked), json_string(reason or ""),
        json_string(details.message or ""), json_string(details.requirement or ""),
        json_number(details.currentPercent), json_number(details.requiredPercent),
        json_number(details.nutrientCarbPercent),
        json_number(details.nutrientProteinPercent),
        json_number(details.nutrientLipidPercent),
        json_bool(changed), json_bool(changed), os.time()
    )
    file:write(line)
    file:close()
    return true
end

local function reject(command_id, verb, steam, reason, capture_id, state, details)
    append_result(command_id or "", verb or "", false, steam or "", state, "", 0, reason, capture_id, false, details)
    log(string.format("[Parking][REJECT] id=%s verb=%s steam=%s reason=%s", tostring(command_id), tostring(verb), tostring(steam), tostring(reason)))
end

local function append_restore_result(command_id, ok, steam, state, reason, modified)
    local file = io.open(RESULT_PATH, "ab")
    if file == nil then
        log(string.format("[Bridge][RESULT] restore-write-failed id=%s", tostring(command_id)))
        return false
    end
    state = state or {}
    local line = string.format(
        '{"id":%s,"verb":"dino.storage.restore","ok":%s,"steam":%s,"species":%s,"growth":%s,"locationMode":%s,"restored":%s,"reason":%s,"dinosaurModified":%s,"gameSaveCalls":false,"respawnCalls":false,"ts":%d}\n',
        json_string(command_id), json_bool(ok), json_string(steam),
        json_string(state.species or ""), json_number(state.growth or 0),
        json_string(state.locationMode or ""), json_bool(ok),
        json_string(reason or ""), json_bool(modified), os.time()
    )
    file:write(line)
    file:close()
    return true
end

local function append_needs_probe_result(command_id, ok, steam, state, reason)
    local file = io.open(RESULT_PATH, "ab")
    if file == nil then
        log(string.format(
            "[Bridge][RESULT] needs-probe-write-failed id=%s",
            tostring(command_id)
        ))
        return false
    end
    state = state or {}
    local line = string.format(
        '{"id":%s,"verb":"dino.storage.needs_probe","ok":%s,"steam":%s,"species":%s,"growth":%s,"maxHunger":%s,"maxFoodValue":%s,"beforeCarb":%s,"beforeProtein":%s,"beforeLipid":%s,"nativeCarb":%s,"nativeProtein":%s,"nativeLipid":%s,"restoredCarb":%s,"restoredProtein":%s,"restoredLipid":%s,"nativeInput":100,"originalValuesRestored":%s,"reason":%s,"dinosaurModified":false,"ts":%d}\n',
        json_string(command_id),
        json_bool(ok),
        json_string(steam),
        json_string(state.species or ""),
        json_number(state.growth),
        json_number(state.maxHunger),
        json_number(state.maxFoodValue),
        json_number(state.beforeCarb),
        json_number(state.beforeProtein),
        json_number(state.beforeLipid),
        json_number(state.nativeCarb),
        json_number(state.nativeProtein),
        json_number(state.nativeLipid),
        json_number(state.restoredCarb),
        json_number(state.restoredProtein),
        json_number(state.restoredLipid),
        json_bool(state.originalValuesRestored),
        json_string(reason or ""),
        os.time()
    )
    file:write(line)
    file:close()
    return true
end

local function append_prime_probe_result(command_id, ok, steam, state, reason)
    local file = io.open(RESULT_PATH, "ab")
    if file == nil then
        log(string.format("[Bridge][RESULT] prime-probe-write-failed id=%s", tostring(command_id)))
        return false
    end
    state = state or {}
    local condition_values = {}
    for index = 1, 10 do
        condition_values[#condition_values + 1] = json_bool(
            state.primeConditions ~= nil and state.primeConditions[index] == true
        )
    end
    local line = string.format(
        '{"id":%s,"verb":"dino.storage.prime_probe","ok":%s,"steam":%s,"species":%s,"growth":%s,"weight":%s,"baseAdultWeight":%s,"maxHealth":%s,"maxBlood":%s,"maxHunger":%s,"maxFoodValue":%s,"maxThirst":%s,"maxStamina":%s,"isPrime":%s,"primeEligible":%s,"primeConditions":[%s],"primeCompletedCount":%s,"elderStacks":%s,"isAlive":%s,"reason":%s,"dinosaurModified":false,"ts":%d}\n',
        json_string(command_id), json_bool(ok), json_string(steam),
        json_string(state.species or ""), json_number(state.growth),
        json_number(state.weight), json_number(state.baseAdultWeight),
        json_number(state.maxHealth), json_number(state.maxBlood),
        json_number(state.maxHunger), json_number(state.maxFoodValue),
        json_number(state.maxThirst), json_number(state.maxStamina),
        json_bool(state.isPrime), json_bool(state.primeEligible),
        table.concat(condition_values, ","), json_number(state.primeCompletedCount),
        json_number(state.elderStacks), json_bool(state.isAlive),
        json_string(reason or ""), os.time()
    )
    file:write(line)
    file:close()
    return true
end

local function negative_effects_json(effects)
    effects = effects or {}
    return string.format(
        '{"slovenly":%s,"fluidDeficient":%s,"hasCataracts":%s,"glassBones":%s,"isSickState":%s,"headFractured":%s,"bodyFractured":%s,"legsFractured":%s}',
        json_bool(safe_get(function() return effects.bSlovenly end, false)),
        json_bool(safe_get(function() return effects.bFluidDeficient end, false)),
        json_bool(safe_get(function() return effects.bHasCataracts end, false)),
        json_bool(safe_get(function() return effects.bGlassBones end, false)),
        json_bool(safe_get(function() return effects.bIsSickState end, false)),
        json_bool(safe_get(function() return effects.bIsHeadFractured end, false)),
        json_bool(safe_get(function() return effects.bIsBodyFractured end, false)),
        json_bool(safe_get(function() return effects.bIsLegsFractured end, false))
    )
end

local function nutrients_json(nutrients)
    nutrients = nutrients or {}
    return string.format(
        '{"carb":%s,"protein":%s,"lipid":%s,"bones":%s,"cannibal":%s,"magy":%s,"rottenFlesh":%s,"mushrooms":%s,"malnutrition":%s}',
        json_number(safe_get(function() return nutrients.CarbValue end, nil)),
        json_number(safe_get(function() return nutrients.ProteinValue end, nil)),
        json_number(safe_get(function() return nutrients.LipidValue end, nil)),
        json_number(safe_get(function() return nutrients.BonesValue end, nil)),
        json_number(safe_get(function() return nutrients.CannibalValue end, nil)),
        json_number(safe_get(function() return nutrients.MagyValue end, nil)),
        json_number(safe_get(function() return nutrients.RottenFleshValue end, nil)),
        json_number(safe_get(function() return nutrients.MushroomsValue end, nil)),
        json_bool(safe_get(function() return nutrients.bMalnutrition end, false))
    )
end

local function append_player_data_probe_result(command_id, ok, steam, state, reason)
    local file = io.open(RESULT_PATH, "ab")
    if file == nil then
        log(string.format("[VenomTimeline][FAIL] steam=%s reason=result-write-failed path=%s", tostring(steam), RESULT_PATH))
        return false
    end
    state = state or {}
    local line = string.format(
        '{"id":%s,"verb":"dino.storage.player_data_probe","ok":%s,"steam":%s,"livePawn":%s,"timelineFile":%s,"schemaObservation":"live pawn only; TIPlayerData has no explicit venom field","reason":%s,"readOnly":true,"dinosaurModified":false,"gameSaveCalls":false,"saveManagerCalls":false,"ts":%d}\n',
        json_string(command_id), json_bool(ok), json_string(steam),
        state.livePawnJson or "null", json_string(state.timelineFile or ""),
        json_string(reason or ""), os.time()
    )
    file:write(line)
    file:close()
    return true
end

local function run_player_data_probe(command_id, steam)
    local function fail(reason)
        append_player_data_probe_result(command_id or "", false, steam or "", nil, reason)
        log(string.format("[VenomTimeline][FAIL] steam=%s reason=%s", tostring(steam or ""), tostring(reason)))
    end
    if command_id == nil or command_id == "" then
        fail("missing-command-id")
        return
    end
    if steam == nil or not tostring(steam):match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
        fail("invalid-steam-id")
        return
    end
    local _, _, pawn, player_error = get_live_player(steam)
    if player_error ~= nil then
        fail(player_error)
        return
    end
    local venom_property = safe_get(function() return pawn.VenomStatus end, nil)
    local venom_method = safe_get(function() return pawn:GetVenomStatus() end, nil)
    local has_stack = safe_get(function() return pawn:HasAnyVenomStack() end, nil)
    local last_pouncer = safe_get(function() return pawn.MyLastVenomPouncer end, nil)
    local replicated_effects = safe_get(function() return pawn.ReplicatedNegativeEffects end, nil)
    local live_nutrients = safe_get(function() return pawn.NutrientsStruct end, nil)
    local class_object = safe_get(function() return pawn:GetClass() end, nil)
    local class_path = object_full_name(class_object):gsub("^BlueprintGeneratedClass%s+", "")
    local live_json = string.format(
        '{"species":%s,"classPath":%s,"objectName":%s,"objectAddress":%s,"growth":%s,"weight":%s,"health":%s,"maxHealth":%s,"blood":%s,"maxBlood":%s,"stamina":%s,"maxStamina":%s,"hunger":%s,"maxHunger":%s,"food":%s,"maxFoodValue":%s,"thirst":%s,"maxThirst":%s,"oxygen":%s,"lockedDamage":%s,"rottenValue":%s,"waterLevel":%s,"nutrients":%s,"venomStatus":%s,"venomStatusText":%s,"getVenomStatus":%s,"getVenomStatusText":%s,"hasAnyVenomStack":%s,"lastVenomPouncer":%s,"replicatedNegativeEffects":%s}',
        json_string(clean_species(class_path, pawn)), json_string(class_path),
        json_string(object_full_name(pawn)),
        json_string(tostring(safe_get(function() return pawn:GetAddress() end, ""))),
        json_number(safe_get(function() return pawn:GetGrowth() end, nil)),
        json_number(safe_get(function() return pawn:GetWeight() end, nil)),
        json_number(safe_get(function() return pawn:GetHealth() end, nil)),
        json_number(safe_get(function() return pawn:GetMaxHealth() end, nil)),
        json_number(safe_get(function() return pawn:GetBlood() end, nil)),
        json_number(safe_get(function() return pawn:GetMaxBlood() end, nil)),
        json_number(safe_get(function() return pawn:GetStamina() end, nil)),
        json_number(safe_get(function() return pawn:GetMaxStamina() end, nil)),
        json_number(safe_get(function() return pawn:GetHunger() end, nil)),
        json_number(safe_get(function() return pawn:GetMaxHunger() end, nil)),
        json_number(safe_get(function() return pawn:GetFoodValue() end, nil)),
        json_number(safe_get(function() return pawn:GetMaxFoodValue() end, nil)),
        json_number(safe_get(function() return pawn:GetThirst() end, nil)),
        json_number(safe_get(function() return pawn:GetMaxThirst() end, nil)),
        json_number(safe_get(function() return pawn:GetOxygen() end, nil)),
        json_number(safe_get(function() return pawn:GetLockedDamage() end, nil)),
        json_number(safe_get(function() return pawn:GetRottenValue() end, nil)),
        json_number(safe_get(function() return pawn:GetWaterLevel() end, nil)),
        nutrients_json(live_nutrients),
        json_number(enum_number(venom_property)), json_string(tostring(venom_property or "")),
        json_number(enum_number(venom_method)), json_string(tostring(venom_method or "")),
        json_bool(has_stack), json_string(object_full_name(last_pouncer)),
        negative_effects_json(replicated_effects)
    )
    local timeline_name = "venom_timeline_" .. tostring(steam) .. ".ndjson"
    local timeline_path = SAVED_ROOT .. "/" .. timeline_name
    local timeline = io.open(timeline_path, "ab")
    if timeline == nil then
        fail("timeline-write-failed")
        return
    end
    timeline:write(string.format('{"steam":%s,"livePawn":%s,"readOnly":true,"ts":%d}\n', json_string(steam), live_json, os.time()))
    timeline:close()
    local state = {livePawnJson = live_json, timelineFile = "Saved/" .. timeline_name}
    append_player_data_probe_result(command_id, true, steam, state, "")
    log(string.format("[VenomTimeline][OK][READ_ONLY] steam=%s venom=%s hasStack=%s file=%s", tostring(steam), tostring(venom_method), tostring(has_stack), timeline_path))
end

local function append_object_dump_result(command_id, ok, reason)
    local file = io.open(RESULT_PATH, "ab")
    if file == nil then
        log(string.format("[Bridge][RESULT] object-dump-write-failed id=%s", tostring(command_id)))
        return false
    end
    local line = string.format(
        '{"id":%s,"verb":"dino.storage.object_dump","ok":%s,"reason":%s,"outputFile":"UE4SS_ObjectDump.txt","dinosaurModified":false,"ts":%d}\n',
        json_string(command_id), json_bool(ok), json_string(reason or ""), os.time()
    )
    file:write(line)
    file:close()
    return true
end

local function run_object_dump(command_id, confirmed)
    if command_id == nil or command_id == "" then
        append_object_dump_result("", false, "missing-command-id")
        return
    end
    if confirmed ~= true then
        append_object_dump_result(command_id, false, "explicit-confirmation-required")
        return
    end
    if object_dump_completed then
        append_object_dump_result(command_id, false, "object-dump-already-completed-this-session")
        return
    end
    if DumpAllObjects == nil then
        append_object_dump_result(command_id, false, "ue4ss-dump-function-unavailable")
        return
    end
    log(string.format("[VenomDump][READ_ONLY][START] id=%s", tostring(command_id)))
    local ok, error_message = pcall(function() DumpAllObjects() end)
    if not ok then
        append_object_dump_result(command_id, false, "object-dump-call-failed:" .. tostring(error_message))
        return
    end
    object_dump_completed = true
    append_object_dump_result(command_id, true, "object-dump-complete")
    log(string.format("[VenomDump][READ_ONLY][COMPLETE] id=%s file=UE4SS_ObjectDump.txt", tostring(command_id)))
end

local function run_prime_probe(command_id, steam)
    if command_id == nil or command_id == "" then
        append_prime_probe_result("", false, steam or "", nil, "missing-command-id")
        return
    end
    if steam == nil or not tostring(steam):match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
        append_prime_probe_result(command_id, false, steam or "", nil, "invalid-steam-id")
        return
    end
    local _, _, pawn, player_error = get_live_player(steam)
    if player_error ~= nil then
        append_prime_probe_result(command_id, false, steam, nil, player_error)
        return
    end
    local class_object = safe_get(function() return pawn:GetClass() end, nil)
    local class_path = object_full_name(class_object):gsub("^BlueprintGeneratedClass%s+", "")
    local prime = safe_get(function() return pawn:GetEligiblePrimeElderData() end, nil)
    if prime == nil then prime = safe_get(function() return pawn.EligiblePrimeElderData end, nil) end
    if prime == nil then
        append_prime_probe_result(command_id, false, steam, nil, "prime-data-read-failed")
        return
    end
    local state = {
        species = clean_species(class_path, pawn),
        growth = tonumber(safe_get(function() return pawn:GetGrowth() end, nil)),
        weight = tonumber(safe_get(function() return pawn:GetWeight() end, nil)),
        baseAdultWeight = tonumber(safe_get(function() return pawn:GetBaseWeightValueFromAdult() end, nil)),
        maxHealth = tonumber(safe_get(function() return pawn:GetMaxHealth() end, nil)),
        maxBlood = tonumber(safe_get(function() return pawn:GetMaxBlood() end, nil)),
        maxHunger = tonumber(safe_get(function() return pawn:GetMaxHunger() end, nil)),
        maxFoodValue = tonumber(safe_get(function() return pawn:GetMaxFoodValue() end, nil)),
        maxThirst = tonumber(safe_get(function() return pawn:GetMaxThirst() end, nil)),
        maxStamina = tonumber(safe_get(function() return pawn:GetMaxStamina() end, nil)),
        isPrime = safe_get(function() return pawn:GetIsEligiblePrimeElder() end, nil),
        primeEligible = safe_get(function() return prime.bIsEligiblePrime end, nil),
        elderStacks = tonumber(safe_get(function() return pawn:GetElderReplicationStacks() end, nil)),
        isAlive = safe_get(function() return pawn:GetIsAlive() end, nil),
        primeConditions = {},
        primeCompletedCount = 0
    }
    local required_numbers = {
        "growth", "weight", "baseAdultWeight", "maxHealth", "maxBlood",
        "maxHunger", "maxFoodValue", "maxThirst", "maxStamina", "elderStacks"
    }
    for _, field in ipairs(required_numbers) do
        if state[field] == nil then
            append_prime_probe_result(command_id, false, steam, state, field .. "-read-failed")
            return
        end
    end
    if type(state.primeEligible) ~= "boolean" then
        append_prime_probe_result(command_id, false, steam, state, "prime-eligible-read-failed")
        return
    end
    if type(state.isPrime) ~= "boolean" then state.isPrime = state.primeEligible end
    for index = 1, 10 do
        local value = safe_get(function() return prime["bPrimeCondition" .. tostring(index)] end, nil)
        if type(value) ~= "boolean" then
            append_prime_probe_result(command_id, false, steam, state, "prime-condition-" .. tostring(index) .. "-read-failed")
            return
        end
        state.primeConditions[index] = value
        if value then state.primeCompletedCount = state.primeCompletedCount + 1 end
    end
    append_prime_probe_result(command_id, true, steam, state, "")
    log(string.format("[PrimeProbe][READ_ONLY] steam=%s species=%s prime=%s eligible=%s completed=%d/10 weight=%s maxHealth=%s", tostring(steam), tostring(state.species), tostring(state.isPrime), tostring(state.primeEligible), state.primeCompletedCount, tostring(state.weight), tostring(state.maxHealth)))
end

local function run_needs_probe(command_id, steam)
    if command_id == nil or command_id == "" then
        append_needs_probe_result("", false, steam or "", nil, "missing-command-id")
        return
    end
    if steam == nil or not tostring(steam):match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
        append_needs_probe_result(
            command_id,
            false,
            steam or "",
            nil,
            "invalid-steam-id"
        )
        return
    end

    local game_mode, controller, pawn, player_error = get_live_player(steam)
    if player_error ~= nil then
        append_needs_probe_result(
            command_id,
            false,
            steam,
            nil,
            player_error
        )
        return
    end
    local captured, capture_error = capture_state(pawn, steam)
    if captured == nil or captured.nutrients == nil then
        append_needs_probe_result(
            command_id,
            false,
            steam,
            nil,
            capture_error or "needs-probe-capture-failed"
        )
        return
    end

    local pawn_address =
        tonumber(safe_get(function() return pawn:GetAddress() end, nil))
    if pawn_address == nil or pawn_address == 0 then
        append_needs_probe_result(
            command_id,
            false,
            steam,
            nil,
            "needs-probe-pawn-address-invalid"
        )
        return
    end

    local result = {
        species = captured.species,
        growth = captured.growth,
        maxHunger = captured.maxHunger,
        maxFoodValue = captured.maxFoodValue,
        beforeCarb = captured.nutrients.carbValue,
        beforeProtein = captured.nutrients.proteinValue,
        beforeLipid = captured.nutrients.lipidValue,
        originalValuesRestored = false
    }
    local target_name = get_controller_name(controller, tostring(steam))
    local native_calls = {
        {
            "carb",
            function()
                game_mode:SetNutrientSlotValue(
                    controller,
                    tostring(steam),
                    target_name,
                    true,
                    false,
                    false,
                    100.0
                )
            end
        },
        {
            "protein",
            function()
                game_mode:SetNutrientSlotValue(
                    controller,
                    tostring(steam),
                    target_name,
                    false,
                    true,
                    false,
                    100.0
                )
            end
        },
        {
            "lipid",
            function()
                game_mode:SetNutrientSlotValue(
                    controller,
                    tostring(steam),
                    target_name,
                    false,
                    false,
                    true,
                    100.0
                )
            end
        }
    }
    for _, call in ipairs(native_calls) do
        local called, call_error = pcall(call[2])
        if not called then
            local live = safe_get(function() return pawn.NutrientsStruct end, nil)
            if live ~= nil then
                pcall(function()
                    live.CarbValue = result.beforeCarb
                    live.ProteinValue = result.beforeProtein
                    live.LipidValue = result.beforeLipid
                    pawn:SetNutrientsStruct(live, true)
                end)
            end
            append_needs_probe_result(
                command_id,
                false,
                steam,
                result,
                "needs-probe-native-" .. call[1] .. "-failed:"
                    .. tostring(call_error)
            )
            return
        end
    end

    local read_fired = false
    local read_handle
    read_handle = LoopInGameThreadWithDelay(300, function()
        if read_fired then return end
        read_fired = true
        if read_handle ~= nil and CancelDelayedAction ~= nil then
            pcall(function() CancelDelayedAction(read_handle) end)
        end

        local _, _, read_pawn, read_error = get_live_player(steam)
        if read_error ~= nil then
            append_needs_probe_result(
                command_id,
                false,
                steam,
                result,
                read_error
            )
            return
        end
        local read_address =
            tonumber(safe_get(function() return read_pawn:GetAddress() end, nil))
        if read_address == nil or read_address ~= pawn_address then
            append_needs_probe_result(
                command_id,
                false,
                steam,
                result,
                "needs-probe-pawn-changed"
            )
            return
        end

        local native = safe_get(function() return read_pawn.NutrientsStruct end, nil)
        if native == nil then
            append_needs_probe_result(
                command_id,
                false,
                steam,
                result,
                "needs-probe-native-read-failed"
            )
            return
        end
        result.nativeCarb =
            tonumber(safe_get(function() return native.CarbValue end, nil))
        result.nativeProtein =
            tonumber(safe_get(function() return native.ProteinValue end, nil))
        result.nativeLipid =
            tonumber(safe_get(function() return native.LipidValue end, nil))

        local restored = pcall(function()
            native.CarbValue = result.beforeCarb
            native.ProteinValue = result.beforeProtein
            native.LipidValue = result.beforeLipid
            read_pawn:SetNutrientsStruct(native, true)
            read_pawn:ForceNetUpdate()
        end)
        if not restored then
            append_needs_probe_result(
                command_id,
                false,
                steam,
                result,
                "needs-probe-original-restore-failed"
            )
            return
        end

        local verify_fired = false
        local verify_handle
        verify_handle = LoopInGameThreadWithDelay(300, function()
            if verify_fired then return end
            verify_fired = true
            if verify_handle ~= nil and CancelDelayedAction ~= nil then
                pcall(function() CancelDelayedAction(verify_handle) end)
            end

            local _, _, verify_pawn, verify_error = get_live_player(steam)
            if verify_error ~= nil then
                append_needs_probe_result(
                    command_id,
                    false,
                    steam,
                    result,
                    verify_error
                )
                return
            end
            local verify_address = tonumber(safe_get(function()
                return verify_pawn:GetAddress()
            end, nil))
            if verify_address == nil or verify_address ~= pawn_address then
                append_needs_probe_result(
                    command_id,
                    false,
                    steam,
                    result,
                    "needs-probe-pawn-changed-before-verification"
                )
                return
            end
            local final =
                safe_get(function() return verify_pawn.NutrientsStruct end, nil)
            if final == nil then
                append_needs_probe_result(
                    command_id,
                    false,
                    steam,
                    result,
                    "needs-probe-restored-read-failed"
                )
                return
            end
            -- The nutrient drain tick can move the first restoration during
            -- this 300 ms observation window. Reapply the captured values once
            -- more after the native setter has fully settled, then read them
            -- immediately. This avoids treating normal drain as probe failure.
            local final_restore_ok = pcall(function()
                final.CarbValue = result.beforeCarb
                final.ProteinValue = result.beforeProtein
                final.LipidValue = result.beforeLipid
                verify_pawn:SetNutrientsStruct(final, true)
                verify_pawn:ForceNetUpdate()
            end)
            if not final_restore_ok then
                append_needs_probe_result(
                    command_id,
                    false,
                    steam,
                    result,
                    "needs-probe-final-original-restore-failed"
                )
                return
            end
            local restored =
                safe_get(function() return verify_pawn.NutrientsStruct end, nil)
            result.restoredCarb = restored ~= nil
                and tonumber(safe_get(function() return restored.CarbValue end, nil))
                or nil
            result.restoredProtein = restored ~= nil
                and tonumber(safe_get(function() return restored.ProteinValue end, nil))
                or nil
            result.restoredLipid = restored ~= nil
                and tonumber(safe_get(function() return restored.LipidValue end, nil))
                or nil
            local tolerance = 0.05
            result.originalValuesRestored =
                result.restoredCarb ~= nil
                and result.restoredProtein ~= nil
                and result.restoredLipid ~= nil
                and math.abs(result.restoredCarb - result.beforeCarb) <= tolerance
                and math.abs(result.restoredProtein - result.beforeProtein) <= tolerance
                and math.abs(result.restoredLipid - result.beforeLipid) <= tolerance
            local reason = result.originalValuesRestored
                and "live-needs-probe-complete"
                or "live-needs-probe-complete-restore-warning"
            append_needs_probe_result(
                command_id,
                true,
                steam,
                result,
                reason
            )
            log(string.format(
                "[NeedsProbe] steam=%s species=%s growth=%.6f maxHunger=%.3f before=%.3f/%.3f/%.3f native100=%.3f/%.3f/%.3f restored=%.3f/%.3f/%.3f restoredOk=%s",
                tostring(steam),
                tostring(result.species),
                tonumber(result.growth) or -1,
                tonumber(result.maxHunger) or -1,
                tonumber(result.beforeCarb) or -1,
                tonumber(result.beforeProtein) or -1,
                tonumber(result.beforeLipid) or -1,
                tonumber(result.nativeCarb) or -1,
                tonumber(result.nativeProtein) or -1,
                tonumber(result.nativeLipid) or -1,
                tonumber(result.restoredCarb) or -1,
                tonumber(result.restoredProtein) or -1,
                tonumber(result.restoredLipid) or -1,
                tostring(result.originalValuesRestored)
            ))
        end)
    end)
end

local function run_restore(command_id, steam, restore_file, location_mode)
    if command_id == nil or command_id == "" then
        append_restore_result("", false, steam or "", nil, "missing-command-id", false)
        return
    end
    if steam == nil or not tostring(steam):match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
        append_restore_result(command_id, false, steam or "", nil, "invalid-steam-id", false)
        return
    end
    local expected_file = "restore_pending_" .. tostring(steam) .. "_" .. tostring(command_id) .. ".json"
    if restore_file ~= expected_file then
        append_restore_result(command_id, false, steam, nil, "invalid-restore-file", false)
        return
    end
    if location_mode ~= "saved" and location_mode ~= "current" then
        append_restore_result(command_id, false, steam, nil, "invalid-location-mode", false)
        return
    end

    local body = read_text_file(SAVED_ROOT .. "/" .. restore_file)
    if body == nil then
        append_restore_result(command_id, false, steam, nil, "restore-file-unavailable", false)
        return
    end
    local state, parse_error = parse_restore_state(body)
    if state == nil then
        append_restore_result(command_id, false, steam, nil, parse_error or "restore-json-invalid", false)
        return
    end
    state.locationMode = location_mode
    if state.currentLocationOnly and location_mode ~= "current" then
        append_restore_result(command_id, false, steam, state, "restore-current-location-required", false)
        return
    end

    local game_mode, controller, pawn, player_error = get_live_player(steam)
    if player_error ~= nil then
        append_restore_result(command_id, false, steam, state, player_error, false)
        return
    end
    local live_class = object_full_name(
        safe_get(function() return pawn:GetClass() end, nil)
    ):gsub("^BlueprintGeneratedClass%s+", "")
    local live_species = clean_species(live_class, pawn)
    if live_species:lower() ~= tostring(state.species):lower() then
        append_restore_result(command_id, false, steam, state, "restore-species-mismatch", false)
        return
    end
    local live_growth = tonumber(safe_get(function() return pawn:GetGrowth() end, nil))
    if live_growth == nil or live_growth >= 0.5 then
        append_restore_result(command_id, false, steam, state, "restore-growth-not-eligible", false)
        return
    end
    local live_health = tonumber(safe_get(function() return pawn:GetHealth() end, nil))
    local live_is_alive = safe_get(function() return pawn:GetIsAlive() end, nil)
    local live_is_dead = safe_get(function() return pawn.bIsDead end, nil)
    if live_health == nil or live_health <= 0
        or live_is_alive ~= true or live_is_dead == true then
        append_restore_result(command_id, false, steam, state, "restore-live-dinosaur-not-alive", false)
        return
    end
    local pawn_address = tonumber(safe_get(function() return pawn:GetAddress() end, nil))
    if pawn_address == nil or pawn_address == 0 then
        append_restore_result(command_id, false, steam, state, "restore-pawn-address-invalid", false)
        return
    end

    local restore_key = tostring(steam)
    local existing_restore = active_restores[restore_key]
    if existing_restore ~= nil then
        local age = os.time() - (tonumber(existing_restore.startedAt) or 0)
        if age < 60 then
            append_restore_result(
                command_id,
                false,
                steam,
                state,
                "restore-already-in-progress",
                false
            )
            return
        end
        log(string.format(
            "[Restore][STALE_GUARD_CLEARED] steam=%s previous=%s age=%d",
            restore_key,
            tostring(existing_restore.commandId),
            age
        ))
    end
    active_restores[restore_key] = {
        commandId = tostring(command_id),
        pawnAddress = pawn_address,
        startedAt = os.time()
    }

    local use_saved_location = location_mode == "saved"
    local finished = false
    local modified = false

    local function complete(ok, reason)
        if finished then return end
        finished = true
        local active = active_restores[restore_key]
        if active ~= nil
            and tostring(active.commandId) == tostring(command_id) then
            active_restores[restore_key] = nil
        end
        append_restore_result(
            command_id,
            ok == true,
            steam,
            state,
            reason or (ok and "dinosaur-restored" or "restore-failed"),
            modified
        )
        if ok then
            log(string.format(
                "[Restore][SUCCESS] id=%s steam=%s species=%s growth=%.6f elderStacks=%d locationMode=%s SHARED_PIPELINE=true GAME_SAVE_CALLS=false RESPAWN_CALLS=false",
                tostring(command_id), tostring(steam), tostring(state.species),
                tonumber(state.growth) or 0, tonumber(state.elderStacks) or 0,
                tostring(location_mode)
            ))
        else
            log(string.format(
                "[Restore][REJECT] id=%s steam=%s reason=%s modified=%s",
                tostring(command_id), tostring(steam), tostring(reason),
                tostring(modified)
            ))
        end
    end

    local function schedule_once(delay_ms, callback)
        local fired = false
        local handle
        handle = LoopInGameThreadWithDelay(delay_ms, function()
            if fired then return end
            fired = true
            if handle ~= nil and CancelDelayedAction ~= nil then
                pcall(function() CancelDelayedAction(handle) end)
            end
            callback()
        end)
        return handle
    end

    local function resolve_phase_pawn(phase)
        local phase_game_mode, phase_controller, phase_pawn, phase_error =
            get_live_player(steam)
        if phase_error ~= nil then
            return nil, nil, nil, phase_error
        end
        local phase_address = tonumber(safe_get(function()
            return phase_pawn:GetAddress()
        end, nil))
        if phase_address == nil or phase_address ~= pawn_address then
            return nil, nil, nil, "restore-pawn-changed:" .. tostring(phase)
        end
        local phase_class = object_full_name(
            safe_get(function() return phase_pawn:GetClass() end, nil)
        ):gsub("^BlueprintGeneratedClass%s+", "")
        local phase_species = clean_species(phase_class, phase_pawn)
        if phase_species:lower() ~= tostring(state.species):lower() then
            return nil, nil, nil, "restore-species-changed:" .. tostring(phase)
        end
        local phase_alive = safe_get(function() return phase_pawn:GetIsAlive() end, nil)
        local phase_dead = safe_get(function() return phase_pawn.bIsDead end, nil)
        if phase_alive ~= true or phase_dead == true then
            return nil, nil, nil, "restore-live-dinosaur-not-alive:" .. tostring(phase)
        end
        return phase_game_mode, phase_controller, phase_pawn, nil
    end

    local growth_guard = {
        initialGrowth = tonumber(safe_get(function() return pawn:GetGrowth() end, nil)),
        writeCount = 0,
        retryIssued = false,
        directFallbackIssued = false,
        successLatched = false
    }

    local function read_growth_capacities(live_pawn)
        local values = {
            tonumber(safe_get(function() return live_pawn:GetMaxHunger() end, nil)),
            tonumber(safe_get(function() return live_pawn:GetMaxFoodValue() end, nil)),
            tonumber(safe_get(function() return live_pawn:GetMaxThirst() end, nil)),
            tonumber(safe_get(function() return live_pawn:GetMaxStamina() end, nil)),
            tonumber(safe_get(function() return live_pawn:GetMaxHealth() end, nil))
        }
        for index = 1, 5 do
            local value = values[index]
            if value == nil or value <= 0 then return nil end
        end
        return values
    end

    local function capacities_match(left, right)
        if left == nil or right == nil then return false end
        for index = 1, 5 do
            local value = left[index]
            if value == nil or right[index] == nil then return false end
            local tolerance = math.max(0.01, math.abs(value) * 0.001)
            if math.abs(value - right[index]) > tolerance then return false end
        end
        return true
    end

    -- A target reading permanently latches success for this operation. After
    -- that point no growth write is allowed, even if a later observation is
    -- ambiguous. One native retry is permitted only when four consecutive
    -- authoritative samples prove the first call left growth at its original
    -- value. Partial movement, invalid reads, or inconsistent state are never
    -- treated as permission to grow again.
    local function wait_for_growth_target(
        phase,
        observation_count,
        unchanged_count,
        matched_once,
        previous_capacities,
        on_ready
    )
        local delay_ms = matched_once and 500 or 750
        schedule_once(delay_ms, function()
            if finished then return end
            local settled_game_mode, settled_controller, settled_pawn,
                settled_error = resolve_phase_pawn(
                    tostring(phase) .. "-growth-settle"
                )
            if settled_error ~= nil then
                complete(false, settled_error)
                return
            end

            local actual_growth = tonumber(safe_get(function()
                return settled_pawn:GetGrowth()
            end, nil))
            local target_growth = tonumber(state.growth) or 0
            local matches = actual_growth ~= nil
                and math.abs(actual_growth - target_growth)
                    <= GROWTH_VERIFY_TOLERANCE
            local next_observation = (tonumber(observation_count) or 0) + 1

            if matches then
                growth_guard.successLatched = true
                local capacities = read_growth_capacities(settled_pawn)
                if capacities == nil then
                    complete(false, "restore-growth-capacity-read-failed:" .. tostring(phase))
                    return
                end
                if matched_once
                    and capacities_match(previous_capacities, capacities) then
                log(string.format(
                    "[Restore][GROWTH_SETTLED] phase=%s steam=%s actual=%.6f target=%.6f writes=%d successLatched=true",
                    tostring(phase),
                    tostring(steam),
                    actual_growth,
                    target_growth,
                    tonumber(growth_guard.writeCount) or 0
                ))
                on_ready(
                    settled_game_mode,
                    settled_controller,
                    settled_pawn
                )
                return
                end
                wait_for_growth_target(
                    phase,
                    next_observation,
                    unchanged_count,
                    true,
                    capacities,
                    on_ready
                )
                return
            end

            local unchanged = actual_growth ~= nil
                and growth_guard.initialGrowth ~= nil
                and math.abs(actual_growth - growth_guard.initialGrowth)
                    <= GROWTH_VERIFY_TOLERANCE
            local next_unchanged = unchanged
                and ((tonumber(unchanged_count) or 0) + 1)
                or 0

            if not growth_guard.successLatched
                and not growth_guard.retryIssued
                and next_unchanged >= 4 then
                growth_guard.retryIssued = true
                log(string.format(
                    "[Restore][GROWTH_CONFIRMED_NOOP_RETRY] phase=%s steam=%s actual=%s original=%s target=%.6f samples=%d",
                    tostring(phase),
                    tostring(steam),
                    tostring(actual_growth),
                    tostring(growth_guard.initialGrowth),
                    target_growth,
                    next_unchanged
                ))
                local retry_ok, retry_error = apply_growth_stage(
                    settled_game_mode,
                    settled_controller,
                    settled_pawn,
                    steam,
                    tostring(phase) .. "-confirmed-noop-retry",
                    state
                )
                if not retry_ok then
                    complete(false, retry_error or "restore-growth-retry-failed")
                    return
                end
                growth_guard.writeCount = growth_guard.writeCount + 1
                wait_for_growth_target(
                    phase,
                    next_observation,
                    0,
                    false,
                    nil,
                    on_ready
                )
                return
            end

            -- Some server states accept the native GameMode Grow call without
            -- changing the pawn. Only after both native attempts are proven
            -- no-ops by four consecutive authoritative samples each may the
            -- documented direct SetGrowth fallback run once. If either native
            -- call ever moved growth, this branch is permanently forbidden.
            if not growth_guard.successLatched
                and growth_guard.retryIssued
                and not growth_guard.directFallbackIssued
                and next_unchanged >= 4 then
                growth_guard.directFallbackIssued = true
                log(string.format(
                    "[Restore][GROWTH_CONFIRMED_NATIVE_NOOP_DIRECT_FALLBACK] phase=%s steam=%s actual=%s original=%s target=%.6f samples=%d",
                    tostring(phase),
                    tostring(steam),
                    tostring(actual_growth),
                    tostring(growth_guard.initialGrowth),
                    target_growth,
                    next_unchanged
                ))
                local direct_ok, direct_error = pcall(function()
                    local fallback_prime_ok, fallback_prime_error =
                        apply_prime_data(settled_pawn, state)
                    if not fallback_prime_ok then
                        error(
                            "prime-stage:" .. tostring(fallback_prime_error)
                        )
                    end
                    settled_pawn:SetGrowth(target_growth)
                    settled_pawn:ForceNetUpdate()
                end)
                if not direct_ok then
                    complete(
                        false,
                        "restore-growth-direct-fallback-failed:"
                            .. tostring(direct_error)
                    )
                    return
                end
                growth_guard.writeCount = growth_guard.writeCount + 1
                wait_for_growth_target(
                    phase,
                    next_observation,
                    0,
                    false,
                    nil,
                    on_ready
                )
                return
            end

            local maximum_observations = growth_guard.directFallbackIssued
                and 16
                or (growth_guard.retryIssued and 12 or 8)
            if next_observation >= maximum_observations then
                complete(
                    false,
                    string.format(
                        "restore-growth-settle-uncertain:%s:actual=%s:target=%.6f:writes=%d:latched=%s",
                        tostring(phase),
                        tostring(actual_growth),
                        target_growth,
                        tonumber(growth_guard.writeCount) or 0,
                        tostring(growth_guard.successLatched)
                    )
                )
                return
            end
            wait_for_growth_target(
                phase,
                next_observation,
                next_unchanged,
                false,
                nil,
                on_ready
            )
        end)
    end

    -- A late server-side growth recalculation is observed but never corrected
    -- after success was latched. Ambiguous or drifting state fails safely and
    -- the bot leaves the inventory entry available for another attempt.
    local function finish_final_restore(
        needs_game_mode,
        needs_controller,
        needs_pawn
    )
        -- Native Grow can rebuild the Prime struct from species defaults.
        -- Reapply the complete captured Prime state after the last growth
        -- settles so native-owned conditions such as Beipi Task 7 survive.
        local prime_ok, prime_error, condition7_source =
            apply_final_prime_data(needs_pawn, state)
        if not prime_ok then
            complete(false, prime_error or "restore-final-prime-phase-failed")
            return
        end
        local handoff_ok, handoff_error = queue_prime_restore_handoff(
            command_id,
            steam,
            needs_pawn,
            state
        )
        if not handoff_ok then
            complete(false, handoff_error or "restore-prime-handoff-failed")
            return
        end
        pcall(function() needs_pawn:ForceNetUpdate() end)
        log(string.format(
            "[Restore][FINAL_PRIME] steam=%s task7=%s task7Source=%s task8=%s eligible=%s",
            tostring(steam),
            tostring(state.primeConditions[7] == true),
            tostring(condition7_source or "snapshot"),
            tostring(state.primeConditions[8] == true),
            tostring(state.isPrime == true)
        ))

        local needs_ok, needs_error = apply_final_needs(
            needs_game_mode,
            needs_controller,
            needs_pawn,
            steam,
            state
        )
        if not needs_ok then
            complete(false, needs_error or "restore-final-needs-phase-failed")
            return
        end

        -- Native percentage commands and ordinary game ticks may perform a
        -- late needs write. Re-resolve the pawn, obtain a fresh nutrient
        -- wrapper, and reconcile every source type once more before
        -- verification. No UObject or USTRUCT wrapper crosses this delay.
        schedule_once(250, function()
            if finished then return end
            local _, _, reconcile_pawn, reconcile_player_error =
                resolve_phase_pawn("final-needs-reconcile")
            if reconcile_player_error ~= nil then
                complete(false, reconcile_player_error)
                return
            end
            if state.percentageBackedSnapshot then
                local refreshed, refresh_error =
                    refresh_percentage_snapshot_from_live(reconcile_pawn, state)
                if not refreshed then
                    complete(false, refresh_error)
                    return
                end
            end
            local reconciled, reconcile_error = reconcile_final_needs(
                reconcile_pawn,
                steam,
                state,
                "deferred-universal"
            )
            if not reconciled then
                complete(false, reconcile_error)
                return
            end

            -- miniEniac polls the handoff at 500ms. Wait through at least two
            -- bridge polls and one normal 1s Prime-tracker poll, then verify
            -- the shared final state before allowing inventory consumption.
            schedule_once(1500, function()
            if finished then return end
            local verify_game_mode, verify_controller, verify_pawn,
                verify_player_error = resolve_phase_pawn("verification")
            if verify_player_error ~= nil then
                complete(false, verify_player_error)
                return
            end
            if use_saved_location then
                log(string.format(
                    "[Restore][LOCATION_VERIFY] steam=%s trustedApplyStage=true blocking=false",
                    tostring(steam)
                ))
            end
            local verified, verify_error = verify_restore(
                verify_pawn,
                state,
                false
            )
            if verified then
                complete(true, "dinosaur-restored")
                return
            end

            if verify_error == "verify-growth-mismatch" then
                local actual_growth = tonumber(safe_get(function()
                    return verify_pawn:GetGrowth()
                end, nil))
                log(string.format(
                    "[Restore][VERIFY_GROWTH_UNCERTAIN] steam=%s actual=%s target=%.6f writes=%d successLatched=%s",
                    tostring(steam),
                    tostring(actual_growth),
                    tonumber(state.growth) or 0,
                    tonumber(growth_guard.writeCount) or 0,
                    tostring(growth_guard.successLatched)
                ))
            end
            complete(false, verify_error or "restore-verification-failed")
            end)
        end)
    end

    -- From this point both parked and administrator-created inventory rows use
    -- exactly the same transform-in-place writers and ordering.
    modified = true

    -- apply_growth_stage stages the complete Prime structure immediately
    -- before its native Grow call. This log remains the audit boundary and no
    -- additional growth write is introduced.
    log(string.format(
        "[Restore][PRIME_PRE_GROWTH] steam=%s eligible=%s completeStruct=true growthWrites=0",
        tostring(steam),
        tostring(state.isPrime == true)
    ))

    local growth_ok, growth_error = apply_growth_stage(
        game_mode,
        controller,
        pawn,
        steam,
        "initial",
        state
    )
    if not growth_ok then
        complete(false, growth_error or "restore-growth-stage-failed")
        return
    end
    growth_guard.writeCount = 1

    -- Do not read or write max/current GAS values until the game's native Grow
    -- recalculation has settled. Ratio-backed admin/shop snapshots are expanded
    -- against the settled species maxima in this phase.
    wait_for_growth_target(
        "initial",
        0,
        0,
        false,
        nil,
        function(bulk_game_mode, bulk_controller, bulk_pawn)
        local bulk_ok, bulk_error = apply_post_growth_restore(
            bulk_game_mode,
            bulk_controller,
            bulk_pawn,
            steam,
            state
        )
        if not bulk_ok then
            complete(false, bulk_error or "restore-post-growth-phase-failed")
            return
        end

        -- Defensive second quest-unlock merge before active mutation fields.
        schedule_once(250, function()
            if finished then return end
            local _, _, unlock_pawn, unlock_error =
                resolve_phase_pawn("quest-unlock")
            if unlock_error ~= nil then
                complete(false, unlock_error)
                return
            end
            local unlock_ok, unlock_reason =
                merge_mutation_unlocks(unlock_pawn, state)
            if not unlock_ok then
                complete(false, unlock_reason or "restore-quest-unlock-phase-failed")
            end
        end)

        -- Active mutations, lineage tier, skin, optional transform, and
        -- canonical max/current vitals run only after the bulk phase settles.
        schedule_once(500, function()
            if finished then return end
            local final_game_mode, final_controller, final_pawn,
                final_player_error = resolve_phase_pawn("deferred-apply")
            if final_player_error ~= nil then
                complete(false, final_player_error)
                return
            end
            local final_ok, final_error = apply_deferred_restore(
                final_game_mode,
                final_controller,
                final_pawn,
                steam,
                state,
                use_saved_location
            )
            if not final_ok then
                complete(false, final_error or "restore-deferred-phase-failed")
                return
            end

            -- Mutation, skin, and transform field writes do not authorize a
            -- second growth operation. Observe target growth and capacities
            -- again read-only; the success latch forbids any retry here.
            wait_for_growth_target(
                "post-deferred",
                0,
                0,
                false,
                nil,
                function(needs_game_mode, needs_controller, needs_pawn)
                finish_final_restore(
                    needs_game_mode,
                    needs_controller,
                    needs_pawn
                )
                end
            )
        end)
        end
    )
end

local function parking_failure(state)
    local function is_full(value, maximum)
        local max_value = tonumber(maximum)
        local current = tonumber(value)
        if current == nil or max_value == nil or max_value <= 0 then return false end
        local tolerance = math.max(0.01, max_value * 0.0001)
        return current + tolerance >= max_value
    end
    local function has_minimum_fraction(value, maximum, minimum)
        local max_value = tonumber(maximum)
        local current = tonumber(value)
        if current == nil or max_value == nil or max_value <= 0 then return false end
        return current + 0.01 >= max_value * minimum
    end
    local function percentage(value, maximum)
        local current = tonumber(value)
        local max_value = tonumber(maximum)
        if current == nil or max_value == nil or max_value <= 0 then return nil end
        return math.max(0, math.min(100, (current / max_value) * 100))
    end
    local function failure(reason, requirement, current_percent, required_percent, minimum)
        local qualifier = minimum and "at least " or ""
        return {
            reason = reason,
            requirement = requirement,
            currentPercent = current_percent,
            requiredPercent = required_percent,
            message = string.format(
                "Couldn't park due to %s being too low. Current %s is %.2f%% (must be %s%d%%).",
                requirement, requirement, tonumber(current_percent) or 0,
                qualifier, required_percent
            )
        }
    end

    if state == nil then
        return {
            reason = "parking-state-unavailable",
            requirement = "parking state",
            message = "Couldn't park because the dinosaur's current state could not be verified."
        }
    end

    local growth_percent = (tonumber(state.growth) or 0) * 100
    if tonumber(state.growth) == nil or state.growth < 0.75 then
        return failure("growth-too-low", "growth", growth_percent, 75, true)
    end
    if not is_full(state.health, state.maxHealth) then
        return failure("health-too-low", "health", percentage(state.health, state.maxHealth), 100, false)
    end
    if not is_full(state.blood, state.maxBlood) then
        return failure("blood-too-low", "blood", percentage(state.blood, state.maxBlood), 100, false)
    end
    if not is_full(state.stamina, state.maxStamina) then
        return failure("stamina-too-low", "stamina", percentage(state.stamina, state.maxStamina), 100, false)
    end
    if not has_minimum_fraction(state.hunger, state.maxHunger, 0.25) then
        return failure("food-too-low", "food", percentage(state.hunger, state.maxHunger), 25, true)
    end
    if not has_minimum_fraction(state.thirst, state.maxThirst, 0.25) then
        return failure("water-too-low", "water", percentage(state.thirst, state.maxThirst), 25, true)
    end
    return nil
end

local function log_parking_requirements(steam, state, stage)
    state = state or {}
    log(string.format(
        "[Parking][REQUIREMENT] stage=%s steam=%s growth=%.6f health=%.3f/%.3f blood=%.3f/%.3f stamina=%.3f/%.3f food=%.3f/%.3f water=%.3f/%.3f allowed=false",
        tostring(stage), tostring(steam), tonumber(state.growth) or -1,
        tonumber(state.health) or -1, tonumber(state.maxHealth) or -1,
        tonumber(state.blood) or -1, tonumber(state.maxBlood) or -1,
        tonumber(state.stamina) or -1, tonumber(state.maxStamina) or -1,
        tonumber(state.hunger) or -1, tonumber(state.maxHunger) or -1,
        tonumber(state.thirst) or -1, tonumber(state.maxThirst) or -1
    ))
end

local function shrink_and_remove_parked_dinosaur(pawn, original_growth)
    local shrunk, shrink_error = pcall(function()
        pawn:SetGrowth(PARKED_CORPSE_GROWTH)
    end)
    if not shrunk then
        return false, "park-corpse-shrink-failed:" .. tostring(shrink_error), false
    end

    pcall(function()
        if pawn.ForceNetUpdate ~= nil then pawn:ForceNetUpdate() end
    end)

    local removed, remove_error = pcall(function()
        pawn:SetHealth(0.0)
    end)
    if removed then return true, nil, true end

    local rolled_back = pcall(function()
        pawn:SetGrowth(tonumber(original_growth) or 0.75)
    end)
    pcall(function()
        if pawn.ForceNetUpdate ~= nil then pawn:ForceNetUpdate() end
    end)
    if rolled_back then
        return false, "park-removal-failed:" .. tostring(remove_error), false
    end
    return false,
        "park-removal-failed-growth-rollback-failed:" .. tostring(remove_error),
        true
end

local function capture_species_nutrient_percentages(
    game_mode,
    controller,
    pawn,
    steam,
    current_state
)
    local original = current_state ~= nil and current_state.nutrients or nil
    if original == nil then return nil, "nutrient-original-state-unavailable" end

    local capacity = tonumber(current_state.maxHunger)
    if capacity == nil or capacity <= 0 then
        return nil, "nutrient-capacity-unavailable"
    end

    local function percent(value)
        local current = tonumber(value)
        if current == nil or current < 0 or current > capacity + math.max(0.01, capacity * 0.001) then
            return nil
        end
        return math.max(0, math.min(100, current / capacity * 100))
    end
    local percentages = {
        carb = percent(original.carbValue),
        protein = percent(original.proteinValue),
        lipid = percent(original.lipidValue)
    }
    if percentages.carb == nil or percentages.protein == nil or percentages.lipid == nil then
        return nil, "nutrient-calibration-percent-invalid"
    end
    return percentages, nil
end

local function run_capture(command_id, verb, steam, for_parking)
    if command_id == nil or command_id == "" then
        reject("", verb, steam, "missing-command-id")
        return
    end
    if steam == nil or not tostring(steam):match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
        reject(command_id, verb, steam, "invalid-steam-id")
        return
    end

    local game_mode, controller, pawn, player_error = get_live_player(steam)
    if player_error ~= nil then
        reject(command_id, verb, steam, player_error)
        return
    end

    local state, capture_error = capture_state(pawn, steam)
    if state == nil then
        reject(command_id, verb, steam, capture_error or "state-capture-failed")
        return
    end

    if for_parking then
        local failure = parking_failure(state)
        if failure ~= nil then
            log_parking_requirements(steam, state, "capture")
            local notified, notify_error = notify_player(steam, failure.message)
            log(string.format(
                "[Parking][NOTIFY] stage=capture steam=%s requirement=%s ok=%s reason=%s",
                tostring(steam), tostring(failure.requirement), tostring(notified), tostring(notify_error or "")
            ))
            reject(command_id, verb, steam, failure.reason, nil, state, failure)
            return
        end
    end

    state.captureMode = for_parking and "park-pending" or "read-only-probe"
    local body = serialize_state(state)
    local snapshot_file
    if for_parking then
        snapshot_file = "park_pending_" .. tostring(steam) .. "_" .. tostring(command_id) .. ".json"
    else
        snapshot_file = "capture_probe_" .. tostring(steam) .. ".json"
    end
    local snapshot_path = SAVED_ROOT .. "/" .. snapshot_file
    local written, write_error = write_atomic(snapshot_path, body, command_id)
    if not written then
        reject(command_id, verb, steam, write_error or "snapshot-write-failed")
        return
    end

    if for_parking then
        local pawn_address = tonumber(safe_get(function() return pawn:GetAddress() end, nil))
        if pawn_address == nil or pawn_address == 0 then
            os.remove(snapshot_path)
            reject(command_id, verb, steam, "pawn-address-read-failed")
            return
        end
        pending_captures[command_id] = {
            steam = tostring(steam),
            pawnAddress = pawn_address,
            classPath = state.classPath,
            state = state,
            snapshotFile = snapshot_file,
            snapshotBytes = #body,
            createdAt = os.time()
        }
    end

    append_result(command_id, verb, true, steam, state, snapshot_file, #body,
        for_parking and "snapshot-awaiting-inventory-commit" or "safe-read-only-json-capture",
        for_parking and command_id or "", false)
    log(string.format(
        "[Capture] id=%s verb=%s steam=%s species=%s growth=%.6f mutations=%d questUnlocks=%d elderStacks=%d primeTasks=%d/10 bytes=%d awaitingCommit=%s ok=true GAME_SAVE_CALLS=false DINOSAUR_MODIFIED=false",
        tostring(command_id), tostring(verb), tostring(steam), tostring(state.species), state.growth,
        state.mutationCount, #state.unlockRequiredMutations, state.elderStacks,
        state.primeData.completedCount, #body, tostring(for_parking)
    ))
end

local function run_commit(command_id, steam, capture_id)
    local verb = "dino.storage.commit_park"
    if command_id == nil or command_id == "" then
        reject("", verb, steam, "missing-command-id", capture_id)
        return
    end
    local pending = pending_captures[tostring(capture_id or "")]
    if pending == nil then
        reject(command_id, verb, steam, "capture-session-expired", capture_id)
        return
    end
    if tostring(steam or "") ~= pending.steam then
        reject(command_id, verb, steam, "capture-owner-mismatch", capture_id)
        return
    end

    local game_mode, controller, pawn, player_error = get_live_player(steam)
    if player_error ~= nil then
        reject(command_id, verb, steam, player_error, capture_id)
        return
    end

    local pawn_address = tonumber(safe_get(function() return pawn:GetAddress() end, nil))
    local class_object = safe_get(function() return pawn:GetClass() end, nil)
    local class_path = object_full_name(class_object):gsub("^BlueprintGeneratedClass%s+", "")
    if pawn_address == nil or pawn_address ~= pending.pawnAddress or class_path ~= pending.classPath then
        reject(command_id, verb, steam, "live-dinosaur-changed-before-commit", capture_id)
        return
    end

    local current_state, capture_error = capture_state(pawn, steam)
    if current_state == nil then
        reject(command_id, verb, steam, capture_error or "state-recheck-failed", capture_id)
        return
    end
    local failure = parking_failure(current_state)
    if failure ~= nil then
        log_parking_requirements(steam, current_state, "commit")
        local notified, notify_error = notify_player(steam, failure.message)
        log(string.format(
            "[Parking][NOTIFY] stage=commit steam=%s requirement=%s ok=%s reason=%s",
            tostring(steam), tostring(failure.requirement), tostring(notified), tostring(notify_error or "")
        ))
        reject(command_id, verb, steam, failure.reason, capture_id, current_state, failure)
        return
    end

    local nutrient_percentages, nutrient_calibration_error =
        capture_species_nutrient_percentages(
            game_mode,
            controller,
            pawn,
            steam,
            current_state
        )
    if nutrient_percentages == nil then
        log(string.format(
            "[Parking][NUTRIENT_PERCENT] steam=%s unavailable reason=%s",
            tostring(steam),
            tostring(nutrient_calibration_error or "unknown")
        ))
    end

    suppressed_deaths[tostring(steam)] = os.time() + 15
    local removed, remove_error, removal_modified = shrink_and_remove_parked_dinosaur(
        pawn,
        current_state.growth
    )
    if not removed then
        if removal_modified ~= true then suppressed_deaths[tostring(steam)] = nil end
        local removal_details = {
            message = removal_modified
                and "Parking failed while removing your dinosaur, and its growth could not be restored. Contact an administrator."
                or "Parking failed because the server could not remove your dinosaur. Its original growth was restored.",
            requirement = "server removal",
            dinosaurModified = removal_modified
        }
        notify_player(steam, removal_details.message)
        reject(command_id, verb, steam, remove_error, capture_id, current_state, removal_details)
        return
    end

    pending_captures[tostring(capture_id)] = nil
    append_result(
        command_id,
        verb,
        true,
        steam,
        pending.state,
        pending.snapshotFile,
        pending.snapshotBytes,
        "inventory-committed-live-dinosaur-removed",
        capture_id,
        true,
        {
            nutrientCarbPercent = nutrient_percentages and nutrient_percentages.carb or nil,
            nutrientProteinPercent = nutrient_percentages and nutrient_percentages.protein or nil,
            nutrientLipidPercent = nutrient_percentages and nutrient_percentages.lipid or nil
        }
    )
    log(string.format(
        "[Parking][COMMIT] id=%s capture=%s steam=%s species=%s ok=true CORPSE_GROWTH=%.4f SET_HEALTH_ZERO=true GAME_SAVE_CALLS=false",
        tostring(command_id), tostring(capture_id), tostring(steam),
        tostring(pending.state.species), PARKED_CORPSE_GROWTH
    ))
end

local function run_self_slay(command_id, steam)
    local verb = "dino.player.self_slay"
    if command_id == nil or command_id == "" then
        reject("", verb, steam, "command-id-missing")
        return
    end
    if steam == nil or steam == "" then
        reject(command_id, verb, "", "steam-id-missing")
        return
    end
    if active_restores[tostring(steam)] ~= nil then
        reject(command_id, verb, steam, "restore-already-in-progress")
        return
    end

    local game_mode, controller, pawn, player_error = get_live_player(steam)
    if player_error ~= nil then
        reject(command_id, verb, steam, player_error)
        return
    end
    local alive = safe_get(function() return pawn:GetIsAlive() end, nil)
    local dead = safe_get(function() return pawn.bIsDead end, nil)
    if alive ~= true or dead == true then
        reject(command_id, verb, steam, "self-slay-dinosaur-not-alive")
        return
    end

    local class_object = safe_get(function() return pawn:GetClass() end, nil)
    local state = {
        classPath = object_full_name(class_object):gsub(
            "^BlueprintGeneratedClass%s+",
            ""
        ),
        growth = tonumber(safe_get(function() return pawn:GetGrowth() end, 0))
            or 0
    }
    state.species = clean_species(state.classPath, pawn)
    recent_self_slays[tostring(steam)] = os.time()
    local ok, error_message = pcall(function()
        pawn:SetHealth(0.0)
    end)
    if not ok then
        recent_self_slays[tostring(steam)] = nil
        reject(
            command_id,
            verb,
            steam,
            "self-slay-call-failed:" .. tostring(error_message)
        )
        return
    end
    pcall(function() pawn:ForceNetUpdate() end)

    local fired = false
    local handle
    handle = LoopInGameThreadWithDelay(250, function()
        if fired then return end
        fired = true
        if handle ~= nil and CancelDelayedAction ~= nil then
            pcall(function() CancelDelayedAction(handle) end)
        end

        local health = tonumber(safe_get(function() return pawn:GetHealth() end, nil))
        local alive_after = safe_get(function() return pawn:GetIsAlive() end, nil)
        local dead_after = safe_get(function() return pawn.bIsDead end, nil)
        local confirmed = not is_valid_object(pawn)
            or (health ~= nil and health <= 0)
            or alive_after == false
            or dead_after == true
        if not confirmed then
            recent_self_slays[tostring(steam)] = nil
            reject(command_id, verb, steam, "self-slay-not-confirmed")
            log(string.format(
                "[PlayerPanel][SLAY] id=%s steam=%s species=%s health=%s ok=false",
                tostring(command_id), tostring(steam), tostring(state.species),
                tostring(health)
            ))
            return
        end

        append_result(
            command_id,
            verb,
            true,
            steam,
            state,
            "",
            0,
            "dinosaur-self-slain",
            "",
            false,
            {
                message = "Your current dinosaur was slayed.",
                dinosaurModified = true
            }
        )
        log(string.format(
            "[PlayerPanel][SLAY] id=%s steam=%s species=%s growth=%.6f ok=true method=SetHealth",
            tostring(command_id),
            tostring(steam),
            tostring(state.species),
            tonumber(state.growth) or 0
        ))
    end)
end

local function process_chat_self_slays()
    if #pending_chat_self_slays == 0 then return end
    local requests = pending_chat_self_slays
    pending_chat_self_slays = {}

    for _, request in ipairs(requests) do
        local steam = tostring(request.steam or "")
        if steam ~= "" then
            chat_self_slay_counter = chat_self_slay_counter + 1
            local command_id = string.format(
                "chat-slay-%s-%d-%d",
                steam,
                tonumber(request.queued_at) or os.time(),
                chat_self_slay_counter
            )
            log(string.format("[InGameCommand][RUN] command=!slay steam=%s", steam))
            run_self_slay(command_id, steam)
        end
    end
end

local function save_cursor()
    local temp_path = CURSOR_PATH .. ".tmp"
    local file = io.open(temp_path, "wb")
    if file == nil then return false end
    file:write(tostring(math.floor(tonumber(command_offset) or 0)))
    file:close()
    os.remove(CURSOR_PATH)
    local renamed = os.rename(temp_path, CURSOR_PATH)
    return renamed ~= nil
end

local function load_bridge()
    if bridge_loaded then return end
    bridge_loaded = true

    local cursor_file = io.open(CURSOR_PATH, "rb")
    if cursor_file ~= nil then
        command_offset = math.max(0, math.floor(tonumber(cursor_file:read("*a")) or 0))
        cursor_file:close()
    end

    local command_file = io.open(COMMAND_PATH, "ab")
    if command_file ~= nil then command_file:close() end
    local result_file = io.open(RESULT_PATH, "ab")
    if result_file ~= nil then result_file:close() end
    local admin_event_file = io.open(ADMIN_EVENT_PATH, "ab")
    if admin_event_file ~= nil then admin_event_file:close() end
    append_admin_event("server_session", {
        event = "started",
        session = tostring(os.time())
    })

    log(string.format(
        "[Bridge] ready version=%s command=%s result=%s saved=%s cursor=%d TWO_PHASE_PARKING=true",
        MOD_VERSION, COMMAND_PATH, RESULT_PATH, SAVED_ROOT, command_offset
    ))
end

local function process_command(line)
    local command_id = json_get_string(line, "id")
    local verb = json_get_string(line, "verb")
    local steam = json_get_string(line, "steam")
    if verb == "dino.storage.probe" then
        run_capture(command_id, verb, steam, false)
    elseif verb == "dino.storage.needs_probe" then
        run_needs_probe(command_id, steam)
    elseif verb == "dino.storage.prime_probe" then
        run_prime_probe(command_id, steam)
    elseif verb == "dino.storage.player_data_probe" then
        run_player_data_probe(command_id, steam)
    elseif verb == "dino.storage.object_dump" then
        run_object_dump(command_id, json_get_bool(line, "confirm"))
    elseif verb == "dino.storage.capture_park" then
        run_capture(command_id, verb, steam, true)
    elseif verb == "dino.storage.commit_park" then
        run_commit(command_id, steam, json_get_string(line, "captureId"))
    elseif verb == "dino.storage.restore" then
        run_restore(
            command_id,
            steam,
            json_get_string(line, "restoreFile"),
            json_get_string(line, "locationMode")
        )
    elseif verb == "dino.player.self_slay" then
        run_self_slay(command_id, steam)
    else
        reject(command_id, verb, steam, "unsupported-verb")
    end
end

local function expire_pending_captures()
    local now = os.time()
    for capture_id, pending in pairs(pending_captures) do
        if now - (tonumber(pending.createdAt) or 0) > 120 then
            os.remove(SAVED_ROOT .. "/" .. tostring(pending.snapshotFile or ""))
            pending_captures[capture_id] = nil
            log(string.format("[Parking][EXPIRE] capture=%s steam=%s", tostring(capture_id), tostring(pending.steam)))
        end
    end
end

local function poll_commands()
    load_bridge()
    expire_pending_captures()
    local file = io.open(COMMAND_PATH, "rb")
    if file == nil then return end

    local size = file:seek("end") or 0
    if size < command_offset then command_offset = 0 end
    file:seek("set", command_offset)
    local chunk = file:read("*a") or ""
    file:close()
    if chunk == "" then return end

    local last_newline = nil
    for index = #chunk, 1, -1 do
        if chunk:sub(index, index) == "\n" then
            last_newline = index
            break
        end
    end
    if last_newline == nil then return end

    local complete = chunk:sub(1, last_newline)
    for line in complete:gmatch("[^\r\n]+") do
        if line ~= "" then
            local ok, error_message = pcall(function() process_command(line) end)
            if not ok then
                reject(json_get_string(line, "id"), json_get_string(line, "verb"),
                    json_get_string(line, "steam"), "unhandled-error:" .. tostring(error_message))
            end
        end
    end

    command_offset = command_offset + last_newline
    save_cursor()
end

load_bridge()
register_admin_log_hooks()
log(string.format(" Loaded; version=%s TWO_PHASE_REAL_PARKING=true ADMIN_LOGS=true GAME_SAVE_CALLS=false", MOD_VERSION))

if LoopInGameThreadWithDelay == nil then
    log("[FATAL] LoopInGameThreadWithDelay unavailable; bridge cannot start")
else
    LoopInGameThreadWithDelay(POLL_INTERVAL_MS, function()
        local command_ok, command_error = pcall(process_chat_self_slays)
        if not command_ok then
            log("[InGameCommand][ERROR] command=!slay reason=" .. tostring(command_error))
        end
        local ok, error_message = pcall(poll_commands)
        if not ok then log("[Bridge][ERROR] " .. tostring(error_message)) end
    end)
    LoopInGameThreadWithDelay(1000, function()
        local ok, error_message = pcall(admin_event_tick)
        if not ok then log("[AdminLogs][TICK_ERROR] " .. tostring(error_message)) end
    end)
end

log(" VERIFIED_BUILD_MARKER=DINO_STORAGE_ALPHA_V0_11_22_WELCOME_MESSAGE")
log(" VERIFIED_BUILD_MARKER=DINO_STORAGE_ALPHA_V0_12_11_ENUM_AND_FINAL_NEEDS")
log(" VERIFIED_BUILD_MARKER=DINO_STORAGE_ALPHA_V0_12_20_PRIME_GROWTH_ORDER")
