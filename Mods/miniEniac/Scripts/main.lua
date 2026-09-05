-- miniEniac - Migration / Patrol Zone Thickness Fix + Reliable Entry Detector
-- Version: 2026-09-04-zone-prime-v33-garage-progress-handoff
--
-- Features:
--   1. Keeps the proven Box-zone thickness fix:
--        Box-shaped TIEdibleSpawner zones with Z half-extent < 100 -> Z = 3000.
--   2. Polls live players once per second instead of relying on overlap hooks.
--   3. Detects Box, Sphere, and Custom Sanctuary/Migration/Patrol zone entry.
--   4. Tracks unique physical zones per dinosaur life and never double-counts the same zone.
--   5. Uses the authoritative Prime Task numbering supplied for The Mesozoic:
--        1 Sanctuary as juvenile; 2 Nested In; 3 Perfect Diet; 4 Mass Migration (panel only);
--        5 two migrations; 6 four patrols; 7 never infertile; 8 never muscle spasms;
--        9 raise children to subadult (panel only); 10 species task.
--   6. Detects Task 2 from bIsFromNestingGround / IsHatchling().
--   7. Detects Task 3 when CarbValue, ProteinValue, and LipidValue are all at least 1.0.
--   8. Task 10 applies to Hypsilophodon, Troodon, Beipiaosaurus/Beipiosaurus, Dryosaurus, and Deinosuchus.
--      Nested Hypsilophodon, Troodon, Beipiaosaurus/Beipiosaurus, Dryosaurus, and Deinosuchus lose Task 10.
--   9. Tasks 4 and 9 remain intentionally unavailable/incomplete for future Discord Prime Status display.
--  10. Freezes all Prime-task updates at 75% growth.
--  11. Tracks a true dinosaur life: species change, confirmed death->new pawn, or OnPlayerRespawned can reset state.
--  12. Continues notifying for every newly discovered unique migration/patrol after Prime thresholds.
--  13. Syncs tracker-owned Tasks 1/2/3/5/6/10 into EVRIMA's EligiblePrimeElderData.
--  14. Preserves native Tasks 4/7/8/9 and sets bIsEligiblePrime only when 5 real conditions are true.
--  15. Keeps state structured for later Discord Prime Status panel export.
--  16. Persists Prime state to disk with atomic writes so progress survives full server restarts.
--  17. Adds the in-game !prime command, replying through ClientShowNotification with:
--        Current progress: x/5 tasks completed!
--  18. Mirrors native Prime Conditions 2/3 immediately, including hatchlings below 25% growth.
--  19. Mirrors native Prime Conditions 7/8 turning false as silent task deductions before 75%.
--  20. Ignores TIAdminPawn / spectator-camera possession so admin spec mode never resets dinosaur life progress.
--  21. Adds !skintest, which directly writes all 10 CustomizerData color fields and calls ForceNetUpdate.
--      It deliberately does NOT touch PatternIndex, SkinVariation, ThemeIndex, or SkinCode.
--  22. Persists the currently applied skin per SteamID + dinosaur-life serial in an atomic TSV file.
--  23. Automatically reapplies that current-life skin after reconnect or full server restart only.
--      A true new dinosaur life (death/respawn or species change) clears the old life skin.
--      Future website default skins will be a separate explicit per-species feature.
--  24. Adds an external flat-NDJSON skin bridge for the future website/API.
--      Commands target a SteamID and provide all 10 color fields as #RRGGBB or #RRGGBBAA.
--      Successful website-applied skins are persisted to the current dinosaur life only.
--  25. Adds skin.inspect metadata readback for the current live dinosaur.
--  26. Adds skin.patterns.inspect, a read-only probe for the authoritative DT_SkinDataList DataTable.
--      It records row names, column names, row struct, and the exported SpeciePatterns column to disk.
--  27. Forces alpha to 1.0 / FF server-side for every website-supplied skin color, even for 8-digit input.
--  28. Parses the authoritative DT_SkinDataList SpeciePatterns export into per-species pattern counts.
--  29. Accepts optional pattern_index in website/API skin commands only when it is an integer inside
--      the current species' authoritative 0..N-1 range; invalid values are rejected, never clamped.
--  30. Restores a saved current-life PatternIndex after reconnect/restart only after the same validation.
--  31. Accepts optional is_female in website/API skin commands and writes CustomizerData.bIsFemale.
--  32. Persists asset sex through CustomizerData and ForceNetUpdate without the broken direct UpdateGender call.
--  33. Refreshes migration/patrol membership at runtime so late and moving zones remain detectable.
--  34. Uses the horizontal footprint for migration/patrol Box and Sphere areas so terrain height cannot hide a valid visit.
--  35. Adds !hp and !primelist player chat commands. !hp uses the Prime HUD notification;
--      !primelist sends the current ten-task list privately through the proven spatial-chat queue.
--
-- Expected startup markers:
--   [miniEniac][ZoneEntry] Script loaded. Waiting 60 seconds for Gateway actors to initialize...
--   [miniEniac][ZoneEntry] Reliable polling detector started. interval=1000ms shapes=Box,Sphere,Custom

local MOD_NAME = "miniEniac"
local MOD_VERSION = "2026-09-04-zone-prime-v33-garage-progress-handoff"

local PATCH_IF_BELOW_Z = 100.0
local TARGET_BOX_Z = 3000.0
local START_DELAY_MS = 60000
local POLL_INTERVAL_MS = 1000
local ZONE_CATALOG_REFRESH_MS = 30000
local NOTIFY_DRAIN_INTERVAL_MS = 500
local HEALTH_LOG_INTERVAL_SEC = 30
local PRIME_STATE_SAVE_INTERVAL_MS = 5000
local PRIME_CHAT_DEDUP_SEC = 3

-- Stored directly under the existing mod directory so no extra Saved folder has
-- to be created manually. Atomic temp+rename writes avoid half-written state files.
local PRIME_STATE_PATH = "Mods/miniEniac/prime_states_v1.tsv"
local PRIVATE_CHAT_QUEUE = "Mods/HerbivoreChat/queue"
local PRIVATE_CHAT_SENDER = "The Mesozoic"

-- Persistent skin storage for the currently living dinosaur only.
-- Keyed by SteamID + Prime life serial, so reconnects/restarts restore the skin,
-- while death/respawn or species change creates a new life and does not inherit it.
local SKIN_STATE_PATH = "Mods/miniEniac/skin_life_states_v2.tsv"
local SKIN_RESTORE_DELAY_SEC = 2
local SKIN_RESTORE_RETRY_SEC = 10

-- External bridge used by the future website/API. The command format is deliberately
-- flat NDJSON so UE4SS Lua does not need a third-party JSON library. The API will be
-- the only writer and must append one complete JSON object plus a newline per command.
--
-- IMPORTANT: bridge files use the absolute miniEniac mod directory derived from this
-- script's own source path. This avoids a Windows process-working-directory mismatch
-- where PowerShell writes to Win64\Mods\miniEniac while Lua reads relative paths from
-- another folder such as the server root. Prime/skin persistence paths are intentionally
-- left unchanged because those already work on this server.
local function resolve_mod_root_from_script()
    local fallback = "Mods/miniEniac"
    if debug == nil or debug.getinfo == nil then
        return fallback
    end

    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    if not ok or info == nil or info.source == nil then
        return fallback
    end

    local source = tostring(info.source):gsub("^@", ""):gsub("\\", "/")
    local root = source:match("^(.*)/[Ss]cripts/main%.lua$")
    if root == nil or root == "" then
        return fallback
    end
    return root
end

local SKIN_BRIDGE_MOD_ROOT = resolve_mod_root_from_script()
local SKIN_BRIDGE_COMMAND_PATH = SKIN_BRIDGE_MOD_ROOT .. "/skin_commands.ndjson"
local SKIN_BRIDGE_RESULT_PATH = SKIN_BRIDGE_MOD_ROOT .. "/skin_results.ndjson"
local SKIN_BRIDGE_CURSOR_PATH = SKIN_BRIDGE_MOD_ROOT .. "/skin_commands.offset"
-- Namespaced global table is intentional: this script already sits at Lua's
-- 200 top-level-local limit. One collision-resistant namespace preserves
-- syntax compatibility without creating multiple loose globals.
PRIME_RESTORE_BRIDGE = {
    command_path = SKIN_BRIDGE_MOD_ROOT .. "/prime_restore_commands.ndjson",
    cursor_path = SKIN_BRIDGE_MOD_ROOT .. "/prime_restore_commands.offset",
    offset = 0,
    loaded = false
}

-- Authoritative EVRIMA skin DataTable discovered in the user's UE4SS object dump.
-- v21 only reads this data and never writes PatternIndex. The raw export is written
-- to a probe file so we can inspect the exact cooked runtime representation before
-- building the final per-species pattern-count parser.
local SKIN_DATA_TABLE_ASSET_PATH = "/Game/TheIsle/UI/Menu/SkinPalette/DT_SkinDataList"
local SKIN_DATA_TABLE_OBJECT_PATH = "/Game/TheIsle/UI/Menu/SkinPalette/DT_SkinDataList.DT_SkinDataList"
local SKIN_PATTERN_PROBE_PATH = SKIN_BRIDGE_MOD_ROOT .. "/skin_pattern_probe_v1.txt"

-- Runtime-authoritative pattern map parsed from DT_SkinDataList.SpeciePatterns.
-- This is intentionally discovered from the game's cooked DataTable instead of hardcoding
-- species counts, so future game updates can be picked up by the same parser.
local skin_pattern_counts = {}
local skin_pattern_counts_ready = false
local skin_pattern_counts_source = "not-loaded"

-- Forward declaration: the implementation is assigned after the DataTable helpers are defined.
-- apply_saved_skin_state is declared earlier in the file but only executes after script loading.
local validate_skin_pattern_index = nil

local PRIME_GROWTH_CUTOFF = 0.75
local PRIME_REQUIRED_TASKS = 5
local MIGRATION_ZONES_REQUIRED = 2
local PATROL_ZONES_REQUIRED = 4

local PERFECT_DIET_MIN_VALUE = 1.0

-- First skin milestone: a deliberately loud preset so live application is obvious.
-- We do not touch PatternIndex yet because an out-of-range species pattern can silently
-- make the entire skin render fail. This test only writes POD FLinearColor fields.
local SKIN_TEST_PRESET = {
    BodyColor        = { R = 0.05, G = 1.00, B = 0.05, A = 1.0 }, -- bright green
    MarkingsColor    = { R = 1.00, G = 0.00, B = 1.00, A = 1.0 }, -- magenta
    FlankColor       = { R = 0.00, G = 1.00, B = 1.00, A = 1.0 }, -- cyan
    UnderbellyColor  = { R = 1.00, G = 1.00, B = 0.00, A = 1.0 }, -- yellow
    Detail1Color     = { R = 1.00, G = 0.20, B = 0.00, A = 1.0 }, -- orange-red
    EyesColor        = { R = 0.15, G = 0.45, B = 1.00, A = 1.0 }, -- bright blue
    MaleDisplayColor = { R = 1.00, G = 0.30, B = 0.80, A = 1.0 }, -- pink
    TeethColor       = { R = 1.00, G = 1.00, B = 1.00, A = 1.0 }, -- white
    MouthColor       = { R = 1.00, G = 0.00, B = 0.00, A = 1.0 }, -- red
    ClawsColor       = { R = 0.05, G = 0.05, B = 0.05, A = 1.0 }  -- near black
}

-- Stable order used by capture, persistence, and restore.
local SKIN_COLOR_FIELDS = {
    "BodyColor",
    "MarkingsColor",
    "FlankColor",
    "UnderbellyColor",
    "Detail1Color",
    "EyesColor",
    "MaleDisplayColor",
    "TeethColor",
    "MouthColor",
    "ClawsColor"
}

-- Flat JSON color keys accepted by the skin bridge. pattern_index is handled separately
-- because it requires authoritative per-species validation from DT_SkinDataList.
local SKIN_BRIDGE_COLOR_KEYS = {
    { json = "body",         field = "BodyColor" },
    { json = "markings",     field = "MarkingsColor" },
    { json = "flank",        field = "FlankColor" },
    { json = "underbelly",   field = "UnderbellyColor" },
    { json = "detail1",      field = "Detail1Color" },
    { json = "eyes",         field = "EyesColor" },
    { json = "male_display", field = "MaleDisplayColor" },
    { json = "teeth",        field = "TeethColor" },
    { json = "mouth",        field = "MouthColor" },
    { json = "claws",        field = "ClawsColor" }
}

-- Authoritative task map supplied for The Mesozoic. This metadata is intentionally
-- kept in Lua state so the Discord Prime Status panel can later consume the same map.
local PRIME_TASK_DEFINITIONS = {
    [1] = { name = "Visit a Sanctuary as a Juvenile", trackable = true },
    [2] = { name = "Get Nested In", trackable = true },
    [3] = { name = "Get Perfect Diet", trackable = true },
    [4] = { name = "Visit Mass Migration Zone", trackable = false, unavailable = true },
    [5] = { name = "Visit 2 Migration Zones", trackable = true, required = 2 },
    [6] = { name = "Visit 4 Patrol Zones", trackable = true, required = 4 },
    [7] = { name = "Never be infertile", trackable = true, native_owned = true },
    [8] = { name = "Never get muscle spasms", trackable = true, native_owned = true },
    [9] = { name = "Raise children to subadult", trackable = false, unavailable = true },
    [10] = { name = "Species task", trackable = true }
}

local TASK10_SPECIES = {
    hypsilophodon = true,
    troodon = true,
    beipiaosaurus = true,
    beipiosaurus = true, -- tolerate spelling variant
    dryosaurus = true,
    deinosuchus = true
}

-- Per the supplied Prime rules, these species lose Task 10 when nested/hatchling.
local TASK10_NESTED_EXCLUSION = {
    hypsilophodon = true,
    troodon = true,
    beipiaosaurus = true,
    beipiosaurus = true,
    dryosaurus = true,
    deinosuchus = true
}

-- [steamId][zoneKey] = true while the player is inside that zone.
local inside_state = {}

-- Queue entries: { steam = "...", message = "...", attempts = 0 }
local pending_notifies = {}

-- Production-safe online presence registry. The SetAdminCred hook seeds it, while
-- each polling tick re-validates entries through gm:GetControllerBySteamId(steam).
local presence_registry = {}

-- Prime state is kept per SteamID and follows the current dinosaur life.
-- Prime history resets only when the species changes. Growth changes never reset zone/task progress.
-- The state is intentionally structured so it can later be exported to the Discord bot.
local prime_states = {}
-- [steamId] = current prime-state key for the currently possessed dinosaur.
local current_prime_state_by_steam = {}

-- [steamId] = true after TIGameModeBase:OnPlayerRespawned fires.
-- This lets same-species respawns create a fresh Prime life without using growth changes.
local pending_respawn_by_steam = {}

-- Admin spectator-camera sessions must never be treated as dinosaur life changes.
-- [steamId] = { state_key = "...", previous_pawn_address = number, saw_dead_before = bool }
local spectator_sessions = {}

-- Persistence + chat-command runtime state.
local prime_state_dirty = false
local prime_state_dirty_reason = ""
local prime_state_loaded = false
local pending_prime_command_requests = {}
local pending_skin_test_command_requests = {}
local pending_health_command_requests = {}
local pending_prime_list_command_requests = {}
local recent_prime_chat_commands = {}
local private_chat_counter = 0

-- Persistent current-life skin state: ["steam|life_serial"] = saved skin snapshot.
local skin_states = {}
local skin_state_dirty = false
local skin_state_dirty_reason = ""
local skin_state_loaded = false

-- Runtime-only restore state, keyed by SteamID. This prevents applying every second.
local skin_restore_runtime = {}

-- Persistent read cursor for the append-only website/API command stream.
local skin_bridge_offset = 0
local skin_bridge_loaded = false

-- Authoritative zone catalog built from TIMigrationManager lists.
-- [zoneKey] = "migration" | "patrol" | "sanctuary"
local zone_catalog = {}
local zone_catalog_counts = { migration = 0, patrol = 0, sanctuary = 0 }

local boot_complete = false
local last_health_log_at = 0

-- UE4SS print() does not reliably append a newline, so always add one.
local function log(message)
    print(string.format("[%s]%s\n", MOD_NAME, tostring(message)))
end

local function safe_call(label, fn)
    local ok, result = pcall(fn)
    if not ok then
        log(string.format("[ZoneEntry][ERROR] %s failed: %s", tostring(label), tostring(result)))
        return false, nil
    end
    return true, result
end

local function safe_get(fn, fallback)
    local ok, value = pcall(fn)
    if ok then return value end
    return fallback
end

local function object_address(obj)
    return safe_get(function() return obj:GetAddress() end, 0)
end

local function is_valid_object(obj)
    if obj == nil then return false end
    local address = object_address(obj)
    return address ~= nil and address ~= 0
end

local function safe_string(value)
    if value == nil then return "" end

    local ok, s = pcall(function() return tostring(value) end)
    if ok and type(s) == "string" and s ~= "" and not s:find("^UObject") then
        return s
    end

    local ok_to_string, converted = pcall(function() return value:ToString() end)
    if ok_to_string and type(converted) == "string" then
        return converted
    end

    return ""
end

local function mark_prime_state_dirty(reason)
    prime_state_dirty = true
    prime_state_dirty_reason = tostring(reason or "state-changed")
end

local function persistence_escape(value)
    local s = tostring(value or "")
    s = s:gsub("%%", "%%25")
    s = s:gsub("\t", "%%09")
    s = s:gsub("\r", "%%0D")
    s = s:gsub("\n", "%%0A")
    s = s:gsub(",", "%%2C")
    return s
end

local function persistence_unescape(value)
    local s = tostring(value or "")
    return (s:gsub("%%(%x%x)", function(hex)
        local byte = tonumber(hex, 16)
        if byte == nil then return "%" .. hex end
        return string.char(byte)
    end))
end

local function bool_to_field(value)
    return value == true and "1" or "0"
end

local function field_to_bool(value)
    return tostring(value or "") == "1"
end

local function split_tsv(line)
    local fields = {}
    for value in (tostring(line or "") .. "\t"):gmatch("(.-)\t") do
        fields[#fields + 1] = value
    end
    return fields
end

local function task_set_to_csv(task_set)
    local values = {}
    for task_number, complete in pairs(task_set or {}) do
        if complete == true then
            values[#values + 1] = tonumber(task_number) or task_number
        end
    end
    table.sort(values, function(a, b) return tonumber(a) < tonumber(b) end)
    local out = {}
    for _, task_number in ipairs(values) do out[#out + 1] = tostring(task_number) end
    return table.concat(out, ",")
end

local function csv_to_task_set(csv)
    local out = {}
    for token in tostring(csv or ""):gmatch("[^,]+") do
        local task_number = tonumber(token)
        if task_number ~= nil then out[task_number] = true end
    end
    return out
end

local function string_set_to_csv(set_table)
    local values = {}
    for key, present in pairs(set_table or {}) do
        if present == true then values[#values + 1] = persistence_escape(key) end
    end
    table.sort(values)
    return table.concat(values, ",")
end

local function csv_to_string_set(csv)
    local out = {}
    for token in tostring(csv or ""):gmatch("[^,]+") do
        local key = persistence_unescape(token)
        if key ~= "" then out[key] = true end
    end
    return out
end

local function serialize_prime_state(state)
    return table.concat({
        persistence_escape(state.steam),
        persistence_escape(state.species),
        string.format("%.9f", tonumber(state.last_growth) or 0),
        tostring(tonumber(state.life_serial) or 1),
        bool_to_field(state.frozen),
        bool_to_field(state.saw_dead),
        bool_to_field(state.nested_in),
        bool_to_field(state.hatchling_spawn),
        bool_to_field(state.from_nesting_ground),
        bool_to_field(state.task10_blocked_by_nesting),
        task_set_to_csv(state.completed_tasks),
        string_set_to_csv(state.visited and state.visited.sanctuary or {}),
        string_set_to_csv(state.visited and state.visited.migration or {}),
        string_set_to_csv(state.visited and state.visited.patrol or {})
    }, "\t")
end

local function save_prime_states_to_disk(reason)
    if not prime_state_dirty then return true, "clean" end

    local keys = {}
    for key, _state in pairs(prime_states) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)

    local lines = { "miniEniacPrimeState\tv1" }
    for _, key in ipairs(keys) do
        local state = prime_states[key]
        if state ~= nil then lines[#lines + 1] = serialize_prime_state(state) end
    end

    local body = table.concat(lines, "\n") .. "\n"
    local tmp_path = PRIME_STATE_PATH .. ".tmp"
    local file = io.open(tmp_path, "wb")
    if file == nil then
        log(string.format("[Prime][PERSIST] save failed path=%s reason=open-temp", PRIME_STATE_PATH))
        return false, "open-temp-failed"
    end

    file:write(body)
    file:close()
    os.remove(PRIME_STATE_PATH)

    local renamed, rename_err = os.rename(tmp_path, PRIME_STATE_PATH)
    if not renamed then
        log(string.format(
            "[Prime][PERSIST] save failed path=%s reason=rename error=%s",
            PRIME_STATE_PATH,
            tostring(rename_err)
        ))
        return false, "rename-failed"
    end

    prime_state_dirty = false
    local dirty_reason = prime_state_dirty_reason
    prime_state_dirty_reason = ""
    log(string.format(
        "[Prime][PERSIST] saved states=%d path=%s reason=%s dirty_reason=%s",
        #keys,
        PRIME_STATE_PATH,
        tostring(reason or "autosave"),
        tostring(dirty_reason)
    ))
    return true, "ok"
end

local function load_prime_states_from_disk()
    if prime_state_loaded then return end
    prime_state_loaded = true

    local file = io.open(PRIME_STATE_PATH, "rb")
    if file == nil then
        log(string.format("[Prime][PERSIST] no existing state file path=%s", PRIME_STATE_PATH))
        return
    end

    local body = file:read("*a") or ""
    file:close()

    local loaded = 0
    local skipped = 0
    local line_number = 0

    for line in body:gmatch("[^\r\n]+") do
        line_number = line_number + 1
        if line_number > 1 and line ~= "" then
            local fields = split_tsv(line)
            if #fields >= 14 then
                local steam = persistence_unescape(fields[1])
                local species = persistence_unescape(fields[2])
                if steam ~= "" and species ~= "" then
                    local state = {
                        steam = steam,
                        state_key = steam,
                        character_id = nil,
                        species = species,
                        last_growth = tonumber(fields[3]) or 0,
                        last_pawn_address = 0,
                        saw_dead = field_to_bool(fields[6]),
                        life_serial = tonumber(fields[4]) or 1,
                        frozen = field_to_bool(fields[5]),
                        completed_tasks = csv_to_task_set(fields[11]),
                        task_definitions = PRIME_TASK_DEFINITIONS,
                        nested_in = field_to_bool(fields[7]),
                        hatchling_spawn = field_to_bool(fields[8]),
                        from_nesting_ground = field_to_bool(fields[9]),
                        task10_blocked_by_nesting = field_to_bool(fields[10]),
                        perfect_diet_values = nil,
                        nutrient_scale_logged = false,
                        loaded_from_disk = true,
                        visited = {
                            sanctuary = csv_to_string_set(fields[12]),
                            migration = csv_to_string_set(fields[13]),
                            patrol = csv_to_string_set(fields[14])
                        }
                    }
                    prime_states[steam] = state
                    current_prime_state_by_steam[steam] = steam
                    loaded = loaded + 1
                else
                    skipped = skipped + 1
                end
            else
                skipped = skipped + 1
            end
        end
    end

    prime_state_dirty = false
    prime_state_dirty_reason = ""
    log(string.format(
        "[Prime][PERSIST] loaded states=%d skipped=%d path=%s",
        loaded,
        skipped,
        PRIME_STATE_PATH
    ))
end

local function skin_state_key(steam, life_serial)
    return tostring(steam or "") .. "|" .. tostring(math.floor(tonumber(life_serial) or 1))
end

local function mark_skin_state_dirty(reason)
    skin_state_dirty = true
    skin_state_dirty_reason = tostring(reason or "skin-state-changed")
end

local function serialize_skin_state(state)
    local fields = {
        persistence_escape(state.steam),
        tostring(math.floor(tonumber(state.life_serial) or 1)),
        persistence_escape(state.species),
        tostring(tonumber(state.revision) or 1),
        tostring(tonumber(state.saved_at) or os.time()),
        state.pattern_index ~= nil and tostring(state.pattern_index) or "",
        state.skin_variation ~= nil and string.format("%.9f", tonumber(state.skin_variation) or 0) or "",
        state.theme_index ~= nil and tostring(state.theme_index) or "",
        bool_to_field(state.is_female == true)
    }

    for _, field in ipairs(SKIN_COLOR_FIELDS) do
        local color = state.colors and state.colors[field] or nil
        fields[#fields + 1] = string.format("%.9f", tonumber(color and color.R) or 0)
        fields[#fields + 1] = string.format("%.9f", tonumber(color and color.G) or 0)
        fields[#fields + 1] = string.format("%.9f", tonumber(color and color.B) or 0)
        fields[#fields + 1] = string.format("%.9f", tonumber(color and color.A) or 1)
    end

    return table.concat(fields, "\t")
end

local function save_skin_states_to_disk(reason)
    if not skin_state_dirty then return true, "clean" end

    local keys = {}
    for key, _state in pairs(skin_states) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)

    local lines = { "miniEniacSkinState\tv1" }
    for _, key in ipairs(keys) do
        local state = skin_states[key]
        if state ~= nil then lines[#lines + 1] = serialize_skin_state(state) end
    end

    local body = table.concat(lines, "\n") .. "\n"
    local tmp_path = SKIN_STATE_PATH .. ".tmp"
    local file = io.open(tmp_path, "wb")
    if file == nil then
        log(string.format("[Skin][PERSIST] save failed path=%s reason=open-temp", SKIN_STATE_PATH))
        return false, "open-temp-failed"
    end

    file:write(body)
    file:close()
    os.remove(SKIN_STATE_PATH)

    local renamed, rename_err = os.rename(tmp_path, SKIN_STATE_PATH)
    if not renamed then
        log(string.format(
            "[Skin][PERSIST] save failed path=%s reason=rename error=%s",
            SKIN_STATE_PATH,
            tostring(rename_err)
        ))
        return false, "rename-failed"
    end

    skin_state_dirty = false
    local dirty_reason = skin_state_dirty_reason
    skin_state_dirty_reason = ""
    log(string.format(
        "[Skin][PERSIST] saved skins=%d path=%s reason=%s dirty_reason=%s",
        #keys,
        SKIN_STATE_PATH,
        tostring(reason or "autosave"),
        tostring(dirty_reason)
    ))
    return true, "ok"
end

local function load_skin_states_from_disk()
    if skin_state_loaded then return end
    skin_state_loaded = true

    local file = io.open(SKIN_STATE_PATH, "rb")
    if file == nil then
        log(string.format("[Skin][PERSIST] no existing skin file path=%s", SKIN_STATE_PATH))
        return
    end

    local body = file:read("*a") or ""
    file:close()

    local loaded = 0
    local skipped = 0
    local line_number = 0
    local expected_fields = 9 + (#SKIN_COLOR_FIELDS * 4)

    for line in body:gmatch("[^\r\n]+") do
        line_number = line_number + 1
        if line_number > 1 and line ~= "" then
            local fields = split_tsv(line)
            if #fields >= expected_fields then
                local steam = persistence_unescape(fields[1])
                local life_serial = tonumber(fields[2]) or 1
                local species = persistence_unescape(fields[3])
                if steam ~= "" and species ~= "" and life_serial >= 1 then
                    local state = {
                        steam = steam,
                        life_serial = math.floor(life_serial),
                        species = species,
                        revision = tonumber(fields[4]) or 1,
                        saved_at = tonumber(fields[5]) or 0,
                        pattern_index = fields[6] ~= "" and tonumber(fields[6]) or nil,
                        skin_variation = fields[7] ~= "" and tonumber(fields[7]) or nil,
                        theme_index = fields[8] ~= "" and tonumber(fields[8]) or nil,
                        is_female = field_to_bool(fields[9]),
                        colors = {}
                    }

                    local index = 10
                    for _, field in ipairs(SKIN_COLOR_FIELDS) do
                        state.colors[field] = {
                            R = tonumber(fields[index]) or 0,
                            G = tonumber(fields[index + 1]) or 0,
                            B = tonumber(fields[index + 2]) or 0,
                            A = tonumber(fields[index + 3]) or 1
                        }
                        index = index + 4
                    end

                    skin_states[skin_state_key(steam, state.life_serial)] = state
                    loaded = loaded + 1
                else
                    skipped = skipped + 1
                end
            else
                skipped = skipped + 1
            end
        end
    end

    skin_state_dirty = false
    skin_state_dirty_reason = ""
    log(string.format(
        "[Skin][PERSIST] loaded skins=%d skipped=%d path=%s",
        loaded,
        skipped,
        SKIN_STATE_PATH
    ))
end

local function clear_saved_skin_for_life(steam, life_serial, reason)
    local key = skin_state_key(steam, life_serial)
    if skin_states[key] == nil then return false end

    skin_states[key] = nil
    skin_restore_runtime[tostring(steam)] = nil
    mark_skin_state_dirty("clear-life:" .. tostring(reason or "new-life"))
    log(string.format(
        "[Skin][LIFE_END] steam=%s life_serial=%d cleared=true reason=%s",
        tostring(steam),
        math.floor(tonumber(life_serial) or 1),
        tostring(reason or "new-life")
    ))
    return true
end

local function find_game_mode()
    local candidates = {
        "BP_SurvivalGameMode_C",
        "TISurvivalGameMode",
        "TIGameModeBase",
        "GameModeBase"
    }

    for _, class_name in ipairs(candidates) do
        local gm = safe_get(function() return FindFirstOf(class_name) end, nil)
        if is_valid_object(gm) then
            return gm
        end
    end

    return nil
end

local function live_pawn_from_ctrl(controller)
    if not is_valid_object(controller) then return nil end

    local pawn = safe_get(function() return controller:K2_GetPawn() end, nil)
    if not is_valid_object(pawn) then return nil end

    return pawn
end

local function get_controller_steam_id(controller)
    if not is_valid_object(controller) then return "" end

    local steam_id = safe_get(function() return controller:GetSteamId() end, nil)
    if steam_id ~= nil then
        -- Prefer the explicit ToString() path. This is the proven EVRIMA pattern
        -- for converting the Steam identifier wrapper to the 17-digit SteamID.
        local value = safe_get(function() return steam_id:ToString() end, nil)
        if value ~= nil then
            value = tostring(value)
            if value ~= "" then return value end
        end

        value = safe_string(steam_id)
        if value ~= "" and not value:find("^UObject") then
            return value
        end
    end

    local fallback_field = safe_get(function() return controller.SteamId end, nil)
    if fallback_field ~= nil then
        local value = safe_string(fallback_field)
        if value ~= "" then return value end
    end

    return ""
end


local function object_full_name(obj)
    if not is_valid_object(obj) then return "" end
    return tostring(safe_get(function() return obj:GetFullName() end, "") or "")
end

local function is_admin_spectator(controller, pawn)
    if not is_valid_object(controller) then return false end

    if safe_get(function() return controller.bIsSpectating end, false) == true then
        return true
    end

    local pawn_name = object_full_name(pawn):lower()
    if pawn_name:find("tiadminpawn", 1, true) or pawn_name:find("bp_adminpawn", 1, true) then
        return true
    end

    local last_admin_pawn = safe_get(function() return controller.LastAdminPawn end, nil)
    if is_valid_object(last_admin_pawn) and is_valid_object(pawn)
        and object_address(last_admin_pawn) == object_address(pawn) then
        return true
    end

    return false
end

local function remember_spectator_session(steam, controller)
    steam = tostring(steam or "")
    if steam == "" or spectator_sessions[steam] ~= nil then return end

    local state = prime_states[steam]
    local previous_pawn = safe_get(function() return controller.PreviousPawnFromSpectator end, nil)
    local previous_address = 0
    if is_valid_object(previous_pawn) then
        previous_address = object_address(previous_pawn)
    elseif state ~= nil then
        previous_address = tonumber(state.last_pawn_address) or 0
    end

    spectator_sessions[steam] = {
        state_key = steam,
        previous_pawn_address = previous_address,
        saw_dead_before = state ~= nil and state.saw_dead == true or false
    }

    pending_respawn_by_steam[steam] = nil
    log(string.format(
        "[Prime][SPECTATOR] steam=%s entered-admin-camera preserve_state=true previous_pawn=0x%X",
        steam, tonumber(previous_address) or 0
    ))
end

local function restore_after_spectator(steam, pawn)
    steam = tostring(steam or "")
    local session = spectator_sessions[steam]
    if session == nil then return false end

    spectator_sessions[steam] = nil
    pending_respawn_by_steam[steam] = nil

    local state = prime_states[session.state_key or steam]
    if state ~= nil and is_valid_object(pawn) then
        state.last_pawn_address = object_address(pawn)
        state.saw_dead = session.saw_dead_before == true
    end

    log(string.format(
        "[Prime][SPECTATOR] steam=%s exited-admin-camera preserve_state=true",
        steam
    ))
    return true
end

local function presence_update(steam)
    if steam == nil then return end
    steam = tostring(steam)
    if steam == "" then return end

    local now = os.time()
    if presence_registry[steam] == nil then
        presence_registry[steam] = { first_seen = now, last_seen = now }
        log(string.format("[Presence] discovered steam=%s", steam))
    else
        presence_registry[steam].last_seen = now
    end
end

local function presence_register_hook()
    if RegisterHook == nil then
        log("[Presence] RegisterHook unavailable; heartbeat hook skipped.")
        return
    end

    local ok, err = pcall(function()
        RegisterHook("/Script/TheIsle.TIPlayerController:SetAdminCred", function(ctrl_param, _bool_param)
            local controller = nil

            -- Hook parameters are wrapper objects on UE4SS; unwrap self safely.
            pcall(function() controller = ctrl_param:get() end)
            if not is_valid_object(controller) then return end

            local steam = get_controller_steam_id(controller)
            if steam ~= "" then
                presence_update(steam)
            end
        end)
    end)

    if ok then
        log("[Presence] SetAdminCred heartbeat hook registered.")
    else
        log("[Presence] SetAdminCred heartbeat hook FAILED: " .. tostring(err))
    end
end

local function respawn_register_hook()
    if RegisterHook == nil then
        log("[Prime][RESPAWN] RegisterHook unavailable; respawn hook skipped.")
        return
    end

    local ok, err = pcall(function()
        RegisterHook("/Script/TheIsle.TIGameModeBase:OnPlayerRespawned", function(_gm_param, controller_param)
            local controller = nil
            pcall(function() controller = controller_param:get() end)
            if not is_valid_object(controller) then return end

            local steam = get_controller_steam_id(controller)
            if steam ~= "" then
                local current_pawn = live_pawn_from_ctrl(controller)
                if is_admin_spectator(controller, current_pawn) or spectator_sessions[steam] ~= nil then
                    pending_respawn_by_steam[steam] = nil
                    presence_update(steam)
                    log(string.format("[Prime][RESPAWN] ignored spectator transition steam=%s", steam))
                    return
                end

                pending_respawn_by_steam[steam] = true
                presence_update(steam)
                log(string.format("[Prime][RESPAWN] pending new life steam=%s", steam))
            end
        end)
    end)

    if ok then
        log("[Prime][RESPAWN] OnPlayerRespawned hook registered.")
    else
        log("[Prime][RESPAWN] OnPlayerRespawned hook FAILED: " .. tostring(err))
    end
end

local function make_text(message)
    if FText == nil then return message end

    local ok, text = pcall(function() return FText(message) end)
    if ok and text ~= nil then return text end

    return message
end

local function hex_encode(value)
    return (tostring(value or ""):gsub(".", function(character)
        return string.format("%02X", string.byte(character))
    end))
end

local function write_private_chat_message(controller, message)
    if not is_valid_object(controller) then return false, "invalid-controller" end
    local target_full_name = tostring(safe_get(function()
        return controller:GetFullName()
    end, "") or "")
    if target_full_name == "" then return false, "target-name-empty" end
    if message == nil or tostring(message) == "" then return false, "message-empty" end

    private_chat_counter = private_chat_counter + 1
    local base_name = string.format(
        "player-command-%d-%06d",
        os.time(),
        private_chat_counter % 1000000
    )
    local temporary_path = PRIVATE_CHAT_QUEUE .. "/" .. base_name .. ".tmp"
    local final_path = PRIVATE_CHAT_QUEUE .. "/" .. base_name .. ".hchat"
    local file, open_error = io.open(temporary_path, "wb")
    if file == nil then return false, "queue-open-failed:" .. tostring(open_error) end

    file:write("version=2\n")
    file:write("created=", tostring(os.time()), "\n")
    file:write("mode=0\n")
    file:write("admin=1\n")
    file:write("dev=0\n")
    file:write("target=", hex_encode(target_full_name), "\n")
    file:write("sender=", hex_encode(PRIVATE_CHAT_SENDER), "\n")
    file:write("body=", hex_encode(tostring(message)), "\n")
    file:write("steam=", hex_encode("0"), "\n")
    file:flush()
    file:close()

    local renamed, rename_error = os.rename(temporary_path, final_path)
    if not renamed then
        os.remove(temporary_path)
        return false, "queue-rename-failed:" .. tostring(rename_error)
    end
    return true, "ok"
end

local function unwrap_hook_param(param)
    if param == nil then return nil end
    local value = nil
    pcall(function() value = param:get() end)
    return value
end

local function hook_text_to_string(param)
    local value = unwrap_hook_param(param)
    if value == nil then value = param end

    local text = safe_get(function() return value:ToString() end, nil)
    if text ~= nil then return tostring(text) end

    return safe_string(value)
end

local function hook_number(param)
    local value = unwrap_hook_param(param)
    if value == nil then value = param end
    local number = tonumber(value)
    if number ~= nil then return number end
    number = tonumber(safe_get(function() return value.Value end, nil))
    if number ~= nil then return number end
    return tonumber(tostring(value or ""):match("(%d+)"))
end

local function register_prime_chat_hook()
    if RegisterHook == nil then
        log("[Prime][CHAT] RegisterHook unavailable; !prime command disabled.")
        return
    end

    local ok, err = pcall(function()
        RegisterHook(
            "/Script/TheIsle.TIPlayerController:GetChatMessage",
            function(_receiver_param, new_text_param, sender_controller_param, chat_mode_param, _no_filter_param)
                local message = hook_text_to_string(new_text_param)
                message = tostring(message or ""):gsub("^%s+", ""):gsub("%s+$", "")
                local command = message:lower()
                if command ~= "!prime"
                    and command ~= "!skintest"
                    and command ~= "!hp"
                    and command ~= "!primelist" then
                    return
                end

                -- Player commands are accepted only from EChatMode.Spatial (0),
                -- the game's local/proximity chat channel.
                if hook_number(chat_mode_param) ~= 0 then return end

                local sender_controller = unwrap_hook_param(sender_controller_param)
                if not is_valid_object(sender_controller) then return end

                local steam = get_controller_steam_id(sender_controller)
                if steam == "" then return end

                local now = os.time()
                local dedup_key = tostring(steam) .. "|" .. command
                local last_seen = tonumber(recent_prime_chat_commands[dedup_key]) or 0
                if (now - last_seen) < PRIME_CHAT_DEDUP_SEC then return end
                recent_prime_chat_commands[dedup_key] = now

                if command == "!prime" then
                    pending_prime_command_requests[#pending_prime_command_requests + 1] = {
                        steam = tostring(steam),
                        queued_at = now
                    }
                    log(string.format("[Prime][CHAT] queued command=!prime steam=%s", tostring(steam)))
                elseif command == "!skintest" then
                    pending_skin_test_command_requests[#pending_skin_test_command_requests + 1] = {
                        steam = tostring(steam),
                        queued_at = now
                    }
                    log(string.format("[Skin][CHAT] queued command=!skintest steam=%s", tostring(steam)))
                elseif command == "!hp" then
                    pending_health_command_requests[#pending_health_command_requests + 1] = {
                        steam = tostring(steam),
                        queued_at = now
                    }
                    log(string.format("[PlayerCommand][CHAT] queued command=!hp steam=%s", tostring(steam)))
                elseif command == "!primelist" then
                    pending_prime_list_command_requests[#pending_prime_list_command_requests + 1] = {
                        steam = tostring(steam),
                        queued_at = now
                    }
                    log(string.format("[PlayerCommand][CHAT] queued command=!primelist steam=%s", tostring(steam)))
                end
            end
        )
    end)

    if ok then
        log("[Prime][CHAT] chat hook registered for !prime, !hp, !primelist, and !skintest.")
    else
        log("[Prime][CHAT] !prime chat hook FAILED: " .. tostring(err))
    end
end

local function notify_player(steam_id, message)
    if steam_id == nil or steam_id == "" then
        return false, "no-steam"
    end

    if message == nil or message == "" then
        return false, "no-message"
    end

    -- Fresh GameMode/controller resolution every notification attempt.
    local gm = find_game_mode()
    if not is_valid_object(gm) then
        return false, "no-gameMode"
    end

    local controller = safe_get(function()
        return gm:GetControllerBySteamId(steam_id)
    end, nil)

    if not is_valid_object(controller) then
        return false, "no-controller"
    end

    local text = make_text(message)
    local ok, err = pcall(function()
        controller:ClientShowNotification(text)
    end)

    if not ok then
        return false, "ClientShowNotification failed: " .. tostring(err)
    end

    return true, "ok"
end

local function queue_notification(steam_id, message)
    if steam_id == nil or steam_id == "" then return end
    if message == nil or message == "" then return end

    pending_notifies[#pending_notifies + 1] = {
        steam = tostring(steam_id),
        message = tostring(message),
        attempts = 0
    }
end

local function drain_notifications()
    if not boot_complete then return end
    if #pending_notifies == 0 then return end

    local drain = pending_notifies
    pending_notifies = {}

    for _, item in ipairs(drain) do
        item.attempts = (item.attempts or 0) + 1

        local ok, reason = notify_player(item.steam, item.message)
        log(string.format(
            "[ZoneEntry][NOTIFY] steam=%s ok=%s reason=%s attempt=%d",
            tostring(item.steam),
            tostring(ok),
            tostring(reason),
            item.attempts
        ))

        -- Retry only if the call itself failed. Do not retry ok=true, because that
        -- could create duplicate HUD popups on clients where delivery succeeded.
        if not ok and item.attempts < 2 then
            pending_notifies[#pending_notifies + 1] = item
        end
    end
end

local function shape_name(value)
    local text = tostring(value)
    local numeric = tonumber(value) or tonumber(text)

    if numeric == 0 or text:find("E_Sphere", 1, true) then
        return "Sphere"
    elseif numeric == 1 or text:find("E_Box", 1, true) then
        return "Box"
    elseif numeric == 2 or text:find("E_Custom", 1, true) then
        return "Custom"
    end

    return text
end

local function zone_key(zone)
    local full_name = safe_get(function() return zone:GetFullName() end, nil)
    if full_name ~= nil and full_name ~= "" then
        return tostring(full_name)
    end

    return string.format("0x%X", object_address(zone) or 0)
end

local function find_migration_manager()
    local candidates = {
        "BP_MigrationManager_C",
        "TIMigrationManager"
    }

    for _, class_name in ipairs(candidates) do
        local manager = safe_get(function() return FindFirstOf(class_name) end, nil)
        if is_valid_object(manager) then
            return manager
        end
    end

    return nil
end

local function unwrap_uobject(value)
    if value == nil then return nil end
    if is_valid_object(value) then return value end

    -- UE4SS TArray:ForEach passes elements as RemoteUnrealParam/LocalUnrealParam
    -- wrappers. The actual UObject is obtained through elem:get().
    local unwrapped = safe_get(function() return value:get() end, nil)
    if is_valid_object(unwrapped) then return unwrapped end

    return nil
end

local function for_each_object_array(array_wrapper, callback)
    if array_wrapper == nil then return false, 0 end

    local callback_count = 0
    local ok = pcall(function()
        array_wrapper:ForEach(function(first, second)
            -- TArray signature is normally (index, elem). Be tolerant of wrapper
            -- differences, but always unwrap the element parameter first.
            local obj = unwrap_uobject(second)
            if not is_valid_object(obj) then
                obj = unwrap_uobject(first)
            end

            if is_valid_object(obj) then
                callback_count = callback_count + 1
                callback(obj)
            end
        end)
    end)

    return ok, callback_count
end

local zone_catalog_signature = ""

local function rebuild_zone_catalog(reason)
    local catalog = {}
    local counts = { migration = 0, patrol = 0, sanctuary = 0 }
    local manager_edible = {}
    local manager_patrol = {}
    local diagnostics = {
        manager_found = false,
        manager_migration_callbacks = 0,
        manager_patrol_callbacks = 0,
        manager_migration_classified = 0,
        fallback_migration = 0,
        fallback_patrol = 0,
        sanctuary_overrides = 0
    }

    local manager = find_migration_manager()
    if is_valid_object(manager) then
        diagnostics.manager_found = true

        -- AllEdibleSpawners contains migration, patrol, and sanctuary spawners.
        -- Capture membership here, then apply the authoritative patrol list and
        -- sanctuary flags before treating remaining manager entries as migration.
        -- This preserves the earlier patrol fix without silently dropping valid
        -- migration spawners whose bShouldUseMigration flag differs at runtime.
        local all_edible = safe_get(function() return manager.AllEdibleSpawners end, nil)
        local edible_ok, edible_callbacks = for_each_object_array(all_edible, function(zone)
            manager_edible[zone_key(zone)] = true
        end)
        diagnostics.manager_migration_callbacks = edible_callbacks or 0
        if not edible_ok then
            log("[ZoneCatalog][WARN] AllEdibleSpawners ForEach failed.")
        end

        -- Authoritative patrol-only list. Patrol always overrides migration
        -- membership because gameplay treats patrol and migration as separate types.
        local patrol_only = safe_get(function() return manager.AllPatrolOnlySpawners end, nil)
        local patrol_ok, patrol_callbacks = for_each_object_array(patrol_only, function(zone)
            local key = zone_key(zone)
            manager_patrol[key] = true
            catalog[key] = "patrol"
        end)
        diagnostics.manager_patrol_callbacks = patrol_callbacks or 0
        if not patrol_ok then
            log("[ZoneCatalog][WARN] AllPatrolOnlySpawners ForEach failed.")
        end
    end

    -- Sanctuary is always a separate category. For uncataloged zones only, use
    -- raw flags as a fallback. If both patrol and migration flags are present,
    -- patrol wins because the user-confirmed gameplay rule says the two zone types
    -- are separate and never combined.
    local spawners = FindAllOf("TIEdibleSpawner")
    if spawners ~= nil then
        for _, zone in ipairs(spawners) do
            if is_valid_object(zone) then
                local key = zone_key(zone)
                local is_sanctuary = safe_get(function() return zone.bJuvenilesZone end, false) == true

                if is_sanctuary then
                    if catalog[key] ~= "sanctuary" then
                        diagnostics.sanctuary_overrides = diagnostics.sanctuary_overrides + 1
                    end
                    catalog[key] = "sanctuary"
                else
                    local is_patrol = safe_get(function() return zone.bPatrolZone end, false) == true
                    local is_nesting_patrol = safe_get(function() return zone.bNestingPatrol end, false) == true
                    local is_migration = safe_get(function() return zone.bShouldUseMigration end, false) == true
                    local migrate_here = safe_get(function() return zone.bMigrateHere end, false) == true

                    -- Classification priority:
                    --   1) authoritative patrol list
                    --   2) explicit patrol/nesting-patrol flags
                    --   3) migration-manager membership or migration flags
                    -- This deliberately gives patrol priority when raw flags conflict.
                    if manager_patrol[key] or catalog[key] == "patrol" then
                        -- Preserve authoritative patrol classification.
                    elseif is_patrol or is_nesting_patrol then
                        catalog[key] = "patrol"
                        diagnostics.fallback_patrol = diagnostics.fallback_patrol + 1
                    elseif manager_edible[key] then
                        catalog[key] = "migration"
                        diagnostics.manager_migration_classified = diagnostics.manager_migration_classified + 1
                    elseif is_migration or migrate_here then
                        catalog[key] = "migration"
                        diagnostics.fallback_migration = diagnostics.fallback_migration + 1
                    end
                end
            end
        end
    end

    for _, zone_type_name in pairs(catalog) do
        counts[zone_type_name] = (counts[zone_type_name] or 0) + 1
    end

    local keys = {}
    for key, kind in pairs(catalog) do
        keys[#keys + 1] = tostring(kind) .. ":" .. tostring(key)
    end
    table.sort(keys)
    local signature = table.concat(keys, "\n")
    local changed = signature ~= zone_catalog_signature

    zone_catalog = catalog
    zone_catalog_counts = counts
    zone_catalog_signature = signature

    if changed or reason == "boot" then
        log(string.format(
            "[ZoneCatalog] reason=%s changed=%s migration=%d patrol=%d sanctuary=%d total=%d manager_found=%s manager_edible_callbacks=%d manager_patrol_callbacks=%d manager_migration_classified=%d fallback_migration=%d fallback_patrol=%d sanctuary_overrides=%d",
            tostring(reason or "unknown"),
            tostring(changed),
            counts.migration or 0,
            counts.patrol or 0,
            counts.sanctuary or 0,
            (counts.migration or 0) + (counts.patrol or 0) + (counts.sanctuary or 0),
            tostring(diagnostics.manager_found),
            diagnostics.manager_migration_callbacks,
            diagnostics.manager_patrol_callbacks,
            diagnostics.manager_migration_classified,
            diagnostics.fallback_migration,
            diagnostics.fallback_patrol,
            diagnostics.sanctuary_overrides
        ))
    end

    return changed
end

local function zone_type(zone)
    if not is_valid_object(zone) then return nil end
    return zone_catalog[zone_key(zone)]
end

local function zone_is_relevant(zone)
    local kind = zone_type(zone)
    return kind ~= nil, kind
end

local function vector_xyz(v)
    if v == nil then return nil end
    local x = safe_get(function() return v.X end, nil)
    local y = safe_get(function() return v.Y end, nil)
    local z = safe_get(function() return v.Z end, nil)
    if x == nil or y == nil or z == nil then return nil end
    return tonumber(x), tonumber(y), tonumber(z)
end

local function actor_location(actor)
    if not is_valid_object(actor) then return nil end
    return safe_get(function() return actor:K2_GetActorLocation() end, nil)
end

local function component_location(component)
    if not is_valid_object(component) then return nil end
    return safe_get(function() return component:K2_GetComponentLocation() end, nil)
end

local function component_rotation(component)
    if not is_valid_object(component) then return nil end
    return safe_get(function() return component:K2_GetComponentRotation() end, nil)
end

-- Convert a world-space delta into component-local coordinates.
-- Unreal Rotator uses degrees; this applies the inverse of Roll(X), Pitch(Y), Yaw(Z).
local function world_delta_to_local(dx, dy, dz, rotation)
    if rotation == nil then return dx, dy, dz end

    local pitch = math.rad(tonumber(safe_get(function() return rotation.Pitch end, 0.0)) or 0.0)
    local yaw   = math.rad(tonumber(safe_get(function() return rotation.Yaw end, 0.0)) or 0.0)
    local roll  = math.rad(tonumber(safe_get(function() return rotation.Roll end, 0.0)) or 0.0)

    local cp, sp = math.cos(pitch), math.sin(pitch)
    local cy, sy = math.cos(yaw), math.sin(yaw)
    local cr, sr = math.cos(roll), math.sin(roll)

    -- R = Rz(yaw) * Ry(pitch) * Rx(roll)
    local r11 = cy * cp
    local r12 = cy * sp * sr - sy * cr
    local r13 = cy * sp * cr + sy * sr

    local r21 = sy * cp
    local r22 = sy * sp * sr + cy * cr
    local r23 = sy * sp * cr - cy * sr

    local r31 = -sp
    local r32 = cp * sr
    local r33 = cp * cr

    -- local = transpose(R) * world_delta
    local lx = r11 * dx + r21 * dy + r31 * dz
    local ly = r12 * dx + r22 * dy + r32 * dz
    local lz = r13 * dx + r23 * dy + r33 * dz
    return lx, ly, lz
end

local function box_contains_pawn(box, pawn, horizontal_only)
    local pawn_loc = actor_location(pawn)
    local box_loc = component_location(box)
    local extent = safe_get(function() return box:GetScaledBoxExtent() end, nil)
    if pawn_loc == nil or box_loc == nil or extent == nil then return false end

    local px, py, pz = vector_xyz(pawn_loc)
    local bx, by, bz = vector_xyz(box_loc)
    local ex, ey, ez = vector_xyz(extent)
    if px == nil or bx == nil or ex == nil then return false end

    local dx, dy, dz = px - bx, py - by, pz - bz
    local rotation = component_rotation(box)
    local lx, ly, lz = world_delta_to_local(dx, dy, dz, rotation)

    local horizontal_inside = math.abs(lx) <= ex and math.abs(ly) <= ey
    local full_inside = horizontal_inside and math.abs(lz) <= ez
    if horizontal_only then
        return horizontal_inside, horizontal_inside and not full_inside
    end
    return full_inside, false
end

local function sphere_contains_pawn(sphere, pawn, horizontal_only)
    local pawn_loc = actor_location(pawn)
    local sphere_loc = component_location(sphere)
    local radius = safe_get(function() return sphere:GetScaledSphereRadius() end, nil)
    if pawn_loc == nil or sphere_loc == nil or radius == nil then return false end

    local px, py, pz = vector_xyz(pawn_loc)
    local sx, sy, sz = vector_xyz(sphere_loc)
    radius = tonumber(radius)
    if px == nil or sx == nil or radius == nil then return false end

    local dx, dy, dz = px - sx, py - sy, pz - sz
    local horizontal_inside = (dx * dx + dy * dy) <= (radius * radius)
    local full_inside = (dx * dx + dy * dy + dz * dz) <= (radius * radius)
    if horizontal_only then
        return horizontal_inside, horizontal_inside and not full_inside
    end
    return full_inside, false
end

local function is_pawn_inside_zone(zone, pawn, area_shape, zone_kind)
    if not is_valid_object(zone) or not is_valid_object(pawn) then
        return false
    end

    if area_shape == "Box" then
        local box = safe_get(function() return zone.Box end, nil)
        if not is_valid_object(box) then return false end
        return box_contains_pawn(box, pawn, zone_kind == "migration" or zone_kind == "patrol")
    end

    if area_shape == "Sphere" then
        local sphere = safe_get(function() return zone.Sphere end, nil)
        if not is_valid_object(sphere) then return false end
        return sphere_contains_pawn(sphere, pawn, zone_kind == "migration" or zone_kind == "patrol")
    end

    if area_shape == "Custom" then
        return safe_get(function()
            return zone:IsPlayerInsideCustomArea(pawn)
        end, false) == true, false
    end

    return false, false
end

local function apply_zone_fix()
    local spawners = FindAllOf("TIEdibleSpawner")

    if spawners == nil then
        log("[ZoneFix] FindAllOf(TIEdibleSpawner) returned nil.")
        return
    end

    local total_found = 0
    local relevant_found = 0
    local box_found = 0
    local patched = 0
    local already_ok = 0
    local failed = 0

    for _, zone in ipairs(spawners) do
        total_found = total_found + 1

        if is_valid_object(zone) then
            local relevant, kind = zone_is_relevant(zone)

            if relevant and (kind == "migration" or kind == "patrol") then
                relevant_found = relevant_found + 1

                local area_shape = shape_name(safe_get(function()
                    return zone.AreaShape
                end, "<unknown>"))

                if area_shape == "Box" then
                    box_found = box_found + 1

                    local box = safe_get(function() return zone.Box end, nil)
                    if is_valid_object(box) then
                        local extent = safe_get(function()
                            return box:GetUnscaledBoxExtent()
                        end, nil)

                        if extent ~= nil then
                            local old_x = safe_get(function() return extent.X end, 0.0)
                            local old_y = safe_get(function() return extent.Y end, 0.0)
                            local old_z = safe_get(function() return extent.Z end, 0.0)

                            if old_z > 0.0 and old_z < PATCH_IF_BELOW_Z then
                                local full_name = safe_get(function()
                                    return zone:GetFullName()
                                end, "<unknown>")

                                extent.Z = TARGET_BOX_Z

                                local ok = pcall(function()
                                    box:SetBoxExtent(extent, true)
                                end)

                                if ok then
                                    local verify = safe_get(function()
                                        return box:GetUnscaledBoxExtent()
                                    end, nil)

                                    local new_z = verify and safe_get(function()
                                        return verify.Z
                                    end, -1.0) or -1.0

                                    if new_z >= TARGET_BOX_Z - 0.01 then
                                        patched = patched + 1
                                        log(string.format(
                                            "[ZoneFix][PATCHED %03d] migration=%s patrol=%s old=(%.2f, %.2f, %.2f) newZ=%.2f name=%s",
                                            patched,
                                            tostring(kind == "migration"),
                                            tostring(kind == "patrol"),
                                            old_x,
                                            old_y,
                                            old_z,
                                            new_z,
                                            tostring(full_name)
                                        ))
                                    else
                                        failed = failed + 1
                                        log(string.format(
                                            "[ZoneFix][VERIFY FAILED] oldZ=%.2f expectedZ=%.2f gotZ=%.2f name=%s",
                                            old_z,
                                            TARGET_BOX_Z,
                                            new_z,
                                            tostring(full_name)
                                        ))
                                    end
                                else
                                    failed = failed + 1
                                    log(string.format(
                                        "[ZoneFix][CALL FAILED] oldZ=%.2f name=%s",
                                        old_z,
                                        tostring(full_name)
                                    ))
                                end
                            else
                                already_ok = already_ok + 1
                            end
                        else
                            failed = failed + 1
                        end
                    else
                        failed = failed + 1
                    end
                end
            end
        end
    end

    log(string.format(
        "[ZoneFix] COMPLETE total_spawners=%d relevant=%d box=%d patched=%d already_ok=%d failed=%d targetZ=%.2f",
        total_found,
        relevant_found,
        box_found,
        patched,
        already_ok,
        failed,
        TARGET_BOX_Z
    ))
end

local function collect_live_players(gm)
    local players = {}
    local by_steam = {}
    local diagnostics = {
        player_array_callbacks = 0,
        controller_set_callbacks = 0,
        registry_checked = 0,
        controllers_valid = 0,
        pawns_valid = 0,
        source_player_array = 0,
        source_controller_set = 0,
        source_registry = 0
    }

    local function add_controller(controller, source)
        if not is_valid_object(controller) then return end

        diagnostics.controllers_valid = diagnostics.controllers_valid + 1

        local steam = get_controller_steam_id(controller)
        if steam == nil or steam == "" then return end

        presence_update(steam)

        if by_steam[steam] ~= nil then return end

        local pawn = live_pawn_from_ctrl(controller)
        if not is_valid_object(pawn) then return end

        diagnostics.pawns_valid = diagnostics.pawns_valid + 1
        by_steam[steam] = true
        players[#players + 1] = {
            steam = steam,
            controller = controller,
            pawn = pawn,
            source = source
        }

        if source == "PlayerArray" then diagnostics.source_player_array = diagnostics.source_player_array + 1
        elseif source == "AllPlayerControllers" then diagnostics.source_controller_set = diagnostics.source_controller_set + 1
        elseif source == "PresenceRegistry" then diagnostics.source_registry = diagnostics.source_registry + 1 end
    end

    -- PRIMARY: GameState.PlayerArray (TArray<APlayerState*>).
    -- This is the cleaner online snapshot path for new EVRIMA Lua code.
    local world = safe_get(function() return gm:GetWorld() end, nil)
    local game_state = nil
    if is_valid_object(world) then
        game_state = safe_get(function() return world.GameState end, nil)
    end

    if is_valid_object(game_state) then
        local player_array = safe_get(function() return game_state.PlayerArray end, nil)
        if player_array ~= nil then
            local ok = pcall(function()
                player_array:ForEach(function(first, second)
                    diagnostics.player_array_callbacks = diagnostics.player_array_callbacks + 1

                    -- TArray ForEach normally passes (index, element). Be tolerant
                    -- of wrapper/version differences and accept the valid UObject.
                    local player_state = second
                    if not is_valid_object(player_state) and is_valid_object(first) then
                        player_state = first
                    end
                    if not is_valid_object(player_state) then return end

                    local controller = safe_get(function()
                        return player_state:GetOwningController()
                    end, nil)
                    add_controller(controller, "PlayerArray")
                end)
            end)

            if not ok then
                log("[ZoneEntry][WARN] GameState.PlayerArray ForEach failed this tick.")
            end
        end
    end

    -- SECONDARY: gm.AllPlayerControllers is a TSet, not a TArray.
    local controllers = safe_get(function() return gm.AllPlayerControllers end, nil)
    if controllers ~= nil then
        local ok = pcall(function()
            controllers:ForEach(function(first, second)
                diagnostics.controller_set_callbacks = diagnostics.controller_set_callbacks + 1

                -- TSet normally passes the element as the first argument. The
                -- second-argument fallback makes this robust across wrapper builds.
                local controller = first
                if not is_valid_object(controller) and is_valid_object(second) then
                    controller = second
                end
                add_controller(controller, "AllPlayerControllers")
            end)
        end)

        if not ok then
            log("[ZoneEntry][WARN] GameMode.AllPlayerControllers ForEach failed this tick.")
        end
    end

    -- TERTIARY / PRODUCTION FALLBACK: known Steam IDs from the presence registry.
    -- Resolve a fresh controller every tick; never cache hook/controller wrappers.
    for steam, _entry in pairs(presence_registry) do
        diagnostics.registry_checked = diagnostics.registry_checked + 1
        local controller = safe_get(function()
            return gm:GetControllerBySteamId(steam)
        end, nil)

        if is_valid_object(controller) then
            presence_registry[steam].last_seen = os.time()
            add_controller(controller, "PresenceRegistry")
        else
            presence_registry[steam] = nil
        end
    end

    return players, diagnostics
end

local function table_count(set_table)
    local count = 0
    if set_table == nil then return 0 end
    for _, value in pairs(set_table) do
        if value == true then count = count + 1 end
    end
    return count
end

local function get_growth(pawn)
    local growth = safe_get(function() return pawn.Growth end, nil)
    growth = tonumber(growth)
    if growth == nil then return 0.0 end
    return growth
end

local function get_character_id(pawn)
    if not is_valid_object(pawn) then return nil end

    local id_string = safe_get(function() return pawn:GetIdString() end, nil)
    if id_string ~= nil then
        id_string = tostring(id_string)
        if id_string ~= "" and id_string ~= "0" then
            return id_string
        end
    end

    local numeric_id = safe_get(function() return pawn:GetId() end, nil)
    numeric_id = tonumber(numeric_id)
    if numeric_id ~= nil and numeric_id ~= 0 then
        return tostring(math.floor(numeric_id))
    end

    return nil
end

local function prime_state_key(steam, pawn, species)
    -- IMPORTANT: Do not key persistent Prime state by GetIdString()/GetId().
    -- On this EVRIMA/UE4SS build those values can change between fresh pawn
    -- resolutions, which recreates state and causes the same zone to be counted
    -- every poll. SteamID is the stable owner key; new dinosaur lives are handled
    -- explicitly in get_or_reset_prime_state() by species-change detection only.
    local character_id = get_character_id(pawn) -- diagnostic only
    return tostring(steam), character_id
end

local PLAYABLE_SPECIES = {
    { "diabloceratops", "Diabloceratops" },
    { "dryosaurus", "Dryosaurus" },
    { "hypsilophodon", "Hypsilophodon" },
    { "kentrosaurus", "Kentrosaurus" },
    { "maiasaura", "Maiasaura" },
    { "pachycephalosaurus", "Pachycephalosaurus" },
    { "stegosaurus", "Stegosaurus" },
    { "tenontosaurus", "Tenontosaurus" },
    { "triceratops", "Triceratops" },
    { "ticeratops", "Triceratops" }, -- tolerate supplied/common misspelling
    { "allosaurus", "Allosaurus" },
    { "carnotaurus", "Carnotaurus" },
    { "ceratosaurus", "Ceratosaurus" },
    { "deinosuchus", "Deinosuchus" },
    { "dilophosaurus", "Dilophosaurus" },
    { "herrerasaurus", "Herrerasaurus" },
    { "omniraptor", "Omniraptor" },
    { "pteranodon", "Pteranodon" },
    { "troodon", "Troodon" },
    { "tyrannosaurus", "Tyrannosaurus" },
    { "beipiaosaurus", "Beipiaosaurus" },
    { "beipiosaurus", "Beipiosaurus" }, -- tolerate server/display spelling variant
    { "gallimimus", "Gallimimus" }
}

local function get_species_name(pawn)
    local full_name = safe_get(function() return pawn:GetFullName() end, "")
    full_name = tostring(full_name or "")
    local lower = full_name:lower()

    for _, item in ipairs(PLAYABLE_SPECIES) do
        if lower:find(item[1], 1, true) then
            return item[2]
        end
    end

    local bp_name = full_name:match("BP_([%w]+)_C")
    if bp_name ~= nil and bp_name ~= "" then
        return bp_name
    end

    return "Unknown"
end

local function normalized_species_key(species)
    if species == nil then return "" end
    return tostring(species):lower()
end

local function is_task10_species(species)
    return TASK10_SPECIES[normalized_species_key(species)] == true
end

local function is_task10_nested_exclusion(species)
    return TASK10_NESTED_EXCLUSION[normalized_species_key(species)] == true
end

local function get_nesting_status(pawn)
    if not is_valid_object(pawn) then
        return false, false, false
    end

    local from_nesting_ground = safe_get(function() return pawn.bIsFromNestingGround end, false) == true
    local hatchling = safe_get(function() return pawn:IsHatchling() end, false) == true
    local nested = from_nesting_ground or hatchling

    return nested, hatchling, from_nesting_ground
end

local function get_nutrient_values(pawn)
    if not is_valid_object(pawn) then return nil end

    local nutrients = safe_get(function() return pawn.NutrientsStruct end, nil)
    if nutrients == nil then return nil end

    local carb = tonumber(safe_get(function() return nutrients.CarbValue end, nil))
    local protein = tonumber(safe_get(function() return nutrients.ProteinValue end, nil))
    local lipid = tonumber(safe_get(function() return nutrients.LipidValue end, nil))

    if carb == nil or protein == nil or lipid == nil then
        return nil
    end

    return { carb = carb, protein = protein, lipid = lipid }
end

local function has_perfect_diet(pawn)
    local values = get_nutrient_values(pawn)
    if values == nil then return false, nil end

    local complete = values.carb >= PERFECT_DIET_MIN_VALUE
        and values.protein >= PERFECT_DIET_MIN_VALUE
        and values.lipid >= PERFECT_DIET_MIN_VALUE

    return complete, values
end

local function completed_task_count(state)
    return table_count(state.completed_tasks)
end

local function prime_progress_line(state)
    local completed = completed_task_count(state)
    if completed >= PRIME_REQUIRED_TASKS then
        return string.format(
            "Prime eligibility reached - %d/%d tasks complete!",
            completed,
            PRIME_REQUIRED_TASKS
        )
    end

    return string.format("Prime progress: %d/5 tasks complete", completed)
end

local function get_prime_data_direct(pawn)
    if not is_valid_object(pawn) then return nil end

    local data = safe_get(function() return pawn:GetEligiblePrimeElderData() end, nil)
    if data ~= nil then return data end

    return safe_get(function() return pawn.EligiblePrimeElderData end, nil)
end

local function get_native_prime_condition(pawn, task_number, data_override)
    local data = data_override or get_prime_data_direct(pawn)
    if data == nil then return nil end

    if task_number == 1 then return safe_get(function() return data.bPrimeCondition1 end, nil)
    elseif task_number == 2 then return safe_get(function() return data.bPrimeCondition2 end, nil)
    elseif task_number == 3 then return safe_get(function() return data.bPrimeCondition3 end, nil)
    elseif task_number == 4 then return safe_get(function() return data.bPrimeCondition4 end, nil)
    elseif task_number == 5 then return safe_get(function() return data.bPrimeCondition5 end, nil)
    elseif task_number == 6 then return safe_get(function() return data.bPrimeCondition6 end, nil)
    elseif task_number == 7 then return safe_get(function() return data.bPrimeCondition7 end, nil)
    elseif task_number == 8 then return safe_get(function() return data.bPrimeCondition8 end, nil)
    elseif task_number == 9 then return safe_get(function() return data.bPrimeCondition9 end, nil)
    elseif task_number == 10 then return safe_get(function() return data.bPrimeCondition10 end, nil)
    end

    return nil
end

local function create_prime_state(steam, pawn, species, growth, state_key, character_id, pawn_address, is_dead)
    -- Tasks 7 and 8 normally start true, but EVRIMA's real Prime struct is
    -- authoritative whenever readable. Native Conditions 2 and 3 also backfill
    -- hatchlings immediately, including below 25% growth.
    local completed = {}
    local native_prime = get_prime_data_direct(pawn)
    local native_task2 = get_native_prime_condition(pawn, 2, native_prime)
    local native_task3 = get_native_prime_condition(pawn, 3, native_prime)
    local native_task7 = get_native_prime_condition(pawn, 7, native_prime)
    local native_task8 = get_native_prime_condition(pawn, 8, native_prime)

    if native_task7 ~= false then completed[7] = true end
    if native_task8 ~= false then completed[8] = true end

    local nested, hatchling, from_nesting_ground = get_nesting_status(pawn)
    if nested or native_task2 == true then
        completed[2] = true -- Get Nested In (silent spawn/native credit)
        nested = true
    end

    if native_task3 == true then
        completed[3] = true -- Perfect Diet may already be true at 0% hatchling growth.
    end

    local task10_blocked_by_nesting = nested and is_task10_nested_exclusion(species)
    if is_task10_species(species) and not task10_blocked_by_nesting then
        completed[10] = true -- Species task (silent spawn credit)
    end

    local state = {
        steam = tostring(steam),
        state_key = tostring(state_key),
        character_id = character_id,
        species = species,
        last_growth = growth,
        last_pawn_address = tonumber(pawn_address) or 0,
        saw_dead = is_dead == true,
        life_serial = 1,
        frozen = false,
        completed_tasks = completed,
        task_definitions = PRIME_TASK_DEFINITIONS,
        nested_in = nested,
        hatchling_spawn = hatchling,
        from_nesting_ground = from_nesting_ground,
        task10_blocked_by_nesting = task10_blocked_by_nesting,
        perfect_diet_values = nil,
        nutrient_scale_logged = false,
        visited = {
            sanctuary = {},
            migration = {},
            patrol = {}
        }
    }

    log(string.format(
        "[Prime][INIT] steam=%s character_id=%s species=%s growth=%.4f nested=%s hatchling=%s from_nesting_ground=%s task10=%s task10_blocked=%s starting_tasks=%d",
        tostring(steam),
        tostring(character_id or "fallback"),
        tostring(species),
        growth,
        tostring(nested),
        tostring(hatchling),
        tostring(from_nesting_ground),
        tostring(completed[10] == true),
        tostring(task10_blocked_by_nesting),
        completed_task_count(state)
    ))

    return state
end

local function get_prime_data(pawn)
    return get_prime_data_direct(pawn)
end

local function count_game_prime_conditions(data)
    if data == nil then return 0 end

    local values = {
        safe_get(function() return data.bPrimeCondition1 end, false),
        safe_get(function() return data.bPrimeCondition2 end, false),
        safe_get(function() return data.bPrimeCondition3 end, false),
        safe_get(function() return data.bPrimeCondition4 end, false),
        safe_get(function() return data.bPrimeCondition5 end, false),
        safe_get(function() return data.bPrimeCondition6 end, false),
        safe_get(function() return data.bPrimeCondition7 end, false),
        safe_get(function() return data.bPrimeCondition8 end, false),
        safe_get(function() return data.bPrimeCondition9 end, false),
        safe_get(function() return data.bPrimeCondition10 end, false)
    }

    local count = 0
    for _, value in ipairs(values) do
        if value == true then count = count + 1 end
    end
    return count
end

local function sync_prime_game_state(pawn, state, reason)
    if not is_valid_object(pawn) or state == nil then
        return false, "invalid-pawn-or-state"
    end

    local data = get_prime_data(pawn)
    if data == nil then
        log(string.format(
            "[Prime][GAME_SYNC] steam=%s reason=%s ok=false error=no-prime-data",
            tostring(state.steam), tostring(reason or "unknown")
        ))
        return false, "no-prime-data"
    end

    local changed = false

    -- Tracker-owned tasks. Tasks 7 and 8 remain native-owned because their failure
    -- conditions are handled by EVRIMA. Tasks 4 and 9 are intentionally untouched.
    if state.completed_tasks[1] == true and safe_get(function() return data.bPrimeCondition1 end, false) ~= true then
        if pcall(function() data.bPrimeCondition1 = true end) then changed = true end
    end

    if state.completed_tasks[2] == true and safe_get(function() return data.bPrimeCondition2 end, false) ~= true then
        if pcall(function() data.bPrimeCondition2 = true end) then changed = true end
    end

    if state.completed_tasks[3] == true and safe_get(function() return data.bPrimeCondition3 end, false) ~= true then
        if pcall(function() data.bPrimeCondition3 = true end) then changed = true end
    end

    if state.completed_tasks[5] == true and safe_get(function() return data.bPrimeCondition5 end, false) ~= true then
        if pcall(function() data.bPrimeCondition5 = true end) then changed = true end
    end

    if state.completed_tasks[6] == true and safe_get(function() return data.bPrimeCondition6 end, false) ~= true then
        if pcall(function() data.bPrimeCondition6 = true end) then changed = true end
    end

    if state.completed_tasks[10] == true and safe_get(function() return data.bPrimeCondition10 end, false) ~= true then
        if pcall(function() data.bPrimeCondition10 = true end) then changed = true end
    elseif state.task10_blocked_by_nesting == true
        and safe_get(function() return data.bPrimeCondition10 end, false) == true then
        -- Nested Hypsi/Troodon/Beipi/Dryo/Deino explicitly lose Task 10.
        if pcall(function() data.bPrimeCondition10 = false end) then changed = true end
    end

    local condition_count = count_game_prime_conditions(data)
    local eligible_before = safe_get(function() return data.bIsEligiblePrime end, false) == true

    if condition_count >= PRIME_REQUIRED_TASKS and not eligible_before then
        if pcall(function() data.bIsEligiblePrime = true end) then changed = true end
    end

    if changed then
        local ok, err = pcall(function()
            pawn:SetEligiblePrimeElderData(data)
        end)
        if not ok then
            log(string.format(
                "[Prime][GAME_SYNC] steam=%s reason=%s ok=false error=%s conditions=%d",
                tostring(state.steam), tostring(reason or "unknown"), tostring(err), condition_count
            ))
            return false, tostring(err)
        end
    end

    local final_data = get_prime_data(pawn)
    local final_count = count_game_prime_conditions(final_data)
    local final_eligible = final_data ~= nil and safe_get(function() return final_data.bIsEligiblePrime end, false) == true

    log(string.format(
        "[Prime][GAME_SYNC] steam=%s reason=%s ok=true changed=%s real_conditions=%d eligible=%s task1=%s task2=%s task3=%s task5=%s task6=%s task10=%s",
        tostring(state.steam),
        tostring(reason or "unknown"),
        tostring(changed),
        final_count,
        tostring(final_eligible),
        tostring(final_data ~= nil and safe_get(function() return final_data.bPrimeCondition1 end, false) == true),
        tostring(final_data ~= nil and safe_get(function() return final_data.bPrimeCondition2 end, false) == true),
        tostring(final_data ~= nil and safe_get(function() return final_data.bPrimeCondition3 end, false) == true),
        tostring(final_data ~= nil and safe_get(function() return final_data.bPrimeCondition5 end, false) == true),
        tostring(final_data ~= nil and safe_get(function() return final_data.bPrimeCondition6 end, false) == true),
        tostring(final_data ~= nil and safe_get(function() return final_data.bPrimeCondition10 end, false) == true)
    ))

    return true, "ok"
end

local function get_or_reset_prime_state(steam, pawn)
    local growth = get_growth(pawn)
    local species = get_species_name(pawn)
    local state_key, character_id = prime_state_key(steam, pawn, species)
    local state = prime_states[state_key]
    local pawn_address = object_address(pawn)
    local is_dead = safe_get(function() return pawn.bIsDead end, false) == true

    if state == nil then
        state = create_prime_state(steam, pawn, species, growth, state_key, character_id, pawn_address, is_dead)
        prime_states[state_key] = state
        mark_prime_state_dirty("first-seen-life")
        -- If OnPlayerRespawned fired before we first observed this pawn, this pawn
        -- already represents the new life; consume the pending marker now.
        pending_respawn_by_steam[tostring(steam)] = nil
        log(string.format(
            "[Prime][LIFE] steam=%s character_id=%s reason=first-seen species=%s growth=%.4f pawn=0x%X",
            tostring(steam),
            tostring(character_id or "fallback"),
            tostring(species),
            growth,
            tonumber(pawn_address) or 0
        ))
        sync_prime_game_state(pawn, state, "initial-life-state")
    else
        local reset_reason = nil
        local previous_pawn_address = tonumber(state.last_pawn_address) or 0
        local pawn_changed = pawn_address ~= nil and pawn_address ~= 0 and previous_pawn_address ~= 0 and pawn_address ~= previous_pawn_address

        if state.species ~= species and species ~= "Unknown" then
            reset_reason = "species-changed"
        elseif state.loaded_from_disk == true and state.saw_dead == true and not is_dead then
            -- A previous server session observed this dinosaur dead. If the first live
            -- pawn after restart is alive, treat it as a new life even though the old
            -- in-memory pawn address no longer exists.
            reset_reason = "persisted-dead-new-life"
        elseif pending_respawn_by_steam[tostring(steam)] == true and pawn_changed then
            reset_reason = "respawn-event-same-species"
        elseif state.saw_dead == true and pawn_changed and not is_dead then
            reset_reason = "dead-pawn-replaced-same-species"
        end

        if reset_reason ~= nil then
            local previous_life_serial = tonumber(state.life_serial) or 1
            local next_life_serial = previous_life_serial + 1
            clear_saved_skin_for_life(steam, previous_life_serial, reset_reason)
            state = create_prime_state(steam, pawn, species, growth, state_key, character_id, pawn_address, is_dead)
            state.life_serial = next_life_serial
            prime_states[state_key] = state
            mark_prime_state_dirty("new-life:" .. tostring(reset_reason))
            inside_state[state_key] = nil
            pending_respawn_by_steam[tostring(steam)] = nil

            log(string.format(
                "[Prime][LIFE] steam=%s character_id=%s reason=%s species=%s growth=%.4f life_serial=%d pawn=0x%X",
                tostring(steam),
                tostring(character_id or "diagnostic-unavailable"),
                reset_reason,
                tostring(species),
                growth,
                state.life_serial,
                tonumber(pawn_address) or 0
            ))
            sync_prime_game_state(pawn, state, "new-life-state")
        else
            -- A pawn-address change by itself is NOT enough to reset Prime progress:
            -- reconnecting may recreate the pawn wrapper/object. We preserve state unless
            -- there is a species change, confirmed previous death, or respawn event.
            state.character_id = character_id or state.character_id
            state.loaded_from_disk = false
            if is_dead and state.saw_dead ~= true then
                state.saw_dead = true
                mark_prime_state_dirty("death-observed")
            elseif is_dead then
                state.saw_dead = true
            end
            if pawn_address ~= nil and pawn_address ~= 0 then
                state.last_pawn_address = pawn_address
            end
        end
    end

    current_prime_state_by_steam[steam] = state_key
    state.last_growth = growth
    if is_dead then state.saw_dead = true end

    -- Final game-state sync happens before the 75% freeze so all tracker-owned
    -- completed tasks are written into EVRIMA's actual Prime struct before eligibility is decided.
    if not state.frozen and growth >= PRIME_GROWTH_CUTOFF then
        sync_prime_game_state(pawn, state, "pre-75%-freeze")
        state.frozen = true
        mark_prime_state_dirty("growth-freeze-75")
        log(string.format(
            "[Prime][FROZEN] steam=%s character_id=%s species=%s growth=%.4f completed_tasks=%d eligible=%s",
            tostring(steam),
            tostring(state.character_id or "fallback"),
            tostring(state.species),
            growth,
            completed_task_count(state),
            tostring(completed_task_count(state) >= PRIME_REQUIRED_TASKS)
        ))
    end

    return state, growth
end

local function mark_task_complete(state, task_number)
    if state.completed_tasks[task_number] == true then
        return false
    end
    state.completed_tasks[task_number] = true
    mark_prime_state_dirty("task-complete:" .. tostring(task_number))
    return true
end


-- Future/native reconciliation hook point for Task 7 (infertility) and Task 8 (muscle spasms).
-- Deductions should remain silent for players, matching the design.
local function mark_task_failed(state, task_number, reason)
    if state == nil or state.frozen then return false end
    if state.completed_tasks[task_number] ~= true then return false end

    state.completed_tasks[task_number] = nil
    mark_prime_state_dirty("task-deducted:" .. tostring(task_number))
    log(string.format(
        "[Prime][TASK_DEDUCTED] steam=%s character_id=%s task=%d reason=%s remaining_tasks=%d",
        tostring(state.steam),
        tostring(state.character_id or "fallback"),
        tonumber(task_number) or -1,
        tostring(reason or "unknown"),
        completed_task_count(state)
    ))
    return true
end


local function notify_prime_message(steam, message)
    log(string.format("[Prime][MESSAGE] steam=%s message=%s", tostring(steam), tostring(message)))
    queue_notification(steam, message)
end

local function reconcile_dynamic_prime_tasks(steam, pawn, state)
    if state == nil or state.frozen or not is_valid_object(pawn) then return end

    local native_prime = get_prime_data(pawn)
    local native_task2 = get_native_prime_condition(pawn, 2, native_prime)
    local native_task3 = get_native_prime_condition(pawn, 3, native_prime)
    local native_task7 = get_native_prime_condition(pawn, 7, native_prime)
    local native_task8 = get_native_prime_condition(pawn, 8, native_prime)

    -- Task 2: native Condition 2 is authoritative and fixes hatchlings whose
    -- nesting status is already complete in EVRIMA but not exposed by IsHatchling().
    if state.completed_tasks[2] ~= true then
        local nested, hatchling, from_nesting_ground = get_nesting_status(pawn)
        if nested or native_task2 == true then
            state.nested_in = true
            state.hatchling_spawn = hatchling or state.hatchling_spawn == true
            state.from_nesting_ground = from_nesting_ground or state.from_nesting_ground == true
            mark_task_complete(state, 2)

            if is_task10_nested_exclusion(state.species) then
                state.task10_blocked_by_nesting = true
                state.completed_tasks[10] = nil
            end

            sync_prime_game_state(pawn, state, "task-2-nested-in")
            log(string.format(
                "[Prime][TASK_COMPLETE] steam=%s task=2 silent=true native=%s nested=%s hatchling=%s from_nesting_ground=%s",
                tostring(steam), tostring(native_task2 == true), tostring(nested), tostring(hatchling), tostring(from_nesting_ground)
            ))
        end
    end

    -- Task 10: species task. Silent credit, with the nested-species exclusion.
    local should_have_task10 = is_task10_species(state.species)
        and not (state.nested_in == true and is_task10_nested_exclusion(state.species))

    if should_have_task10 and state.completed_tasks[10] ~= true then
        mark_task_complete(state, 10)
        state.task10_blocked_by_nesting = false
        sync_prime_game_state(pawn, state, "task-10-species")
        log(string.format(
            "[Prime][TASK_COMPLETE] steam=%s task=10 silent=true species=%s",
            tostring(steam), tostring(state.species)
        ))
    elseif not should_have_task10 and state.completed_tasks[10] == true then
        state.completed_tasks[10] = nil
        mark_prime_state_dirty("task-10-removed-by-nesting")
        state.task10_blocked_by_nesting = state.nested_in == true and is_task10_nested_exclusion(state.species)
        sync_prime_game_state(pawn, state, "task-10-removed-by-nesting")
    end

    -- Tasks 7 and 8 are irreversible "never" conditions for the current life.
    -- If EVRIMA flips the actual condition false before 75%, mirror that silently.
    if native_task7 == false then
        mark_task_failed(state, 7, "native-prime-condition7-false")
    end
    if native_task8 == false then
        mark_task_failed(state, 8, "native-prime-condition8-false")
    end

    -- Task 3: prefer native Condition 3 so parent-fed hatchlings can complete
    -- Perfect Diet immediately at 0% growth. Raw nutrient values remain fallback.
    if state.completed_tasks[3] ~= true then
        local complete = native_task3 == true
        local source = complete and "native-prime-condition3" or "nutrient-values"
        local values = nil

        if not complete then
            complete, values = has_perfect_diet(pawn)
        end

        if values ~= nil then
            state.perfect_diet_values = values
            if state.nutrient_scale_logged ~= true then
                state.nutrient_scale_logged = true
                log(string.format(
                    "[Prime][DIET_STATUS] steam=%s carb=%.3f protein=%.3f lipid=%.3f threshold=%.3f native_task3=%s",
                    tostring(steam), values.carb, values.protein, values.lipid, PERFECT_DIET_MIN_VALUE, tostring(native_task3 == true)
                ))
            end
        end

        if complete and mark_task_complete(state, 3) then
            sync_prime_game_state(pawn, state, "task-3-perfect-diet")
            notify_prime_message(steam, string.format(
                "Prime Task 3 complete - Perfect diet achieved!\n%s",
                prime_progress_line(state)
            ))
            log(string.format(
                "[Prime][TASK_COMPLETE] steam=%s task=3 source=%s carb=%s protein=%s lipid=%s threshold=%.3f growth=%.4f",
                tostring(steam), tostring(source),
                values ~= nil and string.format("%.3f", values.carb) or "n/a",
                values ~= nil and string.format("%.3f", values.protein) or "n/a",
                values ~= nil and string.format("%.3f", values.lipid) or "n/a",
                PERFECT_DIET_MIN_VALUE, get_growth(pawn)
            ))
        end
    end
end

local function process_prime_command_requests()
    if #pending_prime_command_requests == 0 then return end

    local requests = pending_prime_command_requests
    pending_prime_command_requests = {}

    local gm = find_game_mode()
    if not is_valid_object(gm) then
        log("[Prime][CHAT] cannot process !prime requests: no valid GameMode")
        return
    end

    for _, request in ipairs(requests) do
        local steam = tostring(request.steam or "")
        if steam ~= "" then
            local controller = safe_get(function() return gm:GetControllerBySteamId(steam) end, nil)
            local pawn = live_pawn_from_ctrl(controller)

            if is_valid_object(pawn) then
                local state = get_or_reset_prime_state(steam, pawn)
                local completed = completed_task_count(state)
                local message = string.format(
                    "Current progress: %d/5 tasks completed!",
                    completed
                )
                queue_notification(steam, message)
                log(string.format(
                    "[Prime][CHAT] command=!prime steam=%s completed=%d displayed=%d frozen=%s",
                    steam,
                    completed,
                    completed,
                    tostring(state.frozen)
                ))
            else
                queue_notification(steam, "Current progress unavailable - no active dinosaur.")
                log(string.format("[Prime][CHAT] command=!prime steam=%s no-active-pawn", steam))
            end
        end
    end
end

local function process_health_command_requests()
    if #pending_health_command_requests == 0 then return end
    local requests = pending_health_command_requests
    pending_health_command_requests = {}
    local gm = find_game_mode()

    for _, request in ipairs(requests) do
        local steam = tostring(request.steam or "")
        local controller = is_valid_object(gm) and safe_get(function()
            return gm:GetControllerBySteamId(steam)
        end, nil) or nil
        local pawn = live_pawn_from_ctrl(controller)
        if is_valid_object(pawn) then
            local health = tonumber(safe_get(function() return pawn:GetHealth() end, nil))
            local max_health = tonumber(safe_get(function() return pawn:GetMaxHealth() end, nil))
            if health ~= nil and max_health ~= nil and max_health > 0 then
                local percent = math.max(0, math.min(100, health / max_health * 100))
                queue_notification(steam, string.format("Current Health: %.1f%%", percent))
                log(string.format(
                    "[PlayerCommand][RUN] command=!hp steam=%s health=%.3f maxHealth=%.3f percent=%.1f",
                    steam, health, max_health, percent
                ))
            else
                queue_notification(steam, "Current Health unavailable.")
            end
        else
            queue_notification(steam, "Current Health unavailable - no active dinosaur.")
        end
    end
end

local function prime_task_line(state, task_number)
    local definition = PRIME_TASK_DEFINITIONS[task_number] or {}
    local status = state.completed_tasks[task_number] == true and "DONE" or "NOT DONE"
    local progress = ""
    if task_number == 5 then
        progress = string.format(
            " (%d/%d)",
            math.min(table_count(state.visited and state.visited.migration or {}), MIGRATION_ZONES_REQUIRED),
            MIGRATION_ZONES_REQUIRED
        )
    elseif task_number == 6 then
        progress = string.format(
            " (%d/%d)",
            math.min(table_count(state.visited and state.visited.patrol or {}), PATROL_ZONES_REQUIRED),
            PATROL_ZONES_REQUIRED
        )
    end
    return string.format("[%s] %d. %s%s", status, task_number, tostring(definition.name or "Unknown task"), progress)
end

local function process_prime_list_command_requests()
    if #pending_prime_list_command_requests == 0 then return end
    local requests = pending_prime_list_command_requests
    pending_prime_list_command_requests = {}
    local gm = find_game_mode()

    for _, request in ipairs(requests) do
        local steam = tostring(request.steam or "")
        local controller = is_valid_object(gm) and safe_get(function()
            return gm:GetControllerBySteamId(steam)
        end, nil) or nil
        local pawn = live_pawn_from_ctrl(controller)
        if is_valid_object(pawn) then
            local state = get_or_reset_prime_state(steam, pawn)
            reconcile_dynamic_prime_tasks(steam, pawn, state)
            local first = { "PRIME TASKS - " .. tostring(state.species or "Unknown") }
            local second = {}
            for task_number = 1, 5 do
                first[#first + 1] = prime_task_line(state, task_number)
            end
            for task_number = 6, 10 do
                second[#second + 1] = prime_task_line(state, task_number)
            end
            second[#second + 1] = string.format("Completed: %d/10", completed_task_count(state))

            local sent_first, first_reason = write_private_chat_message(controller, table.concat(first, "\n"))
            local sent_second, second_reason = write_private_chat_message(controller, table.concat(second, "\n"))
            if not sent_first or not sent_second then
                queue_notification(steam, "Prime task list could not be delivered in chat.")
            end
            log(string.format(
                "[PlayerCommand][RUN] command=!primelist steam=%s completed=%d first=%s:%s second=%s:%s",
                steam,
                completed_task_count(state),
                tostring(sent_first), tostring(first_reason),
                tostring(sent_second), tostring(second_reason)
            ))
        else
            queue_notification(steam, "Prime task list unavailable - no active dinosaur.")
        end
    end
end


local function apply_skin_test_preset(pawn)
    if not is_valid_object(pawn) then
        return false, "no-valid-pawn"
    end

    -- Same-tick rule: read the live CustomizerData wrapper fresh for every apply.
    -- Never cache this wrapper across ticks.
    local ok_cd, cd = pcall(function()
        return pawn.CustomizerData
    end)

    if not ok_cd or cd == nil then
        return false, "CustomizerData unavailable"
    end

    local failures = {}
    local written = 0

    local function write_color(field, color)
        local ok, err = pcall(function()
            cd[field].R = color.R
            cd[field].G = color.G
            cd[field].B = color.B
            cd[field].A = color.A or 1.0
        end)

        if ok then
            written = written + 1
        else
            failures[#failures + 1] = tostring(field) .. ": " .. tostring(err)
        end
    end

    for field, color in pairs(SKIN_TEST_PRESET) do
        write_color(field, color)
    end

    local net_ok, net_err = pcall(function()
        pawn:ForceNetUpdate()
    end)

    if not net_ok then
        failures[#failures + 1] = "ForceNetUpdate: " .. tostring(net_err)
    end

    if #failures > 0 then
        return false, string.format(
            "written=%d/10 failures=%s",
            written,
            table.concat(failures, " | ")
        )
    end

    return true, string.format("written=%d/10 ForceNetUpdate=ok", written)
end

local function read_customizer_color(cd, field)
    local color = safe_get(function() return cd[field] end, nil)
    if color == nil then return nil end

    local r = tonumber(safe_get(function() return color.R end, nil))
    local g = tonumber(safe_get(function() return color.G end, nil))
    local b = tonumber(safe_get(function() return color.B end, nil))
    local a = tonumber(safe_get(function() return color.A end, 1.0)) or 1.0

    if r == nil or g == nil or b == nil then return nil end
    return { R = r, G = g, B = b, A = a }
end

local function capture_current_skin_state(steam, pawn, species, life_serial, source)
    if not is_valid_object(pawn) then return false, "no-valid-pawn" end

    local cd = safe_get(function() return pawn.CustomizerData end, nil)
    if cd == nil then return false, "CustomizerData unavailable" end

    local colors = {}
    for _, field in ipairs(SKIN_COLOR_FIELDS) do
        local color = read_customizer_color(cd, field)
        if color == nil then
            return false, "read-failed:" .. tostring(field)
        end
        colors[field] = color
    end

    local key = skin_state_key(steam, life_serial)
    local previous = skin_states[key]
    local state = {
        steam = tostring(steam),
        life_serial = math.floor(tonumber(life_serial) or 1),
        species = tostring(species),
        revision = (previous and tonumber(previous.revision) or 0) + 1,
        saved_at = os.time(),
        pattern_index = tonumber(safe_get(function() return cd.PatternIndex end, nil)),
        skin_variation = tonumber(safe_get(function() return cd.SkinVariation end, nil)),
        theme_index = tonumber(safe_get(function() return cd.ThemeIndex end, nil)),
        is_female = safe_get(function() return cd.bIsFemale end, false) == true,
        colors = colors,
        source = tostring(source or "unknown")
    }

    skin_states[key] = state
    mark_skin_state_dirty("capture:" .. tostring(source or "unknown"))

    log(string.format(
        "[Skin][SAVE] steam=%s life_serial=%d species=%s revision=%d source=%s pattern=%s variation=%s theme=%s",
        tostring(steam),
        tonumber(state.life_serial) or 1,
        tostring(species),
        tonumber(state.revision) or 1,
        tostring(source or "unknown"),
        tostring(state.pattern_index),
        tostring(state.skin_variation),
        tostring(state.theme_index)
    ))

    return true, state
end

local function apply_saved_skin_state(pawn, state)
    if not is_valid_object(pawn) then return false, "no-valid-pawn" end
    if state == nil or state.colors == nil then return false, "no-saved-state" end

    -- Same-tick rule: always fetch the live struct wrapper fresh.
    local cd = safe_get(function() return pawn.CustomizerData end, nil)
    if cd == nil then return false, "CustomizerData unavailable" end

    local failures = {}
    local written = 0

    if state.pattern_index ~= nil then
        local species = tostring(state.species or get_species_name(pawn) or "")
        if type(validate_skin_pattern_index) ~= "function" then
            failures[#failures + 1] = "PatternIndex: validator-unavailable"
        else
            local valid, pattern_count, normalized_or_reason = validate_skin_pattern_index(
                species,
                state.pattern_index
            )
            if not valid then
                failures[#failures + 1] = "PatternIndex: " .. tostring(normalized_or_reason)
            else
                local pi_ok, pi_err = pcall(function()
                    cd.PatternIndex = normalized_or_reason
                end)
                if not pi_ok then
                    failures[#failures + 1] = "PatternIndex: " .. tostring(pi_err)
                end
            end
        end
    end

    if state.skin_variation ~= nil then
        local sv_ok, sv_err = pcall(function()
            cd.SkinVariation = math.floor(tonumber(state.skin_variation) or 0)
        end)
        if not sv_ok then
            failures[#failures + 1] = "SkinVariation: " .. tostring(sv_err)
        end
    end

    -- Asset sex is stored in the same CustomizerData snapshot as the colors,
    -- pattern, and variation. Directly writing bIsFemale and calling
    -- ForceNetUpdate works on this server build.
    --
    -- Do not call UpdateGender through UE4SS here. It resolves as a
    -- TrivialObject and incorrectly causes an otherwise successful skin
    -- command to fail before the new current-life skin can be saved.
    if state.is_female ~= nil then
        local sex_ok, sex_err = pcall(function()
            cd.bIsFemale = state.is_female == true
        end)

        if not sex_ok then
            failures[#failures + 1] = "bIsFemale: " .. tostring(sex_err)
        end
    end

    -- PatternIndex can rebuild EVRIMA's pattern material and overwrite color
    -- fields. Apply pattern/variation/sex first, then reacquire CustomizerData
    -- and make all ten colors the final skin writes.
    cd = safe_get(function() return pawn.CustomizerData end, nil)
    if cd == nil then
        return false, "CustomizerData unavailable after pattern write"
    end
    for _, field in ipairs(SKIN_COLOR_FIELDS) do
        local color = state.colors[field]
        if color == nil then
            failures[#failures + 1] = tostring(field) .. ": missing-saved-color"
        else
            local ok, err = pcall(function()
                cd[field].R = color.R
                cd[field].G = color.G
                cd[field].B = color.B
                cd[field].A = color.A or 1.0
            end)

            if ok then
                written = written + 1
            else
                failures[#failures + 1] = tostring(field) .. ": " .. tostring(err)
            end
        end
    end

    local net_ok, net_err = pcall(function() pawn:ForceNetUpdate() end)
    if not net_ok then
        failures[#failures + 1] = "ForceNetUpdate: " .. tostring(net_err)
    end

    if #failures > 0 then
        return false, string.format("written=%d/10 failures=%s", written, table.concat(failures, " | "))
    end

    return true, string.format("written=%d/10 ForceNetUpdate=ok", written)
end

local function remember_skin_applied(steam, pawn, species, life_serial, state)
    skin_restore_runtime[tostring(steam)] = {
        pawn_address = object_address(pawn),
        species = tostring(species),
        life_serial = math.floor(tonumber(life_serial) or 1),
        revision = tonumber(state and state.revision) or 0,
        first_seen_at = os.time(),
        last_attempt_at = os.time(),
        applied = true
    }
end

local function maybe_restore_saved_skin(steam, pawn, prime_state)
    if not is_valid_object(pawn) then return end
    if prime_state == nil then return end

    local species = get_species_name(pawn)
    local life_serial = math.floor(tonumber(prime_state.life_serial) or 1)
    local saved = skin_states[skin_state_key(steam, life_serial)]
    if saved == nil then return end

    -- A current-life skin must never leak onto another species or life.
    if tostring(saved.species) ~= tostring(species) then
        log(string.format(
            "[Skin][RESTORE_SKIP] steam=%s life_serial=%d saved_species=%s live_species=%s reason=species-mismatch",
            tostring(steam),
            life_serial,
            tostring(saved.species),
            tostring(species)
        ))
        return
    end

    local steam_key = tostring(steam)
    local pawn_address = object_address(pawn)
    local revision = tonumber(saved.revision) or 0
    local now = os.time()
    local runtime = skin_restore_runtime[steam_key]

    local target_changed = runtime == nil
        or tonumber(runtime.pawn_address) ~= tonumber(pawn_address)
        or tostring(runtime.species) ~= tostring(species)
        or tonumber(runtime.life_serial) ~= life_serial
        or tonumber(runtime.revision) ~= revision

    if target_changed then
        runtime = {
            pawn_address = pawn_address,
            species = tostring(species),
            life_serial = life_serial,
            revision = revision,
            first_seen_at = now,
            last_attempt_at = 0,
            applied = false
        }
        skin_restore_runtime[steam_key] = runtime
    end

    if runtime.applied == true then return end
    if (now - (tonumber(runtime.first_seen_at) or now)) < SKIN_RESTORE_DELAY_SEC then return end
    if (now - (tonumber(runtime.last_attempt_at) or 0)) < SKIN_RESTORE_RETRY_SEC then return end

    runtime.last_attempt_at = now
    local ok, reason = apply_saved_skin_state(pawn, saved)
    if ok then
        runtime.applied = true
        log(string.format(
            "[Skin][RESTORE] steam=%s life_serial=%d species=%s revision=%d ok=true reason=%s pawn=0x%X",
            tostring(steam),
            life_serial,
            tostring(species),
            revision,
            tostring(reason),
            tonumber(pawn_address) or 0
        ))
    else
        log(string.format(
            "[Skin][RESTORE] steam=%s life_serial=%d species=%s revision=%d ok=false reason=%s pawn=0x%X retry_in=%ds",
            tostring(steam),
            life_serial,
            tostring(species),
            revision,
            tostring(reason),
            tonumber(pawn_address) or 0,
            SKIN_RESTORE_RETRY_SEC
        ))
    end
end

local function process_skin_test_command_requests()
    if #pending_skin_test_command_requests == 0 then return end

    local requests = pending_skin_test_command_requests
    pending_skin_test_command_requests = {}

    local gm = find_game_mode()
    if not is_valid_object(gm) then
        log("[Skin][CHAT] cannot process !skintest requests: no valid GameMode")
        return
    end

    for _, request in ipairs(requests) do
        local steam = tostring(request.steam or "")
        if steam ~= "" then
            local controller = safe_get(function() return gm:GetControllerBySteamId(steam) end, nil)
            local pawn = live_pawn_from_ctrl(controller)

            if not is_valid_object(pawn) then
                queue_notification(steam, "Skin test unavailable - no active dinosaur.")
                log(string.format("[Skin][APPLY] steam=%s ok=false reason=no-active-pawn", steam))
            elseif is_admin_spectator(controller, pawn) then
                queue_notification(steam, "Skin test unavailable while in admin spectator mode.")
                log(string.format("[Skin][APPLY] steam=%s ok=false reason=admin-spectator", steam))
            else
                local ok, reason = apply_skin_test_preset(pawn)
                local save_ok = false
                local save_reason = "not-attempted"

                if ok then
                    local species = get_species_name(pawn)
                    local prime_state = prime_states[tostring(steam)]
                    if prime_state == nil then
                        prime_state = select(1, get_or_reset_prime_state(steam, pawn))
                    end
                    local life_serial = math.floor(tonumber(prime_state and prime_state.life_serial) or 1)
                    local captured_ok, captured = capture_current_skin_state(steam, pawn, species, life_serial, "!skintest")
                    if captured_ok then
                        save_ok = true
                        save_reason = "captured-current-life"
                        remember_skin_applied(steam, pawn, species, life_serial, captured)
                        save_skin_states_to_disk("!skintest")
                        queue_notification(steam, "Skin test applied and saved!")
                    else
                        save_reason = tostring(captured)
                        queue_notification(steam, "Skin applied, but saving failed - check server console.")
                    end
                else
                    queue_notification(steam, "Skin test failed - check server console.")
                end

                log(string.format(
                    "[Skin][APPLY] steam=%s ok=%s reason=%s saved=%s save_reason=%s pawn=%s",
                    steam,
                    tostring(ok),
                    tostring(reason),
                    tostring(save_ok),
                    tostring(save_reason),
                    tostring(object_address(pawn))
                ))
            end
        end
    end
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

    -- The skin bridge uses flat JSON with string values. Lua patterns are not
    -- regular expressions, so avoid regex-only constructs such as alternation (|).
    -- These bridge values (ids, SteamIDs and hex colors) never contain embedded
    -- double quotes, making this simple parser appropriate and deterministic.
    local escaped_key = key:gsub("([^%w])", "%%%1")
    local pattern = '"' .. escaped_key .. '"%s*:%s*"([^"]*)"'
    local raw = line:match(pattern)
    if raw == nil then return nil end
    return json_unescape(raw)
end

local function srgb_channel_to_linear(value)
    local c = (tonumber(value) or 0) / 255.0
    if c <= 0.04045 then
        return c / 12.92
    end
    return ((c + 0.055) / 1.055) ^ 2.4
end

local function linear_channel_to_srgb_byte(value)
    local c = tonumber(value) or 0
    if c < 0 then c = 0 end
    if c > 1 then c = 1 end

    local srgb
    if c <= 0.0031308 then
        srgb = c * 12.92
    else
        srgb = (1.055 * (c ^ (1.0 / 2.4))) - 0.055
    end

    local byte = math.floor((srgb * 255.0) + 0.5)
    if byte < 0 then byte = 0 end
    if byte > 255 then byte = 255 end
    return byte
end

local function parse_hex_color(value)
    value = tostring(value or ""):gsub("^#", ""):upper()
    if #value ~= 6 and #value ~= 8 then return nil end
    if not value:match("^[0-9A-F]+$") then return nil end

    local r = tonumber(value:sub(1, 2), 16)
    local g = tonumber(value:sub(3, 4), 16)
    local b = tonumber(value:sub(5, 6), 16)
    if r == nil or g == nil or b == nil then return nil end

    -- EVRIMA does not reliably apply a completely zero-valued FLinearColor.
    -- Preserve the player's visual choice as effectively black, but send the
    -- smallest non-zero sRGB value so the game treats the color as valid.
    if r == 0 and g == 0 and b == 0 then
        r = 1
        g = 1
        b = 1
    end

    -- Website/API colors are normal sRGB hex values (#RRGGBB). Unreal's
    -- CustomizerData fields are FLinearColor values, so convert sRGB -> linear
    -- before writing. Without this, mid-channel colors such as orange are written
    -- too bright and can look yellow/washed out in-game.
    --
    -- Players never control opacity. Accept 8-digit input defensively so a manually
    -- crafted request cannot break parsing, but deliberately ignore its alpha byte.
    -- Every website-applied color is forced fully opaque (A=1.0 / FF).
    return {
        R = srgb_channel_to_linear(r),
        G = srgb_channel_to_linear(g),
        B = srgb_channel_to_linear(b),
        A = 1.0
    }
end

local function json_get_number(line, key)
    if type(line) ~= "string" or type(key) ~= "string" then return nil end
    local escaped_key = key:gsub("([^%w])", "%%%1")

    -- Accept either a normal JSON number or a quoted numeric string.
    local raw = line:match('"' .. escaped_key .. '"%s*:%s*([%+%-]?[%d%.]+)')
    if raw == nil then
        raw = line:match('"' .. escaped_key .. '"%s*:%s*"([%+%-]?[%d%.]+)"')
    end
    return tonumber(raw)
end

local function json_get_boolean(line, key)
    if type(line) ~= "string" or type(key) ~= "string" then return nil end
    local escaped_key = key:gsub("([^%w])", "%%%1")
    local raw = line:match('"' .. escaped_key .. '"%s*:%s*(true)')
    if raw == "true" then return true end
    raw = line:match('"' .. escaped_key .. '"%s*:%s*(false)')
    if raw == "false" then return false end
    return nil
end

local function json_has_key(line, key)
    if type(line) ~= "string" or type(key) ~= "string" then return false end
    local escaped_key = key:gsub("([^%w])", "%%%1")
    return line:match('"' .. escaped_key .. '"%s*:') ~= nil
end

function PRIME_RESTORE_BRIDGE.save_cursor()
    local tmp_path = PRIME_RESTORE_BRIDGE.cursor_path .. ".tmp"
    local file = io.open(tmp_path, "wb")
    if file == nil then return false end
    file:write(tostring(math.floor(tonumber(PRIME_RESTORE_BRIDGE.offset) or 0)))
    file:close()
    os.remove(PRIME_RESTORE_BRIDGE.cursor_path)
    return os.rename(tmp_path, PRIME_RESTORE_BRIDGE.cursor_path) == true
end

function PRIME_RESTORE_BRIDGE.load()
    if PRIME_RESTORE_BRIDGE.loaded then return end
    PRIME_RESTORE_BRIDGE.loaded = true
    local cursor = io.open(PRIME_RESTORE_BRIDGE.cursor_path, "rb")
    if cursor ~= nil then
        PRIME_RESTORE_BRIDGE.offset = math.max(0, math.floor(tonumber(cursor:read("*a")) or 0))
        cursor:close()
    end
    local commands = io.open(PRIME_RESTORE_BRIDGE.command_path, "ab")
    if commands ~= nil then commands:close() end
    log(string.format(
        "[PrimeRestoreBridge] ready command_path=%s cursor=%d",
        PRIME_RESTORE_BRIDGE.command_path,
        PRIME_RESTORE_BRIDGE.offset
    ))
end

function PRIME_RESTORE_BRIDGE.apply(line)
    local command_id = json_get_string(line, "id")
    local verb = json_get_string(line, "verb")
    local steam = json_get_string(line, "steam")
    local expected_species = json_get_string(line, "species")
    local expected_address = tonumber(json_get_string(line, "pawnAddress"))
    local eligible = json_get_boolean(line, "eligible")
    local capture_skin = json_get_boolean(line, "captureSkin") == true
    if command_id == nil or command_id == "" or verb ~= "prime.restore"
        or steam == nil or steam == "" or expected_species == nil
        or expected_address == nil or eligible == nil then
        log("[PrimeRestoreBridge][REJECT] reason=invalid-command")
        return
    end

    local conditions = {}
    for index = 1, 10 do
        local value = json_get_boolean(line, "cond" .. tostring(index))
        if value == nil then
            log(string.format(
                "[PrimeRestoreBridge][REJECT] id=%s steam=%s reason=missing-condition-%d",
                command_id, steam, index
            ))
            return
        end
        conditions[index] = value
    end

    local gm = find_game_mode()
    local controller = is_valid_object(gm)
        and safe_get(function() return gm:GetControllerBySteamId(steam) end, nil)
        or nil
    local pawn = live_pawn_from_ctrl(controller)
    if not is_valid_object(pawn) then
        log(string.format(
            "[PrimeRestoreBridge][REJECT] id=%s steam=%s reason=no-live-pawn",
            command_id, steam
        ))
        return
    end
    local actual_address = tonumber(object_address(pawn)) or 0
    local actual_species = get_species_name(pawn)
    if actual_address ~= expected_address then
        log(string.format(
            "[PrimeRestoreBridge][REJECT] id=%s steam=%s reason=pawn-changed expected=%s actual=%s",
            command_id, steam, tostring(expected_address), tostring(actual_address)
        ))
        return
    end
    if tostring(actual_species):lower() ~= tostring(expected_species):lower() then
        log(string.format(
            "[PrimeRestoreBridge][REJECT] id=%s steam=%s reason=species-changed expected=%s actual=%s",
            command_id, steam, tostring(expected_species), tostring(actual_species)
        ))
        return
    end

    local state, growth = get_or_reset_prime_state(steam, pawn)
    if state == nil then
        log(string.format(
            "[PrimeRestoreBridge][REJECT] id=%s steam=%s reason=state-unavailable",
            command_id, steam
        ))
        return
    end
    local restored_tasks = {}
    for index = 1, 10 do
        if conditions[index] == true then restored_tasks[index] = true end
    end
    state.completed_tasks = restored_tasks
    state.visited = state.visited or {}
    state.visited.migration = state.visited.migration or {}
    state.visited.patrol = state.visited.patrol or {}
    -- The garage snapshot stores authoritative Prime conditions, not the
    -- transient zone object keys tracked by miniEniac. When a completed zone
    -- condition is restored, seed only enough synthetic history for !primelist
    -- to display the matching completed progress. Real future zone keys remain
    -- independent and the displayed count is already capped at the threshold.
    if conditions[5] == true then
        for index = 1, MIGRATION_ZONES_REQUIRED do
            state.visited.migration[
                "garage-restored-migration-" .. tostring(index)
            ] = true
        end
    end
    if conditions[6] == true then
        for index = 1, PATROL_ZONES_REQUIRED do
            state.visited.patrol[
                "garage-restored-patrol-" .. tostring(index)
            ] = true
        end
    end
    state.last_growth = tonumber(growth) or state.last_growth
    state.last_pawn_address = actual_address
    state.saw_dead = false
    if (tonumber(growth) or 0) >= PRIME_GROWTH_CUTOFF then
        state.frozen = true
    end
    if conditions[10] == true then state.task10_blocked_by_nesting = false end

    -- ServerSetPrimeEligible updates EVRIMA's separate cached eligibility.
    -- Write the complete structure afterwards because the native call may
    -- rebuild it. No growth call is used anywhere in this handoff.
    local server_ok, server_error = pcall(function()
        pawn:ServerSetPrimeEligible(eligible == true)
    end)
    if not server_ok then
        log(string.format(
            "[PrimeRestoreBridge][REJECT] id=%s steam=%s reason=server-eligibility:%s",
            command_id, steam, tostring(server_error)
        ))
        return
    end
    local data = get_prime_data(pawn)
    if data == nil then
        log(string.format(
            "[PrimeRestoreBridge][REJECT] id=%s steam=%s reason=no-prime-data",
            command_id, steam
        ))
        return
    end
    local struct_ok, struct_error = pcall(function()
        for index = 1, 10 do
            data["bPrimeCondition" .. tostring(index)] = conditions[index]
        end
        data.bIsEligiblePrime = eligible == true
        pawn:SetEligiblePrimeElderData(data)
        pawn:ForceNetUpdate()
    end)
    if not struct_ok then
        log(string.format(
            "[PrimeRestoreBridge][REJECT] id=%s steam=%s reason=struct-write:%s",
            command_id, steam, tostring(struct_error)
        ))
        return
    end

    -- DinoStorage queues this only after its final skin write. Capture the
    -- exact live CustomizerData into miniEniac's current-life persistence so
    -- it survives the first hard reconnect after unparking.
    if capture_skin then
        local life_serial = math.floor(tonumber(state.life_serial) or 1)
        local captured_ok, captured = capture_current_skin_state(
            steam,
            pawn,
            actual_species,
            life_serial,
            "garage-restore:" .. command_id
        )
        if not captured_ok then
            log(string.format(
                "[PrimeRestoreBridge][REJECT] id=%s steam=%s reason=skin-capture:%s",
                command_id, steam, tostring(captured)
            ))
            return
        end
        remember_skin_applied(
            steam,
            pawn,
            actual_species,
            life_serial,
            captured
        )
        local saved_ok, saved_reason = save_skin_states_to_disk("garage-restore")
        if not saved_ok then
            log(string.format(
                "[PrimeRestoreBridge][REJECT] id=%s steam=%s reason=skin-save:%s",
                command_id, steam, tostring(saved_reason)
            ))
            return
        end
        log(string.format(
            "[Skin][GARAGE_HANDOFF] id=%s steam=%s species=%s life_serial=%d pattern=%s ok=true",
            command_id, steam, actual_species, life_serial,
            tostring(captured.pattern_index)
        ))
    end

    mark_prime_state_dirty("garage-restore:" .. command_id)
    save_prime_states_to_disk("garage-restore")
    log(string.format(
        "[PrimeRestoreBridge][APPLY] id=%s steam=%s species=%s tasks=%d/10 eligible=%s growth=%.6f ok=true",
        command_id, steam, actual_species, completed_task_count(state),
        tostring(eligible == true), tonumber(growth) or 0
    ))
end

function PRIME_RESTORE_BRIDGE.process()
    -- Garage restores may be requested during miniEniac's 60-second zone boot
    -- delay. Prime persistence is independent of the zone catalog, so load it
    -- here and allow the handoff as soon as a live dinosaur exists.
    load_prime_states_from_disk()
    PRIME_RESTORE_BRIDGE.load()
    local file = io.open(PRIME_RESTORE_BRIDGE.command_path, "rb")
    if file == nil then return end
    local size = file:seek("end") or 0
    if size < PRIME_RESTORE_BRIDGE.offset then PRIME_RESTORE_BRIDGE.offset = 0 end
    file:seek("set", PRIME_RESTORE_BRIDGE.offset)
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
        local ok, error_message = pcall(function()
            PRIME_RESTORE_BRIDGE.apply(line)
        end)
        if not ok then
            log("[PrimeRestoreBridge][ERROR] " .. tostring(error_message))
        end
    end
    PRIME_RESTORE_BRIDGE.offset = PRIME_RESTORE_BRIDGE.offset + last_newline
    PRIME_RESTORE_BRIDGE.save_cursor()
end

local function clamp_byte(value)
    value = tonumber(value) or 0
    if value < 0 then value = 0 end
    if value > 1 then value = 1 end
    return math.floor((value * 255.0) + 0.5)
end

local function color_to_hex(color)
    if color == nil then return "#000000FF" end
    return string.format(
        "#%02X%02X%02X%02X",
        linear_channel_to_srgb_byte(color.R),
        linear_channel_to_srgb_byte(color.G),
        linear_channel_to_srgb_byte(color.B),
        clamp_byte(color.A == nil and 1.0 or color.A)
    )
end

local function read_skin_snapshot(pawn)
    if not is_valid_object(pawn) then return false, "no-valid-pawn" end
    local cd = safe_get(function() return pawn.CustomizerData end, nil)
    if cd == nil then return false, "CustomizerData unavailable" end

    local colors = {}
    for _, spec in ipairs(SKIN_BRIDGE_COLOR_KEYS) do
        local color = read_customizer_color(cd, spec.field)
        if color == nil then
            return false, "read-failed:" .. tostring(spec.field)
        end
        colors[spec.json] = color_to_hex(color)
    end

    return true, {
        colors = colors,
        pattern_index = tonumber(safe_get(function() return cd.PatternIndex end, nil)),
        skin_variation = tonumber(safe_get(function() return cd.SkinVariation end, nil)),
        theme_index = tonumber(safe_get(function() return cd.ThemeIndex end, nil)),
        is_female = safe_get(function() return cd.bIsFemale end, false) == true
    }
end

local function save_skin_bridge_cursor()
    local tmp_path = SKIN_BRIDGE_CURSOR_PATH .. ".tmp"
    local file = io.open(tmp_path, "wb")
    if file == nil then
        log(string.format("[SkinBridge][CURSOR] save failed path=%s", SKIN_BRIDGE_CURSOR_PATH))
        return false
    end

    file:write(tostring(math.floor(tonumber(skin_bridge_offset) or 0)))
    file:close()
    os.remove(SKIN_BRIDGE_CURSOR_PATH)
    local renamed, rename_err = os.rename(tmp_path, SKIN_BRIDGE_CURSOR_PATH)
    if not renamed then
        log(string.format(
            "[SkinBridge][CURSOR] rename failed path=%s error=%s",
            SKIN_BRIDGE_CURSOR_PATH,
            tostring(rename_err)
        ))
        return false
    end
    return true
end

local function load_skin_bridge_cursor()
    if skin_bridge_loaded then return end
    skin_bridge_loaded = true

    local file = io.open(SKIN_BRIDGE_CURSOR_PATH, "rb")
    if file ~= nil then
        skin_bridge_offset = math.max(0, math.floor(tonumber(file:read("*a")) or 0))
        file:close()
    else
        skin_bridge_offset = 0
    end

    -- Touch the files so the future API can immediately append/read them.
    local command_file = io.open(SKIN_BRIDGE_COMMAND_PATH, "ab")
    if command_file ~= nil then command_file:close() end
    local result_file = io.open(SKIN_BRIDGE_RESULT_PATH, "ab")
    if result_file ~= nil then result_file:close() end

    log(string.format(
        "[SkinBridge] ready mod_root=%s command_path=%s result_path=%s cursor=%d format=flat-ndjson colors=hex alpha=forced-FF inspect=true patterns_probe=true skin_variation=optional pattern_index=optional-validated-datatable asset_sex=is_female-optional",
        SKIN_BRIDGE_MOD_ROOT,
        SKIN_BRIDGE_COMMAND_PATH,
        SKIN_BRIDGE_RESULT_PATH,
        skin_bridge_offset
    ))
end

local function append_skin_bridge_result(command_id, ok, steam, species, life_serial, reason)
    local file = io.open(SKIN_BRIDGE_RESULT_PATH, "ab")
    if file == nil then
        log(string.format(
            "[SkinBridge][RESULT] write failed id=%s path=%s",
            tostring(command_id),
            SKIN_BRIDGE_RESULT_PATH
        ))
        return false
    end

    local line = string.format(
        '{"id":"%s","verb":"skin","ok":%s,"steam":"%s","species":"%s","life_serial":%d,"reason":"%s","ts":%d}\n',
        json_escape(command_id),
        ok and "true" or "false",
        json_escape(steam),
        json_escape(species or ""),
        math.floor(tonumber(life_serial) or 0),
        json_escape(reason or ""),
        os.time()
    )
    file:write(line)
    file:close()
    return true
end

local function append_skin_bridge_inspect_result(command_id, ok, steam, species, life_serial, reason, snapshot)
    local file = io.open(SKIN_BRIDGE_RESULT_PATH, "ab")
    if file == nil then
        log(string.format(
            "[SkinBridge][RESULT] inspect write failed id=%s path=%s",
            tostring(command_id),
            SKIN_BRIDGE_RESULT_PATH
        ))
        return false
    end

    snapshot = snapshot or { colors = {} }
    local colors = snapshot.colors or {}
    local function number_or_null(value)
        local n = tonumber(value)
        if n == nil then return "null" end
        return tostring(n)
    end

    local line = string.format(
        '{"id":"%s","verb":"skin.inspect","ok":%s,"steam":"%s","species":"%s","life_serial":%d,"reason":"%s","pattern_index":%s,"skin_variation":%s,"theme_index":%s,"is_female":%s,"body":"%s","markings":"%s","flank":"%s","underbelly":"%s","detail1":"%s","eyes":"%s","male_display":"%s","teeth":"%s","mouth":"%s","claws":"%s","ts":%d}\n',
        json_escape(command_id),
        ok and "true" or "false",
        json_escape(steam),
        json_escape(species or ""),
        math.floor(tonumber(life_serial) or 0),
        json_escape(reason or ""),
        number_or_null(snapshot.pattern_index),
        number_or_null(snapshot.skin_variation),
        number_or_null(snapshot.theme_index),
        snapshot.is_female == true and "true" or "false",
        json_escape(colors.body or ""),
        json_escape(colors.markings or ""),
        json_escape(colors.flank or ""),
        json_escape(colors.underbelly or ""),
        json_escape(colors.detail1 or ""),
        json_escape(colors.eyes or ""),
        json_escape(colors.male_display or ""),
        json_escape(colors.teeth or ""),
        json_escape(colors.mouth or ""),
        json_escape(colors.claws or ""),
        os.time()
    )
    file:write(line)
    file:close()
    return true
end

local function array_value_to_string(value)
    if value == nil then return "" end

    -- UE4SS reflected calls can return RemoteUnrealParam/LocalUnrealParam wrappers.
    -- Unwrap those first when possible.
    local unwrapped = safe_get(function() return value:get() end, nil)
    if unwrapped ~= nil then value = unwrapped end

    -- IMPORTANT: UE4SS FString tostring() only prints a diagnostic wrapper such as
    --   FString: 00000207BC3C4598
    -- while FString:ToString() returns the actual Lua string. Try ToString first.
    local actual = safe_get(function() return value:ToString() end, nil)
    if type(actual) == "string" and actual ~= "" then
        return actual
    end

    -- FName-like wrappers may stringify directly to their useful value.
    local converted = safe_string(value)
    if converted ~= "" then return converted end

    local ok, direct = pcall(function() return tostring(value) end)
    if ok and direct ~= nil then return tostring(direct) end
    return ""
end

local function collect_string_array(array_wrapper)
    local values = {}
    if array_wrapper == nil then return values, false, "nil-array" end

    local lua_type = type(array_wrapper)

    -- Some reflected UFunctions return a normal Lua table instead of a UE4SS TArray wrapper.
    -- Prefer ipairs to preserve numeric order, then fall back to pairs for sparse tables.
    if lua_type == "table" then
        local seen = {}
        for index, value in ipairs(array_wrapper) do
            seen[index] = true
            values[#values + 1] = array_value_to_string(value)
        end
        for key, value in pairs(array_wrapper) do
            if not seen[key] then
                values[#values + 1] = array_value_to_string(value)
            end
        end
        return values, true, "lua-table"
    end

    -- Preferred UE4SS TArray path. Accessing .ForEach itself is guarded because not every
    -- userdata returned from a reflected call is actually a TArray wrapper.
    local has_for_each = safe_get(function()
        return array_wrapper.ForEach ~= nil
    end, false)

    if has_for_each then
        local ok, err = pcall(function()
            array_wrapper:ForEach(function(first, second)
                local candidate = second
                if candidate == nil then candidate = first end
                local text_value = array_value_to_string(candidate)
                if text_value == "" and first ~= nil and first ~= candidate then
                    text_value = array_value_to_string(first)
                end
                values[#values + 1] = text_value
            end)
        end)
        if ok then
            return values, true, "ue4ss-foreach"
        end
    end

    -- Fallback for indexable UE4SS arrays/wrappers. TArray indexing is zero-based.
    local count = safe_get(function()
        if array_wrapper.GetArrayNum ~= nil then
            return tonumber(array_wrapper:GetArrayNum())
        end
        return tonumber(#array_wrapper)
    end, nil)

    if count ~= nil and count >= 0 then
        local ok, err = pcall(function()
            for index = 0, count - 1 do
                local value = array_wrapper[index]
                values[#values + 1] = array_value_to_string(value)
            end
        end)
        if ok then
            return values, true, "indexed-array-count=" .. tostring(count)
        end
        return values, false, "indexed-array-failed:" .. tostring(err)
    end

    return values, false, "unsupported-array-wrapper-lua-type=" .. tostring(lua_type)
end

local function get_data_table_function_library()
    if StaticFindObject == nil then return nil, "StaticFindObject unavailable" end

    local cdo = safe_get(function()
        return StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
    end, nil)
    if is_valid_object(cdo) then return cdo, "default-object" end

    local class_obj = safe_get(function()
        return StaticFindObject("/Script/Engine.DataTableFunctionLibrary")
    end, nil)
    if is_valid_object(class_obj) then
        local class_cdo = safe_get(function() return class_obj:GetCDO() end, nil)
        if is_valid_object(class_cdo) then return class_cdo, "class-cdo" end
    end

    return nil, "DataTableFunctionLibrary unavailable"
end

local function find_or_load_skin_data_table()
    if StaticFindObject == nil then return nil, "StaticFindObject unavailable", false end

    local table_obj = safe_get(function()
        return StaticFindObject(SKIN_DATA_TABLE_OBJECT_PATH)
    end, nil)
    if is_valid_object(table_obj) then
        return table_obj, "already-loaded", false
    end

    -- This function runs from LoopInGameThreadWithDelay, so LoadAsset is invoked on the
    -- game thread as required by UE4SS. The call is read-only and only requests the asset.
    if LoadAsset ~= nil then
        local load_ok, load_err = pcall(function()
            LoadAsset(SKIN_DATA_TABLE_ASSET_PATH)
        end)
        if not load_ok then
            log(string.format("[SkinPatterns][LOAD] LoadAsset failed error=%s", tostring(load_err)))
        end
    end

    table_obj = safe_get(function()
        return StaticFindObject(SKIN_DATA_TABLE_OBJECT_PATH)
    end, nil)
    if is_valid_object(table_obj) then
        return table_obj, "loaded-on-demand", true
    end

    return nil, "DT_SkinDataList not found after load attempt", true
end

local function extract_species_and_pattern_count(serialized)
    if type(serialized) ~= "string" or serialized == "" then
        return nil, nil, "empty-export"
    end

    -- Each SpeciePatterns export contains texture paths under:
    --   /Game/TheIsle/Characters/Dinosaurs/<Species>/...
    -- and top-level entries named ("Pattern1", ...), ("Pattern2", ...), etc.
    local species = serialized:match("/Game/TheIsle/Characters/Dinosaurs/([^/]+)/")
    if species == nil or species == "" then
        return nil, nil, "species-not-found"
    end

    local seen = {}
    local highest = 0
    for raw_index in serialized:gmatch('%("Pattern(%d+)"') do
        local one_based = tonumber(raw_index)
        if one_based ~= nil and one_based >= 1 then
            one_based = math.floor(one_based)
            seen[one_based] = true
            if one_based > highest then highest = one_based end
        end
    end

    if highest < 1 then
        return species, nil, "no-pattern-keys"
    end

    -- Require a contiguous Pattern1..PatternN sequence. This prevents us from treating
    -- a malformed/sparse export as a safe numeric range.
    for expected = 1, highest do
        if not seen[expected] then
            return species, nil, "non-contiguous-pattern-keys-missing=" .. tostring(expected)
        end
    end

    return species, highest, "ok"
end

local function build_skin_pattern_counts_from_exports(exports)
    local counts = {}
    local failures = {}

    for index, serialized in ipairs(exports or {}) do
        local species, count, reason = extract_species_and_pattern_count(serialized)
        if species ~= nil and count ~= nil then
            counts[tostring(species)] = math.floor(count)
        else
            failures[#failures + 1] = string.format(
                "value=%d species=%s reason=%s",
                index,
                tostring(species or ""),
                tostring(reason or "unknown")
            )
        end
    end

    local total = 0
    for _species, _count in pairs(counts) do total = total + 1 end

    if total == 0 then
        return counts, false, "no-pattern-counts;" .. table.concat(failures, " | ")
    end

    if #failures > 0 then
        return counts, true, "partial-success failures=" .. table.concat(failures, " | ")
    end

    return counts, true, "ok"
end

local function refresh_skin_pattern_counts()
    local table_obj, table_reason = find_or_load_skin_data_table()
    if not is_valid_object(table_obj) then
        skin_pattern_counts_ready = false
        skin_pattern_counts_source = "data-table-unavailable:" .. tostring(table_reason)
        return false, skin_pattern_counts_source
    end

    local library, library_source = get_data_table_function_library()
    if not is_valid_object(library) then
        skin_pattern_counts_ready = false
        skin_pattern_counts_source = "function-library-unavailable:" .. tostring(library_source)
        return false, skin_pattern_counts_source
    end

    local specie_patterns_array = safe_get(function()
        return library:GetDataTableColumnAsString(table_obj, FName("SpeciePatterns"))
    end, nil)

    local exports, exports_ok, exports_reason = collect_string_array(specie_patterns_array)
    if not exports_ok then
        skin_pattern_counts_ready = false
        skin_pattern_counts_source = "column-export-failed:" .. tostring(exports_reason)
        return false, skin_pattern_counts_source
    end

    local counts, counts_ok, counts_reason = build_skin_pattern_counts_from_exports(exports)
    if not counts_ok then
        skin_pattern_counts_ready = false
        skin_pattern_counts_source = "parse-failed:" .. tostring(counts_reason)
        return false, skin_pattern_counts_source
    end

    skin_pattern_counts = counts
    skin_pattern_counts_ready = true
    skin_pattern_counts_source = string.format(
        "DT_SkinDataList exports=%d library=%s parse=%s",
        #exports,
        tostring(library_source),
        tostring(counts_reason)
    )

    local species_total = 0
    for _species, _count in pairs(skin_pattern_counts) do species_total = species_total + 1 end
    log(string.format(
        "[SkinPatterns][MAP] ready=true species=%d exports=%d source=%s",
        species_total,
        #exports,
        skin_pattern_counts_source
    ))

    return true, skin_pattern_counts_source
end

local function get_skin_pattern_count(species)
    if not skin_pattern_counts_ready then
        local refreshed, reason = refresh_skin_pattern_counts()
        if not refreshed then return nil, reason end
    end

    local requested = tostring(species or "")
    local direct = skin_pattern_counts[requested]
    if direct ~= nil then return tonumber(direct), "exact" end

    local lowered = requested:lower()
    for known_species, count in pairs(skin_pattern_counts) do
        if tostring(known_species):lower() == lowered then
            return tonumber(count), "case-insensitive"
        end
    end

    return nil, "unmapped-species:" .. requested
end

validate_skin_pattern_index = function(species, value)
    local numeric = tonumber(value)
    if numeric == nil then
        return false, nil, "pattern-index-not-numeric"
    end

    if numeric ~= math.floor(numeric) then
        return false, nil, "pattern-index-must-be-integer"
    end

    local pattern_index = math.floor(numeric)
    local pattern_count, count_reason = get_skin_pattern_count(species)
    if pattern_count == nil then
        return false, nil, "pattern-range-unavailable:" .. tostring(count_reason)
    end

    if pattern_index < 0 or pattern_index >= pattern_count then
        return false, pattern_count, string.format(
            "pattern-index-out-of-range:%d valid=0-%d species=%s",
            pattern_index,
            math.max(0, pattern_count - 1),
            tostring(species or "")
        )
    end

    return true, pattern_count, pattern_index
end

local function write_skin_pattern_probe_file(probe)
    local file = io.open(SKIN_PATTERN_PROBE_PATH, "wb")
    if file == nil then return false, "open-failed" end

    local function line(key, value)
        file:write(tostring(key), "=", tostring(value or ""), "\n")
    end

    file:write("# miniEniac skin pattern DataTable probe v2\n")
    line("timestamp", os.time())
    line("data_table_object_path", SKIN_DATA_TABLE_OBJECT_PATH)
    line("data_table_found", probe.data_table_found == true)
    line("table_source", probe.table_source)
    line("load_attempted", probe.load_attempted == true)
    line("table_full_name", probe.table_full_name)
    line("row_struct", probe.row_struct)
    line("function_library_source", probe.function_library_source)
    line("row_names_ok", probe.row_names_ok == true)
    line("row_names_reason", probe.row_names_reason)
    line("row_names_wrapper_type", probe.row_names_wrapper_type)
    line("row_count", #(probe.row_names or {}))
    line("column_names_ok", probe.column_names_ok == true)
    line("column_names_reason", probe.column_names_reason)
    line("column_names_wrapper_type", probe.column_names_wrapper_type)
    line("column_count", #(probe.column_names or {}))
    line("specie_patterns_wrapper_type", probe.specie_patterns_wrapper_type)
    line("specie_patterns_export_ok", probe.specie_patterns_export_ok == true)
    line("specie_patterns_export_reason", probe.specie_patterns_export_reason)
    line("specie_patterns_export_count", #(probe.specie_patterns_exports or {}))
    line("pattern_counts_ok", probe.pattern_counts_ok == true)
    line("pattern_counts_reason", probe.pattern_counts_reason)
    local pattern_species_count = 0
    for _species, _count in pairs(probe.pattern_counts or {}) do pattern_species_count = pattern_species_count + 1 end
    line("pattern_species_count", pattern_species_count)

    file:write("\n[ROW_NAMES]\n")
    for index, value in ipairs(probe.row_names or {}) do
        file:write(string.format("%d\t%s\n", index, tostring(value or "")))
    end

    file:write("\n[COLUMN_NAMES]\n")
    for index, value in ipairs(probe.column_names or {}) do
        file:write(string.format("%d\t%s\n", index, tostring(value or "")))
    end

    file:write("\n[PATTERN_COUNTS]\n")
    local species_names = {}
    for species, _count in pairs(probe.pattern_counts or {}) do
        species_names[#species_names + 1] = tostring(species)
    end
    table.sort(species_names)
    for _, species in ipairs(species_names) do
        local count = math.floor(tonumber(probe.pattern_counts[species]) or 0)
        file:write(string.format(
            "%s\tcount=%d\tvalid_pattern_index=0-%d\n",
            species,
            count,
            math.max(0, count - 1)
        ))
    end

    file:write("\n[SPECIE_PATTERNS_EXPORT]\n")
    for index, value in ipairs(probe.specie_patterns_exports or {}) do
        file:write(string.format("--- VALUE %d | length=%d ---\n", index, #tostring(value or "")))
        file:write(tostring(value or ""), "\n")
    end

    file:close()
    return true, "ok"
end

local function run_skin_pattern_probe()
    local probe = {
        data_table_found = false,
        table_source = "",
        load_attempted = false,
        table_full_name = "",
        row_struct = "",
        function_library_source = "",
        row_names = {},
        row_names_ok = false,
        row_names_reason = "not-attempted",
        column_names = {},
        column_names_ok = false,
        column_names_reason = "not-attempted",
        row_names_wrapper_type = "",
        column_names_wrapper_type = "",
        specie_patterns_wrapper_type = "",
        specie_patterns_exports = {},
        specie_patterns_export_ok = false,
        specie_patterns_export_reason = "not-attempted",
        pattern_counts = {},
        pattern_counts_ok = false,
        pattern_counts_reason = "not-attempted"
    }

    local table_obj, table_reason, load_attempted = find_or_load_skin_data_table()
    probe.table_source = tostring(table_reason or "")
    probe.load_attempted = load_attempted == true
    if not is_valid_object(table_obj) then
        local write_ok, write_reason = write_skin_pattern_probe_file(probe)
        return false, "data-table-unavailable:" .. tostring(table_reason) .. ";probe-write=" .. tostring(write_ok) .. ":" .. tostring(write_reason), probe
    end

    probe.data_table_found = true
    probe.table_full_name = safe_get(function() return table_obj:GetFullName() end, "") or ""
    local row_struct = safe_get(function() return table_obj.RowStruct end, nil)
    if is_valid_object(row_struct) then
        probe.row_struct = safe_get(function() return row_struct:GetFullName() end, "") or ""
    end

    local library, library_source = get_data_table_function_library()
    probe.function_library_source = tostring(library_source or "")
    if not is_valid_object(library) then
        local write_ok, write_reason = write_skin_pattern_probe_file(probe)
        return false, "datatable-function-library-unavailable;probe-write=" .. tostring(write_ok) .. ":" .. tostring(write_reason), probe
    end

    local row_names_array = safe_get(function()
        return library:GetDataTableRowNames(table_obj)
    end, nil)
    probe.row_names_wrapper_type = type(row_names_array)
    probe.row_names, probe.row_names_ok, probe.row_names_reason = collect_string_array(row_names_array)

    local column_names_array = safe_get(function()
        return library:GetDataTableColumnNames(table_obj)
    end, nil)
    probe.column_names_wrapper_type = type(column_names_array)
    probe.column_names, probe.column_names_ok, probe.column_names_reason = collect_string_array(column_names_array)

    local specie_patterns_array = safe_get(function()
        return library:GetDataTableColumnAsString(table_obj, FName("SpeciePatterns"))
    end, nil)
    probe.specie_patterns_wrapper_type = type(specie_patterns_array)
    probe.specie_patterns_exports, probe.specie_patterns_export_ok, probe.specie_patterns_export_reason = collect_string_array(specie_patterns_array)
    if probe.specie_patterns_export_ok then
        probe.pattern_counts, probe.pattern_counts_ok, probe.pattern_counts_reason =
            build_skin_pattern_counts_from_exports(probe.specie_patterns_exports)

        if probe.pattern_counts_ok then
            skin_pattern_counts = probe.pattern_counts
            skin_pattern_counts_ready = true
            skin_pattern_counts_source = string.format(
                "skin.patterns.inspect exports=%d parse=%s",
                #probe.specie_patterns_exports,
                tostring(probe.pattern_counts_reason)
            )
        end
    else
        probe.pattern_counts_reason = "specie-pattern-export-failed:" .. tostring(probe.specie_patterns_export_reason)
    end

    local write_ok, write_reason = write_skin_pattern_probe_file(probe)
    if not write_ok then
        return false, "probe-file-write-failed:" .. tostring(write_reason), probe
    end

    return true, "probe-complete", probe
end

local function append_skin_pattern_probe_result(command_id, ok, reason, probe)
    local file = io.open(SKIN_BRIDGE_RESULT_PATH, "ab")
    if file == nil then
        log(string.format(
            "[SkinBridge][RESULT] pattern probe write failed id=%s path=%s",
            tostring(command_id),
            SKIN_BRIDGE_RESULT_PATH
        ))
        return false
    end

    probe = probe or {}
    local pattern_species_count = 0
    for _species, _count in pairs(probe.pattern_counts or {}) do pattern_species_count = pattern_species_count + 1 end

    local line = string.format(
        '{"id":"%s","verb":"skin.patterns.inspect","ok":%s,"reason":"%s","data_table_found":%s,"table_source":"%s","row_count":%d,"column_count":%d,"specie_patterns_export_count":%d,"pattern_species_count":%d,"probe_path":"%s","ts":%d}\n',
        json_escape(command_id),
        ok and "true" or "false",
        json_escape(reason or ""),
        probe.data_table_found == true and "true" or "false",
        json_escape(probe.table_source or ""),
        #(probe.row_names or {}),
        #(probe.column_names or {}),
        #(probe.specie_patterns_exports or {}),
        pattern_species_count,
        json_escape(SKIN_PATTERN_PROBE_PATH),
        os.time()
    )
    file:write(line)
    file:close()
    return true
end

local function reject_skin_bridge_command(command_id, steam, reason)
    append_skin_bridge_result(command_id, false, steam or "", "", 0, reason)
    log(string.format(
        "[SkinBridge][APPLY] id=%s steam=%s ok=false reason=%s",
        tostring(command_id),
        tostring(steam or ""),
        tostring(reason)
    ))
end

local function process_skin_bridge_command(line)
    local command_id = json_get_string(line, "id") or ""
    local verb = (json_get_string(line, "verb") or ""):lower()
    local steam = json_get_string(line, "steam") or ""

    if command_id == "" then
        reject_skin_bridge_command("missing-id", steam, "missing-id")
        return
    end
    if verb == "skin.patterns.inspect" then
        local probe_ok, probe_reason, probe = run_skin_pattern_probe()
        append_skin_pattern_probe_result(command_id, probe_ok, probe_reason, probe)
        log(string.format(
            "[SkinPatterns][PROBE] id=%s ok=%s reason=%s data_table_found=%s rows=%d columns=%d specie_pattern_exports=%d pattern_species=%d path=%s",
            command_id,
            tostring(probe_ok),
            tostring(probe_reason),
            tostring(probe and probe.data_table_found == true),
            #(probe and probe.row_names or {}),
            #(probe and probe.column_names or {}),
            #(probe and probe.specie_patterns_exports or {}),
            (function()
                local total = 0
                for _species, _count in pairs(probe and probe.pattern_counts or {}) do total = total + 1 end
                return total
            end)(),
            SKIN_PATTERN_PROBE_PATH
        ))
        return
    end
    if verb ~= "skin" and verb ~= "skin.inspect" then
        reject_skin_bridge_command(command_id, steam, "unsupported-verb")
        return
    end
    if not steam:match("^%d+$") or #steam < 15 or #steam > 20 then
        reject_skin_bridge_command(command_id, steam, "invalid-steam-id")
        return
    end

    local gm = find_game_mode()
    if not is_valid_object(gm) then
        reject_skin_bridge_command(command_id, steam, "no-gameMode")
        return
    end

    local controller = safe_get(function() return gm:GetControllerBySteamId(steam) end, nil)
    local pawn = live_pawn_from_ctrl(controller)
    if not is_valid_object(pawn) then
        reject_skin_bridge_command(command_id, steam, "player-offline-or-no-active-dinosaur")
        return
    end
    if is_admin_spectator(controller, pawn) then
        reject_skin_bridge_command(command_id, steam, "admin-spectator")
        return
    end

    local species = get_species_name(pawn)
    local prime_state = prime_states[tostring(steam)]
    if prime_state == nil then
        prime_state = select(1, get_or_reset_prime_state(steam, pawn))
    end
    local life_serial = math.floor(tonumber(prime_state and prime_state.life_serial) or 1)

    if verb == "skin.inspect" then
        local inspect_ok, snapshot_or_reason = read_skin_snapshot(pawn)
        if not inspect_ok then
            append_skin_bridge_inspect_result(
                command_id,
                false,
                steam,
                species,
                life_serial,
                tostring(snapshot_or_reason),
                nil
            )
            log(string.format(
                "[SkinBridge][INSPECT] id=%s steam=%s species=%s life_serial=%d ok=false reason=%s",
                command_id,
                steam,
                tostring(species),
                life_serial,
                tostring(snapshot_or_reason)
            ))
            return
        end

        append_skin_bridge_inspect_result(
            command_id,
            true,
            steam,
            species,
            life_serial,
            "snapshot-read",
            snapshot_or_reason
        )
        log(string.format(
            "[SkinBridge][INSPECT] id=%s steam=%s species=%s life_serial=%d ok=true pattern_index=%s skin_variation=%s theme_index=%s",
            command_id,
            steam,
            tostring(species),
            life_serial,
            tostring(snapshot_or_reason.pattern_index),
            tostring(snapshot_or_reason.skin_variation),
            tostring(snapshot_or_reason.theme_index)
        ))
        return
    end

    local colors = {}
    for _, spec in ipairs(SKIN_BRIDGE_COLOR_KEYS) do
        local raw = json_get_string(line, spec.json)
        local color = parse_hex_color(raw)
        if color == nil then
            reject_skin_bridge_command(command_id, steam, "invalid-or-missing-color:" .. tostring(spec.json))
            return
        end
        colors[spec.field] = color
    end

    -- SkinVariation is optional and safe to floor to an integer.
    local requested_skin_variation = json_get_number(line, "skin_variation")

    -- Asset sex is optional for backward compatibility. When supplied it must be a
    -- real JSON boolean so strings such as "female" cannot be misinterpreted.
    local requested_is_female = nil
    if json_has_key(line, "is_female") then
        requested_is_female = json_get_boolean(line, "is_female")
        if requested_is_female == nil then
            reject_skin_bridge_command(command_id, steam, "invalid-is-female-format")
            return
        end
    end

    -- PatternIndex is optional, but unlike SkinVariation it is only accepted when:
    --   1. the value is numeric,
    --   2. it is already an integer (no rounding/clamping),
    --   3. it falls inside this species' authoritative DT_SkinDataList range.
    local requested_pattern_index = nil
    if json_has_key(line, "pattern_index") then
        requested_pattern_index = json_get_number(line, "pattern_index")
        if requested_pattern_index == nil then
            reject_skin_bridge_command(command_id, steam, "invalid-pattern-index-format")
            return
        end

        local pattern_ok, pattern_count, normalized_or_reason = validate_skin_pattern_index(
            species,
            requested_pattern_index
        )
        if not pattern_ok then
            reject_skin_bridge_command(command_id, steam, tostring(normalized_or_reason))
            return
        end
        requested_pattern_index = normalized_or_reason
    end

    local apply_payload = {
        species = species,
        colors = colors,
        pattern_index = requested_pattern_index,
        skin_variation = requested_skin_variation,
        is_female = requested_is_female
    }

    local ok, reason = apply_saved_skin_state(pawn, apply_payload)
    if not ok then
        append_skin_bridge_result(command_id, false, steam, species, life_serial, reason)
        log(string.format(
            "[SkinBridge][APPLY] id=%s steam=%s species=%s life_serial=%d ok=false reason=%s",
            command_id, steam, tostring(species), life_serial, tostring(reason)
        ))
        return
    end

    -- Pattern material changes may settle after ForceNetUpdate. Verify a fresh
    -- pawn/CustomizerData read before replacing the durable current-life skin.
    -- Until this succeeds, the previous saved revision remains untouched.
    local expected_pawn_address = object_address(pawn)
    local previous_saved = skin_states[skin_state_key(steam, life_serial)]
    local verification_fired = false
    local verification_handle
    verification_handle = LoopInGameThreadWithDelay(250, function()
        if verification_fired then return end
        verification_fired = true
        if verification_handle ~= nil and CancelDelayedAction ~= nil then
            pcall(function() CancelDelayedAction(verification_handle) end)
        end

        local fresh_gm = find_game_mode()
        local fresh_controller = is_valid_object(fresh_gm)
            and safe_get(function() return fresh_gm:GetControllerBySteamId(steam) end, nil)
            or nil
        local fresh_pawn = live_pawn_from_ctrl(fresh_controller)
        local verify_reason = nil
        if not is_valid_object(fresh_pawn)
            or object_address(fresh_pawn) ~= expected_pawn_address then
            verify_reason = "skin-verify-pawn-changed"
        end

        local snapshot = nil
        if verify_reason == nil then
            local read_ok, snapshot_or_reason = read_skin_snapshot(fresh_pawn)
            if not read_ok then
                verify_reason = "skin-verify-read-failed:" .. tostring(snapshot_or_reason)
            else
                snapshot = snapshot_or_reason
            end
        end
        if verify_reason == nil and requested_pattern_index ~= nil
            and tonumber(snapshot.pattern_index) ~= tonumber(requested_pattern_index) then
            verify_reason = "skin-verify-pattern-mismatch"
        end
        if verify_reason == nil and requested_skin_variation ~= nil
            and tonumber(snapshot.skin_variation) ~= math.floor(requested_skin_variation) then
            verify_reason = "skin-verify-variation-mismatch"
        end
        if verify_reason == nil and requested_is_female ~= nil
            and snapshot.is_female ~= requested_is_female then
            verify_reason = "skin-verify-sex-mismatch"
        end
        if verify_reason == nil then
            for _, spec in ipairs(SKIN_BRIDGE_COLOR_KEYS) do
                local expected = color_to_hex(apply_payload.colors[spec.field])
                local actual = tostring(snapshot.colors[spec.json] or ""):upper()
                if actual ~= tostring(expected):upper() then
                    verify_reason = "skin-verify-color-mismatch:" .. tostring(spec.json)
                    break
                end
            end
        end

        if verify_reason ~= nil then
            if previous_saved ~= nil and is_valid_object(fresh_pawn) then
                apply_saved_skin_state(fresh_pawn, previous_saved)
            end
            append_skin_bridge_result(
                command_id, false, steam, species, life_serial, verify_reason
            )
            log(string.format(
                "[SkinBridge][VERIFY] id=%s steam=%s ok=false reason=%s previousSavedPreserved=true",
                command_id, steam, verify_reason
            ))
            return
        end

        local captured_ok, captured = capture_current_skin_state(
            steam,
            fresh_pawn,
            species,
            life_serial,
            "skin-bridge:" .. tostring(command_id)
        )
        if not captured_ok then
            append_skin_bridge_result(
                command_id, false, steam, species, life_serial,
                "verified-but-save-failed:" .. tostring(captured)
            )
            return
        end
        remember_skin_applied(steam, fresh_pawn, species, life_serial, captured)
        save_skin_states_to_disk("skin-bridge-verified")
        append_skin_bridge_result(
            command_id, true, steam, species, life_serial,
            "verified-and-saved-current-life"
        )
        log(string.format(
            "[SkinBridge][VERIFY] id=%s steam=%s species=%s life_serial=%d revision=%d pattern_index=%s ok=true",
            command_id, steam, tostring(species), life_serial,
            tonumber(captured.revision) or 0,
            tostring(captured.pattern_index)
        ))
    end)
end

local function process_skin_bridge_commands()
    if not boot_complete then return end
    load_skin_bridge_cursor()

    local file = io.open(SKIN_BRIDGE_COMMAND_PATH, "rb")
    if file == nil then return end

    local size = file:seek("end") or 0
    if size > skin_bridge_offset then
        log(string.format(
            "[SkinBridge][POLL] command_size=%d cursor=%d unread=%d",
            size, skin_bridge_offset, size - skin_bridge_offset
        ))
    end
    if size < skin_bridge_offset then
        log(string.format(
            "[SkinBridge][CURSOR] command file rotated/truncated old_offset=%d new_size=%d resetting=0",
            skin_bridge_offset,
            size
        ))
        skin_bridge_offset = 0
    end

    file:seek("set", skin_bridge_offset)
    local chunk = file:read("*a") or ""
    file:close()
    if chunk == "" then return end

    -- Process only complete newline-terminated commands. A partially written final line
    -- stays unread until the next poll, preventing false parse failures during appends.
    local last_newline = nil
    for i = #chunk, 1, -1 do
        if chunk:sub(i, i) == "\n" then
            last_newline = i
            break
        end
    end
    if last_newline == nil then return end

    local complete = chunk:sub(1, last_newline)
    local processed = 0
    for line in complete:gmatch("[^\r\n]+") do
        if line ~= "" then
            processed = processed + 1
            local ok, err = pcall(function() process_skin_bridge_command(line) end)
            if not ok then
                log(string.format("[SkinBridge][ERROR] unhandled command error=%s line=%s", tostring(err), tostring(line)))
            end
        end
    end

    skin_bridge_offset = skin_bridge_offset + last_newline
    save_skin_bridge_cursor()

    if processed > 0 then
        log(string.format("[SkinBridge] processed=%d cursor=%d", processed, skin_bridge_offset))
    end
end

local function handle_new_zone_visit(steam, pawn, state, zone_kind, key)
    if state == nil or state.frozen then return end
    if zone_kind == nil or key == nil then return end

    local visited_set = state.visited[zone_kind]
    if visited_set == nil then return end

    -- Never notify or count the same physical zone twice for this dinosaur life.
    if visited_set[key] == true then return end
    visited_set[key] = true
    mark_prime_state_dirty("new-zone:" .. tostring(zone_kind))

    local unique_count = table_count(visited_set)

    if zone_kind == "sanctuary" then
        local juvenile = safe_get(function() return pawn:IsJuvenile() end, false) == true
        local nested, hatchling = get_nesting_status(pawn)
        local sanctuary_eligible = juvenile
            or nested
            or hatchling
            or state.nested_in == true
            or state.hatchling_spawn == true

        if sanctuary_eligible and mark_task_complete(state, 1) then
            sync_prime_game_state(pawn, state, "task-1-complete")
            local message = "Prime Task 1 complete - Sanctuary visited!\n" .. prime_progress_line(state)
            notify_prime_message(steam, message)
        elseif state.completed_tasks[1] == true then
            log(string.format(
                "[Prime][NEW_ZONE] steam=%s type=sanctuary unique=%d task1_already_complete=true",
                tostring(steam), unique_count
            ))
        else
            notify_prime_message(steam, "New sanctuary discovered - Prime Task 1 requires juvenile or hatchling status")
            log(string.format(
                "[Prime][NEW_ZONE] steam=%s type=sanctuary unique=%d juvenile=%s nested=%s hatchling=%s task1_complete=false",
                tostring(steam), unique_count, tostring(juvenile), tostring(nested), tostring(hatchling)
            ))
        end
        return
    end

    if zone_kind == "migration" then
        if unique_count < MIGRATION_ZONES_REQUIRED then
            notify_prime_message(steam, string.format(
                "New migration zone discovered - Prime Task 5: %d/%d",
                unique_count,
                MIGRATION_ZONES_REQUIRED
            ))
        elseif unique_count == MIGRATION_ZONES_REQUIRED and mark_task_complete(state, 5) then
            sync_prime_game_state(pawn, state, "task-5-complete")
            notify_prime_message(steam,
                string.format(
                    "Prime Task 5 complete - %d/%d unique migration zones visited!\n%s",
                    unique_count,
                    MIGRATION_ZONES_REQUIRED,
                    prime_progress_line(state)
                )
            )
        else
            notify_prime_message(steam, string.format(
                "New migration zone discovered - %d unique migration zones visited",
                unique_count
            ))
        end
        return
    end

    if zone_kind == "patrol" then
        if unique_count < PATROL_ZONES_REQUIRED then
            notify_prime_message(steam, string.format(
                "New patrol zone discovered - Prime Task 6: %d/%d",
                unique_count,
                PATROL_ZONES_REQUIRED
            ))
        elseif unique_count == PATROL_ZONES_REQUIRED and mark_task_complete(state, 6) then
            sync_prime_game_state(pawn, state, "task-6-complete")
            notify_prime_message(steam,
                string.format(
                    "Prime Task 6 complete - %d/%d unique patrol zones visited!\n%s",
                    unique_count,
                    PATROL_ZONES_REQUIRED,
                    prime_progress_line(state)
                )
            )
        else
            notify_prime_message(steam, string.format(
                "New patrol zone discovered - %d unique patrol zones visited",
                unique_count
            ))
        end
    end
end

local function poll_zone_entries()
    if not boot_complete then return end

    local gm = find_game_mode()
    if not is_valid_object(gm) then
        log("[ZoneEntry] No valid GameMode found this tick.")
        return
    end

    local spawners = FindAllOf("TIEdibleSpawner")
    if spawners == nil then
        log("[ZoneEntry] FindAllOf(TIEdibleSpawner) returned nil this tick.")
        return
    end

    local players, player_diag = collect_live_players(gm)

    local seen_steams = {}
    local seen_life_keys = {}
    local player_count = #players
    local relevant_zone_count = 0
    local inside_hits = 0
    local box_hits = 0
    local sphere_hits = 0
    local custom_hits = 0
    local planar_recoveries = 0
    local frozen_players = 0
    local spectator_players = 0

    for _, zone in ipairs(spawners) do
        if is_valid_object(zone) and zone_type(zone) ~= nil then
            relevant_zone_count = relevant_zone_count + 1
        end
    end

    for _, player in ipairs(players) do
        local steam = player.steam
        local pawn = player.pawn
        local controller = player.controller
        seen_steams[steam] = true

        if is_admin_spectator(controller, pawn) then
            spectator_players = spectator_players + 1
            remember_spectator_session(steam, controller)
        else
            -- Returning from admin spectator camera is continuity of the same dinosaur
            -- life, not a respawn. Clear any spectator-caused respawn marker first.
            restore_after_spectator(steam, pawn)

            -- Resolve the current dinosaur life first. A true new life can clear the old
            -- current-life skin before any restore attempt is made.
            local state, growth = get_or_reset_prime_state(steam, pawn)

            -- Only restore a skin saved for this exact life serial. This survives relogs
            -- and full server restarts, but never auto-applies to a new dinosaur life.
            maybe_restore_saved_skin(steam, pawn, state)

            local life_key = state.state_key
            seen_life_keys[life_key] = true

            if state.frozen then
                frozen_players = frozen_players + 1
            else
                reconcile_dynamic_prime_tasks(steam, pawn, state)
            end

            local previous = inside_state[life_key] or {}
            local current = {}

            for _, zone in ipairs(spawners) do
            if is_valid_object(zone) then
                local kind = zone_type(zone)

                if kind ~= nil then
                    local area_shape = shape_name(safe_get(function()
                        return zone.AreaShape
                    end, "<unknown>"))

                    local inside, planar_recovery = is_pawn_inside_zone(zone, pawn, area_shape, kind)
                    if inside then
                        inside_hits = inside_hits + 1
                        if planar_recovery then planar_recoveries = planar_recoveries + 1 end
                        if area_shape == "Box" then box_hits = box_hits + 1
                        elseif area_shape == "Sphere" then sphere_hits = sphere_hits + 1
                        elseif area_shape == "Custom" then custom_hits = custom_hits + 1 end

                        local key = zone_key(zone)
                        current[key] = kind

                        if previous[key] ~= kind then
                            log(string.format(
                                "[ZoneEntry][ENTER] steam=%s character_id=%s source=%s type=%s shape=%s planar_recovery=%s growth=%.4f frozen=%s zone=%s",
                                tostring(steam),
                                tostring(state.character_id or "fallback"),
                                tostring(player.source),
                                tostring(kind),
                                tostring(area_shape),
                                tostring(planar_recovery),
                                growth,
                                tostring(state.frozen),
                                key
                            ))

                            if not state.frozen then
                                handle_new_zone_visit(steam, pawn, state, kind, key)
                            end
                        end
                    end
                end
            end
        end

            inside_state[life_key] = current
        end
    end

    -- Forget only transient inside/outside state for offline dinosaur lives. The
    -- persistent-in-memory visited sets remain in prime_states, so reconnecting does
    -- not create duplicate notifications for already visited physical zones.
    for life_key, _ in pairs(inside_state) do
        if not seen_life_keys[life_key] then
            inside_state[life_key] = nil
        end
    end

    -- Runtime restore markers are intentionally transient. Removing offline players
    -- guarantees that reconnecting to a saved species triggers one fresh reapply.
    for steam, _runtime in pairs(skin_restore_runtime) do
        if not seen_steams[steam] then
            skin_restore_runtime[steam] = nil
        end
    end

    local now = os.time()
    if (now - last_health_log_at) >= HEALTH_LOG_INTERVAL_SEC then
        last_health_log_at = now
        local registry_count = 0
        local prime_state_count = 0
        for _steam, _entry in pairs(presence_registry) do registry_count = registry_count + 1 end
        for _steam, _state in pairs(prime_states) do prime_state_count = prime_state_count + 1 end

        log(string.format(
            "[ZoneEntry][HEALTH] polling=true players=%d spectators=%d relevant_zones=%d migration_zones=%d patrol_zones=%d sanctuary_zones=%d inside_hits=%d box_hits=%d sphere_hits=%d custom_hits=%d planar_recoveries=%d frozen_players=%d prime_states=%d pending_notifications=%d playerArray_callbacks=%d controllerSet_callbacks=%d registry=%d sourcePlayerArray=%d sourceControllerSet=%d sourceRegistry=%d validControllers=%d validPawns=%d",
            player_count,
            spectator_players,
            relevant_zone_count,
            zone_catalog_counts.migration or 0,
            zone_catalog_counts.patrol or 0,
            zone_catalog_counts.sanctuary or 0,
            inside_hits,
            box_hits,
            sphere_hits,
            custom_hits,
            planar_recoveries,
            frozen_players,
            prime_state_count,
            #pending_notifies,
            player_diag.player_array_callbacks,
            player_diag.controller_set_callbacks,
            registry_count,
            player_diag.source_player_array,
            player_diag.source_controller_set,
            player_diag.source_registry,
            player_diag.controllers_valid,
            player_diag.pawns_valid
        ))
    end
end

local function boot_once()
    if boot_complete then return end

    load_prime_states_from_disk()
    load_skin_states_from_disk()
    load_skin_bridge_cursor()
    PRIME_RESTORE_BRIDGE.load()
    rebuild_zone_catalog("boot")
    apply_zone_fix()
    boot_complete = true

    log(string.format(
        "[ZoneEntry] Prime tracker started. interval=%dms zone_catalog_refresh=%dms shapes=Box,Sphere,Custom migration_patrol_containment=horizontal growth_cutoff=%.2f migration_required=%d patrol_required=%d game_sync=Tasks1,2,3,5,6,10 task4=panel-only task9=panel-only life_reset=species,death-respawn,respawn-hook spectator_safe=true native_tasks=2,3,7,8 persistence=atomic-tsv chat_commands=!prime,!hp,!primelist,!skintest skin_apply=direct-CustomizerData+ForceNetUpdate skin_persistence=per-SteamID+life-serial auto_restore=reconnect,restart new-life-clears-skin=true skin_bridge=flat-ndjson-current-life pattern_probe=DT_SkinDataList-runtime-map pattern_index=validated-0-to-Nminus1 alpha=forced-FF asset_sex=is_female+ForceNetUpdate",
        POLL_INTERVAL_MS,
        ZONE_CATALOG_REFRESH_MS,
        PRIME_GROWTH_CUTOFF,
        MIGRATION_ZONES_REQUIRED,
        PATROL_ZONES_REQUIRED
    ))
end

register_prime_chat_hook()
presence_register_hook()
respawn_register_hook()

log(string.format(" Loading; version=%s", MOD_VERSION))
log(string.format(
    "[ZoneEntry] Script loaded. Waiting %d seconds for Gateway actors to initialize...",
    START_DELAY_MS / 1000
))

if LoopInGameThreadWithDelay == nil then
    log("[ZoneEntry][FATAL] LoopInGameThreadWithDelay is unavailable; detector cannot start.")
else
    -- One-shot delayed boot. The boolean guard prevents repeated patching even if
    -- CancelDelayedAction is unavailable on this UE4SS build.
    LoopInGameThreadWithDelay(START_DELAY_MS, function()
        safe_call("boot_once", boot_once)
    end)

    -- Reliable outside -> inside polling detector.
    LoopInGameThreadWithDelay(POLL_INTERVAL_MS, function()
        safe_call("poll_zone_entries", poll_zone_entries)
    end)

    -- Patrol and migration membership changes while the server is running.
    -- Refreshing the small catalog every 30 seconds keeps those changes visible
    -- without adding work to the one-second per-player containment loop.
    LoopInGameThreadWithDelay(ZONE_CATALOG_REFRESH_MS, function()
        safe_call("refresh_zone_catalog", function()
            if not boot_complete then return end
            local changed = rebuild_zone_catalog("runtime-refresh")
            if changed then
                apply_zone_fix()
            end
        end)
    end)

    -- Chat commands are read in the hook, then processed here outside the hook.
    -- Notification delivery remains deferred through the existing safe queue.
    LoopInGameThreadWithDelay(NOTIFY_DRAIN_INTERVAL_MS, function()
        safe_call("process_prime_command_requests", process_prime_command_requests)
        safe_call("process_health_command_requests", process_health_command_requests)
        safe_call("process_prime_list_command_requests", process_prime_list_command_requests)
        safe_call("process_skin_test_command_requests", process_skin_test_command_requests)
        safe_call("process_skin_bridge_commands", process_skin_bridge_commands)
        safe_call("process_prime_restore_commands", PRIME_RESTORE_BRIDGE.process)
        safe_call("drain_notifications", drain_notifications)
    end)

    -- Periodic atomic persistence. State changes only mark the file dirty; this keeps
    -- disk IO bounded while still surviving normal server restarts and most crashes.
    LoopInGameThreadWithDelay(PRIME_STATE_SAVE_INTERVAL_MS, function()
        safe_call("save_prime_states_to_disk", function()
            save_prime_states_to_disk("autosave")
        end)
        safe_call("save_skin_states_to_disk", function()
            save_skin_states_to_disk("autosave")
        end)
    end)
end

log("[ZoneEntry] VERIFIED_BUILD_MARKER=ZONEFIX_PRIME_TRACKER_V33_GARAGE_PROGRESS_HANDOFF")
log(string.format(" Loaded; version=%s", MOD_VERSION))
