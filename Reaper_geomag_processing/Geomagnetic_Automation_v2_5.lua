-- Geomagnetic Automation v2.5
-- Multi-column geomagnetic data to Reaper envelope automation
-- NEW in v2.5: Named preset system with dedicated folder, UK spelling (Centred)
-- FIX in v2.4: CSV parser handles datetime columns with spaces (splits only on delimiter, not spaces)
-- FIX in v2.3.1: File browser filter syntax, remembers last folder, proper file reload
-- NEW in v2.3: Overview preview panel in pre-processing section (all enabled columns at once)
-- NEW in v2.2: Pre-processing collapsible UI, Auto-refresh previews, Points/rate unit selector

local script_version = "2.5"

if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox("ReaImGui extension is required for this script.", "Missing Extension", 0)
    return
end

local ctx = reaper.ImGui_CreateContext('Geomagnetic Automation v2.5')

-- NEW v2.5: Preset system
local PRESET_FOLDER = reaper.GetResourcePath() .. "/GeomagAutomation_Presets"

-- Create preset folder if it doesn't exist
local function ensure_preset_folder()
    local info = reaper.GetOS()
    if info:match("Win") then
        os.execute('if not exist "' .. PRESET_FOLDER:gsub("/", "\\") .. '" mkdir "' .. PRESET_FOLDER:gsub("/", "\\") .. '"')
    else
        os.execute('mkdir -p "' .. PRESET_FOLDER .. '"')
    end
end

-- Simple JSON encode for our preset data
local function json_encode_preset(preset_data)
    local lines = {"{"}
    table.insert(lines, '  "name": "' .. (preset_data.name or "Unnamed") .. '",')
    table.insert(lines, '  "columns": [')
    
    for i = 1, 5 do
        local assignments = preset_data.col_assignments[i] or {}
        local col_enabled = preset_data.col_enabled[i] or false
        table.insert(lines, '    {')
        table.insert(lines, '      "enabled": ' .. tostring(col_enabled) .. ',')
        table.insert(lines, '      "assignments": [')
        
        for j, a in ipairs(assignments) do
            local comma = j < #assignments and "," or ""
            table.insert(lines, string.format('        {"name":"%s","display":"%s","mapping":%d,"amp":%g,"offset":%g}%s',
                a.name or "", a.display or "", a.mapping or 1, a.amp or 1.0, a.offset or 0.0, comma))
        end
        
        local col_comma = i < 5 and "," or ""
        table.insert(lines, '      ]')
        table.insert(lines, '    }' .. col_comma)
    end
    
    table.insert(lines, '  ]')
    table.insert(lines, '}')
    return table.concat(lines, "\n")
end

-- Simple JSON decode for our preset data
local function json_decode_preset(json_str)
    -- This is a simplified parser for our specific JSON structure
    -- For production, you'd want a proper JSON library
    local preset = {
        name = json_str:match('"name"%s*:%s*"([^"]*)"') or "Unnamed",
        col_assignments = {},
        col_enabled = {}
    }
    
    -- Parse each column
    for i = 1, 5 do
        preset.col_assignments[i] = {}
        preset.col_enabled[i] = false
    end
    
    -- Extract enabled states
    local col_idx = 0
    for enabled in json_str:gmatch('"enabled"%s*:%s*(%a+)') do
        col_idx = col_idx + 1
        if col_idx <= 5 then
            preset.col_enabled[col_idx] = (enabled == "true")
        end
    end
    
    -- Extract assignments (simplified - matches our exact format)
    col_idx = 0
    for assignments_block in json_str:gmatch('"assignments"%s*:%s*%[(.-)%]') do
        col_idx = col_idx + 1
        if col_idx <= 5 then
            for assignment in assignments_block:gmatch('{(.-)}') do
                local a = {}
                a.name = assignment:match('"name"%s*:%s*"([^"]*)"') or ""
                a.display = assignment:match('"display"%s*:%s*"([^"]*)"') or ""
                a.mapping = tonumber(assignment:match('"mapping"%s*:%s*(%d+)')) or 1
                a.amp = tonumber(assignment:match('"amp"%s*:%s*([%d%.%-]+)')) or 1.0
                a.offset = tonumber(assignment:match('"offset"%s*:%s*([%d%.%-]+)')) or 0.0
                table.insert(preset.col_assignments[col_idx], a)
            end
        end
    end
    
    return preset
end

-- List all preset files
local function list_presets()
    ensure_preset_folder()
    local presets = {}
    local i = 0
    repeat
        local file = reaper.EnumerateFiles(PRESET_FOLDER, i)
        if file and file:match("%.json$") then
            local name = file:gsub("%.json$", "")
            table.insert(presets, name)
        end
        i = i + 1
    until not file
    return presets
end

-- Save preset to file
local function save_preset(name, preset_data)
    ensure_preset_folder()
    local filepath = PRESET_FOLDER .. "/" .. name .. ".json"
    local file = io.open(filepath, "w")
    if not file then
        return false, "Could not create preset file"
    end
    preset_data.name = name
    file:write(json_encode_preset(preset_data))
    file:close()
    return true, "Preset saved: " .. name
end

-- Load preset from file
local function load_preset(name)
    local filepath = PRESET_FOLDER .. "/" .. name .. ".json"
    local file = io.open(filepath, "r")
    if not file then
        return nil, "Could not open preset file"
    end
    local content = file:read("*all")
    file:close()
    return json_decode_preset(content)
end

-- Delete preset file
local function delete_preset(name)
    local filepath = PRESET_FOLDER .. "/" .. name .. ".json"
    local ok = os.remove(filepath)
    return ok, ok and ("Deleted: " .. name) or "Could not delete preset"
end

-- State variables
local state = {
    -- Track and envelopes
    selected_track = nil,
    envelope_list = {},
    
    -- Per-column envelope assignments (now supports multiple per column)
    -- Structure: col_assignments[col_num] = { {env=envelope, name="Pan", mapping=2, amp=1.0, offset=0.0}, ... }
    col_assignments = {
        [1] = {},
        [2] = {},
        [3] = {},
        [4] = {},
        [5] = {}
    },
    
    -- UI state for collapsible sections
    col_tree_open = {true, true, true, true, true},
    
    -- Data
    data_loaded = false,
    data_cache = {},
    data_file_path = "",
    column_count = 0,
    row_count = 0,
    
    -- NEW v2.0: Column names from CSV header
    column_names = {}, -- Stores header names if detected
    has_header = false,
    
    -- NEW v2.0: Column count warning
    show_column_warning = false,
    
    -- NEW v2.1: Column navigation for >5 columns
    column_offset = 0, -- Which set of 5 columns to display (0 = cols 1-5, 1 = cols 2-6, etc.)
    
    -- Column selection
    col1_enabled = false,
    col2_enabled = false,
    col3_enabled = false,
    col4_enabled = false,
    col5_enabled = false,
    
    -- Duration
    duration_mode = 1, -- 1=New, 2=Use last, 3=Points per second
    duration = 27.0,
    duration_text = "27.0",
    last_duration = 27.0,
    start_mode = 1, -- 1=At 0.0, 2=At cursor, 3=At item
    
    -- NEW v2.1: Points per second mode
    points_per_second = 10.0,
    points_per_second_text = "10.0",
    
    -- NEW v2.0: Tempo sync mode
    tempo_sync = false,
    duration_bars = 4.0,
    duration_bars_text = "4.0",
    
    -- Direction
    direction = 1, -- 1=Forward, 2=Reverse, 3=Palindrome
    
    -- Processing mode
    process_mode = 1, -- 1=Normal, 2=Intense
    threshold = 150.0,
    comp_ratio = 4.0,
    comp_knee = 0.3,
    
    -- NEW v2.2: Pre-processing UI state
    preprocessing_expanded = false,  -- Collapsible section state
    
    -- Options
    curve_shape = 0, -- 0-6 (Quadratic removed)
    interpolation_steps = 10,
    enable_logging = false, -- Console logging
    
    -- NEW v2.2: Points/rate unit selector
    points_rate_unit = 1, -- 1=Seconds, 2=Minutes, 3=Hours
    
    -- NEW v2.0: Preview graph state
    preview_data = {}, -- Stores processed preview data per column
    preview_needs_refresh = {true, true, true, true, true},
    
    -- Status
    status_message = "Ready. Select track and load data.",
    
    -- NEW v2.5: Preset system state
    preset_list = {},
    preset_selected_idx = 0,
    preset_name_input = "",
    show_preset_save_popup = false,
    
    -- GUI initialization flag
    gui_initialized = false
}

-- ExtState for remembering file path
local EXTSTATE_SECTION = "GeomagAutomationV2_3_1"
local EXTSTATE_FILEPATH = "LastDataFile"
local EXTSTATE_SETTINGS = "LastSettings"  -- snapshot of last-used settings

local function basename(path)
    if not path or path == "" then return "" end
    local name = path:match("[^/\\]+$") or path
    return name
end

local function save_settings_snapshot()
    -- Core UI/settings (keep it simple and robust)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_duration_mode", tostring(state.duration_mode), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_duration", tostring(state.duration), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_start_mode", tostring(state.start_mode), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_direction", tostring(state.direction), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_process_mode", tostring(state.process_mode), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_threshold", tostring(state.threshold), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_comp_ratio", tostring(state.comp_ratio), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_comp_knee", tostring(state.comp_knee), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_curve_shape", tostring(state.curve_shape), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_interpolation_steps", tostring(state.interpolation_steps), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_enable_logging", tostring(state.enable_logging and 1 or 0), true)
    
    -- NEW v2.0: Tempo sync settings
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_tempo_sync", tostring(state.tempo_sync and 1 or 0), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_duration_bars", tostring(state.duration_bars), true)
    
    -- NEW v2.1: Points per second settings
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_points_per_second", tostring(state.points_per_second), true)
    
    -- NEW v2.2: UI state and unit selector
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_preprocessing_expanded", tostring(state.preprocessing_expanded and 1 or 0), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_points_rate_unit", tostring(state.points_rate_unit), true)

    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_col1_enabled", tostring(state.col1_enabled and 1 or 0), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_col2_enabled", tostring(state.col2_enabled and 1 or 0), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_col3_enabled", tostring(state.col3_enabled and 1 or 0), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_col4_enabled", tostring(state.col4_enabled and 1 or 0), true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_col5_enabled", tostring(state.col5_enabled and 1 or 0), true)

    -- Column -> envelope assignments (store display string + mapping settings; restore only if available)
    for col = 1, 5 do
        local parts = {}
        for _, a in ipairs(state.col_assignments[col] or {}) do
            local disp = a.display or a.name or ""
            local mapping = a.mapping or 1
            local amp = a.amp or 1.0
            local offset = a.offset or 0.0
            -- disp|mapping|amp|offset
            table.insert(parts, string.format("%s|%d|%g|%g", disp:gsub("[\r\n|;]", " "), mapping, amp, offset))
        end
        reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_col_assign_" .. tostring(col), table.concat(parts, ";"), true)
    end
end

local function load_settings_snapshot()
    if not reaper.HasExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_duration") then
        return false, "No saved settings yet"
    end

    local function get_num(key, default)
        local v = reaper.GetExtState(EXTSTATE_SECTION, key)
        local n = tonumber(v)
        if n == nil then return default end
        return n
    end
    local function get_bool(key, default)
        local v = reaper.GetExtState(EXTSTATE_SECTION, key)
        if v == "" then return default end
        return tonumber(v) == 1
    end

    state.duration_mode = get_num(EXTSTATE_SETTINGS .. "_duration_mode", state.duration_mode)
    state.duration = get_num(EXTSTATE_SETTINGS .. "_duration", state.duration)
    state.duration_text = tostring(state.duration)
    state.start_mode = get_num(EXTSTATE_SETTINGS .. "_start_mode", state.start_mode)
    state.direction = get_num(EXTSTATE_SETTINGS .. "_direction", state.direction)
    state.process_mode = get_num(EXTSTATE_SETTINGS .. "_process_mode", state.process_mode)
    state.threshold = get_num(EXTSTATE_SETTINGS .. "_threshold", state.threshold)
    state.comp_ratio = get_num(EXTSTATE_SETTINGS .. "_comp_ratio", state.comp_ratio)
    state.comp_knee = get_num(EXTSTATE_SETTINGS .. "_comp_knee", state.comp_knee)
    state.curve_shape = get_num(EXTSTATE_SETTINGS .. "_curve_shape", state.curve_shape)
    state.interpolation_steps = get_num(EXTSTATE_SETTINGS .. "_interpolation_steps", state.interpolation_steps)
    state.enable_logging = get_bool(EXTSTATE_SETTINGS .. "_enable_logging", state.enable_logging)
    
    -- NEW v2.0: Load tempo sync settings
    state.tempo_sync = get_bool(EXTSTATE_SETTINGS .. "_tempo_sync", state.tempo_sync)
    state.duration_bars = get_num(EXTSTATE_SETTINGS .. "_duration_bars", state.duration_bars)
    state.duration_bars_text = tostring(state.duration_bars)
    
    -- NEW v2.1: Load points per second settings
    state.points_per_second = get_num(EXTSTATE_SETTINGS .. "_points_per_second", state.points_per_second)
    state.points_per_second_text = tostring(state.points_per_second)
    
    -- NEW v2.2: Load UI state and unit selector
    state.preprocessing_expanded = get_bool(EXTSTATE_SETTINGS .. "_preprocessing_expanded", state.preprocessing_expanded)
    state.points_rate_unit = get_num(EXTSTATE_SETTINGS .. "_points_rate_unit", state.points_rate_unit)

    state.col1_enabled = get_bool(EXTSTATE_SETTINGS .. "_col1_enabled", state.col1_enabled)
    state.col2_enabled = get_bool(EXTSTATE_SETTINGS .. "_col2_enabled", state.col2_enabled)
    state.col3_enabled = get_bool(EXTSTATE_SETTINGS .. "_col3_enabled", state.col3_enabled)
    state.col4_enabled = get_bool(EXTSTATE_SETTINGS .. "_col4_enabled", state.col4_enabled)
    state.col5_enabled = get_bool(EXTSTATE_SETTINGS .. "_col5_enabled", state.col5_enabled)

    -- Restore column assignments only if we have an envelope list to match against.
    -- If no track selected yet, we'll just keep the saved strings and skip env binding.
    local env_display_to_env = {}
    for _, env_info in ipairs(state.envelope_list or {}) do
        env_display_to_env[env_info.display] = env_info
    end

    for col = 1, 5 do
        local s = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_SETTINGS .. "_col_assign_" .. tostring(col))
        local new_list = {}
        if s and s ~= "" then
            for entry in s:gmatch("([^;]+)") do
                local disp, mapping, amp, offset = entry:match("^(.-)|([^|]+)|([^|]+)|([^|]+)$")
                if disp and mapping and amp and offset then
                    local col_ok = (not state.data_loaded) or (col <= (state.column_count or 0))
                    if col_ok then
                        local env_info = env_display_to_env[disp]
                        if env_info then
                            table.insert(new_list, {
                                env = env_info.envelope,
                                name = env_info.name,
                                display = env_info.display,
                                mapping = tonumber(mapping) or 1,
                                amp = tonumber(amp) or 1.0,
                                offset = tonumber(offset) or 0.0
                            })
                        else
                            -- Envelope missing for current track/FX; skip safely.
                        end
                    end
                end
            end
        end
        state.col_assignments[col] = new_list
    end
    
    return true, "Settings restored"
end

if reaper.HasExtState(EXTSTATE_SECTION, EXTSTATE_FILEPATH) then
    state.data_file_path = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_FILEPATH)
end

-- Curve shape names (Quadratic removed)
local curve_names = {"Linear", "Square", "Slow Start/End", "Fast Start", "Fast End", "Bezier", "Sine"}

-- NEW v2.0: Load data file with header detection
-- FIX v2.4: Proper CSV parsing - splits only on delimiter (comma), not spaces
local function load_data_file(filepath)
    local file = io.open(filepath, "r")
    if not file then
        return false, "Could not open file"
    end
    
    local data = {}
    local line_num = 0
    local col_count = 0
    local header_names = {}
    local has_header = false
    local first_line = true
    local nan_count = 0
    
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
    
    if not first_content_line then
        return false, "File is empty"
    end
    
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
    if not file then
        return false, "Could not reopen file"
    end
    
    for line in file:lines() do
        line_num = line_num + 1
        if line:match("%S") then
            -- Split line by delimiter only (not by spaces!)
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
            
            -- Check first line for header (non-numeric tokens)
            if first_line and #tokens > 0 then
                local all_numeric = true
                for _, token in ipairs(tokens) do
                    if not tonumber(token) then
                        all_numeric = false
                        break
                    end
                end
                
                -- If first line has non-numeric tokens, treat as header
                if not all_numeric then
                    has_header = true
                    header_names = tokens
                    -- Don't set col_count from header - let first data row determine it
                    first_line = false
                    
                    if state.enable_logging then
                        reaper.ShowConsoleMsg(string.format("\n=== CSV Header Detected ===\n"))
                        for i, name in ipairs(header_names) do
                            reaper.ShowConsoleMsg(string.format("Column %d: %s\n", i, name))
                        end
                    end
                    
                    goto continue
                end
            end
            
            first_line = false
            
            -- Parse numeric values only (skip non-numeric columns like datetime)
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
                    return false, string.format("Line %d: %d numeric columns (expected %d)", 
                        line_num, #values, col_count)
                end
                
                table.insert(data, values)
            end
        end
        
        ::continue::
    end
    
    file:close()
    
    if #data == 0 then
        return false, "No valid data found"
    end
    
    -- If no header found, generate default names
    if not has_header then
        for i = 1, col_count do
            header_names[i] = string.format("Column %d", i)
        end
    end
    
    return true, data, col_count, #data, header_names, has_header, nan_count
end

-- Note: last used file path is remembered, but not auto-loaded.

-- Calculate column statistics
local function calc_column_stats(data, col_idx)
    local values = {}
    for i = 1, #data do
        table.insert(values, data[i][col_idx])
    end
    
    local sum = 0
    local min_val = values[1]
    local max_val = values[1]
    
    for _, v in ipairs(values) do
        sum = sum + v
        if v < min_val then min_val = v end
        if v > max_val then max_val = v end
    end
    
    local mean = sum / #values
    
    local variance = 0
    for _, v in ipairs(values) do
        variance = variance + ((v - mean) ^ 2)
    end
    local std_dev = math.sqrt(variance / #values)
    
    return {
        min = min_val,
        max = max_val,
        mean = mean,
        std_dev = std_dev,
        values = values  -- Store raw values for preview
    }
end

-- Apply curve shaping (for single value transformation)
local function apply_curve(value, curve_idx)
    if curve_idx == 0 then -- Linear
        return value
    elseif curve_idx == 1 then -- Square
        return value * value
    elseif curve_idx == 2 then -- Slow start/end (smoothstep)
        return value * value * (3 - 2 * value)
    elseif curve_idx == 3 then -- Fast start
        return 1 - (1 - value) * (1 - value)
    elseif curve_idx == 4 then -- Fast end
        return value * value
    elseif curve_idx == 5 then -- Bezier (smootherstep)
        return value * value * value * (value * (value * 6 - 15) + 10)
    elseif curve_idx == 6 then -- Sine
        return math.sin(value * math.pi / 2)
    end
    return value
end

-- Interpolate between two points using curve
local function interpolate_segment(val1, val2, curve_idx, num_steps)
    if curve_idx == 0 then
        -- Linear - no interpolation needed, just endpoints
        return {val1, val2}
    end
    
    local points = {}
    table.insert(points, val1)
    
    for step = 1, num_steps - 1 do
        local t = step / num_steps
        local curved_t = apply_curve(t, curve_idx)
        local interpolated = val1 + (val2 - val1) * curved_t
        table.insert(points, interpolated)
    end
    
    table.insert(points, val2)
    return points
end

-- Soft knee compression
local function apply_compression(value, threshold, ratio, knee)
    if value <= threshold - knee/2 then
        return value
    elseif value >= threshold + knee/2 then
        local over = value - threshold
        return threshold + (over / ratio)
    else
        local knee_start = threshold - knee/2
        local knee_end = threshold + knee/2
        local t = (value - knee_start) / knee
        
        local soft_knee = knee_start + t * knee
        local over = soft_knee - threshold
        return threshold + (over / ratio)
    end
end

-- Process column data
local function process_column_data(data, col_idx, mode, threshold_pct, comp_ratio, comp_knee, amp_limit, mapping_mode, offset)
    local stats = calc_column_stats(data, col_idx)
    local threshold_val = stats.mean + (stats.std_dev * threshold_pct / 100)
    
    local processed = {}
    local clipping_warnings = {}
    
    local mapping_names = {"Centred", "Bottom-up", "Inverted"}
    
    -- Console logging (use column name if available)
    if state.enable_logging then
        local col_name = state.column_names[col_idx] or string.format("Column %d", col_idx)
        reaper.ShowConsoleMsg(string.format("\n=== %s (%s mode, %s) ===\n", 
            col_name,
            mode == 1 and "Normal" or "Intense",
            mapping_names[mapping_mode]))
        reaper.ShowConsoleMsg(string.format("Range: %.2f to %.2f (mean: %.2f, std: %.2f)\n", 
            stats.min, stats.max, stats.mean, stats.std_dev))
        reaper.ShowConsoleMsg(string.format("Threshold: %.2f\n", threshold_val))
    end
    
    for i, row in ipairs(data) do
        local raw_value = row[col_idx]
        local value = raw_value
        
        -- Apply compression in Intense mode
        if mode == 2 then
            value = apply_compression(value, threshold_val, comp_ratio, comp_knee)
        end
        
        -- Normalize to 0-1 range based on stats
        local range = stats.max - stats.min
        local normalized = range > 0 and (value - stats.min) / range or 0.5
        
        -- Apply amplitude limit
        normalized = normalized * amp_limit
        
        -- Apply mapping mode
        local mapped
        if mapping_mode == 1 then -- Centred (-1 to +1)
            mapped = (normalized * 2) - 1
        elseif mapping_mode == 2 then -- Bottom-up (0 to +1)
            mapped = normalized
        elseif mapping_mode == 3 then -- Inverted (0 to -1)
            mapped = -normalized
        end
        
        -- Apply offset
        mapped = mapped + offset
        
        -- Clamp to valid envelope range
        if mapped < -1 then
            mapped = -1
            if not clipping_warnings[i] then
                clipping_warnings[i] = true
            end
        elseif mapped > 1 then
            mapped = 1
            if not clipping_warnings[i] then
                clipping_warnings[i] = true
            end
        end
        
        table.insert(processed, mapped)
    end
    
    local clip_count = 0
    for _ in pairs(clipping_warnings) do
        clip_count = clip_count + 1
    end
    
    if state.enable_logging and clip_count > 0 then
        reaper.ShowConsoleMsg(string.format("Clipping at %d rows\n", clip_count))
    end
    
    return processed, stats, clip_count
end

-- Refresh envelope list
local function refresh_envelope_list()
    state.envelope_list = {}
    
    if not state.selected_track then
        return
    end
    
    -- Get all envelopes on track
    local env_count = reaper.CountTrackEnvelopes(state.selected_track)
    
    for i = 0, env_count - 1 do
        local envelope = reaper.GetTrackEnvelope(state.selected_track, i)
        if envelope then
            local _, env_name = reaper.GetEnvelopeName(envelope)
            table.insert(state.envelope_list, {
                envelope = envelope,
                name = env_name,
                display = string.format("%d: %s", i + 1, env_name)
            })
        end
    end
end

-- NEW v2.0: Apply automation to envelope with tempo sync support
local function apply_to_envelope(envelope, env_name, processed_data, duration, start_pos, direction, curve_idx, interp_steps, use_tempo_sync, duration_bars)
    -- NEW v2.1: Safety check for minimum data points
    if #processed_data < 2 then
        return false, "Need at least 2 data points"
    end
    
    -- Calculate actual end time (depends on tempo sync mode)
    local end_pos
    if use_tempo_sync then
        local proj = 0
        local start_beat = reaper.TimeMap2_timeToBeats(proj, start_pos)
        local end_beat = start_beat + (duration_bars * 4) -- Assuming 4/4 time
        end_pos = reaper.TimeMap2_beatsToTime(proj, end_beat)
    else
        end_pos = start_pos + duration
    end
    
    -- NEW v2.1: Clear existing points in the target range (ignore return value - empty range is fine)
    reaper.DeleteEnvelopePointRange(envelope, start_pos - 0.001, end_pos + 0.001)
    
    -- Check if Volume envelope
    local is_volume = env_name and env_name:lower():match("volume") ~= nil
    local scaling_mode = reaper.GetEnvelopeScalingMode(envelope)
    
    -- Handle direction
    local data_to_use = {}
    if direction == 1 then -- Forward
        data_to_use = processed_data
    elseif direction == 2 then -- Reverse
        for i = #processed_data, 1, -1 do
            table.insert(data_to_use, processed_data[i])
        end
    elseif direction == 3 then -- Palindrome
        for i = 1, #processed_data do
            table.insert(data_to_use, processed_data[i])
        end
        for i = #processed_data - 1, 2, -1 do
            table.insert(data_to_use, processed_data[i])
        end
    end
    
    -- NEW v2.0: Calculate time positions (tempo sync or fixed duration)
    local time_positions = {}
    
    if use_tempo_sync then
        -- Tempo sync mode: distribute points across bars
        local proj = 0
        local start_beat = reaper.TimeMap2_timeToBeats(proj, start_pos)
        local total_beats = duration_bars * 4 -- Assuming 4/4 time
        local beats_per_segment = total_beats / (#data_to_use - 1)
        
        for i = 0, #data_to_use - 1 do
            local beat_pos = start_beat + (i * beats_per_segment)
            local time_pos = reaper.TimeMap2_beatsToTime(proj, beat_pos)
            table.insert(time_positions, time_pos)
        end
    else
        -- Fixed duration mode (original behavior)
        local time_per_segment = duration / (#data_to_use - 1)
        for i = 0, #data_to_use - 1 do
            table.insert(time_positions, start_pos + (i * time_per_segment))
        end
    end
    
    -- Apply interpolation and insert points
    for i = 1, #data_to_use - 1 do
        local val1 = data_to_use[i]
        local val2 = data_to_use[i + 1]
        
        local interpolated = interpolate_segment(val1, val2, curve_idx, interp_steps)
        
        local time_start = time_positions[i]
        local time_end = time_positions[i + 1]
        local time_span = time_end - time_start
        
        for j = 1, #interpolated - 1 do
            local t = (j - 1) / (#interpolated - 1)
            local point_time = time_start + (t * time_span)
            local value = interpolated[j]
            
            -- Volume envelope scaling
            if is_volume and value >= 0 and scaling_mode == 1 then
                if value == 0 then
                    value = 0
                else
                    value = reaper.ScaleToEnvelopeMode(1, value)
                end
            end
            
            reaper.InsertEnvelopePoint(envelope, point_time, value, 0, 0, false, true)
        end
    end
    
    -- Insert final point
    local final_value = data_to_use[#data_to_use]
    if is_volume and final_value >= 0 and scaling_mode == 1 then
        if final_value == 0 then
            final_value = 0
        else
            final_value = reaper.ScaleToEnvelopeMode(1, final_value)
        end
    end
    
    reaper.InsertEnvelopePoint(envelope, time_positions[#time_positions], final_value, 0, 0, false, true)
    reaper.Envelope_SortPoints(envelope)
    
    return true
end

-- Apply automation
local function apply_automation()
    if not state.data_loaded then
        state.status_message = "No data loaded"
        return
    end
    
    -- NEW v2.1: Determine actual duration to use based on mode
    local duration_to_use
    if state.duration_mode == 1 then
        -- Fixed duration mode
        duration_to_use = state.duration
        state.last_duration = duration_to_use
    elseif state.duration_mode == 2 then
        -- Use last duration
        duration_to_use = state.last_duration
    elseif state.duration_mode == 3 then
        -- NEW v2.2: Points per rate mode - calculate duration from row count with unit conversion
        if state.points_per_second > 0 and state.row_count > 0 then
            -- Convert points/unit to points/second
            local unit_multipliers = {1, 60, 3600}  -- Seconds, Minutes, Hours
            local unit_mult = unit_multipliers[state.points_rate_unit] or 1
            local points_per_sec_actual = state.points_per_second / unit_mult
            
            duration_to_use = state.row_count / points_per_sec_actual
            state.last_duration = duration_to_use
        else
            state.status_message = "Invalid points per rate value"
            return
        end
    end
    
    -- Determine start position
    local start_pos = 0.0
    if state.start_mode == 2 then
        start_pos = reaper.GetCursorPosition()
    elseif state.start_mode == 3 then
        local item = reaper.GetSelectedMediaItem(0, 0)
        if item then
            start_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        else
            state.status_message = "No item selected"
            return
        end
    end
    
    -- Count enabled columns
    local enabled_cols = {}
    local col_enabled = {state.col1_enabled, state.col2_enabled, state.col3_enabled, state.col4_enabled, state.col5_enabled}
    for i = 1, math.min(5, state.column_count) do
        if col_enabled[i] then
            table.insert(enabled_cols, i)
        end
    end
    
    if #enabled_cols == 0 then
        state.status_message = "No columns enabled"
        return
    end
    
    reaper.Undo_BeginBlock()
    
    local success_count = 0
    local error_messages = {}
    
    for _, col in ipairs(enabled_cols) do
        local assignments = state.col_assignments[col]
        
        if #assignments == 0 then
            table.insert(error_messages, string.format("Column %d: No envelope assigned", col))
        else
            for _, assignment in ipairs(assignments) do
                local processed_data, stats, clip_count = process_column_data(
                    state.data_cache, 
                    col,
                    state.process_mode,
                    state.threshold,
                    state.comp_ratio,
                    state.comp_knee,
                    assignment.amp,
                    assignment.mapping,
                    assignment.offset
                )
                
                -- NEW v2.0: Pass tempo sync parameters
                local success, err = apply_to_envelope(
                    assignment.env,
                    assignment.name,
                    processed_data,
                    duration_to_use,
                    start_pos,
                    state.direction,
                    state.curve_shape,
                    state.interpolation_steps,
                    state.tempo_sync,
                    state.duration_bars
                )
                
                if success then
                    success_count = success_count + 1
                else
                    table.insert(error_messages, string.format("Column %d (%s): %s", col, assignment.name, err or "Unknown error"))
                end
            end
        end
    end
    
    reaper.Undo_EndBlock("Geomagnetic Automation", -1)
    reaper.UpdateArrange()
    
    if success_count > 0 then
        state.status_message = string.format("Applied to %d envelope(s)", success_count)
        if #error_messages > 0 then
            state.status_message = state.status_message .. "\nErrors: " .. table.concat(error_messages, "; ")
        end
    else
        state.status_message = "Failed: " .. table.concat(error_messages, "; ")
    end
    
    save_settings_snapshot()
end

-- NEW v2.0: Refresh preview data for a column
local function refresh_preview(col)
    if not state.data_loaded or col > state.column_count then
        return
    end
    
    -- Get the first assignment for this column (or use default settings)
    local assignment = state.col_assignments[col][1]
    local mapping_mode = assignment and assignment.mapping or 2
    local amp = assignment and assignment.amp or 1.0
    local offset = assignment and assignment.offset or 0.0
    
    -- Process data with current settings
    local processed_data, stats = process_column_data(
        state.data_cache,
        col,
        state.process_mode,
        state.threshold,
        state.comp_ratio,
        state.comp_knee,
        amp,
        mapping_mode,
        offset
    )
    
    -- Store both raw and processed for visualization
    state.preview_data[col] = {
        raw = stats.values,
        processed = processed_data,
        stats = stats
    }
    
    state.preview_needs_refresh[col] = false
end

-- NEW v2.0: Draw preview graph for a column
local function draw_preview_graph(col, width, height)
    if not state.preview_data[col] then
        return
    end
    
    local preview = state.preview_data[col]
    if not preview.raw or #preview.raw == 0 then
        return
    end
    
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)
    
    -- Background
    reaper.ImGui_DrawList_AddRectFilled(draw_list, cursor_x, cursor_y, cursor_x + width, cursor_y + height, 0x222222FF)
    
    -- Calculate scaling
    local raw_min, raw_max = preview.stats.min, preview.stats.max
    local raw_range = raw_max - raw_min
    if raw_range == 0 then raw_range = 1 end
    
    -- Draw raw data (dimmed gray) using line segments instead of polyline
    if #preview.raw >= 2 then
        for i = 1, #preview.raw - 1 do
            local val1 = preview.raw[i]
            local val2 = preview.raw[i + 1]
            
            local x1 = cursor_x + ((i - 1) / (#preview.raw - 1)) * width
            local normalized1 = (val1 - raw_min) / raw_range
            local y1 = cursor_y + height - (normalized1 * height)
            
            local x2 = cursor_x + (i / (#preview.raw - 1)) * width
            local normalized2 = (val2 - raw_min) / raw_range
            local y2 = cursor_y + height - (normalized2 * height)
            
            reaper.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, 0x666666FF, 1.5)
        end
    end
    
    -- Draw processed data (bright cyan) using line segments
    if #preview.processed >= 2 then
        for i = 1, #preview.processed - 1 do
            local val1 = preview.processed[i]
            local val2 = preview.processed[i + 1]
            
            local x1 = cursor_x + ((i - 1) / (#preview.processed - 1)) * width
            -- Processed values are in -1 to 1 range, need to map to 0-1 for display
            local normalized1 = (val1 + 1) / 2
            local y1 = cursor_y + height - (normalized1 * height)
            
            local x2 = cursor_x + (i / (#preview.processed - 1)) * width
            local normalized2 = (val2 + 1) / 2
            local y2 = cursor_y + height - (normalized2 * height)
            
            reaper.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, 0x00FFFFFF, 2.0)
        end
    end
    
    -- Border
    reaper.ImGui_DrawList_AddRect(draw_list, cursor_x, cursor_y, cursor_x + width, cursor_y + height, 0x444444FF)
    
    -- Labels
    reaper.ImGui_Dummy(ctx, width, height)
    
    -- Legend (small text below)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x666666FF)
    reaper.ImGui_Text(ctx, "Gray: Raw data")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x00FFFFFF)
    reaper.ImGui_Text(ctx, "Cyan: Processed")
    reaper.ImGui_PopStyleColor(ctx)
end

-- GUI drawing
local function draw_gui()
    -- 1. TRACK SELECTION
    reaper.ImGui_SeparatorText(ctx, "1. TRACK SELECTION")
    
    local track = reaper.GetSelectedTrack(0, 0)
    if track and track ~= state.selected_track then
        state.selected_track = track
        refresh_envelope_list()
        
        local _, track_name = reaper.GetTrackName(track)
        state.status_message = string.format("Track selected: %s", track_name)
    end
    
    if state.selected_track then
        local _, track_name = reaper.GetTrackName(state.selected_track)
        reaper.ImGui_Text(ctx, string.format("Track: %s", track_name))
    else
        reaper.ImGui_TextDisabled(ctx, "No track selected")
    end
    
    -- 2. DATA FILE
    reaper.ImGui_SeparatorText(ctx, "2. DATA FILE")
    
    reaper.ImGui_Text(ctx, "File: " .. (state.data_file_path ~= "" and basename(state.data_file_path) or "None"))
    
    if reaper.ImGui_Button(ctx, "Load Data File", 120, 25) then
        -- Get last used folder or empty string
        local last_folder = reaper.GetExtState(EXTSTATE_SECTION, "LastFolder")
        local rv, filepath = reaper.GetUserFileNameForRead(last_folder, "Load Data File", "*.csv;*.txt")
        if rv then
            -- Save the folder for next time
            local folder = filepath:match("(.*/)")
            if folder then
                reaper.SetExtState(EXTSTATE_SECTION, "LastFolder", folder, true)
            end
            
            local success, data, col_count, row_count, column_names, has_header, nan_count = load_data_file(filepath)
            if success then
                state.data_cache = data
                state.column_count = col_count
                state.row_count = row_count
                state.column_names = column_names
                state.has_header = has_header
                state.data_loaded = true
                state.data_file_path = filepath
                
                -- Reset column offset when loading new file
                state.column_offset = 0
                
                -- NEW v2.0: Check for column count warning
                state.show_column_warning = (col_count > 5)
                
                -- Mark all previews for refresh
                for i = 1, 5 do
                    state.preview_needs_refresh[i] = true
                end
                
                reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_FILEPATH, filepath, true)
                
                local header_info = has_header and " (with headers)" or ""
                local nan_warning = ""
                if nan_count and nan_count > 0 then
                    nan_warning = string.format(" | ⚠ %d NaN values converted to 0 - consider cleaning in Python", nan_count)
                end
                state.status_message = string.format("Loaded: %d rows, %d columns%s%s", row_count, col_count, header_info, nan_warning)
            else
                state.status_message = "Load failed: " .. data
            end
        end
    end
    
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Reload", 80, 25) then
        if state.data_file_path and state.data_file_path ~= "" then
            local success, data, col_count, row_count, column_names, has_header, nan_count = load_data_file(state.data_file_path)
            if success then
                state.data_cache = data
                state.column_count = col_count
                state.row_count = row_count
                state.column_names = column_names
                state.has_header = has_header
                state.data_loaded = true
                
                state.show_column_warning = (col_count > 5)
                
                for i = 1, 5 do
                    state.preview_needs_refresh[i] = true
                end
                
                local header_info = has_header and " (with headers)" or ""
                local nan_warning = ""
                if nan_count and nan_count > 0 then
                    nan_warning = string.format(" | ⚠ %d NaN values converted to 0 - consider cleaning in Python", nan_count)
                end
                state.status_message = string.format("Reloaded: %d rows, %d columns%s%s", row_count, col_count, header_info, nan_warning)
            else
                state.status_message = "Reload failed: " .. data
            end
        end
    end
    
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Save Settings", 120, 25) then
        save_settings_snapshot()
        state.status_message = "Settings saved"
    end
    
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Load Settings", 120, 25) then
        local ok, msg = load_settings_snapshot()
        state.status_message = msg
    end
    
    -- NEW v2.5: Named Presets
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, "Named Presets:")
    
    -- Refresh preset list if needed
    if not state.gui_initialized or reaper.ImGui_IsWindowAppearing(ctx) then
        state.preset_list = list_presets()
    end
    
    -- Preset dropdown
    reaper.ImGui_PushItemWidth(ctx, 200)
    local preset_combo = table.concat(state.preset_list, "\0") .. "\0"
    if #state.preset_list == 0 then
        preset_combo = "(No presets)\0"
    end
    local rv, new_idx = reaper.ImGui_Combo(ctx, "##preset", state.preset_selected_idx, preset_combo)
    if rv then
        state.preset_selected_idx = new_idx
    end
    reaper.ImGui_PopItemWidth(ctx)
    
    -- Load preset button
    reaper.ImGui_SameLine(ctx)
    local can_load = #state.preset_list > 0
    if not can_load then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Load Preset", 90, 25) then
        local preset_name = state.preset_list[state.preset_selected_idx + 1]
        if preset_name then
            local preset = load_preset(preset_name)
            if preset then
                -- Apply preset to state - rebuild envelope references
                for i = 1, 5 do
                    state.col_assignments[i] = {}
                    
                    -- Rebuild envelope references by matching names
                    for _, preset_assignment in ipairs(preset.col_assignments[i] or {}) do
                        -- Find matching envelope in current track's envelope list
                        local found_env = nil
                        for _, env_info in ipairs(state.envelope_list) do
                            if env_info.name == preset_assignment.name then
                                found_env = env_info.envelope
                                break
                            end
                        end
                        
                        if found_env then
                            table.insert(state.col_assignments[i], {
                                env = found_env,
                                name = preset_assignment.name,
                                display = preset_assignment.display,
                                mapping = preset_assignment.mapping,
                                amp = preset_assignment.amp,
                                offset = preset_assignment.offset
                            })
                        end
                    end
                    
                    if i == 1 then state.col1_enabled = preset.col_enabled[i]
                    elseif i == 2 then state.col2_enabled = preset.col_enabled[i]
                    elseif i == 3 then state.col3_enabled = preset.col_enabled[i]
                    elseif i == 4 then state.col4_enabled = preset.col_enabled[i]
                    elseif i == 5 then state.col5_enabled = preset.col_enabled[i]
                    end
                    state.preview_needs_refresh[i] = true
                end
                state.status_message = "✓ Loaded preset: " .. preset_name
            else
                state.status_message = "❌ Failed to load preset"
            end
        end
    end
    if not can_load then reaper.ImGui_EndDisabled(ctx) end
    
    -- Save preset button
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Save As...", 90, 25) then
        state.show_preset_save_popup = true
        state.preset_name_input = ""
    end
    
    -- Delete preset button
    reaper.ImGui_SameLine(ctx)
    if not can_load then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Delete", 70, 25) then
        local preset_name = state.preset_list[state.preset_selected_idx + 1]
        if preset_name then
            local ok, msg = delete_preset(preset_name)
            state.preset_list = list_presets()
            state.preset_selected_idx = 0
            state.status_message = msg
        end
    end
    if not can_load then reaper.ImGui_EndDisabled(ctx) end
    
    -- Save preset popup
    if state.show_preset_save_popup then
        reaper.ImGui_OpenPopup(ctx, "Save Preset")
    end
    
    if reaper.ImGui_BeginPopupModal(ctx, "Save Preset", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        reaper.ImGui_Text(ctx, "Preset name:")
        reaper.ImGui_PushItemWidth(ctx, 250)
        local rv, new_text = reaper.ImGui_InputText(ctx, "##preset_name", state.preset_name_input)
        if rv then
            state.preset_name_input = new_text
        end
        reaper.ImGui_PopItemWidth(ctx)
        
        reaper.ImGui_Spacing(ctx)
        
        local can_save = state.preset_name_input ~= ""
        if not can_save then reaper.ImGui_BeginDisabled(ctx) end
        if reaper.ImGui_Button(ctx, "Save", 100, 25) then
            -- Gather current state - only save serializable fields
            local preset_data = {
                col_assignments = {},
                col_enabled = {}
            }
            for i = 1, 5 do
                preset_data.col_assignments[i] = {}
                -- Copy only serializable fields (NOT the envelope object!)
                for _, a in ipairs(state.col_assignments[i] or {}) do
                    table.insert(preset_data.col_assignments[i], {
                        name = a.name or "",
                        display = a.display or "",
                        mapping = a.mapping or 1,
                        amp = a.amp or 1.0,
                        offset = a.offset or 0.0
                    })
                end
                
                if i == 1 then preset_data.col_enabled[i] = state.col1_enabled
                elseif i == 2 then preset_data.col_enabled[i] = state.col2_enabled
                elseif i == 3 then preset_data.col_enabled[i] = state.col3_enabled
                elseif i == 4 then preset_data.col_enabled[i] = state.col4_enabled
                elseif i == 5 then preset_data.col_enabled[i] = state.col5_enabled
                end
            end
            
            local ok, msg = save_preset(state.preset_name_input, preset_data)
            state.preset_list = list_presets()
            state.status_message = msg
            state.show_preset_save_popup = false
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        if not can_save then reaper.ImGui_EndDisabled(ctx) end
        
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Cancel", 100, 25) then
            state.show_preset_save_popup = false
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        
        reaper.ImGui_EndPopup(ctx)
    end
    
    reaper.ImGui_Separator(ctx)
    
    -- NEW v2.2: Pre-processing collapsible button
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_Dummy(ctx, 20, 0)  -- Spacer
    reaper.ImGui_SameLine(ctx)
    
    local mode_label = state.process_mode == 1 and "Normal" or "Intense"
    local button_label = string.format("Pre-processing: %s %s", mode_label, state.preprocessing_expanded and "▲" or "▼")
    
    if reaper.ImGui_Button(ctx, button_label, 180, 25) then
        state.preprocessing_expanded = not state.preprocessing_expanded
    end
    
    -- Draw pre-processing controls if expanded
    if state.preprocessing_expanded then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Indent(ctx, 10)
        
        -- Mode selection
        local prev_mode = state.process_mode
        rv, state.process_mode = reaper.ImGui_RadioButtonEx(ctx, "Normal", state.process_mode, 1)
        reaper.ImGui_SameLine(ctx)
        rv, state.process_mode = reaper.ImGui_RadioButtonEx(ctx, "Intense", state.process_mode, 2)
        
        -- NEW v2.2: Auto-refresh previews when mode changes
        if state.process_mode ~= prev_mode then
            -- Mark all previews for refresh
            for i = 1, 5 do
                state.preview_needs_refresh[i] = true
            end
            -- Also refresh all visible columns immediately for overview panel
            local display_count = math.min(5, state.column_count - state.column_offset)
            for display_idx = 1, display_count do
                local col = display_idx + state.column_offset
                if state.data_loaded and col <= state.column_count then
                    refresh_preview(col)
                end
            end
        end
        
        -- Threshold slider (available for both modes)
        rv, state.threshold = reaper.ImGui_SliderDouble(ctx, "Threshold %", state.threshold, 0, 300, "%.0f")
        if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
            -- NEW v2.2: Refresh on slider release
            for i = 1, 5 do
                state.preview_needs_refresh[i] = true
            end
            -- NEW v2.3: Also refresh for overview panel
            local display_count = math.min(5, state.column_count - state.column_offset)
            for display_idx = 1, display_count do
                local col = display_idx + state.column_offset
                if state.data_loaded and col <= state.column_count then
                    refresh_preview(col)
                end
            end
        end
        
        -- Comp controls (only for Intense mode)
        if state.process_mode == 2 then
            rv, state.comp_ratio = reaper.ImGui_SliderDouble(ctx, "Comp Ratio", state.comp_ratio, 1.0, 20.0, "%.1f:1")
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                for i = 1, 5 do
                    state.preview_needs_refresh[i] = true
                end
                -- NEW v2.3: Also refresh for overview panel
                local display_count = math.min(5, state.column_count - state.column_offset)
                for display_idx = 1, display_count do
                    local col = display_idx + state.column_offset
                    if state.data_loaded and col <= state.column_count then
                        refresh_preview(col)
                    end
                end
            end
            
            rv, state.comp_knee = reaper.ImGui_SliderDouble(ctx, "Knee", state.comp_knee, 0.0, 1.0, "%.2f")
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
                for i = 1, 5 do
                    state.preview_needs_refresh[i] = true
                end
                -- NEW v2.3: Also refresh for overview panel
                local display_count = math.min(5, state.column_count - state.column_offset)
                for display_idx = 1, display_count do
                    local col = display_idx + state.column_offset
                    if state.data_loaded and col <= state.column_count then
                        refresh_preview(col)
                    end
                end
            end
        end
        
        -- NEW v2.3: Overview preview panel showing all enabled columns
        if state.data_loaded then
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Spacing(ctx)
            
            reaper.ImGui_Text(ctx, "📊 Preview (all enabled columns):")
            
            -- Check which columns are enabled
            local col_enabled = {state.col1_enabled, state.col2_enabled, state.col3_enabled, state.col4_enabled, state.col5_enabled}
            local enabled_cols = {}
            
            -- Calculate which columns to show based on offset
            local display_count = math.min(5, state.column_count - state.column_offset)
            for display_idx = 1, display_count do
                if col_enabled[display_idx] then
                    local col = display_idx + state.column_offset
                    table.insert(enabled_cols, col)
                end
            end
            
            if #enabled_cols > 0 then
                -- Draw compact preview graphs stacked vertically at full width
                local avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
                local graph_width = avail_width - 10  -- Full width with small margin
                local graph_height = 80  -- Compact height for overview
                
                for i, col in ipairs(enabled_cols) do
                    -- Ensure preview data exists
                    if not state.preview_data[col] or state.preview_needs_refresh[col] then
                        refresh_preview(col)
                    end
                    
                    if state.preview_data[col] then
                        -- Column label above graph
                        local col_label = state.column_names[col] or string.format("Col %d", col)
                        reaper.ImGui_Text(ctx, col_label)
                        
                        -- Draw compact preview at full width
                        draw_preview_graph(col, graph_width, graph_height)
                        
                        -- Add spacing between graphs (except after last one)
                        if i < #enabled_cols then
                            reaper.ImGui_Spacing(ctx)
                        end
                    end
                end
            else
                reaper.ImGui_TextDisabled(ctx, "No columns enabled - check column boxes below")
            end
        else
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_TextDisabled(ctx, "Load data to see preview")
        end
        
        reaper.ImGui_Unindent(ctx, 10)
        reaper.ImGui_Spacing(ctx)
    end
    
    -- NEW v2.0: Column count warning
    if state.show_column_warning then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF8800FF)
        reaper.ImGui_TextWrapped(ctx, string.format("⚠ Warning: %d columns detected. Preview graphs may impact performance.", state.column_count))
        reaper.ImGui_PopStyleColor(ctx)
    end
    
    if state.data_loaded then
        reaper.ImGui_Text(ctx, string.format("%d rows × %d columns", state.row_count, state.column_count))
        
        -- NEW v2.1: Column navigation arrows (only if >5 columns)
        if state.column_count > 5 then
            local max_offset = state.column_count - 5
            local start_col = state.column_offset + 1
            local end_col = math.min(state.column_offset + 5, state.column_count)
            
            reaper.ImGui_Text(ctx, string.format("Columns %d-%d of %d", start_col, end_col, state.column_count))
            reaper.ImGui_SameLine(ctx)
            
            -- Left arrow (disabled if at start)
            if state.column_offset > 0 then
                if reaper.ImGui_Button(ctx, "◄##col_prev", 30, 20) then
                    state.column_offset = state.column_offset - 1
                end
            else
                reaper.ImGui_BeginDisabled(ctx)
                reaper.ImGui_Button(ctx, "◄##col_prev", 30, 20)
                reaper.ImGui_EndDisabled(ctx)
            end
            
            reaper.ImGui_SameLine(ctx)
            
            -- Right arrow (disabled if at end)
            if state.column_offset < max_offset then
                if reaper.ImGui_Button(ctx, "►##col_next", 30, 20) then
                    state.column_offset = state.column_offset + 1
                end
            else
                reaper.ImGui_BeginDisabled(ctx)
                reaper.ImGui_Button(ctx, "►##col_next", 30, 20)
                reaper.ImGui_EndDisabled(ctx)
            end
        end
    end
    
    -- Column selection and envelope assignment
    if not state.data_loaded then
        reaper.ImGui_BeginDisabled(ctx)
    end
    
    local col_enabled = {state.col1_enabled, state.col2_enabled, state.col3_enabled, state.col4_enabled, state.col5_enabled}
    
    -- NEW v2.1: Calculate which columns to display based on offset
    local display_count = math.min(5, state.column_count - state.column_offset)
    
    for display_idx = 1, display_count do
        local col = display_idx + state.column_offset  -- Actual column index in data
        reaper.ImGui_PushID(ctx, string.format("col%d", col))
        
        -- NEW v2.0: Use column name from header if available
        local col_label = state.column_names[col] or string.format("Column %d", col)
        
        -- Checkbox OUTSIDE the collapsing header
        local rv
        rv, col_enabled[display_idx] = reaper.ImGui_Checkbox(ctx, "##enable", col_enabled[display_idx])
        if rv then
            if display_idx == 1 then state.col1_enabled = col_enabled[display_idx]
            elseif display_idx == 2 then state.col2_enabled = col_enabled[display_idx]
            elseif display_idx == 3 then state.col3_enabled = col_enabled[display_idx]
            elseif display_idx == 4 then state.col4_enabled = col_enabled[display_idx]
            elseif display_idx == 5 then state.col5_enabled = col_enabled[display_idx]
            end
        end
        
        reaper.ImGui_SameLine(ctx)
        
        -- Collapsing header
        local tree_open = reaper.ImGui_CollapsingHeader(ctx, col_label)
        
        if tree_open then
            reaper.ImGui_Indent(ctx)
            
            -- Show assigned envelopes
            if #state.col_assignments[col] > 0 then
                local to_remove = nil
                
                for idx, assignment in ipairs(state.col_assignments[col]) do
                    reaper.ImGui_PushID(ctx, idx)
                    
                    -- Envelope selector
                    local current_idx = 1
                    for i, env_info in ipairs(state.envelope_list) do
                        if env_info.envelope == assignment.env then
                            current_idx = i
                            break
                        end
                    end
                    
                    -- Build combo items string
                    local combo_items = {}
                    for i, env_info in ipairs(state.envelope_list) do
                        table.insert(combo_items, env_info.display)
                    end
                    local combo_str = table.concat(combo_items, "\0") .. "\0"
                    
                    reaper.ImGui_PushItemWidth(ctx, 180)
                    rv, current_idx = reaper.ImGui_Combo(ctx, "##env", current_idx - 1, combo_str)
                    if rv then
                        assignment.env = state.envelope_list[current_idx + 1].envelope
                        assignment.name = state.envelope_list[current_idx + 1].name
                        assignment.display = state.envelope_list[current_idx + 1].display
                    end
                    reaper.ImGui_PopItemWidth(ctx)
                    
                    -- Mapping mode
                    reaper.ImGui_SameLine(ctx)
                    reaper.ImGui_PushItemWidth(ctx, 100)
                    rv, assignment.mapping = reaper.ImGui_Combo(ctx, "##map", assignment.mapping - 1, "Centred\0Bottom-up\0Inverted\0")
                    assignment.mapping = assignment.mapping + 1
                    if rv then
                        state.preview_needs_refresh[col] = true
                    end
                    reaper.ImGui_PopItemWidth(ctx)
                    
                    -- Amplitude
                    reaper.ImGui_SameLine(ctx)
                    reaper.ImGui_PushItemWidth(ctx, 60)
                    rv, assignment.amp = reaper.ImGui_SliderDouble(ctx, "##amp", assignment.amp, 0.0, 1.0, "%.2f")
                    if rv then
                        state.preview_needs_refresh[col] = true
                    end
                    if reaper.ImGui_IsItemHovered(ctx) then
                        reaper.ImGui_SetTooltip(ctx, "Amplitude: Scale the automation range (0.0-1.0)")
                    end
                    reaper.ImGui_PopItemWidth(ctx)
                    
                    -- Offset
                    reaper.ImGui_SameLine(ctx)
                    reaper.ImGui_PushItemWidth(ctx, 80)
                    rv, assignment.offset = reaper.ImGui_SliderDouble(ctx, "##offset", assignment.offset, -1.0, 1.0, "%.2f")
                    if rv then
                        state.preview_needs_refresh[col] = true
                    end
                    if reaper.ImGui_IsItemHovered(ctx) then
                        reaper.ImGui_SetTooltip(ctx, "Offset: Shift envelope values up/down")
                    end
                    reaper.ImGui_PopItemWidth(ctx)
                    
                    -- Remove button
                    reaper.ImGui_SameLine(ctx)
                    if reaper.ImGui_Button(ctx, "X##remove", 25, 20) then
                        to_remove = idx
                    end
                    if reaper.ImGui_IsItemHovered(ctx) then
                        reaper.ImGui_SetTooltip(ctx, "De-select env")
                    end
                    
                    reaper.ImGui_PopID(ctx)
                end
                
                -- Remove marked assignment
                if to_remove then
                    table.remove(state.col_assignments[col], to_remove)
                end
                
                -- Add envelope button
                if #state.envelope_list > 0 then
                    if reaper.ImGui_Button(ctx, string.format("+ Add Envelope##add%d", col), -1, 25) then
                        table.insert(state.col_assignments[col], {
                            env = state.envelope_list[1].envelope,
                            name = state.envelope_list[1].name,
                            display = state.envelope_list[1].display,
                            mapping = 2, -- Bottom-up default
                            amp = 1.0,
                            offset = 0.0
                        })
                    end
                else
                    reaper.ImGui_TextDisabled(ctx, "No envelopes available - refresh list")
                end
            else
                -- No assignments yet
                if #state.envelope_list > 0 then
                    if reaper.ImGui_Button(ctx, string.format("+ Add Envelope##add%d", col), -1, 25) then
                        table.insert(state.col_assignments[col], {
                            env = state.envelope_list[1].envelope,
                            name = state.envelope_list[1].name,
                            display = state.envelope_list[1].display,
                            mapping = 2,
                            amp = 1.0,
                            offset = 0.0
                        })
                    end
                else
                    reaper.ImGui_TextDisabled(ctx, "No envelopes available - refresh list")
                end
            end
            
            -- NEW v2.0: Preview graph
            reaper.ImGui_Spacing(ctx)
            if reaper.ImGui_Button(ctx, "Refresh Preview", 150, 25) then
                refresh_preview(col)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, "Update preview with current intensity/threshold settings")
            end
            
            reaper.ImGui_Spacing(ctx)
            
            -- Draw preview if data exists
            if state.preview_data[col] then
                local avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
                draw_preview_graph(col, avail_width, 150)
            elseif state.preview_needs_refresh[col] then
                reaper.ImGui_TextDisabled(ctx, "Click 'Refresh Preview' to visualize data")
            end
            
            reaper.ImGui_Unindent(ctx)
        end
        
        reaper.ImGui_PopID(ctx)
    end
    
    if not state.data_loaded then
        reaper.ImGui_EndDisabled(ctx)
    end
    
    -- Refresh envelopes button
    if reaper.ImGui_Button(ctx, "Refresh Envelope List", -1, 25) then
        refresh_envelope_list()
        if #state.envelope_list > 0 then
            state.status_message = string.format("Found %d envelope(s)", #state.envelope_list)
        else
            state.status_message = "No envelopes available"
        end
    end
    
    -- 3. DURATION
    reaper.ImGui_SeparatorText(ctx, "3. DURATION")
    
    -- NEW v2.0: Tempo sync toggle
    local rv
    rv, state.tempo_sync = reaper.ImGui_Checkbox(ctx, "Tempo Sync", state.tempo_sync)
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Sync automation to project tempo (bars) instead of fixed time")
    end
    
    if state.tempo_sync then
        -- Bars mode
        reaper.ImGui_PushItemWidth(ctx, 100)
        rv, state.duration_bars_text = reaper.ImGui_InputText(ctx, "##bars", state.duration_bars_text)
        if rv then
            local num = tonumber(state.duration_bars_text)
            if num and num > 0 then
                state.duration_bars = num
            end
        end
        reaper.ImGui_PopItemWidth(ctx)
        
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushItemWidth(ctx, -120)
        rv, state.duration_bars = reaper.ImGui_SliderDouble(ctx, "Bars", state.duration_bars, 0.25, 32.0, "%.2f")
        if rv then
            state.duration_bars_text = string.format("%.2f", state.duration_bars)
        end
        reaper.ImGui_PopItemWidth(ctx)
    else
        -- Seconds mode with NEW v2.1: Points per second option
        rv, state.duration_mode = reaper.ImGui_RadioButtonEx(ctx, "Fixed duration", state.duration_mode, 1)
        reaper.ImGui_SameLine(ctx)
        rv, state.duration_mode = reaper.ImGui_RadioButtonEx(ctx, "Use last", state.duration_mode, 2)
        reaper.ImGui_SameLine(ctx)
        rv, state.duration_mode = reaper.ImGui_RadioButtonEx(ctx, "Points/sec", state.duration_mode, 3)
        
        if state.duration_mode == 1 then
            -- Fixed duration mode
            reaper.ImGui_PushItemWidth(ctx, 100)
            rv, state.duration_text = reaper.ImGui_InputText(ctx, "##dur", state.duration_text)
            if rv then
                local num = tonumber(state.duration_text)
                if num and num > 0 then
                    state.duration = num
                end
            end
            reaper.ImGui_PopItemWidth(ctx)
            
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, -120)
            rv, state.duration = reaper.ImGui_SliderDouble(ctx, "Duration (s)", state.duration, 0.1, 300.0, "%.1f")
            if rv then
                state.duration_text = string.format("%.1f", state.duration)
            end
            reaper.ImGui_PopItemWidth(ctx)
        elseif state.duration_mode == 2 then
            -- Use last duration
            reaper.ImGui_Text(ctx, string.format("Last: %.1fs", state.last_duration))
        elseif state.duration_mode == 3 then
            -- NEW v2.2: Points per rate mode with unit selector
            
            -- Unit selector
            reaper.ImGui_Text(ctx, "Unit:")
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 100)
            rv, state.points_rate_unit = reaper.ImGui_Combo(ctx, "##unit", state.points_rate_unit - 1, "Seconds\0Minutes\0Hours\0")
            state.points_rate_unit = state.points_rate_unit + 1
            reaper.ImGui_PopItemWidth(ctx)
            
            -- Unit labels for display
            local unit_labels = {"sec", "min", "hr"}
            local unit_label = unit_labels[state.points_rate_unit] or "sec"
            local unit_multipliers = {1, 60, 3600}  -- Convert to seconds
            local unit_mult = unit_multipliers[state.points_rate_unit] or 1
            
            -- Quick preset buttons (adapt to unit)
            local presets = {
                {1, 10, 30},      -- Seconds: 1/sec, 10/sec, 30/sec
                {1, 5, 10},       -- Minutes: 1/min, 5/min, 10/min
                {1, 2, 4}         -- Hours: 1/hr, 2/hr, 4/hr
            }
            local preset_set = presets[state.points_rate_unit] or presets[1]
            
            if reaper.ImGui_Button(ctx, string.format("%d/%s##pps1", preset_set[1], unit_label), 60, 20) then
                state.points_per_second = preset_set[1]
                state.points_per_second_text = string.format("%.1f", preset_set[1])
            end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, string.format("%d/%s##pps2", preset_set[2], unit_label), 60, 20) then
                state.points_per_second = preset_set[2]
                state.points_per_second_text = string.format("%.1f", preset_set[2])
            end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, string.format("%d/%s##pps3", preset_set[3], unit_label), 60, 20) then
                state.points_per_second = preset_set[3]
                state.points_per_second_text = string.format("%.1f", preset_set[3])
            end
            
            -- Custom points per unit input
            reaper.ImGui_PushItemWidth(ctx, 100)
            rv, state.points_per_second_text = reaper.ImGui_InputText(ctx, "##pps", state.points_per_second_text)
            if rv then
                local num = tonumber(state.points_per_second_text)
                if num and num > 0 then
                    state.points_per_second = num
                end
            end
            reaper.ImGui_PopItemWidth(ctx)
            
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, -120)
            local slider_label = string.format("Points/%s##slider", unit_label)
            local slider_max = state.points_rate_unit == 1 and 100.0 or (state.points_rate_unit == 2 and 60.0 or 24.0)
            rv, state.points_per_second = reaper.ImGui_SliderDouble(ctx, slider_label, state.points_per_second, 0.1, slider_max, "%.1f")
            if rv then
                state.points_per_second_text = string.format("%.1f", state.points_per_second)
            end
            reaper.ImGui_PopItemWidth(ctx)
            
            -- Show calculated duration
            if state.data_loaded and state.row_count > 0 and state.points_per_second > 0 then
                -- Convert points/unit to points/second for calculation
                local points_per_sec_actual = state.points_per_second / unit_mult
                local calc_duration = state.row_count / points_per_sec_actual
                reaper.ImGui_Text(ctx, string.format("→ Duration: %.1f seconds", calc_duration))
            end
        end
    end
    
    -- Start position
    rv, state.start_mode = reaper.ImGui_RadioButtonEx(ctx, "Start at 0.0", state.start_mode, 1)
    reaper.ImGui_SameLine(ctx)
    rv, state.start_mode = reaper.ImGui_RadioButtonEx(ctx, "Start at cursor", state.start_mode, 2)
    reaper.ImGui_SameLine(ctx)
    rv, state.start_mode = reaper.ImGui_RadioButtonEx(ctx, "Start at selected item", state.start_mode, 3)
    
    -- 4. DIRECTION
    reaper.ImGui_SeparatorText(ctx, "4. DIRECTION")
    
    rv, state.direction = reaper.ImGui_RadioButtonEx(ctx, "Forward", state.direction, 1)
    reaper.ImGui_SameLine(ctx)
    rv, state.direction = reaper.ImGui_RadioButtonEx(ctx, "Reverse", state.direction, 2)
    reaper.ImGui_SameLine(ctx)
    rv, state.direction = reaper.ImGui_RadioButtonEx(ctx, "Palindrome", state.direction, 3)
    
    -- 5. OPTIONS
    reaper.ImGui_SeparatorText(ctx, "5. OPTIONS")
    
    -- Curve selection
    reaper.ImGui_Text(ctx, "Curve:")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushItemWidth(ctx, 200)
    rv, state.curve_shape = reaper.ImGui_Combo(ctx, "##curve", state.curve_shape, 
        table.concat(curve_names, "\0") .. "\0")
    reaper.ImGui_PopItemWidth(ctx)
    
    -- Interpolation steps (only show if non-linear curve selected)
    if state.curve_shape > 0 then
        rv, state.interpolation_steps = reaper.ImGui_SliderInt(ctx, "Interp Steps", state.interpolation_steps, 2, 50)
    end
    
    -- Console logging checkbox
    rv, state.enable_logging = reaper.ImGui_Checkbox(ctx, "Console Log", state.enable_logging)
    
    -- 6. APPLY
    reaper.ImGui_SeparatorText(ctx, "6. APPLY")
    
    local can_apply = state.data_loaded
    if not can_apply then
        reaper.ImGui_BeginDisabled(ctx)
    end
    
    if reaper.ImGui_Button(ctx, "APPLY", -1, 40) then
        apply_automation()
    end
    
    if not can_apply then
        reaper.ImGui_EndDisabled(ctx)
    end
    
    -- 8. STATUS
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextWrapped(ctx, state.status_message)
end

-- Main loop
local function loop()
    -- Set initial window size (first use only)
    reaper.ImGui_SetNextWindowSize(ctx, 700, 800, reaper.ImGui_Cond_FirstUseEver())
    
    local visible, open = reaper.ImGui_Begin(ctx, 'Geomagnetic Automation v2.5', true)
    
    if visible then
        -- Load settings on first GUI frame only
        if not state.gui_initialized then
            state.gui_initialized = true
            -- Optionally load saved settings here if desired
            -- load_settings_snapshot()
        end
        
        draw_gui()
        reaper.ImGui_End(ctx)
    end
    
    if open then
        reaper.defer(loop)
    else
        if reaper.ImGui_DestroyContext then reaper.ImGui_DestroyContext(ctx) end
    end
end

reaper.defer(loop)
