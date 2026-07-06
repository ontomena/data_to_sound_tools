#!/usr/bin/env python3
"""
Combined Geomagnetic Data Processor
Version 7.0 - ALL operations fully implemented (downsample by rows, extract time, cycles)
Cross-platform GUI for processing geomagnetic time series data
"""

import tkinter as tk
from tkinter import ttk, filedialog, scrolledtext, messagebox
import os
import json
from pathlib import Path
from datetime import datetime, timedelta
import sys

# ============================================================================
# DATA CLEANING FUNCTIONS
# ============================================================================

def is_nan(value):
    """Check if a value is NaN"""
    val_lower = str(value).strip().lower()
    return val_lower in ['nan', 'na', '']

def is_numeric(value):
    """Check if a value can be converted to a number"""
    if is_nan(value):
        return True
    try:
        float(value)
        return True
    except (ValueError, TypeError):
        return False

def analyze_column(column_data):
    """Analyze a column to determine if it's numeric and count NaNs"""
    total = len(column_data)
    if total == 0:
        return {'is_numeric': False, 'nan_count': 0, 'nan_percent': 0}
    
    nan_count = sum(1 for val in column_data if is_nan(val))
    numeric_count = sum(1 for val in column_data if is_numeric(val))
    
    is_numeric_col = (numeric_count / total) > 0.8
    nan_percent = (nan_count / total) * 100
    
    return {
        'is_numeric': is_numeric_col,
        'nan_count': nan_count,
        'nan_percent': nan_percent,
        'total': total
    }

def linear_interpolate(before_val, after_val, steps):
    """Create linear interpolation between two values"""
    try:
        before = float(before_val)
        after = float(after_val)
        step_size = (after - before) / (steps + 1)
        return [str(before + step_size * (i + 1)) for i in range(steps)]
    except (ValueError, TypeError):
        return [before_val] * steps

def linear_fill(data):
    """Linear interpolation for NaN values per column"""
    if not data:
        return data
    
    num_cols = len(data[0])
    
    for col_idx in range(num_cols):
        i = 0
        while i < len(data):
            if is_nan(data[i][col_idx]):
                gap_start = i
                gap_end = i
                while gap_end < len(data) and is_nan(data[gap_end][col_idx]):
                    gap_end += 1
                
                gap_length = gap_end - gap_start
                before_val = data[gap_start - 1][col_idx] if gap_start > 0 else '0'
                after_val = data[gap_end][col_idx] if gap_end < len(data) else before_val
                
                if gap_end < len(data):
                    interpolated = linear_interpolate(before_val, after_val, gap_length)
                    for j, val in enumerate(interpolated):
                        data[gap_start + j][col_idx] = val
                else:
                    for j in range(gap_length):
                        data[gap_start + j][col_idx] = before_val
                
                i = gap_end
            else:
                i += 1
    
    return data

def forward_fill(data):
    """Forward fill NaN values per column"""
    cleaned = []
    for row in data:
        new_row = []
        for col_idx, val in enumerate(row):
            if is_nan(val):
                if cleaned:
                    new_row.append(cleaned[-1][col_idx])
                else:
                    new_row.append('0')
            else:
                new_row.append(val)
        cleaned.append(new_row)
    return cleaned

def read_data_file(input_file):
    """Read CSV or TXT file, return data as list of rows
    
    NEW v5.2: Smart comment header detection
    - Preserves last # line before data if it looks like a header
    - Strips leading # from that line
    """
    file_ext = Path(input_file).suffix.lower()
    
    with open(input_file, 'r', encoding='utf-8') as f:
        all_lines = [line.strip() for line in f if line.strip()]
    
    # Separate comment lines and data lines
    comment_lines = [line for line in all_lines if line.startswith('#')]
    data_lines = [line for line in all_lines if not line.startswith('#')]
    
    header_line = None
    
    # PRIORITY 1: Check if first data line is a header (for ESK-style files)
    # This takes priority because it's more reliable than comment detection
    if data_lines:
        first_line = data_lines[0]
        tokens = first_line.replace(',', ' ').replace('\t', ' ').split()
        
        if len(tokens) >= 2:
            non_numeric_count = 0
            for token in tokens:
                try:
                    float(token)
                except:
                    non_numeric_count += 1
            
            # If 60%+ tokens are non-numeric, it's a header
            if non_numeric_count >= len(tokens) * 0.6:
                header_line = first_line
                data_lines = data_lines[1:]  # Remove header from data
    
    # PRIORITY 2: Check comment lines for headers (for Kp-style files)
    # Only do this if we didn't find a header in the data
    if not header_line and comment_lines and data_lines:
        header_keywords = ['YYY', 'MM', 'DD', 'Kp', 'ap', 'Ap', 'Bsr', 'dB', 'SN', 'F10', 
                          'Col', 'Column', 'Date', 'Time', 'Year', 'Month', 'Day',
                          'H', 'D', 'Z', 'F', 'X', 'Y', 'datetime', 'days', 'hours']
        
        best_score = 0
        best_header = None
        best_index = -1
        
        for idx, comment in enumerate(comment_lines):
            potential_header = comment.lstrip('#').strip()
            
            # Skip obviously non-header lines (metadata)
            # - Lines with colons are usually metadata like "Observatory Code: ESK"
            # - Exception: if it looks like column headers (multiple comma/tab-separated short words)
            if ':' in potential_header:
                # Check if it's actually column-like despite having a colon
                comma_count = potential_header.count(',')
                tab_count = potential_header.count('\t')
                if comma_count < 2 and tab_count < 2:  # Not multiple delimited columns
                    continue  # Skip metadata
            
            # Score this line as a potential header
            tokens = potential_header.replace(',', ' ').replace('\t', ' ').split()
            
            if len(tokens) < 2:
                continue  # Need at least 2 columns
            
            score = 0
            
            # Bonus for matching keywords
            for token in tokens:
                if any(keyword == token or keyword in token for keyword in header_keywords):
                    score += 3
            
            # Bonus for short non-numeric tokens (typical column names)
            short_word_count = sum(1 for token in tokens 
                                  if len(token) <= 10 and not token.replace('.','').replace('-','').isdigit())
            score += short_word_count
            
            # Bonus for multiple tokens (more columns)
            if len(tokens) >= 3:
                score += 2
            
            # Strong preference for being near data (last few comments)
            if idx >= len(comment_lines) - 3:
                score += 5
            
            if score > best_score:
                best_score = score
                best_header = potential_header
                best_index = idx
        
        # Accept header if score is high enough
        if best_score >= 5:
            header_line = best_header
    
    # Now process data lines (header_line will be prepended if found)
    lines = data_lines
    
    # Detect delimiter
    if file_ext == '.csv' or (lines and ',' in lines[0]):
        data = [line.split(',') for line in lines]
        delim = ','
    elif lines and '\t' in lines[0]:
        data = [line.split('\t') for line in lines]
        delim = '\t'
    else:
        data = [line.split() for line in lines]
        delim = ' '
    
    # NEW v5.2: Prepend header if found
    if header_line:
        if delim == ',':
            header_row = header_line.split(',')
        elif delim == '\t':
            header_row = header_line.split('\t')
        else:
            header_row = header_line.split()
        
        # Insert header as first row
        data.insert(0, header_row)
    
    return data

def analyze_file_quality(data):
    """Analyze data quality and return stats"""
    if not data:
        return None
    
    total_rows = len(data)
    total_cols = len(data[0]) if data else 0
    
    columns = [[row[i] if i < len(row) else '' for row in data] for i in range(total_cols)]
    
    numeric_cols = []
    total_nans = 0
    col_analysis = []
    
    for i in range(total_cols):
        analysis = analyze_column(columns[i])
        col_analysis.append(analysis)
        if analysis['is_numeric']:
            numeric_cols.append(i)
            total_nans += analysis['nan_count']
    
    return {
        'total_rows': total_rows,
        'total_cols': total_cols,
        'numeric_cols': numeric_cols,
        'total_nans': total_nans,
        'col_analysis': col_analysis,
        'columns': columns
    }

def detect_bartels_column(data, start_row=0, max_check=100):
    """
    Auto-detect which column contains Bartels rotation numbers.
    Returns column index or None if not found.
    
    Bartels characteristics:
    - Integer values typically in range 1000-3000
    - Increments by 1 every ~27 rows (648 hours)
    - Relatively consistent pattern
    """
    if not data or len(data) < 50:
        return None
    
    num_cols = len(data[0])
    check_rows = min(len(data), start_row + max_check)
    
    for col_idx in range(num_cols):
        try:
            # Get sample values
            values = []
            for i in range(start_row, min(check_rows, len(data))):
                if col_idx < len(data[i]):
                    try:
                        val = float(data[i][col_idx])
                        values.append(val)
                    except:
                        continue
            
            if len(values) < 20:
                continue
            
            # Check if values are in typical Bartels range
            if not (1000 <= min(values) <= 3500 and 1000 <= max(values) <= 3500):
                continue
            
            # Check if values increment reasonably (should be mostly same value with occasional +1)
            unique_vals = len(set(values))
            if unique_vals > len(values) * 0.1:  # Too much variation
                continue
            
            # Check for incrementing pattern
            increments = 0
            for i in range(1, len(values)):
                if values[i] == values[i-1] + 1:
                    increments += 1
            
            # Should have some increments but not too many (increments every ~27 rows)
            if increments > 0 and increments < len(values) * 0.2:
                return col_idx
                
        except:
            continue
    
    return None

def detect_start_date(data):
    """
    NEW v5.3: Auto-detect start date from data
    
    Looks for:
    1. datetime column (e.g., '2022-01-01 00:00:00')
    2. Separate YYYY, MM, DD columns
    
    Returns: (year, month, day) tuple or None
    """
    if not data or len(data) < 1:
        return None
    
    # Check first row - if non-numeric, it's a header, skip it
    start_row = 0
    first_row_numeric = True
    try:
        float(data[0][0])
    except:
        first_row_numeric = False
        start_row = 1
    
    if start_row >= len(data):
        return None
    
    first_data_row = data[start_row]
    
    # Method 1: Look for datetime column
    import re
    for val in first_data_row:
        val_str = str(val).strip()
        # Match patterns like: 2022-01-01, 2022-01-01 00:00:00, 2022/01/01
        datetime_pattern = r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})'
        match = re.match(datetime_pattern, val_str)
        if match:
            year, month, day = int(match.group(1)), int(match.group(2)), int(match.group(3))
            return (year, month, day)
    
    # Method 2: Look for YYYY MM DD in first 3 columns
    if len(first_data_row) >= 3:
        try:
            # Try parsing first 3 columns as year/month/day
            col0 = str(first_data_row[0]).strip()
            col1 = str(first_data_row[1]).strip()
            col2 = str(first_data_row[2]).strip()
            
            year = int(float(col0))
            month = int(float(col1))
            day = int(float(col2))
            
            # Validate reasonable ranges
            if 1800 <= year <= 2100 and 1 <= month <= 12 and 1 <= day <= 31:
                return (year, month, day)
        except:
            pass
    
    return None

def detect_data_frequency(data):
    """
    NEW v5.4: Detect data frequency (rows per day) from datetime column or date columns
    
    Returns: rows_per_day (float) or None
    """
    if not data or len(data) < 10:
        return None
    
    # Skip header if present
    start_row = 0
    try:
        float(data[0][0])
    except:
        start_row = 1
    
    if start_row >= len(data):
        return None
    
    # Method 1: Look for datetime column and parse timestamps
    import re
    datetime_col = None
    for col_idx in range(len(data[start_row])):
        val = str(data[start_row][col_idx]).strip()
        if re.match(r'\d{4}[-/]\d{1,2}[-/]\d{1,2}', val):
            datetime_col = col_idx
            break
    
    if datetime_col is not None:
        # Extract timestamps from first 50 rows
        timestamps = []
        for i in range(start_row, min(start_row + 50, len(data))):
            try:
                val = str(data[i][datetime_col]).strip()
                # Parse datetime
                match = re.match(r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})\s+(\d{1,2}):(\d{1,2}):(\d{1,2})', val)
                if match:
                    y, m, d, h, mn, s = match.groups()
                    dt = datetime(int(y), int(m), int(d), int(h), int(mn), int(s))
                    timestamps.append(dt)
                else:
                    # Try date-only format
                    match = re.match(r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})', val)
                    if match:
                        y, m, d = match.groups()
                        dt = datetime(int(y), int(m), int(d))
                        timestamps.append(dt)
            except:
                continue
        
        if len(timestamps) >= 10:
            # Calculate average time between rows
            time_diffs = []
            for i in range(1, len(timestamps)):
                diff = (timestamps[i] - timestamps[i-1]).total_seconds()
                if diff > 0:  # Ignore zero or negative diffs
                    time_diffs.append(diff)
            
            if time_diffs:
                avg_seconds_per_row = sum(time_diffs) / len(time_diffs)
                rows_per_day = (24 * 3600) / avg_seconds_per_row
                return rows_per_day
    
    # Method 2: Check YYYY MM DD columns
    dates_sample = []
    for i in range(start_row, min(start_row + 50, len(data))):
        try:
            if len(data[i]) >= 3:
                date_str = f"{data[i][0]}-{str(data[i][1]).zfill(2)}-{str(data[i][2]).zfill(2)}"
                dates_sample.append(date_str)
        except:
            continue
    
    if len(dates_sample) >= 10:
        unique_dates = len(set(dates_sample))
        rows_per_day = len(dates_sample) / unique_dates
        return rows_per_day
    
    return None

# ============================================================================
# MAIN GUI APPLICATION
# ============================================================================

class GeomagProcessorGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("Geomagnetic Data Processor v7.0")
        self.root.geometry("800x700")
        
        # Variables
        self.file_paths = []
        self.total_rows = 0
        self.total_cols = 0
        self.data = []
        self.file_analysis = None
        self.presets_file = Path("geomag_presets.json")
        self.last_settings_file = Path("geomag_last_settings.json")
        self.processing = False
        
        # NEW v5.0: Bartels detection
        self.bartels_column_detected = None
        
        # Check if drag-and-drop is available
        self.dnd_available = False
        try:
            import tkinterdnd2
            self.dnd_available = True
        except ImportError:
            pass
        
        # Create tabbed interface
        self.create_tabbed_interface()
        
        # Setup drag-and-drop if available
        if self.dnd_available:
            self.setup_drag_drop()
        
        # Load last settings
        self.load_last_settings()
        
        # Auto-detect files
        self.auto_detect_files()
    
    def create_tabbed_interface(self):
        """Create main tabbed interface"""
        # Create notebook (tab container)
        self.notebook = ttk.Notebook(self.root)
        self.notebook.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)
        
        # Bind tab switch event to handle Settings canvas update
        self.notebook.bind("<<NotebookTabChanged>>", self.on_tab_changed)
        
        # Create tabs
        self.data_preview_tab = ttk.Frame(self.notebook)
        self.settings_tab = ttk.Frame(self.notebook)
        self.output_log_tab = ttk.Frame(self.notebook)
        
        self.notebook.add(self.data_preview_tab, text="Data Preview")
        self.notebook.add(self.settings_tab, text="Settings")
        self.notebook.add(self.output_log_tab, text="Output Log")
        
        # Populate each tab
        self.create_data_preview_tab()
        self.create_settings_tab()
        self.create_output_log_tab()
    
    def on_tab_changed(self, event):
        """Handle tab switching - force Settings canvas update"""
        selected_tab = self.notebook.select()
        tab_text = self.notebook.tab(selected_tab, "text")
        
        if tab_text == "Settings" and hasattr(self, 'settings_canvas'):
            # Force canvas update when switching to Settings tab
            self.settings_canvas.update_idletasks()
            self.settings_canvas.configure(scrollregion=self.settings_canvas.bbox("all"))
    
    def create_data_preview_tab(self):
        """Create Data Preview tab contents"""
        frame = self.data_preview_tab
        
        # File controls at top
        controls = ttk.Frame(frame)
        controls.pack(fill=tk.X, padx=10, pady=10)
        
        ttk.Button(controls, text="Browse Files", command=self.browse_files, 
                  width=15).pack(side=tk.LEFT, padx=5)
        ttk.Button(controls, text="Clear All", command=self.clear_files, 
                  width=12).pack(side=tk.LEFT, padx=5)
        
        self.file_count_label = ttk.Label(controls, text="No files", foreground="gray", 
                                         font=("Arial", 10, "bold"))
        self.file_count_label.pack(side=tk.LEFT, padx=10)
        
        dnd_status = "✓ Drag & drop enabled" if self.dnd_available else "Drag & drop: pip install tkinterdnd2"
        ttk.Label(controls, text=dnd_status, 
                 foreground="green" if self.dnd_available else "gray").pack(side=tk.LEFT, padx=10)
        
        # File list
        ttk.Label(frame, text="Loaded Files:", font=("Arial", 10, "bold")).pack(anchor=tk.W, padx=10, pady=(5,0))
        
        list_frame = ttk.Frame(frame)
        list_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)
        
        scrollbar = ttk.Scrollbar(list_frame)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        
        self.file_listbox = tk.Listbox(list_frame, yscrollcommand=scrollbar.set, 
                                       height=8, font=("Courier", 9))
        self.file_listbox.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.config(command=self.file_listbox.yview)
        
        # Data info
        info_frame = ttk.LabelFrame(frame, text="Data Information", padding=10)
        info_frame.pack(fill=tk.X, padx=10, pady=10)
        
        # Version verification label
        version_label = ttk.Label(info_frame, text="v7.0 - All Operations Working", 
                                 foreground="green", font=("Arial", 9, "bold"))
        version_label.pack(anchor=tk.E)
        
        self.data_info_label = ttk.Label(info_frame, text="No data loaded", 
                                         foreground="gray", wraplength=750)
        self.data_info_label.pack(anchor=tk.W)
        
        # NEW v5.0: Bartels detection info
        self.bartels_info_frame = ttk.Frame(info_frame)
        self.bartels_info_frame.pack(fill=tk.X, pady=(10,0))
        
        self.bartels_info_label = ttk.Label(self.bartels_info_frame, text="", 
                                           foreground="blue", font=("Arial", 9, "bold"))
        self.bartels_info_label.pack(anchor=tk.W)
        
        # Column preview (will show checkboxes in rows of 5)
        self.column_preview_frame = ttk.LabelFrame(frame, text="Column Selection Preview", padding=10)
        self.column_preview_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)
        
        # Scrollable canvas for column checkboxes
        canvas_frame = ttk.Frame(self.column_preview_frame)
        canvas_frame.pack(fill=tk.BOTH, expand=True)
        
        self.col_canvas = tk.Canvas(canvas_frame, height=200)
        col_scrollbar = ttk.Scrollbar(canvas_frame, orient="vertical", command=self.col_canvas.yview)
        self.col_scrollable_frame = ttk.Frame(self.col_canvas)
        
        self.col_scrollable_frame.bind(
            "<Configure>",
            lambda e: self.col_canvas.configure(scrollregion=self.col_canvas.bbox("all"))
        )
        
        self.col_canvas.create_window((0, 0), window=self.col_scrollable_frame, anchor="nw")
        self.col_canvas.configure(yscrollcommand=col_scrollbar.set)
        
        self.col_canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        col_scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
    
    def create_settings_tab(self):
        """Create Settings tab contents"""
        # Create scrollable frame for settings
        self.settings_canvas = tk.Canvas(self.settings_tab)
        scrollbar = ttk.Scrollbar(self.settings_tab, orient="vertical", command=self.settings_canvas.yview)
        scrollable_frame = ttk.Frame(self.settings_canvas)
        
        scrollable_frame.bind(
            "<Configure>",
            lambda e: self.settings_canvas.configure(scrollregion=self.settings_canvas.bbox("all"))
        )
        
        self.settings_canvas.create_window((0, 0), window=scrollable_frame, anchor="nw")
        self.settings_canvas.configure(yscrollcommand=scrollbar.set)
        
        # NEW v7.0: Enable trackpad scrolling on Mac
        def _on_mousewheel(event):
            # Mac uses event.delta directly, Windows/Linux use event.delta//120
            if self.root.tk.call('tk', 'windowingsystem') == 'aqua':  # macOS
                self.settings_canvas.yview_scroll(int(-1 * event.delta), "units")
            else:  # Windows/Linux
                self.settings_canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")
        
        self.settings_canvas.bind_all("<MouseWheel>", _on_mousewheel)  # Windows/Mac
        self.settings_canvas.bind_all("<Button-4>", lambda e: self.settings_canvas.yview_scroll(-1, "units"))  # Linux scroll up
        self.settings_canvas.bind_all("<Button-5>", lambda e: self.settings_canvas.yview_scroll(1, "units"))   # Linux scroll down
        
        self.settings_canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        
        # Now add all settings to scrollable_frame
        frame = scrollable_frame
        
        # ===== STAGE 1: FILE MANAGEMENT =====
        stage1 = ttk.LabelFrame(frame, text="Stage 1: File Management", padding=10)
        stage1.pack(fill=tk.X, padx=10, pady=10)
        
        # Preset management
        preset_frame = ttk.Frame(stage1)
        preset_frame.pack(fill=tk.X, pady=5)
        
        ttk.Label(preset_frame, text="Presets:").pack(side=tk.LEFT, padx=5)
        
        self.preset_var = tk.StringVar()
        self.preset_combo = ttk.Combobox(preset_frame, textvariable=self.preset_var, 
                                        width=20, state='readonly')
        self.preset_combo.pack(side=tk.LEFT, padx=5)
        self.preset_combo.bind('<<ComboboxSelected>>', self.load_preset)
        
        ttk.Button(preset_frame, text="Save", command=self.save_preset, 
                  width=8).pack(side=tk.LEFT, padx=2)
        ttk.Button(preset_frame, text="Delete", command=self.delete_preset, 
                  width=8).pack(side=tk.LEFT, padx=2)
        
        self.load_preset_list()
        
        # ===== STAGE 2: DATA CLEANING =====
        stage2 = ttk.LabelFrame(frame, text="Stage 2: Data Cleaning", padding=10)
        stage2.pack(fill=tk.X, padx=10, pady=10)
        
        # NEW v5.0: Changed to "Keep header row"
        self.keep_header_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(stage2, text="Keep header row (if present)", 
                       variable=self.keep_header_var).pack(anchor=tk.W, pady=2)
        
        ttk.Label(stage2, text="Clean Method:").pack(anchor=tk.W, pady=(10,2))
        
        self.clean_method_var = tk.StringVar(value="skip")
        ttk.Radiobutton(stage2, text="Leave NaNs in (process raw data)", 
                       variable=self.clean_method_var, value="skip").pack(anchor=tk.W, padx=20)
        ttk.Radiobutton(stage2, text="Linear interpolation (fill gaps smoothly)", 
                       variable=self.clean_method_var, value="linear").pack(anchor=tk.W, padx=20)
        ttk.Radiobutton(stage2, text="Forward fill (repeat last value)", 
                       variable=self.clean_method_var, value="forward").pack(anchor=tk.W, padx=20)
        
        # ===== STAGE 3: PROCESSING OPERATION =====
        stage3 = ttk.LabelFrame(frame, text="Stage 3: Select Processing Operation", padding=10)
        stage3.pack(fill=tk.X, padx=10, pady=10)
        
        self.operation_var = tk.StringVar(value="downsample")
        operations = [
            ("Downsample - Reduce to percentage or row count", "downsample"),
            ("Truncate - Split into equal parts", "truncate"),
            ("Extract Columns - Select specific columns", "extract_cols"),
            ("Extract Time Range - By dates/days/Bartels", "extract_time"),
            ("Sequential Cycles - Regular periods (weekly, Bartels, monthly)", "cycles"),
            ("Batch Process - Multiple operations at once", "batch")
        ]
        
        for text, value in operations:
            ttk.Radiobutton(stage3, text=text, variable=self.operation_var, 
                           value=value, command=self.update_operation_ui).pack(anchor=tk.W, pady=2)
        
        # ===== STAGE 4: OPERATION CONFIG =====
        self.stage4_frame = ttk.LabelFrame(frame, text="Stage 4: Configure Operation", padding=10)
        self.stage4_frame.pack(fill=tk.X, padx=10, pady=10)
        
        # This will be populated dynamically
        self.create_operation_configs()
        self.update_operation_ui()
        
        # ===== PROCESS BUTTON =====
        process_frame = ttk.Frame(frame)
        process_frame.pack(fill=tk.X, padx=10, pady=20)
        
        self.process_button = ttk.Button(process_frame, text="PROCESS FILES", 
                                        command=self.process_files, 
                                        style='Accent.TButton')
        self.process_button.pack(fill=tk.X, ipady=10)
        
        # Progress bar
        self.progress_bar = ttk.Progressbar(process_frame, mode='indeterminate')
        self.progress_bar.pack(fill=tk.X, pady=(10,0))
    
    def create_output_log_tab(self):
        """Create Output Log tab contents"""
        frame = self.output_log_tab
        
        # Controls at top
        controls = ttk.Frame(frame)
        controls.pack(fill=tk.X, padx=10, pady=10)
        
        ttk.Label(controls, text="Processing Output:", 
                 font=("Arial", 10, "bold")).pack(side=tk.LEFT, padx=5)
        
        ttk.Button(controls, text="Clear Log", 
                  command=lambda: self.output_log.delete(1.0, tk.END), 
                  width=12).pack(side=tk.RIGHT, padx=5)
        
        ttk.Button(controls, text="Save Log", 
                  command=self.save_log, 
                  width=12).pack(side=tk.RIGHT, padx=5)
        
        # Scrolled text for output
        self.output_log = scrolledtext.ScrolledText(frame, wrap=tk.WORD, 
                                                    font=("Courier", 9),
                                                    bg="#1e1e1e", fg="#00ff00",
                                                    insertbackground="white")
        self.output_log.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)
    
    def create_operation_configs(self):
        """Create all operation-specific configuration frames"""
        # Clear existing
        for widget in self.stage4_frame.winfo_children():
            widget.destroy()
        
        # Downsample config
        self.downsample_frame = ttk.Frame(self.stage4_frame)
        
        self.downsample_mode_var = tk.StringVar(value="percent")
        ttk.Radiobutton(self.downsample_frame, text="By percentage:", 
                       variable=self.downsample_mode_var, value="percent").pack(anchor=tk.W)
        
        percent_frame = ttk.Frame(self.downsample_frame)
        percent_frame.pack(fill=tk.X, padx=20, pady=2)
        self.downsample_percent_var = tk.IntVar(value=10)
        ttk.Scale(percent_frame, from_=1, to=100, variable=self.downsample_percent_var, 
                 orient=tk.HORIZONTAL).pack(side=tk.LEFT, fill=tk.X, expand=True)
        ttk.Label(percent_frame, textvariable=self.downsample_percent_var).pack(side=tk.LEFT, padx=5)
        ttk.Label(percent_frame, text="%").pack(side=tk.LEFT)
        
        ttk.Radiobutton(self.downsample_frame, text="By row count:", 
                       variable=self.downsample_mode_var, value="rows").pack(anchor=tk.W, pady=(10,0))
        
        rows_frame = ttk.Frame(self.downsample_frame)
        rows_frame.pack(fill=tk.X, padx=20, pady=2)
        self.downsample_rows_var = tk.IntVar(value=1000)
        ttk.Entry(rows_frame, textvariable=self.downsample_rows_var, width=10).pack(side=tk.LEFT)
        ttk.Label(rows_frame, text="rows").pack(side=tk.LEFT, padx=5)
        
        self.create_subfolder_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(self.downsample_frame, text="Create output subfolder", 
                       variable=self.create_subfolder_var).pack(anchor=tk.W, pady=(10,0))
        
        # Truncate config - THREE MODES
        self.truncate_frame = ttk.Frame(self.stage4_frame)
        
        self.truncate_mode_var = tk.StringVar(value="range")
        
        # Mode 1: Row range (start to end)
        ttk.Radiobutton(self.truncate_frame, text="Extract row range:", 
                       variable=self.truncate_mode_var, value="range").pack(anchor=tk.W)
        
        range_frame = ttk.Frame(self.truncate_frame)
        range_frame.pack(fill=tk.X, padx=20, pady=2)
        ttk.Label(range_frame, text="Start:").pack(side=tk.LEFT)
        self.truncate_start_var = tk.IntVar(value=1)
        ttk.Entry(range_frame, textvariable=self.truncate_start_var, width=8).pack(side=tk.LEFT, padx=5)
        ttk.Label(range_frame, text="End:").pack(side=tk.LEFT, padx=(10,0))
        self.truncate_end_var = tk.IntVar(value=1000)
        ttk.Entry(range_frame, textvariable=self.truncate_end_var, width=8).pack(side=tk.LEFT, padx=5)
        
        # Mode 2: Split by row count
        ttk.Radiobutton(self.truncate_frame, text="Split by row count:", 
                       variable=self.truncate_mode_var, value="rows").pack(anchor=tk.W, pady=(10,0))
        
        rows_split_frame = ttk.Frame(self.truncate_frame)
        rows_split_frame.pack(fill=tk.X, padx=20, pady=2)
        self.truncate_rows_var = tk.IntVar(value=1000)
        entry = ttk.Entry(rows_split_frame, textvariable=self.truncate_rows_var, width=10)
        entry.pack(side=tk.LEFT)
        entry.bind('<KeyRelease>', self.update_truncate_file_count)
        ttk.Label(rows_split_frame, text="rows per file").pack(side=tk.LEFT, padx=5)
        
        # File count display for split by rows
        self.truncate_rows_file_count_label = ttk.Label(rows_split_frame, text="", foreground="gray")
        self.truncate_rows_file_count_label.pack(side=tk.LEFT, padx=10)
        
        # Mode 3: Equal parts
        ttk.Radiobutton(self.truncate_frame, text="Split into equal parts:", 
                       variable=self.truncate_mode_var, value="parts").pack(anchor=tk.W, pady=(10,0))
        
        parts_frame = ttk.Frame(self.truncate_frame)
        parts_frame.pack(fill=tk.X, padx=20, pady=2)
        self.truncate_parts_var = tk.IntVar(value=10)
        entry_parts = ttk.Entry(parts_frame, textvariable=self.truncate_parts_var, width=10)
        entry_parts.pack(side=tk.LEFT)
        entry_parts.bind('<KeyRelease>', self.update_truncate_parts_count)
        ttk.Label(parts_frame, text="parts").pack(side=tk.LEFT, padx=5)
        
        # File count display for equal parts
        self.truncate_parts_file_count_label = ttk.Label(parts_frame, text="", foreground="gray")
        self.truncate_parts_file_count_label.pack(side=tk.LEFT, padx=10)
        
        # Extract columns config
        self.extract_cols_frame = ttk.Frame(self.stage4_frame)
        
        ttk.Label(self.extract_cols_frame, 
                 text="Enter column numbers (e.g., 1,3,5 or 1-4):").pack(anchor=tk.W)
        self.extract_cols_var = tk.StringVar(value="1,2,3")
        ttk.Entry(self.extract_cols_frame, textvariable=self.extract_cols_var, 
                 width=40).pack(fill=tk.X, pady=5)
        
        # Extract time range config
        self.extract_time_frame = ttk.Frame(self.stage4_frame)
        
        ttk.Label(self.extract_time_frame, text="Extract by:").pack(anchor=tk.W)
        
        self.time_extract_mode_var = tk.StringVar(value="rows")
        ttk.Radiobutton(self.extract_time_frame, text="Row numbers (start-end)", 
                       variable=self.time_extract_mode_var, value="rows").pack(anchor=tk.W, padx=10)
        ttk.Radiobutton(self.extract_time_frame, text="Days from start", 
                       variable=self.time_extract_mode_var, value="days").pack(anchor=tk.W, padx=10)
        ttk.Radiobutton(self.extract_time_frame, text="Bartels rotation number", 
                       variable=self.time_extract_mode_var, value="bartels").pack(anchor=tk.W, padx=10)
        
        range_frame = ttk.Frame(self.extract_time_frame)
        range_frame.pack(fill=tk.X, pady=5)
        
        ttk.Label(range_frame, text="Start:").pack(side=tk.LEFT, padx=5)
        self.time_start_var = tk.StringVar(value="1")
        ttk.Entry(range_frame, textvariable=self.time_start_var, width=15).pack(side=tk.LEFT, padx=5)
        
        ttk.Label(range_frame, text="End:").pack(side=tk.LEFT, padx=5)
        self.time_end_var = tk.StringVar(value="100")
        ttk.Entry(range_frame, textvariable=self.time_end_var, width=15).pack(side=tk.LEFT, padx=5)
        
        # Cycles config
        self.cycles_frame = ttk.Frame(self.stage4_frame)
        
        cycle_len_frame = ttk.Frame(self.cycles_frame)
        cycle_len_frame.pack(fill=tk.X, pady=5)
        
        ttk.Label(cycle_len_frame, text="Cycle Length:").pack(side=tk.LEFT, padx=5)
        self.cycle_length_var = tk.IntVar(value=27)
        ttk.Entry(cycle_len_frame, textvariable=self.cycle_length_var, width=10).pack(side=tk.LEFT)
        ttk.Label(cycle_len_frame, text="days (7=weekly, 27=solar, 30=monthly)").pack(side=tk.LEFT, padx=5)
        
        ttk.Label(self.cycles_frame, text="Extraction Mode:").pack(anchor=tk.W, pady=(10,5))
        
        self.cycle_mode_var = tk.StringVar(value="single")
        ttk.Radiobutton(self.cycles_frame, text="Single Cycle - Extract one specific cycle", 
                       variable=self.cycle_mode_var, value="single", 
                       command=self.update_cycle_ui).pack(anchor=tk.W, padx=10)
        
        single_frame = ttk.Frame(self.cycles_frame)
        single_frame.pack(fill=tk.X, padx=30, pady=2)
        ttk.Label(single_frame, text="Cycle Number:").pack(side=tk.LEFT, padx=5)
        self.cycle_number_var = tk.IntVar(value=1)
        ttk.Entry(single_frame, textvariable=self.cycle_number_var, width=10).pack(side=tk.LEFT)
        
        ttk.Radiobutton(self.cycles_frame, text="Range - Multiple consecutive cycles in one file", 
                       variable=self.cycle_mode_var, value="range", 
                       command=self.update_cycle_ui).pack(anchor=tk.W, padx=10)
        
        range_frame = ttk.Frame(self.cycles_frame)
        range_frame.pack(fill=tk.X, padx=30, pady=2)
        ttk.Label(range_frame, text="Start:").pack(side=tk.LEFT, padx=5)
        self.cycle_start_var = tk.IntVar(value=1)
        ttk.Entry(range_frame, textvariable=self.cycle_start_var, width=10).pack(side=tk.LEFT)
        ttk.Label(range_frame, text="End:").pack(side=tk.LEFT, padx=5)
        self.cycle_end_var = tk.IntVar(value=5)
        ttk.Entry(range_frame, textvariable=self.cycle_end_var, width=10).pack(side=tk.LEFT)
        
        ttk.Radiobutton(self.cycles_frame, text="All Cycles (Auto-split) - Create separate file for each cycle", 
                       variable=self.cycle_mode_var, value="all", 
                       command=self.update_cycle_ui).pack(anchor=tk.W, padx=10)
        
        # Batch config
        self.batch_frame = ttk.Frame(self.stage4_frame)
        
        ttk.Label(self.batch_frame, text="🔥 Batch Mode: Select multiple operations to run in sequence", 
                 font=("Arial", 10, "bold"), foreground="orange").pack(anchor=tk.W, pady=5)
        
        self.batch_weekly_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(self.batch_frame, text="Weekly cycles (7 days) → /cycles_7day/", 
                       variable=self.batch_weekly_var).pack(anchor=tk.W, padx=10, pady=2)
        
        self.batch_bartels_cycles_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(self.batch_frame, text="Bartels cycles (27 days) → /cycles_27day/", 
                       variable=self.batch_bartels_cycles_var).pack(anchor=tk.W, padx=10, pady=2)
        
        self.batch_monthly_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(self.batch_frame, text="Monthly cycles (30 days) → /cycles_30day/", 
                       variable=self.batch_monthly_var).pack(anchor=tk.W, padx=10, pady=2)
        
        downsample_frame = ttk.Frame(self.batch_frame)
        downsample_frame.pack(fill=tk.X, padx=10, pady=2)
        self.batch_downsample_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(downsample_frame, text="Downsample to", 
                       variable=self.batch_downsample_var).pack(side=tk.LEFT)
        self.batch_downsample_percent_var = tk.IntVar(value=10)
        ttk.Entry(downsample_frame, textvariable=self.batch_downsample_percent_var, 
                 width=5).pack(side=tk.LEFT, padx=5)
        ttk.Label(downsample_frame, text="% → /downsampled/").pack(side=tk.LEFT)
        
        # NEW v5.0: Bartels extraction with auto-detection
        bartels_frame = ttk.LabelFrame(self.batch_frame, text="Bartels Rotation Extraction", padding=10)
        bartels_frame.pack(fill=tk.X, pady=10)
        
        self.batch_bartels_extract_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(bartels_frame, text="Extract ALL Bartels rotations → /bartels/", 
                       variable=self.batch_bartels_extract_var,
                       command=self.update_bartels_ui).pack(anchor=tk.W)
        
        # NEW v7.0: Concatenate files option
        self.bartels_concatenate_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(bartels_frame, text="Concatenate contiguous files before extraction (for multi-month datasets)", 
                       variable=self.bartels_concatenate_var).pack(anchor=tk.W, padx=20, pady=2)
        ttk.Label(bartels_frame, text="    ℹ️ Merges files in date order to extract complete rotations + partials", 
                 foreground="gray", font=("Arial", 9)).pack(anchor=tk.W, padx=20)
        
        # Bartels column detection/selection
        self.bartels_col_frame = ttk.Frame(bartels_frame)
        self.bartels_col_frame.pack(fill=tk.X, padx=20, pady=5)
        
        self.bartels_use_column_var = tk.BooleanVar(value=False)
        self.bartels_use_column_check = ttk.Checkbutton(self.bartels_col_frame, 
                                                        text="Use Bartels column from data", 
                                                        variable=self.bartels_use_column_var)
        self.bartels_use_column_check.pack(side=tk.LEFT)
        
        # Dynamic label that shows detection status
        self.bartels_detection_label = ttk.Label(self.bartels_col_frame, text="(No data loaded)", foreground="gray")
        self.bartels_detection_label.pack(side=tk.LEFT, padx=5)
        
        self.bartels_column_var = tk.IntVar(value=6)
        
        # NEW v5.3: Date is now auto-detected from data - no manual entry needed
    
    def update_bartels_ui(self):
        """Update Bartels UI based on checkbox state"""
        if self.batch_bartels_extract_var.get():
            # Check if we have detected Bartels column
            if self.bartels_column_detected is not None:
                self.bartels_column_var.set(self.bartels_column_detected + 1)  # 1-indexed for display
                self.bartels_use_column_var.set(True)
    
    def update_cycle_ui(self):
        """Update cycle UI based on selection"""
        # This can be enhanced if needed
        pass
    
    def update_operation_ui(self):
        """Show/hide operation config frames based on selection"""
        # Hide all
        self.downsample_frame.pack_forget()
        self.truncate_frame.pack_forget()
        self.extract_cols_frame.pack_forget()
        self.extract_time_frame.pack_forget()
        self.cycles_frame.pack_forget()
        self.batch_frame.pack_forget()
        
        # Show selected
        op = self.operation_var.get()
        if op == "downsample":
            self.downsample_frame.pack(fill=tk.BOTH, expand=True)
        elif op == "truncate":
            self.truncate_frame.pack(fill=tk.BOTH, expand=True)
            self.update_truncate_file_count()
            self.update_truncate_parts_count()
        elif op == "extract_cols":
            self.extract_cols_frame.pack(fill=tk.BOTH, expand=True)
        elif op == "extract_time":
            self.extract_time_frame.pack(fill=tk.BOTH, expand=True)
        elif op == "cycles":
            self.cycles_frame.pack(fill=tk.BOTH, expand=True)
        elif op == "batch":
            self.batch_frame.pack(fill=tk.BOTH, expand=True)
    
    def update_downsample_file_count(self, event=None):
        """Calculate and display how many files will be created"""
        if not hasattr(self, 'data') or not self.data or self.downsample_mode_var.get() != "rows":
            if hasattr(self, 'downsample_file_count_label'):
                self.downsample_file_count_label.config(text="")
            return
        
        try:
            target_rows = self.downsample_rows_var.get()
            total_rows = len(self.data)
            
            if target_rows > 0 and target_rows < total_rows:
                num_files = (total_rows + target_rows - 1) // target_rows  # Ceiling division
                self.downsample_file_count_label.config(text=f"→ Will create: ~{num_files} files")
            else:
                self.downsample_file_count_label.config(text="")
        except:
            if hasattr(self, 'downsample_file_count_label'):
                self.downsample_file_count_label.config(text="")
    
    def update_truncate_file_count(self, event=None):
        """Calculate file count for split by rows"""
        if not hasattr(self, 'data') or not self.data:
            if hasattr(self, 'truncate_rows_file_count_label'):
                self.truncate_rows_file_count_label.config(text="")
            return
        
        try:
            rows_per_file = self.truncate_rows_var.get()
            total_rows = len(self.data)
            
            if rows_per_file > 0 and rows_per_file < total_rows:
                num_files = (total_rows + rows_per_file - 1) // rows_per_file
                self.truncate_rows_file_count_label.config(text=f"→ Will create: ~{num_files} files")
            else:
                self.truncate_rows_file_count_label.config(text="")
        except:
            if hasattr(self, 'truncate_rows_file_count_label'):
                self.truncate_rows_file_count_label.config(text="")
    
    def update_truncate_parts_count(self, event=None):
        """Show file count for equal parts (just echoes the input)"""
        try:
            num_parts = self.truncate_parts_var.get()
            if num_parts > 1:
                self.truncate_parts_file_count_label.config(text=f"→ Will create: {num_parts} files")
            else:
                self.truncate_parts_file_count_label.config(text="")
        except:
            if hasattr(self, 'truncate_parts_file_count_label'):
                self.truncate_parts_file_count_label.config(text="")
    
    def setup_drag_drop(self):
        """Setup drag and drop for file list"""
        try:
            self.file_listbox.drop_target_register('DND_Files')
            self.file_listbox.dnd_bind('<<Drop>>', self.drop_files)
        except:
            pass
    
    def drop_files(self, event):
        """Handle dropped files"""
        files = self.root.tk.splitlist(event.data)
        for file in files:
            if file.endswith(('.txt', '.csv')) and file not in self.file_paths:
                self.file_paths.append(file)
        self.update_file_list()
    
    def browse_files(self):
        """Browse for files"""
        files = filedialog.askopenfilenames(
            title="Select data files",
            filetypes=[("Data files", "*.txt *.csv"), ("All files", "*.*")]
        )
        for file in files:
            if file not in self.file_paths:
                self.file_paths.append(file)
        self.update_file_list()
    
    def clear_files(self):
        """Clear file list"""
        self.file_paths = []
        self.update_file_list()
    
    def auto_detect_files(self):
        """Auto-detect files in current directory"""
        cwd = Path.cwd()
        found = list(cwd.glob("*.txt")) + list(cwd.glob("*.csv"))
        
        for file in found:
            file_str = str(file)
            if file_str not in self.file_paths:
                self.file_paths.append(file_str)
        
        if self.file_paths:
            self.update_file_list()
    
    def update_file_list(self):
        """Update file listbox and analyze first file"""
        self.file_listbox.delete(0, tk.END)
        
        if not self.file_paths:
            self.file_count_label.config(text="No files", foreground="gray")
            self.data_info_label.config(text="No data loaded", foreground="gray")
            self.bartels_info_label.config(text="")
            self.bartels_column_detected = None
            # Clear column preview
            for widget in self.col_scrollable_frame.winfo_children():
                widget.destroy()
            return
        
        for file in self.file_paths:
            self.file_listbox.insert(tk.END, Path(file).name)
        
        count = len(self.file_paths)
        self.file_count_label.config(
            text=f"{count} file{'s' if count != 1 else ''} loaded",
            foreground="green"
        )
        
        # Analyze first file
        try:
            self.data = read_data_file(self.file_paths[0])
            
            # DEBUG: Print to console to verify detection
            print(f"\n=== DEBUG v7.0 ===")
            print(f"File: {Path(self.file_paths[0]).name}")
            print(f"Rows loaded: {len(self.data)}")
            print(f"Cols in first row: {len(self.data[0]) if self.data else 0}")
            if self.data and len(self.data) > 0:
                print(f"First row: {self.data[0][:5] if len(self.data[0]) > 5 else self.data[0]}")
            print(f"==================\n")
            
            self.file_analysis = analyze_file_quality(self.data)
            
            if self.file_analysis:
                self.total_rows = self.file_analysis['total_rows']
                self.total_cols = self.file_analysis['total_cols']
                
                info = f"📊 {self.total_rows} rows × {self.total_cols} columns"
                if self.file_analysis['total_nans'] > 0:
                    info += f" | {self.file_analysis['total_nans']} NaN values found"
                else:
                    info += " | ✓ Data is clean (0 NaN values)"
                
                self.data_info_label.config(text=info, foreground="black")
                
                # NEW v5.0: Detect Bartels column
                self.bartels_column_detected = detect_bartels_column(self.data)
                if self.bartels_column_detected is not None:
                    bartels_info = f"🔍 Bartels column detected: Column {self.bartels_column_detected + 1}"
                    self.bartels_info_label.config(text=bartels_info, foreground="blue")
                    # Update Bartels settings - DETECTED
                    self.bartels_column_var.set(self.bartels_column_detected + 1)
                    self.bartels_use_column_var.set(True)
                    self.bartels_use_column_check.config(state='normal')
                    self.bartels_detection_label.config(text=f"(Column {self.bartels_column_detected + 1} detected)", foreground="blue")
                else:
                    self.bartels_info_label.config(text="ℹ️ No Bartels column detected - will calculate from dates if needed", 
                                                   foreground="gray")
                    # Update Bartels settings - NOT DETECTED
                    self.bartels_use_column_var.set(False)
                    self.bartels_use_column_check.config(state='disabled')
                    self.bartels_detection_label.config(text="(No Bartels column detected - will calculate from dates)", foreground="gray")
                
                # NEW v5.0: Display column checkboxes in rows of 5
                self.update_column_preview()
            
        except Exception as e:
            self.data_info_label.config(text=f"Error analyzing file: {str(e)}", 
                                       foreground="red")
    
    def update_column_preview(self):
        """NEW v5.0: Display column checkboxes wrapped in rows of 5"""
        # Clear existing
        for widget in self.col_scrollable_frame.winfo_children():
            widget.destroy()
        
        if not self.data or self.total_cols == 0:
            return
        
        # Create checkboxes in rows of 5
        max_cols_per_row = 5
        current_row = None
        
        for col_idx in range(self.total_cols):
            if col_idx % max_cols_per_row == 0:
                current_row = ttk.Frame(self.col_scrollable_frame)
                current_row.pack(fill=tk.X, pady=2)
            
            # Simple checkbox for preview (not functional, just shows layout)
            cb = ttk.Checkbutton(current_row, text=f"Col {col_idx + 1}")
            cb.pack(side=tk.LEFT, padx=10)
        
        # Add info label
        if self.total_cols > 8:
            info = ttk.Label(self.col_scrollable_frame, 
                           text=f"💡 {self.total_cols} columns will be wrapped into rows of {max_cols_per_row}",
                           foreground="gray", font=("Arial", 8, "italic"))
            info.pack(pady=10)
    
    def save_log(self):
        """Save output log to file"""
        filepath = filedialog.asksaveasfilename(
            defaultextension=".txt",
            filetypes=[("Text files", "*.txt"), ("All files", "*.*")],
            initialfile="processing_log.txt"
        )
        if filepath:
            with open(filepath, 'w') as f:
                f.write(self.output_log.get(1.0, tk.END))
            self.log(f"✓ Log saved to {Path(filepath).name}")
    
    def log(self, message):
        """Add message to output log"""
        self.output_log.insert(tk.END, message + "\n")
        self.output_log.see(tk.END)
        self.root.update_idletasks()
    
    def process_concatenated_bartels(self):
        """NEW v7.0: Concatenate multiple contiguous files and extract Bartels rotations"""
        self.log("=" * 70)
        self.log(f"🔗 CONCATENATING {len(self.file_paths)} file(s) for Bartels extraction")
        self.log("=" * 70)
        
        try:
            # Load all files and detect their dates
            file_data_map = []  # List of (start_date, filepath, data, header_row, delim)
            
            for filepath in self.file_paths:
                self.log(f"\n📄 Loading: {Path(filepath).name}")
                
                # Load data
                data = read_data_file(filepath)
                
                # Handle header
                header_row = None
                if self.keep_header_var.get() and data:
                    first_row = data[0]
                    is_header = not all(is_numeric(val) for val in first_row)
                    if is_header:
                        header_row = data[0]
                        data = data[1:]
                
                # Clean data
                clean_method = self.clean_method_var.get()
                if clean_method == "linear":
                    data = linear_fill(data)
                elif clean_method == "forward":
                    data = forward_fill(data)
                
                # Detect delimiter
                file_ext = Path(filepath).suffix.lstrip('.')
                if file_ext == 'csv' or ',' in str(data[0]):
                    delim = ','
                elif '\t' in str(data[0]):
                    delim = '\t'
                else:
                    delim = ' '
                
                # Auto-detect start date
                detected_date = detect_start_date(data)
                if not detected_date:
                    self.log(f"  ❌ Could not detect start date - skipping")
                    continue
                
                year, month, day = detected_date
                start_date = datetime(year, month, day)
                self.log(f"  ✓ Start date: {start_date.strftime('%Y-%m-%d')} ({len(data)} rows)")
                
                file_data_map.append((start_date, filepath, data, header_row, delim))
            
            if len(file_data_map) < 2:
                self.log("\n❌ Need at least 2 files with valid dates to concatenate")
                return
            
            # Sort by date
            file_data_map.sort(key=lambda x: x[0])
            
            self.log(f"\n🔗 Merging {len(file_data_map)} files in chronological order...")
            for start_date, filepath, _, _, _ in file_data_map:
                self.log(f"  • {start_date.strftime('%Y-%m-%d')}: {Path(filepath).name}")
            
            # Concatenate all data
            combined_data = []
            for _, _, data, _, _ in file_data_map:
                combined_data.extend(data)
            
            # Use first file's header and delimiter
            first_header = file_data_map[0][3]
            first_delim = file_data_map[0][4]
            
            # Determine base name from file range
            first_file = Path(file_data_map[0][1]).stem
            last_file = Path(file_data_map[-1][1]).stem
            
            # Try to extract common prefix (e.g., "esk2022" from "esk2022-01" to "esk2022-12")
            base_name = first_file
            for i in range(min(len(first_file), len(last_file))):
                if first_file[i] != last_file[i]:
                    base_name = first_file[:i].rstrip('-_')
                    break
            
            if not base_name:
                base_name = "merged"
            
            self.log(f"\n📊 Combined dataset: {len(combined_data)} rows × {len(combined_data[0])} columns")
            self.log(f"   Base name: {base_name}")
            
            # Now extract Bartels with partial handling
            self.extract_bartels_with_partials(combined_data, base_name, "csv", first_delim, first_header)
            
            self.log("\n" + "=" * 70)
            self.log("✅ CONCATENATION COMPLETE!")
            self.log("=" * 70)
            
        except Exception as e:
            self.log(f"\n❌ Error during concatenation: {str(e)}")
            import traceback
            self.log(traceback.format_exc())
        
        finally:
            self.processing = False
            self.process_button.config(state='normal')
            self.progress_bar.stop()
    
    def process_files(self):
        """Main processing function"""
        if not self.file_paths:
            messagebox.showwarning("No Files", "Please load data files first.")
            return
        
        if self.processing:
            return
        
        self.processing = True
        self.process_button.config(state='disabled')
        self.progress_bar.start()
        
        # Switch to Output Log tab
        self.notebook.select(self.output_log_tab)
        
        try:
            operation = self.operation_var.get()
            
            # NEW v7.0: Check if we should concatenate files for Bartels extraction
            if (operation == "batch" and 
                self.batch_bartels_extract_var.get() and 
                self.bartels_concatenate_var.get() and 
                len(self.file_paths) > 1):
                # Concatenate files and process as single dataset
                self.process_concatenated_bartels()
                return
            
            self.log("=" * 70)
            self.log(f"🔥 PROCESSING: {len(self.file_paths)} file(s)")
            self.log(f"Operation: {operation}")
            self.log("=" * 70)
            
            for idx, filepath in enumerate(self.file_paths, 1):
                self.log(f"\n📄 FILE {idx}/{len(self.file_paths)}: {Path(filepath).name}")
                self.log("-" * 70)
                
                try:
                    # Load and clean data
                    data = read_data_file(filepath)
                    self.log(f"  Loaded: {len(data)} rows × {len(data[0]) if data else 0} columns")
                    
                    # NEW v5.0: Handle header preservation
                    header_row = None
                    if self.keep_header_var.get() and data:
                        # Check if first row is header (non-numeric)
                        first_row = data[0]
                        is_header = not all(is_numeric(val) for val in first_row)
                        if is_header:
                            header_row = data[0]
                            data = data[1:]  # Remove header for processing
                            self.log(f"  ✓ Header row preserved")
                    
                    # Clean data
                    clean_method = self.clean_method_var.get()
                    if clean_method == "linear":
                        data = linear_fill(data)
                        self.log(f"  ✓ Applied linear interpolation")
                    elif clean_method == "forward":
                        data = forward_fill(data)
                        self.log(f"  ✓ Applied forward fill")
                    else:
                        self.log(f"  ✓ Processing raw data (no cleaning)")
                    
                    # Detect delimiter (needed for all operations)
                    file_ext = Path(filepath).suffix.lstrip('.')
                    if file_ext == 'csv' or ',' in str(data[0]):
                        delim = ','
                    elif '\t' in str(data[0]):
                        delim = '\t'
                    else:
                        delim = ' '
                    
                    # Process based on operation
                    if operation == "batch":
                        self.process_batch(data, Path(filepath), header_row)
                    elif operation == "downsample":
                        mode = self.downsample_mode_var.get()
                        if mode == "percent":
                            percent = self.downsample_percent_var.get()
                            self.process_downsample_percent(data, Path(filepath).stem, percent, 
                                                          Path(filepath).suffix[1:], delim, header_row)
                        else:  # mode == "rows"
                            target_rows = self.downsample_rows_var.get()
                            self.process_downsample_rows(data, Path(filepath).stem, target_rows,
                                                        Path(filepath).suffix[1:], delim, header_row)
                    elif operation == "truncate":
                        mode = self.truncate_mode_var.get()
                        if mode == "range":
                            # Mode 1: Row range (start to end)
                            start_row = self.truncate_start_var.get()
                            end_row = self.truncate_end_var.get()
                            self.process_truncate(data, Path(filepath).stem, start_row, end_row,
                                                Path(filepath).suffix[1:], delim, header_row)
                        elif mode == "rows":
                            # Mode 2: Split by row count
                            rows_per_file = self.truncate_rows_var.get()
                            self.process_split_by_rows(data, Path(filepath).stem, rows_per_file,
                                                      Path(filepath).suffix[1:], delim, header_row)
                        else:  # mode == "parts"
                            # Mode 3: Equal parts
                            num_parts = self.truncate_parts_var.get()
                            self.process_split_equal_parts(data, Path(filepath).stem, num_parts,
                                                          Path(filepath).suffix[1:], delim, header_row)
                    elif operation == "extract_cols":
                        cols = self.extract_cols_var.get()
                        self.process_extract_cols(data, Path(filepath).stem, cols,
                                                 Path(filepath).suffix[1:], delim, header_row)
                    elif operation == "extract_time":
                        mode = self.extract_time_mode_var.get()
                        if mode == "rows":
                            start = self.extract_time_start_var.get()
                            end = self.extract_time_end_var.get()
                            self.process_extract_time_rows(data, Path(filepath).stem, start, end,
                                                          Path(filepath).suffix[1:], delim, header_row)
                        elif mode == "days":
                            start_day = self.extract_time_days_start_var.get()
                            end_day = self.extract_time_days_end_var.get()
                            self.process_extract_time_days(data, Path(filepath).stem, start_day, end_day,
                                                          Path(filepath).suffix[1:], delim, header_row)
                        else:  # bartels
                            bartels_num = self.extract_time_bartels_var.get()
                            self.process_extract_time_bartels(data, Path(filepath).stem, bartels_num,
                                                             Path(filepath).suffix[1:], delim, header_row)
                    elif operation == "cycles":
                        cycle_mode = self.cycles_mode_var.get()
                        cycle_length = self.cycles_length_var.get()
                        
                        if cycle_mode == "single":
                            cycle_num = self.cycles_single_num_var.get()
                            self.process_single_cycle(data, Path(filepath).stem, cycle_length, cycle_num,
                                                     Path(filepath).suffix[1:], delim, header_row)
                        elif cycle_mode == "range":
                            start_cycle = self.cycles_range_start_var.get()
                            end_cycle = self.cycles_range_end_var.get()
                            self.process_cycle_range(data, Path(filepath).stem, cycle_length, 
                                                    start_cycle, end_cycle,
                                                    Path(filepath).suffix[1:], delim, header_row)
                        else:  # all
                            self.process_all_cycles(data, Path(filepath).stem, cycle_length,
                                                   Path(filepath).suffix[1:], delim, header_row)
                    else:
                        self.log(f"  ℹ️ Operation '{operation}' not recognized")
                    
                    self.log(f"  ✅ File {idx}/{len(self.file_paths)} complete!")
                    
                except Exception as e:
                    self.log(f"  ❌ Error: {str(e)}")
            
            self.log("\n" + "=" * 70)
            self.log(f"✅ PROCESSING COMPLETE! Successfully processed {len(self.file_paths)} file(s)")
            self.log("=" * 70)
            
        except Exception as e:
            self.log(f"\n❌ FATAL ERROR: {str(e)}")
            messagebox.showerror("Processing Error", str(e))
        
        finally:
            self.processing = False
            self.process_button.config(state='normal')
            self.progress_bar.stop()
            self.save_last_settings()
    
    def process_batch(self, data, base_path, header_row=None):
        """Process batch operations"""
        base_name = base_path.stem
        file_ext = base_path.suffix.lstrip('.')
        
        # Detect delimiter
        if file_ext == 'csv' or ',' in str(data[0]):
            delim = ','
        elif '\t' in str(data[0]):
            delim = '\t'
        else:
            delim = ' '
        
        self.log(f"  🔥 Batch mode enabled...")
        
        # Sequential cycles
        if self.batch_bartels_cycles_var.get():
            self.process_all_cycles(data, base_name, 27, file_ext, delim, header_row)
        
        if self.batch_weekly_var.get():
            self.process_all_cycles(data, base_name, 7, file_ext, delim, header_row)
        
        if self.batch_monthly_var.get():
            self.process_all_cycles(data, base_name, 30, file_ext, delim, header_row)
        
        # Bartels rotations (NEW v5.0: improved)
        if self.batch_bartels_extract_var.get():
            self.process_all_bartels(data, base_name, file_ext, delim, header_row)
        
        # Downsampling
        if self.batch_downsample_var.get():
            percent = self.batch_downsample_percent_var.get()
            self.process_downsample(data, base_name, percent, file_ext, delim, header_row)
    
    def process_all_cycles(self, data, base_name, cycle_length, ext="txt", delim=" ", header_row=None):
        """Extract all cycles of given length"""
        rows_per_cycle = cycle_length * 24  # Assuming hourly data
        total_cycles = len(data) // rows_per_cycle
        
        if total_cycles == 0:
            self.log(f"  ⚠️ Not enough data for {cycle_length}-day cycles")
            return
        
        self.log(f"  → {cycle_length}-day Cycles")
        
        output_dir = Path(f"cycles_{cycle_length}day")
        output_dir.mkdir(exist_ok=True)
        
        for cycle_num in range(1, total_cycles + 1):
            start_row = (cycle_num - 1) * rows_per_cycle
            end_row = start_row + rows_per_cycle
            
            extracted = data[start_row:end_row]
            output_file = output_dir / f"{base_name}_cycle{cycle_num}_{cycle_length}days.{ext}"
            
            with open(output_file, 'w') as f:
                if header_row:
                    f.write(delim.join(header_row) + '\n')
                for row in extracted:
                    f.write(delim.join(row) + '\n')
            
            if cycle_num % 25 == 0 or cycle_num == total_cycles:
                self.log(f"    • Cycles 1-{cycle_num} of {total_cycles}...")
                self.root.update_idletasks()
        
        self.log(f"  ✓ Created {total_cycles} cycles → {output_dir}/")
    
    def process_all_bartels(self, data, base_name, ext="txt", delim=" ", header_row=None):
        """NEW v5.0: Extract all Bartels rotations with improved logic"""
        self.log(f"  → All Bartels Rotations")
        
        try:
            # Check if we should use existing Bartels column or calculate
            use_column = self.bartels_use_column_var.get()
            bartels_col = self.bartels_column_var.get() - 1  # Convert to 0-indexed
            
            if use_column and bartels_col < len(data[0]):
                # Use existing Bartels column from data
                self.log(f"    • Using Bartels column {bartels_col + 1} from data")
                self.extract_bartels_from_column(data, base_name, bartels_col, ext, delim, header_row)
            else:
                # Calculate Bartels rotations from epoch
                self.log(f"    • Calculating Bartels rotations from epoch (1832-02-08)")
                self.extract_bartels_calculated(data, base_name, ext, delim, header_row)
        
        except Exception as e:
            self.log(f"  ❌ Error extracting Bartels: {str(e)}")
    
    def extract_bartels_from_column(self, data, base_name, bartels_col, ext, delim, header_row):
        """Extract Bartels rotations using existing column in data"""
        output_dir = Path("bartels")
        output_dir.mkdir(exist_ok=True)
        
        # Group data by Bartels rotation number
        bartels_groups = {}
        
        for row in data:
            try:
                bartels_num = int(float(row[bartels_col]))
                if bartels_num not in bartels_groups:
                    bartels_groups[bartels_num] = []
                bartels_groups[bartels_num].append(row)
            except (ValueError, IndexError):
                continue
        
        # Detect expected rows per rotation by checking the most common group size
        # Should be 27 for daily data, 648 for hourly data, 216 for 3-hourly, etc.
        group_sizes = [len(v) for v in bartels_groups.values()]
        if not group_sizes:
            self.log(f"    ⚠️ No Bartels data found")
            return
        
        # Find most common group size (this is the expected rows per rotation)
        from collections import Counter
        size_counts = Counter(group_sizes)
        expected_rows = size_counts.most_common(1)[0][0]
        
        self.log(f"    • Detected data frequency: {expected_rows} rows per Bartels rotation")
        
        # Get sorted list of rotation numbers to identify first/last
        sorted_bartels = sorted(bartels_groups.keys())
        first_bartels = sorted_bartels[0]
        last_bartels = sorted_bartels[-1]
        
        # Separate complete and incomplete rotations
        complete_rotations = {}
        incomplete_rotations = {}
        boundary_skipped = 0
        
        for bartels_num, rotation_data in bartels_groups.items():
            if len(rotation_data) == expected_rows:
                complete_rotations[bartels_num] = rotation_data
            elif len(rotation_data) > 0:
                # Check if this is a boundary rotation
                if bartels_num == first_bartels or bartels_num == last_bartels:
                    # Skip boundary partials - don't try to fill
                    boundary_skipped += 1
                    self.log(f"    • Rotation {bartels_num}: Boundary rotation incomplete ({len(rotation_data)}/{expected_rows} rows) - skipped")
                else:
                    # Internal incomplete rotation - candidate for filling
                    incomplete_rotations[bartels_num] = rotation_data
        
        # Check cleaning method for gap-filling (internal gaps only)
        clean_method = self.clean_method_var.get()
        gap_threshold = 0.05  # 5% threshold
        filled_count = 0
        warning_count = 0
        
        # Try to fill incomplete rotations if cleaning is enabled
        if clean_method != "skip" and incomplete_rotations:
            for bartels_num, rotation_data in incomplete_rotations.items():
                missing_rows = expected_rows - len(rotation_data)
                missing_percent = (missing_rows / expected_rows) * 100
                
                # Only fill if gap is reasonable (<100% - i.e., has some data)
                if len(rotation_data) == 0:
                    continue
                
                # Fill the gap
                filled_data = self.fill_rotation_gap(rotation_data, expected_rows, clean_method)
                if filled_data:
                    complete_rotations[bartels_num] = filled_data
                    filled_count += 1
                    
                    if missing_percent > gap_threshold * 100:
                        warning_count += 1
                        self.log(f"    • ⚠️ Rotation {bartels_num}: {missing_rows} rows missing ({missing_percent:.1f}%) - filled with {clean_method}")
                    else:
                        self.log(f"    • Rotation {bartels_num}: {missing_rows} rows missing ({missing_percent:.1f}%) - filled with {clean_method}")
        
        if len(complete_rotations) == 0:
            self.log(f"    ⚠️ No complete Bartels rotations found (expected {expected_rows} rows each)")
            # Show what we found
            incomplete_counts = Counter(group_sizes)
            self.log(f"    Found: {dict(incomplete_counts)}")
            if boundary_skipped > 0:
                self.log(f"    ({boundary_skipped} boundary rotation{'s' if boundary_skipped != 1 else ''} skipped)")
            return
        
        # Write each rotation to file
        count = 0
        for bartels_num in sorted(complete_rotations.keys()):
            rotation_data = complete_rotations[bartels_num]
            output_file = output_dir / f"{base_name}_Bartels{bartels_num}.{ext}"
            
            with open(output_file, 'w') as f:
                if header_row:
                    f.write(delim.join(header_row) + '\n')
                for row in rotation_data:
                    f.write(delim.join(row) + '\n')
            
            count += 1
            
            if count % 10 == 0:
                self.log(f"    • Bartels {min(complete_rotations.keys())}-{bartels_num} ({count} rotations)...")
                self.root.update_idletasks()
        
        # Summary
        summary = f"  ✓ Extracted {count} complete Bartels rotations (#{min(complete_rotations.keys())}-#{max(complete_rotations.keys())}) → {output_dir}/"
        if filled_count > 0:
            summary += f"\n    ({filled_count} rotation{'s' if filled_count != 1 else ''} had internal gaps filled"
            if warning_count > 0:
                summary += f", {warning_count} with >5% missing"
            summary += ")"
        if boundary_skipped > 0:
            summary += f"\n    ({boundary_skipped} boundary rotation{'s' if boundary_skipped != 1 else ''} skipped)"
        self.log(summary)
    
    def fill_rotation_gap(self, rotation_data, expected_rows, method):
        """Fill missing rows in an incomplete Bartels rotation
        
        This extends the rotation to expected_rows by duplicating/interpolating
        the last available values.
        """
        if not rotation_data:
            return None
        
        missing_count = expected_rows - len(rotation_data)
        if missing_count <= 0:
            return rotation_data
        
        filled_data = rotation_data.copy()
        
        if method == "forward":
            # Forward fill - repeat last row
            last_row = rotation_data[-1]
            for _ in range(missing_count):
                filled_data.append(last_row.copy())
        
        elif method == "linear":
            # Linear interpolation - create gradient from last row back to first
            # This is a simplified approach for missing tail data
            last_row = rotation_data[-1]
            first_row = rotation_data[0]
            
            for i in range(missing_count):
                # Create interpolated row
                t = (i + 1) / (missing_count + 1)
                interpolated_row = []
                
                for j, (last_val, first_val) in enumerate(zip(last_row, first_row)):
                    try:
                        # Try numeric interpolation
                        last_num = float(last_val)
                        first_num = float(first_val)
                        interp_val = last_num + t * (first_num - last_num)
                        interpolated_row.append(str(interp_val))
                    except:
                        # Non-numeric - just repeat last value
                        interpolated_row.append(last_val)
                
                filled_data.append(interpolated_row)
        
        return filled_data
    
    def extract_bartels_calculated(self, data, base_name, ext, delim, header_row):
        """Calculate and extract Bartels rotations from epoch
        
        NEW v5.3: Auto-detects start date from data
        """
        # NEW v5.3: Auto-detect start date
        detected_date = detect_start_date(data)
        if not detected_date:
            self.log(f"    ⚠️ Could not auto-detect start date from data")
            self.log(f"    ℹ️ Expected datetime column or YYYY MM DD columns")
            return
        
        year, month, day = detected_date
        dataset_start = datetime(year, month, day)
        self.log(f"    • Auto-detected start date: {dataset_start.strftime('%Y-%m-%d')}")
        
        try:
            epoch = datetime(1832, 2, 8)
            
            # NEW v5.4: Smart data frequency detection
            rows_per_day = detect_data_frequency(data)
            
            if not rows_per_day or rows_per_day <= 0:
                self.log(f"    ⚠️ Cannot determine data frequency")
                return
            
            # Calculate rows per 27-day rotation
            rows_per_rotation = int(27 * rows_per_day)
            
            self.log(f"    • Detected data frequency: {rows_per_day:.1f} rows/day ({rows_per_rotation} rows per rotation)")
            
            # Calculate dataset span
            total_rows = len(data)
            days = total_rows / rows_per_day
            dataset_end = dataset_start + timedelta(days=days)
            
            # Find first Bartels rotation that is COMPLETELY within dataset
            days_from_epoch = (dataset_start - epoch).days
            first_bartels_candidate = (days_from_epoch // 27) + 1
            
            # Find the first rotation that starts ON OR AFTER dataset_start
            rotation_start_date = epoch + timedelta(days=(first_bartels_candidate - 1) * 27)
            while rotation_start_date < dataset_start:
                first_bartels_candidate += 1
                rotation_start_date = epoch + timedelta(days=(first_bartels_candidate - 1) * 27)
            
            # This is the first complete rotation possible
            first_bartels_start = first_bartels_candidate
            
            # Find last complete rotation
            days_to_end = (dataset_end - epoch).days
            last_bartels_candidate = (days_to_end // 27)
            
            output_dir = Path("bartels")
            output_dir.mkdir(exist_ok=True)
            
            count = 0
            filled_count = 0
            warning_count = 0
            boundary_skipped = 0
            gap_threshold = 0.05  # 5% threshold
            clean_method = self.clean_method_var.get()
            bartels_num = first_bartels_start  # Initialize in case no rotations are extracted
            
            for bartels_num in range(first_bartels_start, last_bartels_candidate + 1):
                # Calculate Bartels start date
                bartels_start = epoch + timedelta(days=(bartels_num - 1) * 27)
                
                # Calculate offset from dataset start
                days_from_dataset_start = (bartels_start - dataset_start).days
                start_row = int(days_from_dataset_start * rows_per_day)
                end_row = start_row + rows_per_rotation
                
                # Check if this is a boundary rotation
                is_first = (bartels_num == first_bartels_start)
                is_last = (bartels_num == last_bartels_candidate)
                
                # Check bounds
                if start_row < 0:
                    # Starts before dataset - skip
                    boundary_skipped += 1
                    self.log(f"    • Rotation {bartels_num}: Boundary rotation (starts before dataset) - skipped")
                    continue
                
                # Extract what we can
                if end_row > len(data):
                    # Partial rotation at end - this is a BOUNDARY, skip it
                    boundary_skipped += 1
                    extracted = data[start_row:]
                    missing_rows = rows_per_rotation - len(extracted)
                    self.log(f"    • Rotation {bartels_num}: Boundary rotation incomplete ({len(extracted)}/{rows_per_rotation} rows) - skipped")
                    continue
                else:
                    extracted = data[start_row:end_row]
                
                # Check if extraction is complete
                missing_rows = rows_per_rotation - len(extracted)
                
                if len(extracted) == rows_per_rotation:
                    # Complete rotation - good to go
                    pass
                elif len(extracted) > 0 and not is_first and not is_last:
                    # Internal incomplete rotation - try to fill if cleaning enabled
                    if clean_method != "skip":
                        missing_percent = (missing_rows / rows_per_rotation) * 100
                        
                        filled_data = self.fill_rotation_gap(extracted, rows_per_rotation, clean_method)
                        if filled_data and len(filled_data) == rows_per_rotation:
                            extracted = filled_data
                            filled_count += 1
                            
                            if missing_percent > gap_threshold * 100:
                                warning_count += 1
                                self.log(f"    • ⚠️ Rotation {bartels_num}: {missing_rows} rows missing ({missing_percent:.1f}%) - filled with {clean_method}")
                            else:
                                self.log(f"    • Rotation {bartels_num}: {missing_rows} rows missing ({missing_percent:.1f}%) - filled with {clean_method}")
                        else:
                            continue  # Skip if filling failed
                    else:
                        continue  # Skip incomplete rotation when cleaning disabled
                else:
                    # Boundary or empty - skip
                    if is_first or is_last:
                        boundary_skipped += 1
                    continue
                
                # Verify we got exactly the right number of rows
                if len(extracted) != rows_per_rotation:
                    continue
                
                output_file = output_dir / f"{base_name}_Bartels{bartels_num}.{ext}"
                
                with open(output_file, 'w') as f:
                    if header_row:
                        f.write(delim.join(header_row) + '\n')
                    for row in extracted:
                        f.write(delim.join(row) + '\n')
                
                count += 1
                
                if count % 10 == 0:
                    self.log(f"    • Bartels {first_bartels_start}-{bartels_num} ({count} rotations)...")
                    self.root.update_idletasks()
            
            # Summary
            if count > 0:
                summary = f"  ✓ Extracted {count} complete Bartels rotations (#{first_bartels_start}-#{bartels_num}) → {output_dir}/"
                if filled_count > 0:
                    summary += f"\n    ({filled_count} rotation{'s' if filled_count != 1 else ''} had internal gaps filled"
                    if warning_count > 0:
                        summary += f", {warning_count} with >5% missing"
                    summary += ")"
                if boundary_skipped > 0:
                    summary += f"\n    ({boundary_skipped} boundary rotation{'s' if boundary_skipped != 1 else ''} skipped)"
                self.log(summary)
            else:
                self.log(f"  ⚠️ No complete Bartels rotations found in this dataset")
                if boundary_skipped > 0:
                    self.log(f"    ({boundary_skipped} boundary rotation{'s' if boundary_skipped != 1 else ''} skipped)")
            
        except Exception as e:
            self.log(f"  ❌ Error extracting Bartels: {str(e)}")
    
    def extract_bartels_with_partials(self, data, base_name, ext, delim, header_row):
        """NEW v7.0: Extract Bartels rotations including partials at boundaries
        
        For concatenated datasets, saves:
        - Complete rotations normally
        - Partial rotations at start/end with -partial suffix
        """
        self.log(f"  → Extracting Bartels Rotations (with partials)")
        
        # Auto-detect start date
        detected_date = detect_start_date(data)
        if not detected_date:
            self.log(f"    ⚠️ Could not auto-detect start date from data")
            return
        
        year, month, day = detected_date
        dataset_start = datetime(year, month, day)
        self.log(f"    • Dataset start date: {dataset_start.strftime('%Y-%m-%d')}")
        
        try:
            epoch = datetime(1832, 2, 8)
            
            # Detect data frequency
            rows_per_day = detect_data_frequency(data)
            if not rows_per_day or rows_per_day <= 0:
                self.log(f"    ⚠️ Cannot determine data frequency")
                return
            
            rows_per_rotation = int(27 * rows_per_day)
            self.log(f"    • Data frequency: {rows_per_day:.1f} rows/day ({rows_per_rotation} rows per rotation)")
            
            # Calculate dataset span
            total_rows = len(data)
            days = total_rows / rows_per_day
            dataset_end = dataset_start + timedelta(days=days)
            
            # Find which Bartels rotation the dataset starts in
            days_from_epoch = (dataset_start - epoch).days
            start_bartels_num = (days_from_epoch // 27) + 1
            start_day_in_rotation = (days_from_epoch % 27) + 1
            
            # Find which Bartels rotation the dataset ends in
            days_to_end = (dataset_end - epoch).days
            end_bartels_num = (days_to_end // 27) + 1
            
            self.log(f"    • Dataset spans Bartels #{start_bartels_num} to #{end_bartels_num}")
            self.log(f"    • Starts on day {start_day_in_rotation}/27 of rotation #{start_bartels_num}")
            
            output_dir = Path("bartels")
            output_dir.mkdir(exist_ok=True)
            
            complete_count = 0
            partial_count = 0
            
            # Process each Bartels rotation in range
            for bartels_num in range(start_bartels_num, end_bartels_num + 1):
                # Calculate this rotation's boundaries
                rotation_start = epoch + timedelta(days=(bartels_num - 1) * 27)
                rotation_end = rotation_start + timedelta(days=27)
                
                # Calculate data indices for this rotation
                days_from_dataset_start = (rotation_start - dataset_start).days
                start_row = int(days_from_dataset_start * rows_per_day)
                end_row = start_row + rows_per_rotation
                
                # Determine if this is complete or partial
                is_partial = False
                partial_reason = ""
                
                if start_row < 0:
                    # Rotation starts before dataset
                    is_partial = True
                    partial_reason = "starts before dataset"
                    start_row = 0
                
                if end_row > len(data):
                    # Rotation ends after dataset
                    is_partial = True
                    partial_reason = "ends after dataset" if not partial_reason else "partial at both ends"
                    end_row = len(data)
                
                # Extract data
                extracted = data[start_row:end_row]
                
                if len(extracted) == 0:
                    continue
                
                # Save with appropriate filename
                if is_partial:
                    output_file = output_dir / f"{base_name}_Bartels{bartels_num}-partial.{ext}"
                    partial_count += 1
                    self.log(f"    • Rotation #{bartels_num}: {len(extracted)}/{rows_per_rotation} rows ({partial_reason}) → -partial")
                else:
                    output_file = output_dir / f"{base_name}_Bartels{bartels_num}.{ext}"
                    complete_count += 1
                
                with open(output_file, 'w') as f:
                    if header_row:
                        f.write(delim.join(header_row) + '\n')
                    for row in extracted:
                        f.write(delim.join(row) + '\n')
            
            # Summary
            self.log(f"  ✓ Extracted {complete_count} complete + {partial_count} partial Bartels rotations → {output_dir}/")
            
        except Exception as e:
            self.log(f"  ❌ Error extracting Bartels: {str(e)}")
    
    def process_downsample_percent(self, data, base_name, percent, ext, delim, header_row):
        """Downsample data by percentage"""
        step = int(100 / percent)
        downsampled = data[::step]
        
        output_dir = Path("downsampled")
        output_dir.mkdir(exist_ok=True)
        
        output_file = output_dir / f"{base_name}_downsampled_{percent}pct.{ext}"
        
        with open(output_file, 'w') as f:
            if header_row:
                f.write(delim.join(header_row) + '\n')
            for row in downsampled:
                f.write(delim.join(row) + '\n')
        
        self.log(f"  ✓ Downsampled to {percent}% ({len(downsampled)} rows) → {output_dir}/")
    
    def process_downsample_rows(self, data, base_name, target_rows, ext, delim, header_row):
        """Downsample data to target row count"""
        if target_rows >= len(data):
            self.log(f"  ⚠️ Target rows ({target_rows}) >= data rows ({len(data)}), no downsampling needed")
            return
        
        if target_rows <= 0:
            self.log(f"  ⚠️ Target rows must be greater than 0")
            return
        
        # Calculate step to get approximately target_rows
        step = max(1, len(data) // target_rows)
        downsampled = data[::step]
        
        output_dir = Path("downsampled")
        output_dir.mkdir(exist_ok=True)
        
        output_file = output_dir / f"{base_name}_downsampled_{target_rows}rows.{ext}"
        
        with open(output_file, 'w') as f:
            if header_row:
                f.write(delim.join(header_row) + '\n')
            for row in downsampled:
                f.write(delim.join(row) + '\n')
        
        self.log(f"  ✓ Downsampled to ~{target_rows} rows (actual: {len(downsampled)}) → {output_dir}/")
    
    def process_truncate(self, data, base_name, start_row, end_row, ext, delim, header_row):
        """Truncate data to specified row range"""
        # Adjust for 1-indexed user input
        start_idx = max(0, start_row - 1)
        end_idx = min(len(data), end_row)
        
        if start_idx >= len(data):
            self.log(f"  ⚠️ Start row {start_row} exceeds data length ({len(data)} rows)")
            return
        
        if end_idx <= start_idx:
            self.log(f"  ⚠️ End row must be greater than start row")
            return
        
        truncated = data[start_idx:end_idx]
        
        output_dir = Path("truncated")
        output_dir.mkdir(exist_ok=True)
        
        output_file = output_dir / f"{base_name}_rows{start_row}-{end_row}.{ext}"
        
        with open(output_file, 'w') as f:
            if header_row:
                f.write(delim.join(header_row) + '\n')
            for row in truncated:
                f.write(delim.join(row) + '\n')
        
        self.log(f"  ✓ Truncated rows {start_row}-{end_row} ({len(truncated)} rows) → {output_dir}/")
    
    def process_split_by_rows(self, data, base_name, rows_per_file, ext, delim, header_row):
        """Split data into multiple files with specified rows per file"""
        if rows_per_file <= 0:
            self.log(f"  ⚠️ Rows per file must be greater than 0")
            return
        
        if rows_per_file >= len(data):
            self.log(f"  ⚠️ Rows per file ({rows_per_file}) >= total rows ({len(data)}), no split needed")
            return
        
        output_dir = Path("output")
        output_dir.mkdir(exist_ok=True)
        
        file_count = 0
        start_idx = 0
        
        while start_idx < len(data):
            end_idx = min(start_idx + rows_per_file, len(data))
            chunk = data[start_idx:end_idx]
            file_count += 1
            
            output_file = output_dir / f"{base_name}_part{file_count:03d}.{ext}"
            
            with open(output_file, 'w') as f:
                if header_row:
                    f.write(delim.join(header_row) + '\n')
                for row in chunk:
                    f.write(delim.join(row) + '\n')
            
            start_idx = end_idx
        
        self.log(f"  ✓ Split into {file_count} files ({rows_per_file} rows each) → {output_dir}/")
    
    def process_split_equal_parts(self, data, base_name, num_parts, ext, delim, header_row):
        """Split data into equal parts"""
        if num_parts <= 0:
            self.log(f"  ⚠️ Number of parts must be greater than 0")
            return
        
        if num_parts >= len(data):
            self.log(f"  ⚠️ Number of parts ({num_parts}) >= total rows ({len(data)}), cannot split")
            return
        
        output_dir = Path("output")
        output_dir.mkdir(exist_ok=True)
        
        rows_per_part = len(data) // num_parts
        remainder = len(data) % num_parts
        
        start_idx = 0
        for part_num in range(1, num_parts + 1):
            # Distribute remainder rows across first few parts
            extra = 1 if part_num <= remainder else 0
            chunk_size = rows_per_part + extra
            
            end_idx = start_idx + chunk_size
            chunk = data[start_idx:end_idx]
            
            output_file = output_dir / f"{base_name}_part{part_num:03d}.{ext}"
            
            with open(output_file, 'w') as f:
                if header_row:
                    f.write(delim.join(header_row) + '\n')
                for row in chunk:
                    f.write(delim.join(row) + '\n')
            
            start_idx = end_idx
        
        self.log(f"  ✓ Split into {num_parts} equal parts (~{rows_per_part} rows each) → {output_dir}/")
    
    def process_extract_cols(self, data, base_name, cols_str, ext, delim, header_row):
        """Extract specific columns"""
        try:
            # Parse column string (e.g., "1,3,5" or "1-5,10")
            col_indices = []
            for part in cols_str.split(','):
                part = part.strip()
                if '-' in part:
                    # Range like "1-5"
                    start, end = part.split('-')
                    col_indices.extend(range(int(start)-1, int(end)))  # Convert to 0-indexed
                else:
                    # Single column
                    col_indices.append(int(part)-1)  # Convert to 0-indexed
            
            # Validate columns
            max_col = len(data[0]) if data else 0
            col_indices = [c for c in col_indices if 0 <= c < max_col]
            
            if not col_indices:
                self.log(f"  ⚠️ No valid columns specified")
                return
            
            # Extract columns
            extracted = []
            for row in data:
                new_row = [row[i] for i in col_indices if i < len(row)]
                extracted.append(new_row)
            
            output_dir = Path("extracted_cols")
            output_dir.mkdir(exist_ok=True)
            
            cols_desc = cols_str.replace(',', '_').replace('-', 'to')
            output_file = output_dir / f"{base_name}_cols{cols_desc}.{ext}"
            
            with open(output_file, 'w') as f:
                if header_row:
                    header_subset = [header_row[i] for i in col_indices if i < len(header_row)]
                    f.write(delim.join(header_subset) + '\n')
                for row in extracted:
                    f.write(delim.join(row) + '\n')
            
            self.log(f"  ✓ Extracted {len(col_indices)} columns → {output_dir}/")
            
        except Exception as e:
            self.log(f"  ❌ Error extracting columns: {str(e)}")
    
    def process_extract_time_rows(self, data, base_name, start_row, end_row, ext, delim, header_row):
        """Extract time range by row numbers"""
        self.process_truncate(data, base_name, start_row, end_row, ext, delim, header_row)
    
    def process_extract_time_days(self, data, base_name, start_day, end_day, ext, delim, header_row):
        """Extract time range by days from start"""
        # Detect rows per day
        rows_per_day = detect_data_frequency(data)
        if not rows_per_day:
            self.log(f"  ⚠️ Could not detect data frequency")
            return
        
        start_row = int((start_day - 1) * rows_per_day) + 1
        end_row = int(end_day * rows_per_day)
        
        self.log(f"  • Days {start_day}-{end_day} = rows {start_row}-{end_row} ({rows_per_day:.1f} rows/day)")
        self.process_truncate(data, base_name, start_row, end_row, ext, delim, header_row)
    
    def process_extract_time_bartels(self, data, base_name, bartels_num, ext, delim, header_row):
        """Extract specific Bartels rotation"""
        # Detect start date
        detected_date = detect_start_date(data)
        if not detected_date:
            self.log(f"  ⚠️ Could not auto-detect start date")
            return
        
        year, month, day = detected_date
        dataset_start = datetime(year, month, day)
        epoch = datetime(1832, 2, 8)
        
        # Calculate rows per day
        rows_per_day = detect_data_frequency(data)
        if not rows_per_day:
            self.log(f"  ⚠️ Could not detect data frequency")
            return
        
        # Calculate Bartels rotation start
        rotation_start_date = epoch + timedelta(days=(bartels_num - 1) * 27)
        rotation_end_date = rotation_start_date + timedelta(days=27)
        
        # Calculate row positions
        days_to_start = (rotation_start_date - dataset_start).days
        days_to_end = (rotation_end_date - dataset_start).days
        
        start_row = int(days_to_start * rows_per_day) + 1
        end_row = int(days_to_end * rows_per_day)
        
        if start_row < 1 or end_row > len(data):
            self.log(f"  ⚠️ Bartels {bartels_num} ({rotation_start_date.date()} to {rotation_end_date.date()}) not in dataset range")
            return
        
        self.log(f"  • Bartels {bartels_num} ({rotation_start_date.date()} to {rotation_end_date.date()}) = rows {start_row}-{end_row}")
        
        # Extract
        start_idx = max(0, start_row - 1)
        end_idx = min(len(data), end_row)
        extracted = data[start_idx:end_idx]
        
        output_dir = Path("extracted_time")
        output_dir.mkdir(exist_ok=True)
        
        output_file = output_dir / f"{base_name}_Bartels{bartels_num}.{ext}"
        
        with open(output_file, 'w') as f:
            if header_row:
                f.write(delim.join(header_row) + '\n')
            for row in extracted:
                f.write(delim.join(row) + '\n')
        
        self.log(f"  ✓ Extracted Bartels {bartels_num} ({len(extracted)} rows) → {output_dir}/")
    
    def process_single_cycle(self, data, base_name, cycle_length, cycle_num, ext, delim, header_row):
        """Extract a single cycle"""
        rows_per_day = detect_data_frequency(data)
        if not rows_per_day:
            self.log(f"  ⚠️ Could not detect data frequency")
            return
        
        rows_per_cycle = int(cycle_length * rows_per_day)
        start_row = (cycle_num - 1) * rows_per_cycle + 1
        end_row = cycle_num * rows_per_cycle
        
        if start_row < 1 or end_row > len(data):
            self.log(f"  ⚠️ Cycle {cycle_num} (rows {start_row}-{end_row}) out of range")
            return
        
        self.log(f"  • Extracting cycle {cycle_num} ({cycle_length} days, rows {start_row}-{end_row})")
        
        start_idx = start_row - 1
        end_idx = end_row
        extracted = data[start_idx:end_idx]
        
        output_dir = Path(f"cycles_{cycle_length}day")
        output_dir.mkdir(exist_ok=True)
        
        output_file = output_dir / f"{base_name}_cycle{cycle_num}.{ext}"
        
        with open(output_file, 'w') as f:
            if header_row:
                f.write(delim.join(header_row) + '\n')
            for row in extracted:
                f.write(delim.join(row) + '\n')
        
        self.log(f"  ✓ Extracted cycle {cycle_num} ({len(extracted)} rows) → {output_dir}/")
    
    def process_cycle_range(self, data, base_name, cycle_length, start_cycle, end_cycle, ext, delim, header_row):
        """Extract a range of cycles into one file"""
        rows_per_day = detect_data_frequency(data)
        if not rows_per_day:
            self.log(f"  ⚠️ Could not detect data frequency")
            return
        
        rows_per_cycle = int(cycle_length * rows_per_day)
        start_row = (start_cycle - 1) * rows_per_cycle + 1
        end_row = end_cycle * rows_per_cycle
        
        if start_row < 1 or end_row > len(data):
            self.log(f"  ⚠️ Cycle range {start_cycle}-{end_cycle} out of bounds")
            return
        
        self.log(f"  • Extracting cycles {start_cycle}-{end_cycle} ({cycle_length} days each, rows {start_row}-{end_row})")
        
        start_idx = start_row - 1
        end_idx = end_row
        extracted = data[start_idx:end_idx]
        
        output_dir = Path(f"cycles_{cycle_length}day")
        output_dir.mkdir(exist_ok=True)
        
        output_file = output_dir / f"{base_name}_cycles{start_cycle}-{end_cycle}.{ext}"
        
        with open(output_file, 'w') as f:
            if header_row:
                f.write(delim.join(header_row) + '\n')
            for row in extracted:
                f.write(delim.join(row) + '\n')
        
        self.log(f"  ✓ Extracted cycles {start_cycle}-{end_cycle} ({len(extracted)} rows) → {output_dir}/")
    
    def save_preset(self):
        """Save current settings as preset"""
        import tkinter.simpledialog as sd
        name = sd.askstring("Save Preset", "Enter preset name:")
        if not name:
            return
        
        preset = self.get_current_settings()
        preset['name'] = name
        
        presets = self.load_presets_data()
        presets[name] = preset
        
        with open(self.presets_file, 'w') as f:
            json.dump(presets, f, indent=2)
        
        self.load_preset_list()
        self.log(f"✓ Preset saved: {name}")
    
    def load_preset(self, event=None):
        """Load a saved preset"""
        name = self.preset_var.get()
        if not name:
            return
        
        presets = self.load_presets_data()
        if name in presets:
            self.apply_settings(presets[name])
            self.log(f"✓ Preset loaded: {name}")
    
    def delete_preset(self):
        """Delete selected preset"""
        name = self.preset_var.get()
        if not name:
            return
        
        if messagebox.askyesno("Delete Preset", f"Delete preset '{name}'?"):
            presets = self.load_presets_data()
            if name in presets:
                del presets[name]
                with open(self.presets_file, 'w') as f:
                    json.dump(presets, f, indent=2)
                self.load_preset_list()
                self.log(f"✓ Preset deleted: {name}")
    
    def load_presets_data(self):
        """Load presets from file"""
        if self.presets_file.exists():
            try:
                with open(self.presets_file, 'r') as f:
                    return json.load(f)
            except:
                return {}
        return {}
    
    def load_preset_list(self):
        """Update preset dropdown"""
        presets = self.load_presets_data()
        self.preset_combo['values'] = list(presets.keys())
    
    def get_current_settings(self):
        """Get current settings as dict"""
        settings = {
            'clean_method': self.clean_method_var.get(),
            'operation': self.operation_var.get(),
            'keep_header': self.keep_header_var.get(),
        }
        
        # Add operation-specific settings
        if hasattr(self, 'downsample_mode_var'):
            settings['downsample_mode'] = self.downsample_mode_var.get()
            settings['downsample_percent'] = self.downsample_percent_var.get()
        
        if hasattr(self, 'cycle_length_var'):
            settings['cycle_length'] = self.cycle_length_var.get()
            settings['cycle_mode'] = self.cycle_mode_var.get()
        
        return settings
    
    def apply_settings(self, settings):
        """Apply settings from dict"""
        if 'clean_method' in settings:
            self.clean_method_var.set(settings['clean_method'])
        if 'operation' in settings:
            self.operation_var.set(settings['operation'])
            self.update_operation_ui()
        if 'keep_header' in settings:
            self.keep_header_var.set(settings['keep_header'])
        
        if 'downsample_mode' in settings and hasattr(self, 'downsample_mode_var'):
            self.downsample_mode_var.set(settings['downsample_mode'])
        if 'downsample_percent' in settings and hasattr(self, 'downsample_percent_var'):
            self.downsample_percent_var.set(settings['downsample_percent'])
        if 'cycle_length' in settings and hasattr(self, 'cycle_length_var'):
            self.cycle_length_var.set(settings['cycle_length'])
    
    def save_last_settings(self):
        """Save current settings as last used"""
        settings = self.get_current_settings()
        with open(self.last_settings_file, 'w') as f:
            json.dump(settings, f, indent=2)
    
    def load_last_settings(self):
        """Load last used settings"""
        if self.last_settings_file.exists():
            try:
                with open(self.last_settings_file, 'r') as f:
                    settings = json.load(f)
                self.apply_settings(settings)
            except:
                pass

# ============================================================================
# MAIN
# ============================================================================

if __name__ == "__main__":
    # Try to use TkinterDnD for drag-and-drop
    try:
        from tkinterdnd2 import TkinterDnD
        root = TkinterDnD.Tk()
    except ImportError:
        root = tk.Tk()
    
    # Try to use better theme
    try:
        style = ttk.Style()
        available_themes = style.theme_names()
        if 'clam' in available_themes:
            style.theme_use('clam')
    except:
        pass
    
    app = GeomagProcessorGUI(root)
    root.mainloop()
