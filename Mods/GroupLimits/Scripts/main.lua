local MOD_NAME = "GroupLimits"
local VERSION = "0.2.1-alpha"

local function log(message)
    print(string.format(
        "[%s] %s\n",
        MOD_NAME,
        tostring(message)
    ))
end

local function safe_call(callback, fallback)
    local ok, value = pcall(callback)

    if ok then
        return value
    end

    return fallback
end

local function unwrap(param)
    if param == nil then
        return nil
    end

    local value = safe_call(function()
        return param:get()
    end, nil)

    if value ~= nil then
        return value
    end

    return param
end

local function is_valid_object(object)
    if object == nil then
        return false
    end

    local address = safe_call(function()
        return object:GetAddress()
    end, 0)

    return address ~= nil and address ~= 0
end

local function object_from_context(context)
    local object = unwrap(context)

    if is_valid_object(object) then
        return object
    end

    return nil
end

local function full_name(object)
    if not is_valid_object(object) then
        return "<invalid>"
    end

    return tostring(safe_call(function()
        return object:GetFullName()
    end, "<unknown>"))
end

local function value_as_number(param)
    local value = unwrap(param)

    if type(value) == "number" then
        return value
    end

    return tonumber(value)
end

local function object_address(object)
    if not is_valid_object(object) then return 0 end
    return tonumber(safe_call(function() return object:GetAddress() end, 0)) or 0
end

local function live_pawn_from_controller(controller)
    if not is_valid_object(controller) then return nil end
    local pawn = safe_call(function() return controller:GetPawn() end, nil)
    if is_valid_object(pawn) then return pawn end
    pawn = safe_call(function() return controller.Pawn end, nil)
    if is_valid_object(pawn) then return pawn end
    return nil
end

local function resolve_mod_root()
    if debug == nil or debug.getinfo == nil then
        return "Mods/GroupLimits"
    end

    local info = safe_call(function()
        return debug.getinfo(1, "S")
    end, nil)

    if info == nil or info.source == nil then
        return "Mods/GroupLimits"
    end

    local source = tostring(info.source)
        :gsub("^@", "")
        :gsub("\\", "/")

    return source:match(
        "^(.*)/[Ss]cripts/main%.lua$"
    ) or "Mods/GroupLimits"
end

local MOD_ROOT = resolve_mod_root()
local CONFIG_PATH = MOD_ROOT .. "/config/GroupLimits.ini"

local function trim(value)
    local cleaned = tostring(value or "")
        :gsub("^%s+", "")

    cleaned = cleaned:gsub("%s+$", "")

    return cleaned
end

local function normalized(value)
    local cleaned = trim(value):lower()
    cleaned = cleaned:gsub("[^%w]", "")

    return cleaned
end

local function canonical_species(value)
    local key = normalized(value)

    if key == "beipiaosaurus" or key == "beipiosaurus" then
        return "beipiosaurus"
    end

    if key == "ticeratops" or key == "triceratops" then
        return "triceratops"
    end

    return key
end

local SPECIES_MATCHERS = {
    { "beipiaosaurus", "beipiosaurus" },
    { "beipiosaurus", "beipiosaurus" },
    { "diabloceratops", "diabloceratops" },
    { "dryosaurus", "dryosaurus" },
    { "gallimimus", "gallimimus" },
    { "hypsilophodon", "hypsilophodon" },
    { "kentrosaurus", "kentrosaurus" },
    { "maiasaura", "maiasaura" },
    { "pachycephalosaurus", "pachycephalosaurus" },
    { "stegosaurus", "stegosaurus" },
    { "tenontosaurus", "tenontosaurus" },
    { "triceratops", "triceratops" },
    { "ticeratops", "triceratops" },
    { "allosaurus", "allosaurus" },
    { "carnotaurus", "carnotaurus" },
    { "ceratosaurus", "ceratosaurus" },
    { "deinosuchus", "deinosuchus" },
    { "dilophosaurus", "dilophosaurus" },
    { "herrerasaurus", "herrerasaurus" },
    { "omniraptor", "omniraptor" },
    { "pteranodon", "pteranodon" },
    { "troodon", "troodon" },
    { "tyrannosaurus", "tyrannosaurus" }
}

local function species_from_object(object)
    local name = full_name(object):lower()

    for _, matcher in ipairs(SPECIES_MATCHERS) do
        if name:find(matcher[1], 1, true) then
            return matcher[2]
        end
    end

    local fallback = name:match("bp_([%w]+)_c")

    return canonical_species(fallback)
end

local configured_limits = {}

local function load_config()
    local file = io.open(CONFIG_PATH, "r")

    if file == nil then
        log("config missing path=" .. CONFIG_PATH)
        return false
    end

    for raw_line in file:lines() do
        local line = trim(raw_line)

        if (
            line ~= ""
            and line:sub(1, 1) ~= ";"
            and line:sub(1, 1) ~= "#"
            and line:sub(1, 1) ~= "["
        ) then
            local key, value = line:match("^([^=]+)=(.*)$")

            if key ~= nil then
                local species = canonical_species(key)
                local cleaned_value = trim(value)
                local limit = tonumber(cleaned_value)

                if species ~= "" and limit ~= nil and limit >= 1 then
                    configured_limits[species] = math.floor(limit)
                end
            end
        end
    end

    file:close()

    return true
end

local function configured_species_count()
    local count = 0

    for _ in pairs(configured_limits) do
        count = count + 1
    end

    return count
end

local logged_stamps = {}
local logged_stamp_failures = {}
local logged_overrides = {}

local function log_stamp_failure(character, species, source, reason)
    local key = table.concat({tostring(object_address(character)), tostring(species), tostring(source), tostring(reason)}, "|")
    if logged_stamp_failures[key] then return end
    logged_stamp_failures[key] = true
    log(string.format("[StampFailed] source=%s species=%s reason=%s object=%s", tostring(source), tostring(species), tostring(reason), full_name(character)))
end

local function stamp_character_limit(character, source)
    if not is_valid_object(character) then return false, "invalid-character" end
    local species = species_from_object(character)
    local configured_limit = configured_limits[species]
    if configured_limit == nil then return false, "species-not-configured" end

    local settings = safe_call(function() return character.GeneralSettings end, nil)
    if settings == nil then
        log_stamp_failure(character, species, source, "GeneralSettings-unavailable")
        return false, "GeneralSettings-unavailable"
    end

    local before = value_as_number(safe_call(function() return settings.MaxGroupSize end, nil))
    local write_ok, write_error = pcall(function()
        -- This embedded USTRUCT field is what native C++ join validation reads.
        settings.MaxGroupSize = configured_limit
    end)

    if not write_ok then
        log_stamp_failure(character, species, source, "write-error:" .. tostring(write_error))
        return false, tostring(write_error)
    end

    local after = value_as_number(safe_call(function() return character.GeneralSettings.MaxGroupSize end, nil))
    local getter_ok, getter_value = pcall(function() return character:GetMaxGroupSize() end)
    local getter_limit = getter_ok and value_as_number(getter_value) or nil
    local verified = after == configured_limit
    if getter_ok then verified = verified and getter_limit == configured_limit end

    local stamp_key = table.concat({tostring(object_address(character)), tostring(configured_limit)}, "|")
    if not logged_stamps[stamp_key] or not verified then
        logged_stamps[stamp_key] = verified
        log(string.format(
            "[Stamp] source=%s species=%s before=%s after=%s getterOk=%s getter=%s configured=%d verified=%s object=%s",
            tostring(source), tostring(species), tostring(before), tostring(after), tostring(getter_ok),
            tostring(getter_limit), configured_limit, tostring(verified), full_name(character)
        ))
    end

    return verified, verified and "ok" or "verification-failed"
end

local function schedule_controller_stamp(controller, source)
    if not is_valid_object(controller) then return end
    local function apply()
        local pawn = live_pawn_from_controller(controller)
        if is_valid_object(pawn) then stamp_character_limit(pawn, source) end
    end
    if ExecuteInGameThread ~= nil then ExecuteInGameThread(apply) else apply() end
end

local function register_reflected_limit_override()
    local path = "/Script/TheIsle.TICharacterBase:GetMaxGroupSize"
    local ok, pre_id, post_id = pcall(function()
        return RegisterHook(path, function(_context) end, function(context, return_value)
            local character = object_from_context(context)
            if not is_valid_object(character) then return nil end
            local species = species_from_object(character)
            local configured_limit = configured_limits[species]
            if configured_limit == nil then return nil end
            local native_limit = value_as_number(return_value)
            local key = table.concat({tostring(species), tostring(native_limit), tostring(configured_limit)}, "|")
            if not logged_overrides[key] then
                logged_overrides[key] = true
                log(string.format("[Override] species=%s native=%s configured=%d object=%s", tostring(species), tostring(native_limit), configured_limit, full_name(character)))
            end
            -- Secondary path for UI/Blueprint calls using ProcessEvent.
            return configured_limit
        end)
    end)
    if ok then
        log(string.format("reflected GetMaxGroupSize override registered pre=%s post=%s", tostring(pre_id), tostring(post_id)))
    else
        log("reflected GetMaxGroupSize override failed: " .. tostring(pre_id))
    end
end

local function register_join_stamp()
    local path = "/Script/TheIsle.TIPlayerController:ServerJoinGroup"
    local ok, pre_id, post_id = pcall(function()
        return RegisterHook(path, function(_context, joining_character_param, _ignore_group_size_param, _ignore_distance_param, _comes_from_request_param, _friend_steam_param)
            local character = unwrap(joining_character_param)
            if is_valid_object(character) then stamp_character_limit(character, "ServerJoinGroup") end
            return nil
        end, function() return nil end)
    end)
    if ok then
        log(string.format("ServerJoinGroup stamp registered pre=%s post=%s", tostring(pre_id), tostring(post_id)))
    else
        log("ServerJoinGroup stamp failed: " .. tostring(pre_id))
    end
end

local function register_add_member_stamp()
    local path = "/Script/TheIsle.TIGameModeBase:AddNewGroupMember"
    local ok, pre_id, post_id = pcall(function()
        return RegisterHook(path, function(_context, character_param, _group_id_param, _ignore_limit_param)
            local character = unwrap(character_param)
            if is_valid_object(character) then stamp_character_limit(character, "AddNewGroupMember") end
            return nil
        end, function() return nil end)
    end)
    if ok then
        log(string.format("AddNewGroupMember stamp registered pre=%s post=%s", tostring(pre_id), tostring(post_id)))
    else
        log("AddNewGroupMember stamp failed: " .. tostring(pre_id))
    end
end

local function register_controller_heartbeat_stamp()
    local path = "/Script/TheIsle.TIPlayerController:SetAdminCred"
    local ok, pre_id, post_id = pcall(function()
        return RegisterHook(path, function(context, _is_admin_param)
            schedule_controller_stamp(object_from_context(context), "SetAdminCred")
            return nil
        end, function() return nil end)
    end)
    if ok then
        log(string.format("SetAdminCred heartbeat stamp registered pre=%s post=%s", tostring(pre_id), tostring(post_id)))
    else
        log("SetAdminCred heartbeat stamp failed: " .. tostring(pre_id))
    end
end

local function register_respawn_stamp()
    local path = "/Script/TheIsle.TIGameModeBase:OnPlayerRespawned"
    local ok, pre_id, post_id = pcall(function()
        return RegisterHook(path, function(_context, controller_param)
            schedule_controller_stamp(unwrap(controller_param), "OnPlayerRespawned")
            return nil
        end, function() return nil end)
    end)
    if ok then
        log(string.format("OnPlayerRespawned stamp registered pre=%s post=%s", tostring(pre_id), tostring(post_id)))
    else
        log("OnPlayerRespawned stamp failed: " .. tostring(pre_id))
    end
end

local config_loaded = load_config()
log(string.format(
    "loaded version=%s configLoaded=%s configuredSpecies=%d adminsExempt=false hatchlingsCount=true enforcement=GeneralSettings-stamp modRoot=%s",
    VERSION, tostring(config_loaded), configured_species_count(), MOD_ROOT
))

register_join_stamp()
register_add_member_stamp()
register_controller_heartbeat_stamp()
register_respawn_stamp()
register_reflected_limit_override()
