local MOD_NAME = "HerbivoreChat"
local VERSION = "0.2.1-alpha"

local function log(message)
    print(string.format(
        "[%s][Lua] %s\n",
        MOD_NAME,
        tostring(message)
    ))
end

local function safe_get(fn, fallback)
    local ok, value = pcall(fn)

    if ok then
        return value
    end

    return fallback
end

local function object_address(object)
    return safe_get(function()
        return object:GetAddress()
    end, 0)
end

local function is_valid_object(object)
    if object == nil then
        return false
    end

    local address = object_address(object)

    return address ~= nil and address ~= 0
end

local function safe_string(value)
    if value == nil then
        return ""
    end

    if type(value) == "string" then
        return value
    end

    local converted = safe_get(function()
        return value:ToString()
    end, nil)

    if converted ~= nil then
        return tostring(converted)
    end

    local ok, text = pcall(function()
        return tostring(value)
    end)

    if ok and type(text) == "string" then
        return text
    end

    return ""
end

local function resolve_mod_root()
    local fallback = "Mods/HerbivoreChat"

    if debug == nil or debug.getinfo == nil then
        return fallback
    end

    local ok, info = pcall(function()
        return debug.getinfo(1, "S")
    end)

    if not ok or info == nil or info.source == nil then
        return fallback
    end

    local source = tostring(info.source)
        :gsub("^@", "")
        :gsub("\\", "/")

    local root = source:match(
        "^(.*)/[Ss]cripts/main%.lua$"
    )

    if root == nil or root == "" then
        return fallback
    end

    return root
end

local MOD_ROOT = resolve_mod_root()
local CONFIG_PATH = MOD_ROOT .. "/config/HerbivoreChat.ini"
local QUEUE_DIR = MOD_ROOT .. "/queue"

local DEFAULT_HERBIVORES = {
    "Beipiosaurus",
    "Beipiaosaurus",
    "Diabloceratops",
    "Dryosaurus",
    "Gallimimus",
    "Hypsilophodon",
    "Kentrosaurus",
    "Maiasaura",
    "Pachycephalosaurus",
    "Stegosaurus",
    "Tenontosaurus",
    "Triceratops"
}

local config = {
    enabled = true,
    local_chat_range = 20000,
    deduplication_milliseconds = 2500,
    herbivores = {}
}

local function trim(value)
    return tostring(value or "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

local function normalized_name(value)
    return trim(value):lower():gsub("[^%w]", "")
end

local function canonical_species_name(value)
    local key = normalized_name(value)

    if key == "beipiaosaurus" or key == "beipiosaurus" then
        return "beipiosaurus"
    end

    if key == "ticeratops" or key == "triceratops" then
        return "triceratops"
    end

    return key
end

local function parse_boolean(value, fallback)
    local key = normalized_name(value)

    if key == "true" or key == "1" or key == "yes" or key == "on" then
        return true
    end

    if key == "false" or key == "0" or key == "no" or key == "off" then
        return false
    end

    return fallback
end

local function set_default_herbivores()
    config.herbivores = {}

    for _, species in ipairs(DEFAULT_HERBIVORES) do
        config.herbivores[
            canonical_species_name(species)
        ] = true
    end
end

local function load_config()
    set_default_herbivores()

    local file = io.open(CONFIG_PATH, "r")

    if file == nil then
        log(
            "config not found; using defaults path="
            .. CONFIG_PATH
        )
        return
    end

    local configured_herbivores = nil

    for raw_line in file:lines() do
        local line = trim(raw_line)

        if (
            line ~= ""
            and line:sub(1, 1) ~= ";"
            and line:sub(1, 1) ~= "#"
            and line:sub(1, 1) ~= "["
        ) then
            local key, value = line:match(
                "^([^=]+)=(.*)$"
            )

            if key ~= nil then
                key = normalized_name(key)
                value = trim(value)

                if key == "enabled" then
                    config.enabled = parse_boolean(
                        value,
                        config.enabled
                    )
                elseif key == "localchatrange" then
                    local parsed = tonumber(value)

                    if parsed ~= nil and parsed > 0 then
                        config.local_chat_range = parsed
                    end
                elseif key == "deduplicationmilliseconds" then
                    local parsed = tonumber(value)

                    if parsed ~= nil and parsed >= 250 then
                        config.deduplication_milliseconds = parsed
                    end
                elseif key == "herbivores" then
                    configured_herbivores = {}

                    for species in value:gmatch("[^,]+") do
                        local canonical = canonical_species_name(
                            species
                        )

                        if canonical ~= "" then
                            configured_herbivores[
                                canonical
                            ] = true
                        end
                    end
                end
            end
        end
    end

    file:close()

    if configured_herbivores ~= nil then
        config.herbivores = configured_herbivores
    end
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

local function get_species_key(pawn)
    if not is_valid_object(pawn) then
        return ""
    end

    local full_name = tostring(safe_get(function()
        return pawn:GetFullName()
    end, "") or "")

    local lower = full_name:lower()

    for _, item in ipairs(SPECIES_MATCHERS) do
        if lower:find(item[1], 1, true) then
            return item[2]
        end
    end

    local fallback = full_name:match(
        "BP_([%w]+)_C"
    )

    return canonical_species_name(fallback)
end

local function is_herbivore_species(species)
    return config.herbivores[
        canonical_species_name(species)
    ] == true
end

local function find_game_mode()
    local candidates = {
        "BP_SurvivalGameMode_C",
        "TISurvivalGameMode",
        "TIGameModeBase",
        "GameModeBase"
    }

    for _, class_name in ipairs(candidates) do
        local game_mode = safe_get(function()
            return FindFirstOf(class_name)
        end, nil)

        if is_valid_object(game_mode) then
            return game_mode
        end
    end

    return nil
end

local function live_pawn_from_controller(controller)
    if not is_valid_object(controller) then
        return nil
    end

    local pawn = safe_get(function()
        return controller:K2_GetPawn()
    end, nil)

    if not is_valid_object(pawn) then
        return nil
    end

    return pawn
end

local function get_controller_steam_id(controller)
    if not is_valid_object(controller) then
        return ""
    end

    local steam_id = safe_get(function()
        return controller:GetSteamId()
    end, nil)

    local value = safe_string(steam_id)

    if value ~= "" and not value:find("^UObject") then
        return value
    end

    local fallback = safe_get(function()
        return controller.SteamId
    end, nil)

    return safe_string(fallback)
end

local function is_admin_spectator(controller, pawn)
    if not is_valid_object(controller) then
        return true
    end

    if safe_get(function()
        return controller.bIsSpectating
    end, false) == true then
        return true
    end

    local pawn_name = tostring(safe_get(function()
        return pawn:GetFullName()
    end, "") or ""):lower()

    return pawn_name:find(
        "tiadminpawn",
        1,
        true
    ) ~= nil
        or pawn_name:find(
            "bp_adminpawn",
            1,
            true
        ) ~= nil
end

local function get_player_name(controller, fallback)
    if not is_valid_object(controller) then
        return fallback
    end

    local player_state = safe_get(function()
        return controller.PlayerState
    end, nil)

    if is_valid_object(player_state) then
        local name = safe_get(function()
            return player_state:GetPlayerName()
        end, nil)

        name = trim(safe_string(name))

        if name ~= "" then
            return name
        end
    end

    return fallback
end

local function actor_location(actor)
    if not is_valid_object(actor) then
        return nil
    end

    return safe_get(function()
        return actor:K2_GetActorLocation()
    end, nil)
end

local function vector_xyz(vector)
    if vector == nil then
        return nil
    end

    local x = tonumber(safe_get(function()
        return vector.X
    end, nil))
    local y = tonumber(safe_get(function()
        return vector.Y
    end, nil))
    local z = tonumber(safe_get(function()
        return vector.Z
    end, nil))

    if x == nil or y == nil or z == nil then
        return nil
    end

    return x, y, z
end

local function collect_live_players(game_mode)
    local players = {}
    local by_steam = {}

    local function add_controller(controller)
        if not is_valid_object(controller) then
            return
        end

        local steam = get_controller_steam_id(
            controller
        )

        if steam == "" or by_steam[steam] then
            return
        end

        local pawn = live_pawn_from_controller(
            controller
        )

        if (
            not is_valid_object(pawn)
            or is_admin_spectator(controller, pawn)
        ) then
            return
        end

        by_steam[steam] = true
        players[#players + 1] = {
            steam = steam,
            controller = controller,
            pawn = pawn
        }
    end

    if is_valid_object(game_mode) then
        local world = safe_get(function()
            return game_mode:GetWorld()
        end, nil)

        local game_state = nil

        if is_valid_object(world) then
            game_state = safe_get(function()
                return world.GameState
            end, nil)
        end

        if is_valid_object(game_state) then
            local player_array = safe_get(function()
                return game_state.PlayerArray
            end, nil)

            if player_array ~= nil then
                pcall(function()
                    player_array:ForEach(function(
                        first,
                        second
                    )
                        local player_state = second

                        if not is_valid_object(player_state) then
                            player_state = first
                        end

                        if not is_valid_object(player_state) then
                            return
                        end

                        local controller = safe_get(function()
                            return player_state:GetOwningController()
                        end, nil)

                        if not is_valid_object(controller) then
                            controller = safe_get(function()
                                return player_state:GetPlayerController()
                            end, nil)
                        end

                        add_controller(controller)
                    end)
                end)
            end
        end

        local controllers = safe_get(function()
            return game_mode.AllPlayerControllers
        end, nil)

        if controllers ~= nil then
            pcall(function()
                controllers:ForEach(function(
                    first,
                    second
                )
                    local controller = first

                    if not is_valid_object(controller) then
                        controller = second
                    end

                    add_controller(controller)
                end)
            end)
        end
    end

    local found = safe_get(function()
        return FindAllOf("BP_PlayerController_C")
    end, nil)

    if type(found) == "table" then
        for _, controller in pairs(found) do
            add_controller(controller)
        end
    end

    return players
end

local function unwrap_hook_param(param)
    if param == nil then
        return nil
    end

    return safe_get(function()
        return param:get()
    end, nil)
end

local function hook_text_to_string(param)
    local value = unwrap_hook_param(param)

    if value == nil then
        value = param
    end

    return safe_string(value)
end

local function hook_mode_to_number(param)
    local value = unwrap_hook_param(param)

    if type(value) == "number" then
        return math.floor(value)
    end

    local direct = tonumber(value)

    if direct ~= nil then
        return math.floor(direct)
    end

    local enum_value = tonumber(safe_get(function()
        return value.Value
    end, nil))

    if enum_value ~= nil then
        return math.floor(enum_value)
    end

    local text = safe_string(value)
    local parsed = tonumber(text:match("(%d+)"))

    if parsed ~= nil then
        return math.floor(parsed)
    end

    return nil
end

local function hook_bool_to_boolean(param, fallback)
    local value = unwrap_hook_param(param)

    if value == nil then
        value = param
    end

    if type(value) == "boolean" then
        return value
    end

    if type(value) == "number" then
        return value ~= 0
    end

    local numeric = tonumber(value)

    if numeric ~= nil then
        return numeric ~= 0
    end

    local text = normalized_name(
        safe_string(value)
    )

    if (
        text == "true"
        or text == "yes"
        or text == "on"
    ) then
        return true
    end

    if (
        text == "false"
        or text == "no"
        or text == "off"
    ) then
        return false
    end

    return fallback == true
end

local function hex_encode(value)
    value = tostring(value or "")

    return (
        value:gsub(".", function(character)
            return string.format(
                "%02X",
                string.byte(character)
            )
        end)
    )
end

local admin_status_by_steam = {}

local function register_admin_credential_hook()
    if RegisterHook == nil then
        log(
            "SetAdminCred hook unavailable; admin color preservation disabled"
        )
        return
    end

    local ok, error_message = pcall(function()
        RegisterHook(
            "/Script/TheIsle.TIPlayerController:SetAdminCred",
            function(
                controller_param,
                admin_param
            )
                local controller = unwrap_hook_param(
                    controller_param
                )

                if not is_valid_object(controller) then
                    return
                end

                local steam = get_controller_steam_id(
                    controller
                )

                if steam == "" then
                    return
                end

                local is_admin = hook_bool_to_boolean(
                    admin_param,
                    false
                )

                admin_status_by_steam[
                    tostring(steam)
                ] = is_admin

                log(string.format(
                    "[Admin] credential updated steam=%s isAdmin=%s",
                    tostring(steam),
                    tostring(is_admin)
                ))
            end
        )
    end)

    if ok then
        log(
            "SetAdminCred hook registered"
        )
    else
        log(
            "SetAdminCred hook failed: "
            .. tostring(error_message)
        )
    end
end

local queue_counter = 0

local function write_delivery_file(
    target_controller,
    sender_name,
    message,
    sender_steam,
    is_admin,
    is_dev
)
    if not is_valid_object(target_controller) then
        return false, "invalid-target"
    end

    local target_full_name = safe_get(function()
        return target_controller:GetFullName()
    end, nil)

    target_full_name = tostring(
        target_full_name or ""
    )

    if target_full_name == "" then
        return false, "target-name-empty"
    end

    queue_counter = queue_counter + 1

    local created = os.time()
    local random_part = math.random(
        100000,
        999999
    )

    local base_name = string.format(
        "msg-%d-%06d-%d",
        created,
        queue_counter % 1000000,
        random_part
    )

    local temporary_path =
        QUEUE_DIR .. "/" .. base_name .. ".tmp"
    local final_path =
        QUEUE_DIR .. "/" .. base_name .. ".hchat"

    local file, open_error = io.open(
        temporary_path,
        "wb"
    )

    if file == nil then
        return false, tostring(open_error)
    end

    file:write("version=2\n")
    file:write("created=", tostring(created), "\n")
    file:write("mode=0\n")
    file:write(
        "admin=",
        is_admin == true and "1" or "0",
        "\n"
    )
    file:write(
        "dev=",
        is_dev == true and "1" or "0",
        "\n"
    )
    file:write(
        "target=",
        hex_encode(target_full_name),
        "\n"
    )
    file:write(
        "sender=",
        hex_encode(sender_name),
        "\n"
    )
    file:write(
        "body=",
        hex_encode(message),
        "\n"
    )
    file:write(
        "steam=",
        hex_encode(sender_steam),
        "\n"
    )
    file:flush()
    file:close()

    local renamed, rename_error = os.rename(
        temporary_path,
        final_path
    )

    if not renamed then
        os.remove(temporary_path)
        return false, tostring(rename_error)
    end

    return true, final_path
end

local pending_messages = {}
local recent_messages = {}
local deduplication_seconds = 3

local function cleanup_dedup(now)
    for key, seen_at in pairs(recent_messages) do
        if (now - seen_at) > 15 then
            recent_messages[key] = nil
        end
    end
end

local function process_spatial_message(request)
    local game_mode = find_game_mode()

    if not is_valid_object(game_mode) then
        log(
            "route skipped: no valid GameMode"
        )
        return
    end

    local sender_controller = safe_get(function()
        return game_mode:GetControllerBySteamId(
            request.steam
        )
    end, nil)

    if not is_valid_object(sender_controller) then
        log(
            "route skipped: sender disconnected steam="
            .. tostring(request.steam)
        )
        return
    end

    local sender_pawn = live_pawn_from_controller(
        sender_controller
    )

    if (
        not is_valid_object(sender_pawn)
        or is_admin_spectator(
            sender_controller,
            sender_pawn
        )
    ) then
        return
    end

    local sender_species = get_species_key(
        sender_pawn
    )

    if not is_herbivore_species(sender_species) then
        return
    end

    local sender_location = actor_location(
        sender_pawn
    )
    local sx, sy, sz = vector_xyz(
        sender_location
    )

    if sx == nil then
        log(
            "route skipped: sender location unavailable steam="
            .. tostring(request.steam)
        )
        return
    end

    local sender_name = get_player_name(
        sender_controller,
        sender_species
    )

    local sender_is_admin =
        request.is_admin == true
        or admin_status_by_steam[
            tostring(request.steam)
        ] == true

    local sender_is_dev =
        request.is_dev == true

    local range_squared =
        config.local_chat_range
        * config.local_chat_range

    local recipients = 0
    local failures = 0

    for _, player in ipairs(
        collect_live_players(game_mode)
    ) do
        if player.steam ~= request.steam then
            local target_species = get_species_key(
                player.pawn
            )

            if (
                target_species ~= ""
                and target_species ~= sender_species
                and is_herbivore_species(
                    target_species
                )
            ) then
                local tx, ty, tz = vector_xyz(
                    actor_location(player.pawn)
                )

                if tx ~= nil then
                    local dx = tx - sx
                    local dy = ty - sy
                    local dz = tz - sz
                    local distance_squared =
                        dx * dx
                        + dy * dy
                        + dz * dz

                    if distance_squared <= range_squared then
                        local ok, reason = write_delivery_file(
                            player.controller,
                            sender_name,
                            request.message,
                            request.steam,
                            sender_is_admin,
                            sender_is_dev
                        )

                        if ok then
                            recipients = recipients + 1
                        else
                            failures = failures + 1
                            log(
                                "queue write failed targetSteam="
                                .. tostring(player.steam)
                                .. " reason="
                                .. tostring(reason)
                            )
                        end
                    end
                end
            end
        end
    end

    log(string.format(
        "[Route] sender=%s species=%s recipients=%d failures=%d admin=%s dev=%s",
        tostring(request.steam),
        tostring(sender_species),
        recipients,
        failures,
        tostring(sender_is_admin),
        tostring(sender_is_dev)
    ))
end

local function process_pending_messages()
    local processed = 0

    while #pending_messages > 0 and processed < 8 do
        local request = table.remove(
            pending_messages,
            1
        )

        processed = processed + 1

        local ok, error_message = pcall(function()
            process_spatial_message(request)
        end)

        if not ok then
            log(
                "route processing error: "
                .. tostring(error_message)
            )
        end
    end

    cleanup_dedup(os.time())
end

local function register_chat_hook()
    if RegisterHook == nil then
        log(
            "RegisterHook unavailable; feature disabled"
        )
        return
    end

    local ok, error_message = pcall(function()
        RegisterHook(
            "/Script/TheIsle.TIPlayerController:GetChatMessage",
            function(
                _receiver_param,
                new_text_param,
                sender_controller_param,
                chat_mode_param,
                no_filter_param
            )
                if not config.enabled then
                    return
                end

                local mode = hook_mode_to_number(
                    chat_mode_param
                )

                if mode ~= 0 then
                    return
                end

                local message = hook_text_to_string(
                    new_text_param
                )

                if message == "" then
                    message = hook_text_to_string(
                        no_filter_param
                    )
                end

                message = tostring(
                    message or ""
                )

                if trim(message) == "" then
                    return
                end

                local sender_controller =
                    unwrap_hook_param(
                        sender_controller_param
                    )

                if not is_valid_object(
                    sender_controller
                ) then
                    return
                end

                local sender_steam =
                    get_controller_steam_id(
                        sender_controller
                    )

                if sender_steam == "" then
                    return
                end

                local now = os.time()
                local dedup_key =
                    tostring(sender_steam)
                    .. "|0|"
                    .. message

                local last_seen = tonumber(
                    recent_messages[dedup_key]
                ) or 0

                if (
                    now - last_seen
                ) < deduplication_seconds then
                    return
                end

                recent_messages[dedup_key] = now

                if #pending_messages >= 100 then
                    table.remove(
                        pending_messages,
                        1
                    )
                end

                local sender_is_admin =
                    admin_status_by_steam[
                        tostring(sender_steam)
                    ] == true

                pending_messages[
                    #pending_messages + 1
                ] = {
                    steam = tostring(sender_steam),
                    message = message,
                    queued_at = now,
                    is_admin = sender_is_admin,
                    is_dev = false
                }
            end
        )
    end)

    if ok then
        log(
            "GetChatMessage hook registered"
        )
    else
        log(
            "GetChatMessage hook failed: "
            .. tostring(error_message)
        )
    end
end

math.randomseed(
    os.time()
    + math.floor(
        (os.clock() or 0) * 100000
    )
)

load_config()

deduplication_seconds = math.max(
    1,
    math.ceil(
        config.deduplication_milliseconds
        / 1000
    )
)

log(string.format(
    "loaded version=%s enabled=%s range=%.0f dedupSeconds=%d modRoot=%s",
    VERSION,
    tostring(config.enabled),
    config.local_chat_range,
    deduplication_seconds,
    MOD_ROOT
))

register_admin_credential_hook()
register_chat_hook()

if LoopInGameThreadWithDelay ~= nil then
    LoopInGameThreadWithDelay(
        100,
        process_pending_messages
    )
else
    log(
        "LoopInGameThreadWithDelay unavailable; feature disabled"
    )
end
