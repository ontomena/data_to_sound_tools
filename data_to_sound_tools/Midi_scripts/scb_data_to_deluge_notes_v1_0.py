#!/usr/bin/env python3
"""
SCB Data to Deluge Notes
Version 1.0 - Converts a single column of geomagnetic CSV data into a
              Synthstrom Deluge MIDI clip XML file (notes + optional velocity).

              One column → pitch (quantised to scale, mapped across MIDI range).
              Optional second column → per-note velocity.

              Output is a Deluge MIDI clip: copy to SONGS/ on SD card.
              Assign the clip's MIDI channel to a synth or external instrument
              on the Deluge.

Part of the Magnet Opus Geomagnetic Sonification Toolkit

No extra dependencies beyond the Python standard library.

Naming convention: scb_data_to_deluge_notes_v1_0.py
"""

import tkinter as tk
from tkinter import ttk, filedialog, scrolledtext, messagebox
import struct
import json
from pathlib import Path

# ============================================================================
# PREFS FILE
# ============================================================================

PREFS_FILE = Path(__file__).parent / "scb_deluge_notes_prefs.json"

# ============================================================================
# SCALE DEFINITIONS
# ============================================================================

SCALES = {
    'Chromatic':           [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
    'Ionian (Major)':      [0, 2, 4, 5, 7, 9, 11],
    'Dorian':              [0, 2, 3, 5, 7, 9, 10],
    'Phrygian':            [0, 1, 3, 5, 7, 8, 10],
    'Lydian':              [0, 2, 4, 6, 7, 9, 11],
    'Mixolydian':          [0, 2, 4, 5, 7, 9, 10],
    'Aeolian (Minor)':     [0, 2, 3, 5, 7, 8, 10],
    'Locrian':             [0, 1, 3, 5, 6, 8, 10],
    'Pentatonic Major':    [0, 2, 4, 7, 9],
    'Pentatonic Minor':    [0, 3, 5, 7, 10],
}

SCALE_NAMES = list(SCALES.keys())

NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']

DELUGE_PPQN = 48   # ticks per quarter note

# ============================================================================
# DATA READING
# ============================================================================

def _is_float(s):
    try:
        float(s)
        return True
    except ValueError:
        return False


def read_csv_data(filepath):
    """Read CSV/TXT, return (header_or_None, data_rows, delimiter)."""
    path = Path(filepath)
    ext = path.suffix.lower()

    with open(filepath, 'r', encoding='utf-8') as f:
        all_lines = [line.strip() for line in f if line.strip()]

    data_lines   = [l for l in all_lines if not l.startswith('#')]
    comment_lines = [l for l in all_lines if l.startswith('#')]

    if not data_lines:
        return None, [], ','

    first = data_lines[0]
    if ext == '.csv' or ',' in first:
        delim = ','
    elif '\t' in first:
        delim = '\t'
    else:
        delim = ' '

    rows = [line.split(delim) for line in data_lines]

    header = None
    if rows:
        non_num = sum(1 for t in rows[0] if not _is_float(t.strip()))
        if non_num >= len(rows[0]) * 0.6:
            header = [t.strip() for t in rows[0]]
            rows = rows[1:]

    if header is None and comment_lines:
        potential = comment_lines[-1].lstrip('#').strip()
        tokens = potential.replace(',', ' ').replace('\t', ' ').split()
        if len(tokens) >= 2:
            non_num = sum(1 for t in tokens if not _is_float(t))
            if non_num >= len(tokens) * 0.5:
                if delim == ',':
                    header = [t.strip() for t in potential.split(',')]
                elif delim == '\t':
                    header = [t.strip() for t in potential.split('\t')]
                else:
                    header = tokens

    return header, rows, delim


def extract_numeric_columns(header, rows):
    """Return {col_idx: (col_name, [float_values])} for numeric columns."""
    if not rows:
        return {}
    num_cols = max(len(r) for r in rows)
    result = {}
    for col_idx in range(num_cols):
        values, valid, total = [], 0, 0
        for row in rows:
            total += 1
            if col_idx < len(row):
                try:
                    values.append(float(row[col_idx].strip()))
                    valid += 1
                except ValueError:
                    values.append(None)
            else:
                values.append(None)
        if total > 0 and valid / total > 0.8:
            name = (header[col_idx] if header and col_idx < len(header)
                    else f"Col {col_idx + 1}")
            values = _interpolate_nones(values)
            result[col_idx] = (name, values)
    return result


def _interpolate_nones(values):
    result = list(values)
    i = 0
    while i < len(result):
        if result[i] is None:
            start = i
            while i < len(result) and result[i] is None:
                i += 1
            end = i
            before = result[start - 1] if start > 0 else 0.0
            after  = result[end] if end < len(result) else before
            gap    = end - start
            for j in range(gap):
                result[start + j] = before + (after - before) * (j + 1) / (gap + 1)
        else:
            i += 1
    return result


# ============================================================================
# MIDI / NOTE UTILITIES
# ============================================================================

def quantise_to_scale(midi_float, scale_intervals):
    note   = int(round(midi_float))
    octave = note // 12
    pc     = note % 12
    best, best_dist = scale_intervals[0], 999
    for degree in scale_intervals:
        d = min(abs(pc - degree), 12 - abs(pc - degree))
        if d < best_dist:
            best_dist = d
            best = degree
    return max(0, min(127, octave * 12 + best))


def note_name(midi_note):
    return f"{NOTE_NAMES[midi_note % 12]}{midi_note // 12 - 1}"


# ============================================================================
# DELUGE XML GENERATION
# ============================================================================

def bpm_to_deluge_tempo(bpm):
    ref_bpm, ref_tpt, ref_frac = 120.0, 328, 536870912
    ref_combined = ref_tpt * (2 ** 32) + ref_frac
    combined = int(ref_combined * ref_bpm / bpm)
    tpt  = combined >> 32
    frac = combined & 0xFFFFFFFF
    if frac >= 2 ** 31:
        frac -= 2 ** 32
    return tpt, frac


def encode_note_data(events):
    """
    events: list of (pos_ticks, dur_ticks, velocity)
    Returns Deluge noteDataWithLift hex string.
    11 bytes per note: pos(4) dur(4) vel(1) lift(1) prob(1)
    """
    parts = []
    for pos, dur, vel in sorted(events, key=lambda e: e[0]):
        parts.append(struct.pack('>II', pos, dur) + bytes([vel, 64, 20]))
    return '0x' + ''.join(p.hex().upper() for p in parts)


def generate_xml(pitch_col_name, pitch_values, vel_values,
                 midi_low, midi_high, scale_name,
                 midi_channel, tempo, duration_ms, default_velocity,
                 output_path, log_func=None):
    """Build and write a Deluge MIDI clip XML song file."""

    scale_intervals = SCALES[scale_name]
    tpt, frac = bpm_to_deluge_tempo(tempo)

    ms_per_tick = 60000.0 / (tempo * DELUGE_PPQN)
    dur_ticks   = max(1, int(round(duration_ms / ms_per_tick)))

    data_min = min(pitch_values)
    data_max = max(pitch_values)
    data_range = (data_max - data_min) or 1.0
    midi_range = midi_high - midi_low

    # Velocity source
    if vel_values:
        vel_min = min(vel_values)
        vel_max = max(vel_values)
        vel_range = (vel_max - vel_min) or 1.0

    # Build note events grouped by pitch (one noteRow per MIDI note)
    pitch_events = {}   # midi_note -> [(pos, dur, vel), ...]
    for i, val in enumerate(pitch_values):
        if val is None:
            continue
        pos = i * dur_ticks
        norm = (val - data_min) / data_range
        midi_float = midi_low + norm * midi_range
        midi_note  = quantise_to_scale(midi_float, scale_intervals)

        if vel_values and i < len(vel_values) and vel_values[i] is not None:
            v_norm = (vel_values[i] - vel_min) / vel_range
            vel    = max(1, min(127, int(1 + v_norm * 126)))
        else:
            vel = default_velocity

        if midi_note not in pitch_events:
            pitch_events[midi_note] = []
        pitch_events[midi_note].append((pos, dur_ticks, vel))

    if not pitch_events:
        if log_func:
            log_func("❌ No note events generated.")
        return False

    total_notes = sum(len(v) for v in pitch_events.values())
    max_pos     = max(pos for evts in pitch_events.values() for pos, _, _ in evts)
    ticks_per_bar = DELUGE_PPQN * 4
    clip_length   = ((max_pos + dur_ticks + ticks_per_bar - 1) // ticks_per_bar) * ticks_per_bar

    all_notes = sorted(pitch_events.keys())
    mid_note  = all_notes[len(all_notes) // 2]
    y_scroll  = max(0, mid_note - 7)
    ch_zero   = midi_channel - 1   # Deluge is 0-indexed

    if log_func:
        log_func(f"  {total_notes} notes | {len(pitch_events)} pitches "
                 f"({note_name(all_notes[0])}–{note_name(all_notes[-1])}) | "
                 f"{clip_length // ticks_per_bar} bars")
        if vel_values:
            log_func(f"  Velocity: from {pitch_col_name} vel column")

    # Build noteRows XML
    note_rows_xml = []
    for midi_note in sorted(pitch_events.keys()):
        hex_data = encode_note_data(pitch_events[midi_note])
        note_rows_xml.append(
            f'\t\t\t\t<noteRow\n'
            f'\t\t\t\t\ty="{midi_note}"\n'
            f'\t\t\t\t\tnoteDataWithLift="{hex_data}" />'
        )
    note_rows_str = '\n'.join(note_rows_xml)

    # Sections (Deluge expects 12)
    sections_xml = '\n'.join(
        f'\t\t<section id="{i}" numRepeats="0" />' for i in range(12)
    )

    song_xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<song
\tfirmwareVersion="c1.2.0"
\tearliestCompatibleFirmware="4.1.0-alpha"
\tpreviewNumPads="144"
\tpreview=""
\tarrangementAutoScrollOn="0"
\txScroll="0"
\txZoom="24"
\tyScrollSongView="-6"
\tyScrollArrangementView="-6"
\txScrollArrangementView="0"
\txZoomArrangementView="192"
\ttimePerTimerTick="{tpt}"
\ttimerTickFraction="{frac}"
\trootNote="0"
\tinputTickMagnitude="2"
\tswingAmount="0"
\tswingInterval="7"
\taffectEntire="0"
\tactiveModFunction="0"
\tmodFXCurrentParam="feedback"
\tcurrentFilterType="lpf"
\tmodFXType="none"
\tlpfMode="24dB"
\thpfMode="HPLadder"
\tfilterRoute="H2L"
\tsongGridScrollX="0"
\tsongGridScrollY="0"
\tsessionLayout="0">
\t<modeNotes>
\t\t<modeNote>0</modeNote>
\t\t<modeNote>2</modeNote>
\t\t<modeNote>4</modeNote>
\t\t<modeNote>5</modeNote>
\t\t<modeNote>7</modeNote>
\t\t<modeNote>9</modeNote>
\t\t<modeNote>11</modeNote>
\t</modeNotes>
\t<reverb
\t\troomSize="1288490112"
\t\tdampening="1546188288"
\t\twidth="2147483647"
\t\thpf="0"
\t\tpan="0"
\t\tmodel="1">
\t\t<compressor
\t\t\tattack="-254"
\t\t\trelease="384"
\t\t\tvolume="-21474836"
\t\t\tshape="-601295438"
\t\t\tsyncLevel="4" />
\t</reverb>
\t<delay
\t\tpingPong="1"
\t\tanalog="0"
\t\tsyncLevel="7"
\t\tsyncType="0" />
\t<sidechain
\t\tattack="327244"
\t\trelease="936"
\t\tsyncLevel="6"
\t\tsyncType="0" />
\t<audioCompressor
\t\tattack="83886080"
\t\trelease="83886080"
\t\tthresh="0"
\t\tratio="1073741824"
\t\tcompHPF="0"
\t\tcompBlend="2147483647" />
\t<songParams
\t\treverbAmount="0x80000000"
\t\tvolume="0x3504F334"
\t\tpan="0x00000000"
\t\tsidechainCompressorShape="0xDC28F5B2"
\t\tmodFXDepth="0x00000000"
\t\tmodFXRate="0xE0000000"
\t\tstutterRate="0x00000000"
\t\tsampleRateReduction="0x80000000"
\t\tbitCrush="0x80000000"
\t\tmodFXOffset="0x00000000"
\t\tmodFXFeedback="0x80000000"
\t\tcompressorThreshold="0x00000000"
\t\tlpfMorph="0x80000000"
\t\thpfMorph="0x80000000"
\t\ttempo="0x00002EE0">
\t\t<delay
\t\t\trate="0x00000000"
\t\t\tfeedback="0x80000000" />
\t\t<lpf
\t\t\tfrequency="0x7FFFFFFF"
\t\t\tresonance="0x80000000" />
\t\t<hpf
\t\t\tfrequency="0x80000000"
\t\t\tresonance="0x80000000" />
\t\t<equalizer
\t\t\tbass="0x00000000"
\t\t\ttreble="0x00000000"
\t\t\tbassFrequency="0x00000000"
\t\t\ttrebleFrequency="0x00000000" />
\t</songParams>
\t<instruments>
\t\t<midi
\t\t\tchannel="{ch_zero}"
\t\t\tsuffix="-1"
\t\t\tdefaultVelocity="64"
\t\t\tisArmedForRecording="0"
\t\t\tactiveModFunction="0"
\t\t\tcolour="0" />
\t</instruments>
\t<sections>
{sections_xml}
\t</sections>
\t<sessionClips>
\t\t<instrumentClip
\t\t\tclipName="{pitch_col_name}"
\t\t\tinKeyMode="0"
\t\t\tyScroll="{y_scroll}"
\t\t\tyScrollKeyboard="50"
\t\t\tmidiChannel="{ch_zero}"
\t\t\tisPlaying="0"
\t\t\tisSoloing="0"
\t\t\tisArmedForRecording="0"
\t\t\tlength="{clip_length}"
\t\t\tcolourOffset="0"
\t\t\tsection="0"
\t\t\tkeyboardLayout="0"
\t\t\tkeyboardRowInterval="5"
\t\t\tdrumsScrollOffset="0"
\t\t\tdrumsEdgeSize="4"
\t\t\tinKeyScrollOffset="21"
\t\t\tinKeyRowInterval="3">
\t\t\t<arpeggiator
\t\t\t\tmode="off"
\t\t\t\tsyncLevel="6"
\t\t\t\tnumOctaves="2"
\t\t\t\tsyncType="0"
\t\t\t\tarpMode="off"
\t\t\t\tnoteMode="up"
\t\t\t\toctaveMode="up"
\t\t\t\tmpeVelocity="off" />
\t\t\t<columnControls>
\t\t\t\t<leftCol
\t\t\t\t\ttype="velocity" />
\t\t\t\t<rightCol
\t\t\t\t\ttype="mod" />
\t\t\t</columnControls>
\t\t\t<noteRows>
{note_rows_str}
\t\t\t</noteRows>
\t\t</instrumentClip>
\t</sessionClips>
\t<sessionMacros>
\t\t<macro />
\t\t<macro />
\t\t<macro />
\t\t<macro />
\t\t<macro />
\t\t<macro />
\t\t<macro />
\t\t<macro />
\t</sessionMacros>
\t<scales>
\t\t<userScale>0</userScale>
\t\t<disabledPresetScales>0</disabledPresetScales>
\t</scales>
</song>
'''

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(song_xml)

    if log_func:
        log_func(f"\n✅ Written: {output_path}")
        log_func(f"   Copy to SONGS/ on Deluge SD card")
        log_func(f"   Assign MIDI ch {midi_channel} to a synth or external instrument")

    return True


# ============================================================================
# GUI
# ============================================================================

class DelugeNotesGUI:

    DEFAULTS = {
        'tempo':     '120',
        'duration':  '250',
        'velocity':  '80',
        'midi_low':  48,
        'midi_high': 84,
        'scale':     'Chromatic',
        'channel':   1,
        'output_dir':  '',
        'output_stem': '',
    }

    def __init__(self, root):
        self.root = root
        self.root.title("SCB Deluge Notes v1.0")
        self.root.geometry("680x620")
        self.root.minsize(500, 480)

        self.file_path       = None
        self.numeric_columns = {}

        self._build_gui()
        self._try_restore()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    # ------------------------------------------------------------------
    def _build_gui(self):
        # Header bar
        hbar = ttk.Frame(self.root, padding=(5, 5, 5, 0))
        hbar.pack(fill=tk.X, side=tk.TOP)

        ttk.Label(hbar, text="Dir:").pack(side=tk.LEFT, padx=(5, 2))
        self.out_dir_var = tk.StringVar()
        ttk.Entry(hbar, textvariable=self.out_dir_var, width=28).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=2)
        ttk.Button(hbar, text="Browse…", width=8,
                   command=self._browse_output_dir).pack(side=tk.LEFT, padx=2)

        ttk.Separator(hbar, orient='vertical').pack(side=tk.LEFT, fill=tk.Y, padx=4, pady=2)

        ttk.Label(hbar, text="File:").pack(side=tk.LEFT, padx=(2, 2))
        self.out_stem_var = tk.StringVar()
        ttk.Entry(hbar, textvariable=self.out_stem_var, width=18).pack(
            side=tk.LEFT, padx=2)

        ttk.Separator(hbar, orient='vertical').pack(side=tk.LEFT, fill=tk.Y, padx=4, pady=2)

        self.gen_btn = ttk.Button(hbar, text="▶  GENERATE", command=self._generate)
        self.gen_btn.pack(side=tk.LEFT, padx=(2, 5))

        self.progress = ttk.Progressbar(self.root, mode='indeterminate')
        self.progress.pack(fill=tk.X, side=tk.TOP, padx=5)
        ttk.Separator(self.root, orient='horizontal').pack(fill=tk.X, pady=2)

        # Main content
        main = ttk.Frame(self.root, padding=10)
        main.pack(fill=tk.BOTH, expand=True)

        # --- File ---
        file_frame = ttk.LabelFrame(main, text="Input CSV File", padding=8)
        file_frame.pack(fill=tk.X, pady=(0, 8))

        fr = ttk.Frame(file_frame)
        fr.pack(fill=tk.X)
        ttk.Button(fr, text="Browse…", command=self._browse_file,
                   width=10).pack(side=tk.LEFT, padx=5)
        self.file_label = ttk.Label(fr, text="No file loaded", foreground="gray")
        self.file_label.pack(side=tk.LEFT, padx=8)
        self.data_info = ttk.Label(file_frame, text="", foreground="blue")
        self.data_info.pack(anchor=tk.W, pady=(4, 0))

        # --- Column selection ---
        col_frame = ttk.LabelFrame(main, text="Column Selection", padding=8)
        col_frame.pack(fill=tk.X, pady=(0, 8))

        # Pitch column
        pr = ttk.Frame(col_frame)
        pr.pack(fill=tk.X, pady=2)
        ttk.Label(pr, text="Pitch column:", width=16).pack(side=tk.LEFT)
        self.pitch_col_var = tk.StringVar()
        self.pitch_combo = ttk.Combobox(pr, textvariable=self.pitch_col_var,
                                         state='readonly', width=22)
        self.pitch_combo.pack(side=tk.LEFT, padx=5)

        # Velocity column (optional)
        vr = ttk.Frame(col_frame)
        vr.pack(fill=tk.X, pady=2)
        ttk.Label(vr, text="Velocity column:", width=16).pack(side=tk.LEFT)
        self.vel_col_var = tk.StringVar(value="(none)")
        self.vel_combo = ttk.Combobox(vr, textvariable=self.vel_col_var,
                                       state='readonly', width=22)
        self.vel_combo.pack(side=tk.LEFT, padx=5)
        ttk.Label(vr, text="optional", foreground="gray",
                  font=("Arial", 8)).pack(side=tk.LEFT, padx=5)

        # --- Pitch settings ---
        pitch_frame = ttk.LabelFrame(main, text="Pitch Settings", padding=8)
        pitch_frame.pack(fill=tk.X, pady=(0, 8))

        row1 = ttk.Frame(pitch_frame)
        row1.pack(fill=tk.X, pady=2)
        ttk.Label(row1, text="MIDI range:", width=14).pack(side=tk.LEFT)
        ttk.Label(row1, text="Low:").pack(side=tk.LEFT, padx=(8, 2))
        self.midi_low_var = tk.IntVar(value=self.DEFAULTS['midi_low'])
        self.low_spin = ttk.Spinbox(row1, from_=0, to=127,
                                     textvariable=self.midi_low_var, width=5)
        self.low_spin.pack(side=tk.LEFT)
        ttk.Label(row1, text="High:").pack(side=tk.LEFT, padx=(10, 2))
        self.midi_high_var = tk.IntVar(value=self.DEFAULTS['midi_high'])
        self.high_spin = ttk.Spinbox(row1, from_=0, to=127,
                                      textvariable=self.midi_high_var, width=5)
        self.high_spin.pack(side=tk.LEFT)
        self.range_hint = ttk.Label(row1, text="", foreground="gray", font=("Arial", 8))
        self.range_hint.pack(side=tk.LEFT, padx=10)
        self.midi_low_var.trace_add('write', self._update_range_hint)
        self.midi_high_var.trace_add('write', self._update_range_hint)

        row2 = ttk.Frame(pitch_frame)
        row2.pack(fill=tk.X, pady=2)
        ttk.Label(row2, text="Scale:", width=14).pack(side=tk.LEFT)
        self.scale_var = tk.StringVar(value=self.DEFAULTS['scale'])
        ttk.Combobox(row2, textvariable=self.scale_var, values=SCALE_NAMES,
                     state='readonly', width=22).pack(side=tk.LEFT, padx=8)

        # --- Timing & MIDI ---
        timing_frame = ttk.LabelFrame(main, text="Timing & MIDI", padding=8)
        timing_frame.pack(fill=tk.X, pady=(0, 8))

        tr = ttk.Frame(timing_frame)
        tr.pack(fill=tk.X, pady=2)
        ttk.Label(tr, text="Tempo (BPM):").pack(side=tk.LEFT, padx=5)
        self.tempo_var = tk.StringVar(value=self.DEFAULTS['tempo'])
        ttk.Entry(tr, textvariable=self.tempo_var, width=7).pack(side=tk.LEFT, padx=5)

        ttk.Label(tr, text="  Note duration (ms):").pack(side=tk.LEFT, padx=5)
        self.dur_var = tk.StringVar(value=self.DEFAULTS['duration'])
        ttk.Entry(tr, textvariable=self.dur_var, width=7).pack(side=tk.LEFT, padx=5)

        tr2 = ttk.Frame(timing_frame)
        tr2.pack(fill=tk.X, pady=2)
        ttk.Label(tr2, text="Default velocity:").pack(side=tk.LEFT, padx=5)
        self.vel_var = tk.StringVar(value=self.DEFAULTS['velocity'])
        ttk.Entry(tr2, textvariable=self.vel_var, width=5).pack(side=tk.LEFT, padx=5)
        ttk.Label(tr2, text="(1-127; overridden by velocity column)",
                  foreground="gray", font=("Arial", 8)).pack(side=tk.LEFT, padx=5)

        ttk.Label(tr2, text="  MIDI ch:").pack(side=tk.LEFT, padx=(15, 2))
        self.channel_var = tk.IntVar(value=self.DEFAULTS['channel'])
        ttk.Spinbox(tr2, from_=1, to=16, textvariable=self.channel_var,
                    width=4).pack(side=tk.LEFT)

        # --- Log ---
        log_frame = ttk.LabelFrame(main, text="Log", padding=4)
        log_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 4))

        ctrl = ttk.Frame(log_frame)
        ctrl.pack(fill=tk.X)
        ttk.Button(ctrl, text="Clear", width=6,
                   command=lambda: self.log_text.delete(1.0, tk.END)).pack(side=tk.RIGHT)

        self.log_text = scrolledtext.ScrolledText(log_frame, wrap=tk.WORD,
                                                   font=("Courier", 9),
                                                   bg="#1e1e1e", fg="#00ff00",
                                                   height=6,
                                                   insertbackground="white")
        self.log_text.pack(fill=tk.BOTH, expand=True, pady=(4, 0))

        self._update_range_hint()

    # ------------------------------------------------------------------
    def _update_range_hint(self, *args):
        try:
            lo = self.midi_low_var.get()
            hi = self.midi_high_var.get()
            self.range_hint.config(
                text=f"({note_name(lo)} – {note_name(hi)}, {(hi - lo) / 12:.1f} oct)")
        except Exception:
            pass

    def _browse_file(self):
        fp = filedialog.askopenfilename(
            title="Select processed CSV file",
            filetypes=[("CSV/TXT files", "*.csv *.txt"), ("All files", "*.*")]
        )
        if fp:
            self._load_file(fp)

    def _load_file(self, fp):
        if not Path(fp).exists():
            self.file_label.config(text=f"Not found: {fp}", foreground="red")
            return

        self.file_path = fp
        self.file_label.config(text=Path(fp).name, foreground="black")

        try:
            header, rows, _ = read_csv_data(fp)
            self.numeric_columns = extract_numeric_columns(header, rows)

            col_names = [f"{idx}: {name}"
                         for idx, (name, _) in sorted(self.numeric_columns.items())]

            self.pitch_combo['values'] = col_names
            self.vel_combo['values']   = ["(none)"] + col_names

            if col_names:
                self.pitch_combo.current(0)
                self.vel_combo.current(0)   # "(none)"

            self.data_info.config(
                text=f"{len(rows)} rows | {len(self.numeric_columns)} numeric columns")

            # Auto-set output dir/stem if blank
            if not self.out_dir_var.get().strip():
                self.out_dir_var.set(str(Path(fp).parent))
            if not self.out_stem_var.get().strip():
                self.out_stem_var.set(Path(fp).stem + "_notes")

            self.log(f"Loaded: {Path(fp).name} — "
                     f"{len(rows)} rows, {len(self.numeric_columns)} columns")

        except Exception as e:
            self.file_label.config(text=f"Error: {e}", foreground="red")

    def _browse_output_dir(self):
        d = filedialog.askdirectory(title="Select output directory")
        if d:
            self.out_dir_var.set(d)

    def _get_col_values(self, combo_var):
        """Return (col_name, values) from a combobox selection, or None."""
        sel = combo_var.get()
        if not sel or sel == "(none)":
            return None, None
        try:
            idx = int(sel.split(':')[0])
            name, values = self.numeric_columns[idx]
            return name, values
        except Exception:
            return None, None

    def _generate(self):
        if not self.numeric_columns:
            messagebox.showwarning("No Data", "Load a CSV file first.")
            return

        # Pitch column
        pitch_name, pitch_values = self._get_col_values(self.pitch_col_var)
        if pitch_values is None:
            messagebox.showwarning("No Column", "Select a pitch column.")
            return

        # Velocity column (optional)
        _, vel_values = self._get_col_values(self.vel_col_var)

        # Validate settings
        try:
            tempo = float(self.tempo_var.get())
            assert 20 <= tempo <= 300
        except Exception:
            messagebox.showwarning("Invalid Tempo", "Tempo must be 20–300 BPM.")
            return

        try:
            duration_ms = float(self.dur_var.get())
            assert 10 <= duration_ms <= 10000
        except Exception:
            messagebox.showwarning("Invalid Duration", "Duration must be 10–10000 ms.")
            return

        try:
            default_velocity = int(self.vel_var.get())
            assert 1 <= default_velocity <= 127
        except Exception:
            messagebox.showwarning("Invalid Velocity", "Velocity must be 1–127.")
            return

        midi_low  = self.midi_low_var.get()
        midi_high = self.midi_high_var.get()
        if midi_low >= midi_high:
            messagebox.showwarning("Invalid Range", "MIDI Low must be less than High.")
            return

        channel    = self.channel_var.get()
        scale_name = self.scale_var.get()

        # Output path
        out_dir  = self.out_dir_var.get().strip() or str(Path(self.file_path).parent)
        out_stem = self.out_stem_var.get().strip() or (Path(self.file_path).stem + "_notes")
        output_path = str(Path(out_dir) / out_stem) + ".XML"

        self.progress.start()
        self.log("\n" + "=" * 50)
        self.log("GENERATING")
        self.log(f"  Pitch:    {pitch_name}  ({len(pitch_values)} values)")
        self.log(f"  Velocity: {self.vel_col_var.get()}")
        self.log(f"  Scale:    {scale_name}  |  Range: {note_name(midi_low)}–{note_name(midi_high)}")
        self.log(f"  Tempo:    {tempo} BPM  |  Duration: {duration_ms} ms")
        self.log(f"  MIDI ch:  {channel}")
        self.log(f"  Output:   {output_path}")

        try:
            ok = generate_xml(
                pitch_col_name=pitch_name,
                pitch_values=pitch_values,
                vel_values=vel_values,
                midi_low=midi_low,
                midi_high=midi_high,
                scale_name=scale_name,
                midi_channel=channel,
                tempo=tempo,
                duration_ms=duration_ms,
                default_velocity=default_velocity,
                output_path=output_path,
                log_func=self.log,
            )
            if ok:
                self.log("=" * 50)
        except Exception as e:
            self.log(f"❌ Error: {e}")
            import traceback
            self.log(traceback.format_exc())
        finally:
            self.progress.stop()

    def log(self, msg):
        self.log_text.insert(tk.END, msg + "\n")
        self.log_text.see(tk.END)
        self.root.update_idletasks()

    # ------------------------------------------------------------------
    # PREFS
    # ------------------------------------------------------------------

    def _collect_prefs(self):
        return {
            'file_path':   self.file_path,
            'out_dir':     self.out_dir_var.get(),
            'out_stem':    self.out_stem_var.get(),
            'tempo':       self.tempo_var.get(),
            'duration':    self.dur_var.get(),
            'velocity':    self.vel_var.get(),
            'midi_low':    self.midi_low_var.get(),
            'midi_high':   self.midi_high_var.get(),
            'scale':       self.scale_var.get(),
            'channel':     self.channel_var.get(),
            'pitch_col':   self.pitch_col_var.get(),
            'vel_col':     self.vel_col_var.get(),
        }

    def _save_prefs(self):
        try:
            with open(PREFS_FILE, 'w', encoding='utf-8') as f:
                json.dump(self._collect_prefs(), f, indent=2)
        except Exception:
            pass

    def _try_restore(self):
        if not PREFS_FILE.exists():
            return
        try:
            with open(PREFS_FILE, 'r', encoding='utf-8') as f:
                p = json.load(f)
        except Exception:
            return

        self.out_dir_var.set(p.get('out_dir', ''))
        self.out_stem_var.set(p.get('out_stem', ''))
        self.tempo_var.set(p.get('tempo', self.DEFAULTS['tempo']))
        self.dur_var.set(p.get('duration', self.DEFAULTS['duration']))
        self.vel_var.set(p.get('velocity', self.DEFAULTS['velocity']))
        self.midi_low_var.set(p.get('midi_low', self.DEFAULTS['midi_low']))
        self.midi_high_var.set(p.get('midi_high', self.DEFAULTS['midi_high']))
        self.scale_var.set(p.get('scale', self.DEFAULTS['scale']))
        self.channel_var.set(p.get('channel', self.DEFAULTS['channel']))

        fp = p.get('file_path')
        if fp and Path(fp).exists():
            self._load_file(fp)
            # Restore column selections after combos are populated
            saved_pitch = p.get('pitch_col', '')
            saved_vel   = p.get('vel_col', '(none)')
            if saved_pitch in self.pitch_combo['values']:
                self.pitch_col_var.set(saved_pitch)
            if saved_vel in self.vel_combo['values']:
                self.vel_col_var.set(saved_vel)
            self.log("Session restored.")

    def _on_close(self):
        self._save_prefs()
        self.root.destroy()


# ============================================================================
# MAIN
# ============================================================================

if __name__ == "__main__":
    root = tk.Tk()
    try:
        style = ttk.Style()
        if 'clam' in style.theme_names():
            style.theme_use('clam')
    except Exception:
        pass
    DelugeNotesGUI(root)
    root.mainloop()
