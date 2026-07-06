-- Geomagnetic MIDI CC Automation v2.0
-- Geomagnetic data -> MIDI CC events on selected MIDI items
-- NEW v2.0: Normal persistent window, duration input fields, workflow matches Track/Take automation
-- Clean 5-column interface with preset CCs and adjustable ranges

local script_version = "2.0"

if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox("ReaImGui extension is required.", "Missing Extension", 0)
    return
end

local ctx = reaper.ImGui_CreateContext("Geomagnetic MIDI CC Automation v2.0")

-- ============================================================
-- CC PRESET DEFINITIONS
-- ============================================================
local CC_PRESETS = {
    {name = "Pitch Bend", cc = -1, min = -8192, max = 8191, default_min = -8192, default_max = 8191, is_pitchbend = true},
    {name = "CC7 - Volume", cc = 7, min = 0, max = 127, default_min = 0, default_max = 127, is_pitchbend = false},
    {name = "CC10 - Pan", cc = 10, min = 0, max = 127, default_min = 0, default_max = 127, is_pitchbend = false},
    {name = "CC1 - Modulation", cc = 1, min = 0, max = 127, default_min = 0, default_max = 127, is_pitchbend = false},
}

-- All CCs 0-127 for "Other" dropdown
local ALL_CCS = {}
for i = 0, 127 do
    local name = "CC" .. i
    if i == 1 then name = "CC1 - Modulation Wheel"
    elseif i == 2 then name = "CC2 - Breath Controller"
    elseif i == 7 then name = "CC7 - Volume"
    elseif i == 10 then name = "CC10 - Pan"
    elseif i == 11 then name = "CC11 - Expression"
    elseif i == 64 then name = "CC64 - Sustain Pedal"
    elseif i == 71 then name = "CC71 - Resonance"
    elseif i == 74 then name = "CC74 - Brightness"
    elseif i == 91 then name = "CC91 - Reverb"
    elseif i == 93 then name = "CC93 - Chorus"
    end
    table.insert(ALL_CCS, {cc = i, name = name})
end

-- ============================================================
-- STATE
-- ============================================================
local state = {
    -- Data
    data_loaded = false,
    data_cache = {},
    data_file_path = "",
    column_count = 0,
    row_count = 0,
    column_names = {},
    has_header = false,
    
    -- Column navigation
    column_offset = 0,
    
    -- Per-column configuration (5 visible columns)
    columns = {},
    
    -- Selected MIDI items
    selected_items = {},
    
    -- Duration
    duration_mode = 1,
    duration = 60.0,
    duration_text = "60.0",  -- NEW v2.0: text input for fixed duration
    points_per_second = 1.0,
    points_per_second_text = "1.0",  -- NEW v2.0: text input for points/rate
    points_rate_unit = 1,  -- 1=second, 2=minute, 3=hour
    last_duration = 0,  -- NEW v2.0: for "Use last" functionality
    
    -- Direction
    direction = 1,
    
    -- Pre-processing
    process_mode = 1,
    threshold = 150.0,
    comp_ratio = 4.0,
    
    -- Status
    status_message = "",
}

-- Initialize columns
for i = 1, 5 do
    state.columns[i] = {
        enabled = false,
        cc_type = i <= 4 and i or 5,
        cc_num = 1,
        name = "CC1 - Modulation Wheel",
        range_min = 0,
        range_max = 127,
        range_min_text = "0",
        range_max_text = "127",
        mapping = 1,
        is_pitchbend = false,
    }
    
    if i <= 4 then
        local preset = CC_PRESETS[i]
        state.columns[i].cc_num = preset.cc
        state.columns[i].name = preset.name
        state.columns[i].range_min = preset.default_min
        state.columns[i].range_max = preset.default_max
        state.columns[i].range_min_text = tostring(preset.default_min)
        state.columns[i].range_max_text = tostring(preset.default_max)
        state.columns[i].is_pitchbend = preset.is_pitchbend
    end
end

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

function is_numeric(str)
    return tonumber(str) ~= nil
end

function is_nan(val)
    local s = tostring(val)
    return s:match("nan") or s:match("NaN") or s == "" or s == "N/A"
end

function map_value(val, data_min, data_max, target_min, target_max, mapping_mode)
    local norm = 0
    if data_max ~= data_min then
        norm = (val - data_min) / (data_max - data_min)
    end
    
    if mapping_mode == 2 then
        norm = norm * norm
    elseif mapping_mode == 3 then
        norm = norm * norm * (3 - 2 * norm)
    end
    
    return target_min + norm * (target_max - target_min)
end

function load_data_file(filepath)
    local file = io.open(filepath, "r")
    if not file then
        return nil, "Could not open file"
    end
    
    local lines = {}
    for line in file:lines() do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and not trimmed:match("^#") then
            table.insert(lines, trimmed)
        end
    end
    file:close()
    
    if #lines == 0 then
        return nil, "File is empty"
    end
    
    -- Detect header
    local first_line = lines[1]
    local first_tokens = {}
    for token in first_line:gmatch("[^,\t]+") do
        table.insert(first_tokens, token:match("^%s*(.-)%s*$"))
    end
    
    local non_numeric = 0
    for _, token in ipairs(first_tokens) do
        if not is_numeric(token) then
            non_numeric = non_numeric + 1
        end
    end
    
    local has_header = false
    local header_line = nil
    local header_names = {}
    if non_numeric >= #first_tokens * 0.6 then
        has_header = true
        header_line = table.remove(lines, 1)
        -- Store all header names (including non-numeric columns)
        for token in header_line:gmatch("[^,\t]+") do
            table.insert(header_names, token:match("^%s*(.-)%s*$"))
        end
    end
    
    -- Parse data - only extract numeric values
    local data = {}
    local max_cols = 0
    
    for _, line in ipairs(lines) do
        local row = {}
        for token in line:gmatch("[^,\t]+") do
            local val = token:match("^%s*(.-)%s*$")
            if is_nan(val) then
                table.insert(row, 0)
            else
                local num = tonumber(val)
                if num then
                    table.insert(row, num)
                end
                -- Skip non-numeric values (like datetime strings)
            end
        end
        if #row > max_cols then max_cols = #row end
        table.insert(data, row)
    end
    
    -- Build column names for numeric columns only
    local col_names = {}
    if has_header and #header_names > 0 then
        -- Just use the first max_cols header names
        -- (assumes numeric columns come first, datetime last)
        for i = 1, max_cols do
            if header_names[i] then
                col_names[i] = header_names[i]
            end
        end
    end
    
    return {
        data = data,
        rows = #data,
        cols = max_cols,
        has_header = has_header,
        column_names = col_names
    }
end

function refresh_selected_items()
    state.selected_items = {}
    local item_count = reaper.CountSelectedMediaItems(0)
    
    for i = 0, item_count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local take = reaper.GetActiveTake(item)
        
        if take and reaper.TakeIsMIDI(take) then
            table.insert(state.selected_items, {
                item = item,
                take = take,
                name = reaper.GetTakeName(take),
                length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
                pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            })
        end
    end
    
    return #state.selected_items
end

-- ============================================================
-- MIDI EVENT INSERTION
-- ============================================================

function insert_cc_events(take, cc_num, time_points, values, is_pitchbend)
    if not take or not reaper.TakeIsMIDI(take) then
        return false
    end
    
    for i, time_sec in ipairs(time_points) do
        local value = values[i]
        local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, time_sec)
        
        if is_pitchbend then
            local pitch_int = math.floor(value + 0.5)
            pitch_int = math.max(-8192, math.min(8191, pitch_int))
            
            local pitch_14bit = pitch_int + 8192
            local lsb = pitch_14bit & 0x7F
            local msb = (pitch_14bit >> 7) & 0x7F
            
            reaper.MIDI_InsertCC(take, false, false, ppq, 0xE0, 0, lsb, msb)
        else
            local cc_int = math.floor(value + 0.5)
            cc_int = math.max(0, math.min(127, cc_int))
            
            reaper.MIDI_InsertCC(take, false, false, ppq, 0xB0, cc_num, cc_int, 0)
        end
    end
    
    reaper.MIDI_Sort(take)
    return true
end

-- ============================================================
-- DATA PROCESSING
-- ============================================================

function preprocess_data(data_col, mode, threshold, comp_ratio)
    if mode == 1 then return data_col end
    
    local processed = {}
    for _, val in ipairs(data_col) do
        if val > threshold then
            local excess = val - threshold
            table.insert(processed, threshold + (excess / comp_ratio))
        else
            table.insert(processed, val)
        end
    end
    return processed
end

function apply_automation()
    if not state.data_loaded then
        state.status_message = "❌ No data loaded"
        return
    end
    
    local midi_item_count = refresh_selected_items()
    if midi_item_count == 0 then
        state.status_message = "❌ No MIDI items selected"
        return
    end
    
    local any_enabled = false
    for i = 1, 5 do
        if state.columns[i].enabled then
            any_enabled = true
            break
        end
    end
    
    if not any_enabled then
        state.status_message = "❌ No columns enabled"
        return
    end
    
    reaper.Undo_BeginBlock()
    local total_events = 0
    
    for _, item_info in ipairs(state.selected_items) do
        local take = item_info.take
        local duration = item_info.length
        
        if state.duration_mode == 2 then
            local rate_mult = state.points_rate_unit == 2 and 60 or (state.points_rate_unit == 3 and 3600 or 1)
            duration = state.row_count / (state.points_per_second / rate_mult)
        elseif state.duration_mode == 3 then
            duration = state.duration
        end
        
        for col_idx = 1, 5 do
            local col = state.columns[col_idx]
            local actual_col = col_idx + state.column_offset
            
            if actual_col <= state.column_count and col.enabled then
                local col_data = {}
                for row_idx = 1, state.row_count do
                    table.insert(col_data, state.data_cache[row_idx][actual_col] or 0)
                end
                
                if state.direction == 2 then
                    local rev = {}
                    for i = #col_data, 1, -1 do table.insert(rev, col_data[i]) end
                    col_data = rev
                elseif state.direction == 3 then
                    local orig = {}
                    for _, v in ipairs(col_data) do table.insert(orig, v) end
                    for i = #orig - 1, 1, -1 do table.insert(col_data, orig[i]) end
                end
                
                col_data = preprocess_data(col_data, state.process_mode, state.threshold, state.comp_ratio)
                
                local data_min, data_max = math.huge, -math.huge
                for _, v in ipairs(col_data) do
                    if v < data_min then data_min = v end
                    if v > data_max then data_max = v end
                end
                
                local time_points = {}
                local dt = duration / #col_data
                for i = 1, #col_data do
                    table.insert(time_points, item_info.pos + (i - 1) * dt)
                end
                
                local mapped_values = {}
                for _, val in ipairs(col_data) do
                    local mapped = map_value(val, data_min, data_max, col.range_min, col.range_max, col.mapping)
                    table.insert(mapped_values, mapped)
                end
                
                if insert_cc_events(take, col.cc_num, time_points, mapped_values, col.is_pitchbend) then
                    total_events = total_events + #time_points
                end
            end
        end
    end
    
    reaper.Undo_EndBlock("Apply Geomagnetic MIDI CC Automation", -1)
    reaper.UpdateArrange()
    
    state.status_message = string.format("✓ Applied %d CC events to %d MIDI item(s)", total_events, midi_item_count)
end

-- ============================================================
-- UI RENDERING
-- ============================================================

function draw_column_config(col_idx)
    local col = state.columns[col_idx]
    local actual_col = col_idx + state.column_offset
    
    if actual_col > state.column_count then return end
    
    local col_name = "Column " .. actual_col
    if state.has_header and state.column_names[actual_col] then
        col_name = state.column_names[actual_col]
    end
    
    reaper.ImGui_PushID(ctx, col_idx)
    
    local rv, enabled = reaper.ImGui_Checkbox(ctx, "##enable", col.enabled)
    if rv then col.enabled = enabled end
    
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_Text(ctx, col_name)
    
    if col.enabled then
        reaper.ImGui_Indent(ctx, 20)
        
        reaper.ImGui_Text(ctx, "CC:")
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, 200)
        
        if reaper.ImGui_BeginCombo(ctx, "##cctype", col.name) then
            for i, preset in ipairs(CC_PRESETS) do
                if reaper.ImGui_Selectable(ctx, preset.name, col.cc_type == i) then
                    col.cc_type = i
                    col.cc_num = preset.cc
                    col.name = preset.name
                    col.range_min = preset.default_min
                    col.range_max = preset.default_max
                    col.range_min_text = tostring(preset.default_min)
                    col.range_max_text = tostring(preset.default_max)
                    col.is_pitchbend = preset.is_pitchbend
                end
            end
            
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Text(ctx, "Other CCs:")
            
            for _, cc_info in ipairs(ALL_CCS) do
                if reaper.ImGui_Selectable(ctx, cc_info.name, col.cc_type == 5 and col.cc_num == cc_info.cc) then
                    col.cc_type = 5
                    col.cc_num = cc_info.cc
                    col.name = cc_info.name
                    col.range_min = 0
                    col.range_max = 127
                    col.range_min_text = "0"
                    col.range_max_text = "127"
                    col.is_pitchbend = false
                end
            end
            
            reaper.ImGui_EndCombo(ctx)
        end
        
        reaper.ImGui_Text(ctx, "Range:")
        
        local slider_min = col.is_pitchbend and -8192 or 0
        local slider_max = col.is_pitchbend and 8191 or 127
        
        -- Min slider
        reaper.ImGui_Text(ctx, "  Min:")
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, 70)
        rv, text = reaper.ImGui_InputText(ctx, "##min", col.range_min_text)
        if rv then
            col.range_min_text = text
            local val = tonumber(text)
            if val then
                col.range_min = math.max(slider_min, math.min(slider_max, val))
            end
        end
        
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, 200)
        rv, new_min = reaper.ImGui_SliderDouble(ctx, "##minslider", col.range_min, slider_min, slider_max, "%.0f")
        if rv then
            col.range_min = new_min
            col.range_min_text = string.format("%.0f", new_min)
        end
        
        -- Max slider
        reaper.ImGui_Text(ctx, "  Max:")
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, 70)
        rv, text = reaper.ImGui_InputText(ctx, "##max", col.range_max_text)
        if rv then
            col.range_max_text = text
            local val = tonumber(text)
            if val then
                col.range_max = math.max(slider_min, math.min(slider_max, val))
            end
        end
        
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, 200)
        rv, new_max = reaper.ImGui_SliderDouble(ctx, "##maxslider", col.range_max, slider_min, slider_max, "%.0f")
        if rv then
            col.range_max = new_max
            col.range_max_text = string.format("%.0f", new_max)
        end
        
        reaper.ImGui_Text(ctx, "Mapping:")
        reaper.ImGui_SameLine(ctx)
        rv, mapping = reaper.ImGui_RadioButtonEx(ctx, "Linear", col.mapping, 1)
        if rv then col.mapping = mapping end
        
        reaper.ImGui_SameLine(ctx)
        rv, mapping = reaper.ImGui_RadioButtonEx(ctx, "Exp", col.mapping, 2)
        if rv then col.mapping = mapping end
        
        reaper.ImGui_SameLine(ctx)
        rv, mapping = reaper.ImGui_RadioButtonEx(ctx, "S-Curve", col.mapping, 3)
        if rv then col.mapping = mapping end
        
        reaper.ImGui_Unindent(ctx, 20)
        reaper.ImGui_Spacing(ctx)
    end
    
    reaper.ImGui_PopID(ctx)
end

function draw_main_window()
    local visible, open = reaper.ImGui_Begin(ctx, "Geomagnetic MIDI CC Automation v2.0", true)
    
    if visible then
        reaper.ImGui_Text(ctx, "📁 Data File")
        reaper.ImGui_Separator(ctx)
        
        if reaper.ImGui_Button(ctx, "Browse File", 120) then
            local retval, filepath = reaper.GetUserFileNameForRead("", "Load Geomagnetic Data", "*.csv;*.txt")
            if retval then
                local result, err = load_data_file(filepath)
                if result then
                    state.data_cache = result.data
                    state.row_count = result.rows
                    state.column_count = result.cols
                    state.has_header = result.has_header
                    state.column_names = result.column_names
                    state.data_loaded = true
                    state.data_file_path = filepath
                    state.status_message = string.format("✓ Loaded %d rows × %d columns", state.row_count, state.column_count)
                else
                    state.status_message = "❌ " .. err
                end
            end
        end
        
        reaper.ImGui_SameLine(ctx)
        if state.data_loaded then
            reaper.ImGui_TextColored(ctx, 0x00FF00FF, string.format("%d rows × %d cols", state.row_count, state.column_count))
        else
            reaper.ImGui_TextDisabled(ctx, "No data loaded")
        end
        
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)
        
        -- Disable all controls until data is loaded
        if not state.data_loaded then
            reaper.ImGui_BeginDisabled(ctx)
        end
        
        reaper.ImGui_Text(ctx, "🎛️ Column → CC Assignments")
        reaper.ImGui_Separator(ctx)
        
        for i = 1, 5 do
            draw_column_config(i)
        end
            
            if state.column_count > 5 then
                reaper.ImGui_Spacing(ctx)
                if reaper.ImGui_Button(ctx, "◀ Prev") then
                    state.column_offset = math.max(0, state.column_offset - 1)
                end
                reaper.ImGui_SameLine(ctx)
                if reaper.ImGui_Button(ctx, "Next ▶") then
                    if state.column_offset + 5 < state.column_count then
                        state.column_offset = state.column_offset + 1
                    end
                end
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, string.format("(Showing %d-%d of %d)", 
                    state.column_offset + 1, 
                    math.min(state.column_offset + 5, state.column_count),
                    state.column_count))
            end
            
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Spacing(ctx)
            
            reaper.ImGui_Text(ctx, "⏱️ Duration")
            local rv, mode = reaper.ImGui_RadioButtonEx(ctx, "Item Length (auto)", state.duration_mode, 1)
            if rv then state.duration_mode = mode end
            
            reaper.ImGui_SameLine(ctx)
            rv, mode = reaper.ImGui_RadioButtonEx(ctx, "Points/Rate", state.duration_mode, 2)
            if rv then state.duration_mode = mode end
            
            reaper.ImGui_SameLine(ctx)
            rv, mode = reaper.ImGui_RadioButtonEx(ctx, "Fixed", state.duration_mode, 3)
            if rv then state.duration_mode = mode end
            
            -- NEW v2.0: Duration input fields
            if state.duration_mode == 2 then
                -- Points/Rate mode
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Text(ctx, "  Points per:")
                reaper.ImGui_PushItemWidth(ctx, 80)
                rv, state.points_per_second_text = reaper.ImGui_InputText(ctx, "##pps", state.points_per_second_text)
                if rv then
                    local val = tonumber(state.points_per_second_text)
                    if val and val > 0 then
                        state.points_per_second = val
                    end
                end
                reaper.ImGui_PopItemWidth(ctx)
                
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_PushItemWidth(ctx, 80)
                rv, state.points_rate_unit = reaper.ImGui_Combo(ctx, "##unit", state.points_rate_unit - 1, "Second\0Minute\0Hour\0")
                state.points_rate_unit = state.points_rate_unit + 1
                reaper.ImGui_PopItemWidth(ctx)
                
            elseif state.duration_mode == 3 then
                -- Fixed duration mode
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Text(ctx, "  Duration (seconds):")
                reaper.ImGui_PushItemWidth(ctx, 100)
                rv, state.duration_text = reaper.ImGui_InputText(ctx, "##dur", state.duration_text)
                if rv then
                    local val = tonumber(state.duration_text)
                    if val and val > 0 then
                        state.duration = val
                    end
                end
                reaper.ImGui_PopItemWidth(ctx)
            end
            
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Spacing(ctx)
            
            refresh_selected_items()
            local button_text = string.format("▶ APPLY TO %d MIDI ITEM(S)", #state.selected_items)
            if reaper.ImGui_Button(ctx, button_text, -1, 40) then
                apply_automation()
            end
            
            -- End disabled block
            if not state.data_loaded then
                reaper.ImGui_EndDisabled(ctx)
            end
            
            if state.status_message ~= "" then
                reaper.ImGui_Spacing(ctx)
                local color = state.status_message:match("❌") and 0xFF0000FF or 0x00FF00FF
                reaper.ImGui_TextColored(ctx, color, state.status_message)
            end
        
        reaper.ImGui_End(ctx)
    end
    
    if open then
        reaper.defer(draw_main_window)
    end
end

draw_main_window()
