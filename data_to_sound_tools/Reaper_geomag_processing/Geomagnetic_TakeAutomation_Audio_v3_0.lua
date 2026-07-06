-- Geomagnetic Take Automation (Audio) v3.0
-- Geomagnetic data -> take envelopes on selected AUDIO items
-- Targets: Volume, Pan, Pitch, Mute
-- Each selected item is processed independently using its own length as duration
-- Multi-column support with per-column take envelope assignment

local script_version = "3.0"

if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox("ReaImGui extension is required.", "Missing Extension", 0)
    return
end

local ctx = reaper.ImGui_CreateContext("Geomagnetic_TakeAutomation_Audio_v3_0")

-- ============================================================
-- TAKE ENVELOPE DEFINITIONS
-- ============================================================
-- These are the exact name strings Reaper uses for GetTakeEnvelopeByName
local TAKE_ENV_NAMES = {
    "Volume",
    "Pan",
    "Pitch",
    "Mute",
}

-- Display labels and value ranges for each envelope type
local TAKE_ENV_INFO = {
    Volume   = { label = "Volume",    min = 0.0,  max = 1.0,   default = 1.0,  fmt = "%.3f", unit = "" },
    Pan      = { label = "Pan",       min = -1.0, max = 1.0,   default = 0.0,  fmt = "%.3f", unit = "" },
    Pitch    = { label = "Pitch",     min = -24.0,max = 24.0,  default = 0.0,  fmt = "%.2f", unit = "st" },
    Mute     = { label = "Mute",      min = 0.0,  max = 1.0,   default = 0.0,  fmt = "%.0f", unit = "" },
}

-- ============================================================
-- STATE
-- ============================================================
local state = {
    -- Data
    data_loaded            = false,
    data_cache             = {},
    data_file_path         = "",
    column_count           = 0,
    row_count              = 0,
    column_names           = {},
    has_header             = false,

    -- Per-column assignments
    -- col_assignments[col] = { {env_name="Volume", mapping=2, amp=1.0, offset=0.0}, ... }
    col_assignments        = { [1]={}, [2]={}, [3]={}, [4]={}, [5]={} },
    col_tree_open          = { true, true, true, true, true },
    col_enabled            = { false, false, false, false, false },

    -- Column navigation for >5 columns
    column_offset          = 0,

    -- Selected items info (refreshed on apply / button press)
    selected_items         = {},   -- list of {item, take, name, length, pos}
    item_count             = 0,

    -- Duration / timing
    duration_mode          = 1,   -- 1=Item length (auto), 2=Points/rate, 3=Fixed
    duration               = 60.0,
    duration_text          = "60.0",
    last_duration          = 60.0,
    points_per_second      = 1.0,
    points_per_second_text = "1.0",
    points_rate_unit       = 1,   -- 1=Seconds, 2=Minutes, 3=Hours

    -- Direction
    direction              = 1,   -- 1=Forward, 2=Reverse, 3=Palindrome

    -- Start position within item
    start_offset           = 0.0, -- seconds offset from item start (usually 0)

    -- Pre-processing
    preprocessing_expanded = false,
    process_mode           = 1,
    threshold              = 150.0,
    comp_ratio             = 4.0,
    comp_knee              = 0.3,

    -- Options
    clear_existing         = true,
    show_envelope_panel    = false,

    -- Preview
    preview_data           = {},
    preview_needs_refresh  = { true, true, true, true, true },

    -- Warning flags
    show_column_warning    = false,

    -- Status
    status_message         = "Ready. Select items and load data.",
    gui_initialized        = false,
}

-- ============================================================
-- EXTSTATE
-- ============================================================
local EXT_SECTION  = "GeomagTakeAuto_v1_1"
local EXT_FILEPATH = "LastDataFile"
local EXT_SETTINGS = "Settings"

-- ============================================================
-- HELPERS
-- ============================================================
local function basename(path)
    if not path or path == "" then return "" end
    return path:match("[^/\\]+$") or path
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- ============================================================
-- SETTINGS PERSISTENCE
-- ============================================================
local function save_settings()
    local function s(k, v)
        reaper.SetExtState(EXT_SECTION, EXT_SETTINGS .. k, tostring(v), true)
    end
    s("_duration_mode",       state.duration_mode)
    s("_duration",            state.duration)
    s("_last_duration",       state.last_duration)
    s("_points_per_second",   state.points_per_second)
    s("_points_rate_unit",    state.points_rate_unit)
    s("_direction",           state.direction)
    s("_process_mode",        state.process_mode)
    s("_threshold",           state.threshold)
    s("_comp_ratio",          state.comp_ratio)
    s("_comp_knee",           state.comp_knee)
    s("_preprocessing_expanded", state.preprocessing_expanded and 1 or 0)
    s("_clear_existing",      state.clear_existing and 1 or 0)
    s("_show_envelope_panel", state.show_envelope_panel and 1 or 0)
    for i = 1, 5 do
        s("_col_enabled_" .. i, state.col_enabled[i] and 1 or 0)
    end
    -- Column assignments: env_name|mapping|amp|offset per assignment, semicolon-separated
    for col = 1, 5 do
        local parts = {}
        for _, a in ipairs(state.col_assignments[col] or {}) do
            table.insert(parts, string.format("%s|%d|%g|%g",
                a.env_name, a.mapping, a.amp, a.offset))
        end
        s("_col_assign_" .. col, table.concat(parts, ";"))
    end
end

local function load_settings()
    if not reaper.HasExtState(EXT_SECTION, EXT_SETTINGS .. "_duration_mode") then
        return false, "No saved settings"
    end
    local function n(k, d)
        return tonumber(reaper.GetExtState(EXT_SECTION, EXT_SETTINGS .. k)) or d
    end
    local function b(k, d)
        local v = reaper.GetExtState(EXT_SECTION, EXT_SETTINGS .. k)
        if v == "" then return d end
        return tonumber(v) == 1
    end
    state.duration_mode       = n("_duration_mode",     state.duration_mode)
    state.duration            = n("_duration",          state.duration)
    state.duration_text       = string.format("%.1f",   state.duration)
    state.last_duration       = n("_last_duration",     state.last_duration)
    state.points_per_second   = n("_points_per_second", state.points_per_second)
    state.points_per_second_text = string.format("%.1f", state.points_per_second)
    state.points_rate_unit    = n("_points_rate_unit",  state.points_rate_unit)
    state.direction           = n("_direction",         state.direction)
    state.process_mode        = n("_process_mode",      state.process_mode)
    state.threshold           = n("_threshold",         state.threshold)
    state.comp_ratio          = n("_comp_ratio",        state.comp_ratio)
    state.comp_knee           = n("_comp_knee",         state.comp_knee)
    state.preprocessing_expanded = b("_preprocessing_expanded", state.preprocessing_expanded)
    state.clear_existing      = b("_clear_existing",    state.clear_existing)
    state.show_envelope_panel = b("_show_envelope_panel", state.show_envelope_panel)
    for i = 1, 5 do
        state.col_enabled[i]  = b("_col_enabled_" .. i, false)
    end
    for col = 1, 5 do
        local s_val = reaper.GetExtState(EXT_SECTION, EXT_SETTINGS .. "_col_assign_" .. col)
        state.col_assignments[col] = {}
        if s_val and s_val ~= "" then
            for entry in s_val:gmatch("([^;]+)") do
                local env_name, mapping, amp, offset = entry:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
                if env_name and TAKE_ENV_INFO[env_name] then
                    table.insert(state.col_assignments[col], {
                        env_name = env_name,
                        mapping  = tonumber(mapping) or 2,
                        amp      = tonumber(amp)     or 1.0,
                        offset   = tonumber(offset)  or 0.0,
                    })
                end
            end
        end
    end
    return true, "Settings loaded"
end

-- Restore last filepath
if reaper.HasExtState(EXT_SECTION, EXT_FILEPATH) then
    state.data_file_path = reaper.GetExtState(EXT_SECTION, EXT_FILEPATH)
end

-- ============================================================
-- DATA LOADING
-- ============================================================
local function load_data_file(filepath)
    local file = io.open(filepath, "r")
    if not file then return false, "Could not open file" end

    local data         = {}
    local col_count    = 0
    local header_names = {}
    local has_header   = false
    local first_line   = true
    local nan_count    = 0
    local line_num     = 0
    
    -- Detect delimiter from first non-empty line
    local delimiter = ","
    local first_content_line = nil
    for line in file:lines() do
        if line:match("%S") then
            first_content_line = line
            break
        end
    end
    file:close()
    
    if not first_content_line then return false, "File is empty" end
    
    -- Detect delimiter: comma, tab, or space
    if first_content_line:find(",") then
        delimiter = ","
    elseif first_content_line:find("\t") then
        delimiter = "\t"
    else
        delimiter = "%s+"  -- One or more spaces
    end
    
    -- Reopen file for actual parsing
    file = io.open(filepath, "r")
    if not file then return false, "Could not reopen file" end

    for line in file:lines() do
        line_num = line_num + 1
        if line:match("%S") then
            -- Split line by delimiter
            local tokens = {}
            if delimiter == "," or delimiter == "\t" then
                -- Simple split for comma or tab
                for val in (line .. delimiter):gmatch("(.-)" .. delimiter) do
                    table.insert(tokens, val:match("^%s*(.-)%s*$"))  -- Trim whitespace
                end
            else
                -- Space-separated
                for val in line:gmatch("[^%s]+") do
                    table.insert(tokens, val)
                end
            end

            if first_line and #tokens > 0 then
                local all_numeric = true
                for _, token in ipairs(tokens) do
                    if not tonumber(token) then all_numeric = false; break end
                end
                if not all_numeric then
                    has_header   = true
                    header_names = tokens
                    -- Don't set col_count here - let first data row determine it
                    first_line   = false
                    goto continue
                end
            end
            first_line = false

            -- Parse numeric values (skip non-numeric columns like datetime)
            local values = {}
            for _, val in ipairs(tokens) do
                local num = tonumber(val)
                if num then
                    table.insert(values, num)
                elseif val:lower() == "nan" then
                    table.insert(values, 0)
                    nan_count = nan_count + 1
                end
                -- Skip non-numeric values (like datetime strings)
            end

            if #values > 0 then
                if col_count == 0 then
                    col_count = #values
                elseif #values ~= col_count then
                    file:close()
                    return false, string.format("Line %d: %d numeric cols (expected %d)",
                        line_num, #values, col_count)
                end
                table.insert(data, values)
            end
        end
        ::continue::
    end
    file:close()

    if #data == 0 then return false, "No valid data found" end
    if not has_header then
        for i = 1, col_count do header_names[i] = string.format("Column %d", i) end
    end
    return true, data, col_count, #data, header_names, has_header, nan_count
end

-- ============================================================
-- SELECTED ITEMS REFRESH
-- ============================================================
local function refresh_selected_items()
    state.selected_items = {}
    local count = reaper.CountSelectedMediaItems(0)
    for i = 0, count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        if item then
            local take = reaper.GetActiveTake(item)
            if take then
                local pos    = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                local _, track = reaper.GetMediaItemTrack(item), nil
                local track_h = reaper.GetMediaItemTrack(item)
                local _, track_name = reaper.GetTrackName(track_h)
                table.insert(state.selected_items, {
                    item       = item,
                    take       = take,
                    pos        = pos,
                    length     = length,
                    take_name  = take_name ~= "" and take_name or ("Take " .. (i+1)),
                    track_name = track_name,
                })
            end
        end
    end
    state.item_count = #state.selected_items
end

-- ============================================================
-- DATA PROCESSING
-- ============================================================
local function calc_stats(values)
    local mn, mx = values[1], values[1]
    local sum = 0
    for _, v in ipairs(values) do
        if v < mn then mn = v end
        if v > mx then mx = v end
        sum = sum + v
    end
    local mean = sum / #values
    local var  = 0
    for _, v in ipairs(values) do var = var + (v - mean)^2 end
    return { min = mn, max = mx, mean = mean, std_dev = math.sqrt(var / #values) }
end

local function apply_compression(value, threshold, ratio, knee)
    if value <= threshold - knee / 2 then
        return value
    elseif value >= threshold + knee / 2 then
        return threshold + (value - threshold) / ratio
    else
        local t    = (value - (threshold - knee / 2)) / knee
        local soft = (threshold - knee / 2) + t * knee
        return threshold + (soft - threshold) / ratio
    end
end

local function smooth_values(values, window)
    if window < 2 then return values end
    local out  = {}
    local half = math.floor(window / 2)
    for i = 1, #values do
        local sv, cnt = 0, 0
        for j = math.max(1, i - half), math.min(#values, i + half) do
            sv = sv + values[j]; cnt = cnt + 1
        end
        table.insert(out, sv / cnt)
    end
    return out
end

-- Process column data into 0-1 normalised values
-- Returns normalised array and stats
local function process_column_data(col)
    if not state.data_loaded or col < 1 or col > state.column_count then return nil end

    local raw = {}
    for _, row in ipairs(state.data_cache) do table.insert(raw, row[col]) end

    local stats      = calc_stats(raw)
    local thresh_val = stats.mean + (stats.std_dev * state.threshold / 100)

    local processed = {}
    for _, v in ipairs(raw) do
        if state.process_mode == 2 then
            table.insert(processed, apply_compression(v, thresh_val, state.comp_ratio, state.comp_knee))
        else
            table.insert(processed, v)
        end
    end

    if state.smoothing_enabled then
        processed = smooth_values(processed, state.smooth_window)
    end

    -- Direction
    local directed = {}
    if state.direction == 1 then
        directed = processed
    elseif state.direction == 2 then
        for i = #processed, 1, -1 do table.insert(directed, processed[i]) end
    elseif state.direction == 3 then
        for i = 1, #processed do table.insert(directed, processed[i]) end
        for i = #processed - 1, 2, -1 do table.insert(directed, processed[i]) end
    end

    local dstats = calc_stats(directed)
    local range  = dstats.max - dstats.min
    if range == 0 then range = 1 end

    local normalised = {}
    for _, v in ipairs(directed) do
        table.insert(normalised, (v - dstats.min) / range)
    end

    return normalised, dstats
end

-- Map normalised 0-1 value to take envelope range using assignment settings
-- mapping: 1=Centered, 2=Full range, 3=Inverted
local function map_to_env_value(norm, env_name, mapping, amp, offset)
    local info = TAKE_ENV_INFO[env_name]
    if not info then return 0 end

    local lo, hi = info.min, info.max
    local range  = hi - lo
    local scaled = norm * amp  -- apply amplitude scaling

    local mapped
    if mapping == 1 then      -- Centered: maps 0-1 to midpoint ± half range
        local mid = (lo + hi) / 2
        mapped = mid + (scaled - 0.5) * range
    elseif mapping == 2 then  -- Full range: maps 0-1 directly to lo-hi
        mapped = lo + scaled * range
    elseif mapping == 3 then  -- Inverted: maps 0-1 to hi-lo
        mapped = hi - scaled * range
    else
        mapped = lo + scaled * range
    end

    -- Apply offset in env units then clamp
    mapped = clamp(mapped + offset, lo, hi)
    return mapped
end

-- ============================================================
-- PREVIEW GRAPH
-- ============================================================
-- Minimal smoothing flag (added inline since not in state above)
if state.smoothing_enabled == nil then state.smoothing_enabled = false end
if state.smooth_window     == nil then state.smooth_window     = 3      end

local function refresh_preview(col)
    if not state.data_loaded or col > state.column_count then return end
    local norm, dstats = process_column_data(col)
    if not norm then return end

    -- For preview, use first assignment's mapping if available, else default
    local assignment = state.col_assignments[col] and state.col_assignments[col][1]
    local env_name   = assignment and assignment.env_name or "Volume"
    local mapping    = assignment and assignment.mapping  or 2
    local amp        = assignment and assignment.amp      or 1.0
    local offset_v   = assignment and assignment.offset   or 0.0

    local mapped = {}
    for _, n in ipairs(norm) do
        table.insert(mapped, map_to_env_value(n, env_name, mapping, amp, offset_v))
    end

    local mstats = calc_stats(mapped)
    state.preview_data[col] = {
        values = mapped,
        stats  = mstats,
        raw    = norm,
        env_name = env_name,
    }
    state.preview_needs_refresh[col] = false
end

local function draw_preview_graph(col, width, height)
    local pd = state.preview_data[col]
    if not pd or #pd.values < 2 then return end

    local dl   = reaper.ImGui_GetWindowDrawList(ctx)
    local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
    local vals = pd.values
    local st   = pd.stats
    local rng  = st.max - st.min
    if rng == 0 then rng = 1 end

    -- Background
    reaper.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + width, cy + height, 0x1A1A2EFF)

    local function val_to_y(v)
        local t = (v - st.min) / rng
        return cy + height - (t * (height - 6)) - 3
    end

    -- Grid lines
    for _, gv in ipairs({ st.min, st.mean, st.max }) do
        local gy = val_to_y(gv)
        reaper.ImGui_DrawList_AddLine(dl, cx, gy, cx + width, gy, 0x334466AA, 1.0)
    end

    -- Curve (teal for take automation, distinct from tempo map amber)
    local n = #vals
    for i = 1, n - 1 do
        local x1 = cx + ((i-1)/(n-1)) * width
        local x2 = cx + (i    /(n-1)) * width
        local y1 = val_to_y(vals[i])
        local y2 = val_to_y(vals[i+1])
        reaper.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, 0x00E5FFFF, 2.0)
    end

    reaper.ImGui_DrawList_AddRect(dl, cx, cy, cx + width, cy + height, 0x446688FF, 0, 0, 1.5)
    reaper.ImGui_Dummy(ctx, width, height)

    local info = TAKE_ENV_INFO[pd.env_name] or {}
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x00E5FFFF)
    reaper.ImGui_Text(ctx, string.format("%s  min: %.3f   mean: %.3f   max: %.3f   pts: %d",
        pd.env_name, st.min, st.mean, st.max, n))
    reaper.ImGui_PopStyleColor(ctx)
end

-- ============================================================
-- APPLY AUTOMATION
-- ============================================================
local function apply_automation()
    if not state.data_loaded then
        state.status_message = "No data loaded"
        return
    end

    refresh_selected_items()

    if state.item_count == 0 then
        state.status_message = "No items selected (select items in arrange view first)"
        return
    end

    -- Collect enabled columns
    local enabled_cols = {}
    for i = 1, math.min(5, state.column_count) do
        if state.col_enabled[i] then
            local col = i + state.column_offset
            if col <= state.column_count then
                table.insert(enabled_cols, col)
            end
        end
    end

    if #enabled_cols == 0 then
        state.status_message = "No columns enabled"
        return
    end

    reaper.Undo_BeginBlock()

    local success_count = 0
    local error_msgs    = {}

    for _, item_info in ipairs(state.selected_items) do
        local take   = item_info.take
        local item   = item_info.item
        local item_pos    = item_info.pos
        local item_length = item_info.length

        -- Calculate duration for this item
        local duration_to_use
        if state.duration_mode == 1 then
            -- Item length mode - use item's own length
            duration_to_use = item_length
        elseif state.duration_mode == 2 then
            -- Points/rate mode
            if state.points_per_second > 0 then
                local unit_mults = {1, 60, 3600}
                local unit_mult  = unit_mults[state.points_rate_unit] or 1
                local pps_actual = state.points_per_second / unit_mult
                local eff_rows   = state.direction == 3
                    and (state.row_count * 2 - 2) or state.row_count
                duration_to_use  = eff_rows / pps_actual
                state.last_duration = duration_to_use
            else
                table.insert(error_msgs, "Invalid points/rate")
                break
            end
        elseif state.duration_mode == 3 then
            duration_to_use = state.last_duration
        end

        if not duration_to_use or duration_to_use <= 0 then
            table.insert(error_msgs, string.format("Item '%s': invalid duration", item_info.take_name))
            goto next_item
        end

        for _, col in ipairs(enabled_cols) do
            local assignments = state.col_assignments[col]
            if not assignments or #assignments == 0 then
                table.insert(error_msgs, string.format("Col %d: no take envelope assigned", col))
            else
                local norm, _ = process_column_data(col)
                if not norm then
                    table.insert(error_msgs, string.format("Col %d: data processing failed", col))
                else
                    for _, assignment in ipairs(assignments) do
                        local env_name = assignment.env_name

                        -- Get the take envelope
                        local env = reaper.GetTakeEnvelopeByName(take, env_name)

                        if env then
                            -- Write the automation points
                            local n_points       = #norm
                            local time_per_point = duration_to_use / (n_points - 1)
                            local start_t        = 0.0

                            if state.clear_existing then
                                reaper.DeleteEnvelopePointRange(env,
                                    start_t - 0.001,
                                    start_t + duration_to_use + 0.001)
                            end

                            for i, n_val in ipairs(norm) do
                                local t     = start_t + (i - 1) * time_per_point
                                local value = map_to_env_value(n_val, env_name,
                                    assignment.mapping, assignment.amp, assignment.offset)
                                reaper.InsertEnvelopePoint(env, t, value, 0, 0, false, true)
                            end

                            reaper.Envelope_SortPoints(env)
                            success_count = success_count + 1
                        else
                            table.insert(error_msgs, string.format(
                                "Col %d: Could not create '%s' envelope on '%s'",
                                col, env_name, item_info.take_name))
                        end
                    end
                end
            end
        end

        ::next_item::
    end

    reaper.Undo_EndBlock("Geomagnetic Take Automation", -1)
    reaper.UpdateArrange()

    if success_count > 0 then
        state.status_message = string.format(
            "Applied to %d envelope(s) across %d item(s)",
            success_count, state.item_count)
        if #error_msgs > 0 then
            state.status_message = state.status_message .. "\n⚠ " .. table.concat(error_msgs, "; ")
        end
    else
        state.status_message = "Nothing applied.\n" .. table.concat(error_msgs, "\n")
    end

    save_settings()
end

-- ============================================================
-- COLUMN COMBO STRING
-- ============================================================
local function build_col_combo_string()
    local parts = {}
    for i = 1, state.column_count do
        local name = state.column_names[i] or string.format("Column %d", i)
        table.insert(parts, string.format("%d: %s", i, name))
    end
    return table.concat(parts, "\0") .. "\0"
end

-- Env name combo string
local function build_env_combo_string()
    return table.concat(TAKE_ENV_NAMES, "\0") .. "\0"
end

local function env_name_to_idx(name)
    for i, n in ipairs(TAKE_ENV_NAMES) do
        if n == name then return i end
    end
    return 1
end

-- ============================================================
-- GUI
-- ============================================================
local function draw_gui()
    local rv

    -- ── 1. SELECTED ITEMS ─────────────────────────────────────
    reaper.ImGui_SeparatorText(ctx, "1. SELECTED ITEMS")

    if reaper.ImGui_Button(ctx, "Refresh Item List", 140, 25) then
        refresh_selected_items()
        if state.item_count > 0 then
            state.status_message = string.format(
                "%d item(s) selected", state.item_count)
        else
            state.status_message = "No items selected"
        end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Refresh after selecting/deselecting items in Reaper")
    end

    if state.item_count > 0 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x88FF88FF)
        reaper.ImGui_Text(ctx, string.format("✓ %d item(s) ready", state.item_count))
        reaper.ImGui_PopStyleColor(ctx)
        -- Show item list (compact)
        for i, info in ipairs(state.selected_items) do
            if i <= 8 then  -- Show max 8 to avoid overflowing
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x888888FF)
                reaper.ImGui_Text(ctx, string.format(
                    "  [%d] %s / %s  (%.2fs)",
                    i, info.track_name, info.take_name, info.length))
                reaper.ImGui_PopStyleColor(ctx)
            elseif i == 9 then
                reaper.ImGui_TextDisabled(ctx, string.format("  ... and %d more", state.item_count - 8))
            end
        end
    else
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF8844FF)
        reaper.ImGui_Text(ctx, "⚠ No items selected — select items in arrange view")
        reaper.ImGui_PopStyleColor(ctx)
    end

    -- ── 2. DATA FILE ──────────────────────────────────────────
    reaper.ImGui_SeparatorText(ctx, "2. DATA FILE")

    -- Display current loaded file (updates immediately after load)
    local display_filename = (state.data_file_path ~= "" and basename(state.data_file_path) or "None")
    reaper.ImGui_Text(ctx, "File: " .. display_filename)

    local function do_load(filepath)
        local ok, data, cc, rc, cn, hh, nc = load_data_file(filepath)
        if ok then
            state.data_cache     = data
            state.column_count   = cc
            state.row_count      = rc
            state.column_names   = cn
            state.has_header     = hh
            state.data_loaded    = true
            state.data_file_path = filepath
            state.column_offset  = 0
            state.show_column_warning = (cc > 5)
            state.just_loaded    = true  -- Flag to force display update
            for i = 1, 5 do state.preview_needs_refresh[i] = true end
            reaper.SetExtState(EXT_SECTION, EXT_FILEPATH, filepath, true)
            local h = hh and " (headers)" or ""
            local w = (nc and nc > 0) and string.format(" | ⚠ %d NaN→0", nc) or ""
            state.status_message = string.format("✓ Loaded: %d rows × %d columns%s%s", rc, cc, h, w)
        else
            state.status_message = "❌ Load failed: " .. tostring(data)
            state.just_loaded = false
        end
    end

    if reaper.ImGui_Button(ctx, "Load Data File", 130, 25) then
        local last = reaper.GetExtState(EXT_SECTION, "LastFolder")
        local ok, fp = reaper.GetUserFileNameForRead(last, "Load Data File", "*.csv;*.txt")
        if ok then
            local folder = fp:match("(.*[/\\])")
            if folder then reaper.SetExtState(EXT_SECTION, "LastFolder", folder, true) end
            do_load(fp)
        end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Reload", 70, 25) then
        if state.data_file_path ~= "" then do_load(state.data_file_path) end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Save Settings", 110, 25) then
        save_settings(); state.status_message = "Settings saved"
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Load Settings", 110, 25) then
        local ok, msg = load_settings()
        state.status_message = msg
    end

    if state.data_loaded then
        reaper.ImGui_Text(ctx, string.format("%d rows × %d columns", state.row_count, state.column_count))
        if state.show_column_warning then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF8800FF)
            reaper.ImGui_TextWrapped(ctx, string.format(
                "⚠ %d columns detected — showing 5 at a time, use ◄ ► to navigate",
                state.column_count))
            reaper.ImGui_PopStyleColor(ctx)
        end
    end

    -- disable below until data loaded
    if not state.data_loaded then reaper.ImGui_BeginDisabled(ctx) end

    -- ── 3. PRE-PROCESSING ─────────────────────────────────────
    reaper.ImGui_Spacing(ctx)
    local mode_lbl = state.process_mode == 1 and "Normal" or "Intense"
    local pp_lbl   = string.format("Pre-processing: %s %s",
        mode_lbl, state.preprocessing_expanded and "▲" or "▼")
    if reaper.ImGui_Button(ctx, pp_lbl, 230, 25) then
        state.preprocessing_expanded = not state.preprocessing_expanded
    end

    if state.preprocessing_expanded then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Indent(ctx, 10)

        local prev_pm = state.process_mode
        rv, state.process_mode = reaper.ImGui_RadioButtonEx(ctx, "Normal",  state.process_mode, 1)
        reaper.ImGui_SameLine(ctx)
        rv, state.process_mode = reaper.ImGui_RadioButtonEx(ctx, "Intense", state.process_mode, 2)
        if state.process_mode ~= prev_pm then
            for i = 1, 5 do state.preview_needs_refresh[i] = true end
        end

        local prev_thr = state.threshold
        rv, state.threshold = reaper.ImGui_SliderDouble(ctx, "Threshold %", state.threshold, 0, 300, "%.0f")
        if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) and state.threshold ~= prev_thr then
            for i = 1, 5 do state.preview_needs_refresh[i] = true end
        end

        if state.process_mode == 2 then
            rv, state.comp_ratio = reaper.ImGui_SliderDouble(ctx, "Comp Ratio",
                state.comp_ratio, 1.0, 20.0, "%.1f:1")
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                for i = 1, 5 do state.preview_needs_refresh[i] = true end
            end
            rv, state.comp_knee = reaper.ImGui_SliderDouble(ctx, "Knee",
                state.comp_knee, 0.0, 1.0, "%.2f")
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                for i = 1, 5 do state.preview_needs_refresh[i] = true end
            end
        end

        -- Smoothing inside pre-processing
        reaper.ImGui_Spacing(ctx)
        local prev_sm = state.smoothing_enabled
        rv, state.smoothing_enabled = reaper.ImGui_Checkbox(ctx,
            "Moving average smoothing", state.smoothing_enabled)
        if state.smoothing_enabled ~= prev_sm then
            for i = 1, 5 do state.preview_needs_refresh[i] = true end
        end
        if state.smoothing_enabled then
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 140)
            local prev_sw = state.smooth_window
            rv, state.smooth_window = reaper.ImGui_SliderInt(ctx, "Window##sw",
                state.smooth_window, 2, 100)
            reaper.ImGui_PopItemWidth(ctx)
            if rv and state.smooth_window ~= prev_sw then
                for i = 1, 5 do state.preview_needs_refresh[i] = true end
            end
        end

        reaper.ImGui_Unindent(ctx, 10)
        reaper.ImGui_Spacing(ctx)
    end

    -- ── 4. COLUMNS & TAKE ENVELOPE ASSIGNMENT ─────────────────
    reaper.ImGui_SeparatorText(ctx, "4. COLUMN → TAKE ENVELOPE")

    -- Column navigation for >5 columns
    if state.column_count > 5 then
        local max_offset = state.column_count - 5
        local start_col  = state.column_offset + 1
        local end_col    = math.min(state.column_offset + 5, state.column_count)
        reaper.ImGui_Text(ctx, string.format("Showing cols %d–%d of %d", start_col, end_col, state.column_count))
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "◄##prev", 30, 20) then
            state.column_offset = math.max(0, state.column_offset - 1)
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "►##next", 30, 20) then
            state.column_offset = math.min(max_offset, state.column_offset + 1)
        end
    end

    local env_combo_str = build_env_combo_string()
    local mapping_names = {"Centered", "Full range", "Inverted"}

    local display_count = math.min(5, state.column_count - state.column_offset)
    for display_idx = 1, display_count do
        local col      = display_idx + state.column_offset
        local col_name = state.column_names[col] or string.format("Column %d", col)

        reaper.ImGui_PushID(ctx, col)

        -- Column header with enable checkbox and tree toggle
        local tree_label = string.format("Col %d: %s", col, col_name)
        rv, state.col_enabled[display_idx] = reaper.ImGui_Checkbox(ctx,
            "##en" .. display_idx, state.col_enabled[display_idx])
        if rv then state.preview_needs_refresh[display_idx] = true end
        reaper.ImGui_SameLine(ctx)

        state.col_tree_open[display_idx] = reaper.ImGui_TreeNode(ctx, tree_label)

        if state.col_tree_open[display_idx] then
            reaper.ImGui_Indent(ctx)

            local assignments = state.col_assignments[col]
            local to_remove   = nil

            for idx, assignment in ipairs(assignments) do
                reaper.ImGui_PushID(ctx, idx)

                -- Envelope selector
                local env_idx = env_name_to_idx(assignment.env_name) - 1
                reaper.ImGui_PushItemWidth(ctx, 110)
                rv, env_idx = reaper.ImGui_Combo(ctx, "##env", env_idx, env_combo_str)
                if rv then
                    assignment.env_name = TAKE_ENV_NAMES[env_idx + 1]
                    state.preview_needs_refresh[display_idx] = true
                end
                reaper.ImGui_PopItemWidth(ctx)

                -- Mapping
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_PushItemWidth(ctx, 100)
                rv, assignment.mapping = reaper.ImGui_Combo(ctx, "##map",
                    assignment.mapping - 1,
                    "Centered\0Full range\0Inverted\0")
                assignment.mapping = assignment.mapping + 1
                if rv then state.preview_needs_refresh[display_idx] = true end
                reaper.ImGui_PopItemWidth(ctx)

                -- Amplitude
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_PushItemWidth(ctx, 60)
                rv, assignment.amp = reaper.ImGui_SliderDouble(ctx, "##amp",
                    assignment.amp, 0.0, 1.0, "%.2f")
                if rv then state.preview_needs_refresh[display_idx] = true end
                if reaper.ImGui_IsItemHovered(ctx) then
                    reaper.ImGui_SetTooltip(ctx, "Amplitude (0-1 scale of full envelope range)")
                end
                reaper.ImGui_PopItemWidth(ctx)

                -- Offset (in normalised units -1 to 1)
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_PushItemWidth(ctx, 70)
                rv, assignment.offset = reaper.ImGui_SliderDouble(ctx, "##offset",
                    assignment.offset, -1.0, 1.0, "%.2f")
                if rv then state.preview_needs_refresh[display_idx] = true end
                if reaper.ImGui_IsItemHovered(ctx) then
                    reaper.ImGui_SetTooltip(ctx,
                        "Offset in normalised units (-1 to +1 of full envelope range)")
                end
                reaper.ImGui_PopItemWidth(ctx)

                -- Remove button
                reaper.ImGui_SameLine(ctx)
                if reaper.ImGui_Button(ctx, "X##rm", 24, 20) then
                    to_remove = idx
                end

                -- Show value range info
                local info = TAKE_ENV_INFO[assignment.env_name]
                if info then
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x888888FF)
                    reaper.ImGui_Text(ctx, string.format(
                        "    Range: %.2f – %.2f %s",
                        info.min, info.max, info.unit))
                    reaper.ImGui_PopStyleColor(ctx)
                end

                reaper.ImGui_PopID(ctx)
            end

            if to_remove then
                table.remove(state.col_assignments[col], to_remove)
            end

            -- Add assignment button
            if reaper.ImGui_Button(ctx, string.format("+ Add Take Envelope##add%d", col), -1, 25) then
                table.insert(state.col_assignments[col], {
                    env_name = "Volume",
                    mapping  = 2,
                    amp      = 1.0,
                    offset   = 0.0,
                })
                state.preview_needs_refresh[display_idx] = true
            end

            -- Preview
            reaper.ImGui_Spacing(ctx)
            if reaper.ImGui_Button(ctx, "Refresh Preview##prev" .. col, 150, 22) then
                refresh_preview(col)
            end

            if state.preview_needs_refresh[display_idx] then
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF8844FF)
                reaper.ImGui_Text(ctx, "⚠ stale")
                reaper.ImGui_PopStyleColor(ctx)
            end

            if state.preview_data[col] then
                local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
                draw_preview_graph(col, avail_w - 10, 100)
            end

            reaper.ImGui_Unindent(ctx)
            reaper.ImGui_TreePop(ctx)
        end

        reaper.ImGui_PopID(ctx)
    end

    -- ── 5. DURATION ───────────────────────────────────────────
    reaper.ImGui_SeparatorText(ctx, "5. DURATION")

    rv, state.duration_mode = reaper.ImGui_RadioButtonEx(ctx, "Item length (auto)", state.duration_mode, 1)
    reaper.ImGui_SameLine(ctx)
    rv, state.duration_mode = reaper.ImGui_RadioButtonEx(ctx, "Points/rate",        state.duration_mode, 2)
    reaper.ImGui_SameLine(ctx)
    rv, state.duration_mode = reaper.ImGui_RadioButtonEx(ctx, "Use last",           state.duration_mode, 3)

    if state.duration_mode == 1 then
        if state.item_count > 0 then
            -- Show lengths of selected items
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xAAFFAAFF)
            for i, info in ipairs(state.selected_items) do
                if i <= 4 then
                    reaper.ImGui_Text(ctx, string.format(
                        "  Item %d: %.2f s", i, info.length))
                end
            end
            if state.item_count > 4 then
                reaper.ImGui_Text(ctx, string.format("  ... (%d items)", state.item_count))
            end
            reaper.ImGui_PopStyleColor(ctx)
        else
            reaper.ImGui_TextDisabled(ctx, "  (item lengths shown after refresh)")
        end

    elseif state.duration_mode == 2 then
        reaper.ImGui_Text(ctx, "Unit:")
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushItemWidth(ctx, 100)
        rv, state.points_rate_unit = reaper.ImGui_Combo(ctx, "##unit",
            state.points_rate_unit - 1, "Seconds\0Minutes\0Hours\0")
        state.points_rate_unit = state.points_rate_unit + 1
        reaper.ImGui_PopItemWidth(ctx)

        local ul   = ({"sec","min","hr"})[state.points_rate_unit] or "sec"
        local um   = ({1,60,3600})[state.points_rate_unit] or 1
        local psets = {{1,10,30},{1,5,10},{1,2,4}}
        local pset  = psets[state.points_rate_unit] or psets[1]
        for pi, pv in ipairs(pset) do
            if pi > 1 then reaper.ImGui_SameLine(ctx) end
            if reaper.ImGui_Button(ctx, string.format("%d/%s##pp%d", pv, ul, pi), 55, 20) then
                state.points_per_second      = pv
                state.points_per_second_text = string.format("%.1f", pv)
            end
        end
        reaper.ImGui_PushItemWidth(ctx, 80)
        rv, state.points_per_second_text = reaper.ImGui_InputText(ctx, "##pps_t", state.points_per_second_text)
        if rv then
            local n = tonumber(state.points_per_second_text)
            if n and n > 0 then state.points_per_second = n end
        end
        reaper.ImGui_PopItemWidth(ctx)
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushItemWidth(ctx, -1)
        local slmax = state.points_rate_unit == 1 and 100.0
                   or state.points_rate_unit == 2 and 60.0 or 24.0
        rv, state.points_per_second = reaper.ImGui_SliderDouble(ctx,
            string.format("Points/%s##pps_s", ul),
            state.points_per_second, 0.01, slmax, "%.2f")
        if rv then state.points_per_second_text = string.format("%.2f", state.points_per_second) end
        reaper.ImGui_PopItemWidth(ctx)

        if state.data_loaded and state.row_count > 0 and state.points_per_second > 0 then
            local pps_a = state.points_per_second / um
            local eff   = state.direction == 3 and (state.row_count * 2 - 2) or state.row_count
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xAAFFAAFF)
            reaper.ImGui_Text(ctx, string.format("→ %.1f seconds total", eff / pps_a))
            reaper.ImGui_PopStyleColor(ctx)
        end

    elseif state.duration_mode == 3 then
        reaper.ImGui_Text(ctx, string.format("Last used: %.1f s", state.last_duration))
    end

    -- ── 6. DIRECTION ──────────────────────────────────────────
    reaper.ImGui_SeparatorText(ctx, "6. DIRECTION")

    local prev_dir = state.direction
    rv, state.direction = reaper.ImGui_RadioButtonEx(ctx, "Forward",    state.direction, 1)
    reaper.ImGui_SameLine(ctx)
    rv, state.direction = reaper.ImGui_RadioButtonEx(ctx, "Reverse",    state.direction, 2)
    reaper.ImGui_SameLine(ctx)
    rv, state.direction = reaper.ImGui_RadioButtonEx(ctx, "Palindrome", state.direction, 3)
    if state.direction ~= prev_dir then
        for i = 1, 5 do state.preview_needs_refresh[i] = true end
    end

    -- ── 7. OPTIONS ────────────────────────────────────────────
    reaper.ImGui_SeparatorText(ctx, "7. OPTIONS")

    rv, state.clear_existing = reaper.ImGui_Checkbox(ctx,
        "Clear existing envelope points in range before applying", state.clear_existing)
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Unchecked = merge with existing points")
    end
    
    rv, state.show_envelope_panel = reaper.ImGui_Checkbox(ctx,
        "Show take envelope panel", state.show_envelope_panel)
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Opens Reaper's Take Envelope Panel where you can enable/disable envelope visibility")
    end
    
    -- If checkbox was just ticked, open the panel
    if rv and state.show_envelope_panel then
        reaper.Main_OnCommand(41974, 0)  -- Item properties: Show take envelopes...
    end

    -- End main disabled block
    if not state.data_loaded then reaper.ImGui_EndDisabled(ctx) end

    -- ── 8. APPLY ──────────────────────────────────────────────
    reaper.ImGui_SeparatorText(ctx, "8. APPLY")

    local can_apply = state.data_loaded and state.item_count > 0
    if not can_apply then reaper.ImGui_BeginDisabled(ctx) end

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x005555FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),  0x007777FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),   0x00AAAAFF)
    if reaper.ImGui_Button(ctx, "APPLY TO SELECTED ITEMS", -1, 45) then
        local aok, aerr = pcall(apply_automation)
        if not aok then state.status_message = "Apply error: " .. tostring(aerr) end
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    if not can_apply then reaper.ImGui_EndDisabled(ctx) end

    -- ── STATUS ────────────────────────────────────────────────
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextWrapped(ctx, state.status_message)
end

-- ============================================================
-- MAIN LOOP
-- ============================================================
local function loop()
    reaper.ImGui_SetNextWindowSize(ctx, 660, 900, reaper.ImGui_Cond_FirstUseEver())
    local visible, open = reaper.ImGui_Begin(ctx, "Geomagnetic Take Automation (Audio) v3.0", true)

    if visible then
        if not state.gui_initialized then
            state.gui_initialized = true
            load_settings()
            refresh_selected_items()
        end
        local ok, err = pcall(draw_gui)
        if not ok then
            reaper.ImGui_TextWrapped(ctx, "GUI Error: " .. tostring(err))
        end
        reaper.ImGui_End(ctx)
    end

    if open then
        reaper.defer(loop)
    else
        if reaper.ImGui_DestroyContext then reaper.ImGui_DestroyContext(ctx) end
    end
end

reaper.defer(loop)
