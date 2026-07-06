# SCB Data → MIDI Converter
### Magnet Opus Geomagnetic Sonification Toolkit

Convert cleaned geomagnetic CSV data into MIDI notes and Synthstrom Deluge song files.

Part of the **Magnet Opus** project — geomagnetic data sonification using Eskdalemuir Observatory BGS data.

---

## Contents

| File | Description |
|------|-------------|
| `scb_data_to_midi_v1_4.py` | Full combo converter — MIDI + Deluge XML + automation |
| `scb_data_to_deluge_notes_v1_0.py` | Standalone — Deluge MIDI clip notes only |
| `launch_combo_converter.command` | Mac launcher for combo converter |
| `launch_deluge_notes.command` | Mac launcher for Deluge notes standalone |
| `launch_combo_converter.bat` | Windows launcher for combo converter |
| `launch_deluge_notes.bat` | Windows launcher for Deluge notes standalone |

---

## Requirements

- Python 3.7 or higher
- `midiutil` library (combo converter only)

**Install midiutil:**

```
# Mac / Linux
pip3 install midiutil

# Windows
pip install midiutil
```

`tkinter` is included with standard Python installations on all platforms.  
The Deluge notes standalone requires no additional libraries.

---

## Quick Start

### Mac

First time only — make the launchers executable:

```bash
chmod +x launch_combo_converter.command
chmod +x launch_deluge_notes.command
```

Then double-click either `.command` file to launch.

### Windows

Double-click either `.bat` file to launch.  
If Python is not recognised, ensure it was added to PATH during installation.

### Linux

```bash
python3 scb_data_to_midi_v1_4.py
python3 scb_data_to_deluge_notes_v1_0.py
```

---

## The Two Tools

### 1. Combo Converter — `scb_data_to_midi_v1_4.py`

The full toolkit. Loads a multi-column CSV and converts it to:

- Standard MIDI file (`.mid`) — for import into REAPER or any DAW
- Synthstrom Deluge song XML (`.XML`) — copy to `SONGS/` on Deluge SD card

**Column roles** — each column in your CSV can be assigned as:

- **Pitch** — data values mapped across a MIDI note range, quantised to a scale
- **Velocity** — modulates note velocity from a data column
- **Duration** — modulates note length from a data column
- **Automation** — maps data to a Deluge soundParams parameter (volume, pan, LPF frequency, reverb, etc.) or MIDI CC

**Key features:**

- 10 scales including Chromatic, all diatonic modes, Pentatonic Major/Minor
- Per-column MIDI note range (low/high) with octave readout
- Mapping modes: Bottom-up, Centred, Bipolar — with live preview graph per column
- Amplitude and offset sliders with instant visual feedback before generating
- Clipping warnings in preview (red) with percentage readout
- Global pre-processing for automation columns: Normal or Intense mode
  - Intense: soft-knee compression (threshold, ratio, knee) applied before normalisation — expands dynamics, tames outlier spikes
- 30+ Deluge automation targets (volume, pan, LPF/HPF, oscillators, delay, reverb, LFOs, bit crush, etc.)
- MIDI CC output for automation (alongside Deluge soundParams)
- Persistent header bar — output directory, filename stem, and Generate button always visible
- Session persistence — last file and all settings restored on relaunch
- Keep settings prompt when loading a new file
- Reset to Defaults button

**Workflow:**

1. Load your cleaned CSV file (Input / Columns tab)
2. Enable columns and assign roles
3. Set MIDI ranges, scales, and automation targets
4. Adjust amplitude/offset using the live preview graphs
5. Configure tempo, duration, velocity in Settings tab
6. Set pre-processing mode if needed (Settings tab)
7. Set output directory and filename in the header bar
8. Click **▶ GENERATE**

---

### 2. Deluge Notes Standalone — `scb_data_to_deluge_notes_v1_0.py`

A simple, single-purpose tool. Takes one data column and converts it to a Deluge MIDI clip — a string of quantised notes across a chosen pitch range.

No automation. No soundParams. No standard MIDI output. Just notes.

**Use this when** you want to load a clip directly into the Deluge and route it to a synth or external instrument via MIDI channel, without any automation complexity.

**Features:**

- Loads multi-column CSVs — choose any column as pitch from a dropdown
- Optional second column for velocity
- 10 scales, settable MIDI note range
- MIDI channel selection (assign to any synth or external instrument on the Deluge)
- Output directory and editable filename stem
- Session persistence

**Workflow:**

1. Load your CSV file
2. Select pitch column (and optional velocity column)
3. Set MIDI note range and scale
4. Set tempo, note duration, MIDI channel
5. Set output directory and filename
6. Click **▶ GENERATE**
7. Copy the `.XML` file to `SONGS/` on your Deluge SD card
8. On the Deluge, assign the clip's MIDI channel to a synth or external instrument

---

## Input File Format

Both tools accept CSV or TXT files with numeric data columns.  
Files should be cleaned before use — NaN values are interpolated automatically.

Compatible with output from the Magnet Opus Geomagnetic Data Processor (`geomag_processor_v7_0.py`).

**Supported formats:**
- Comma-separated (`.csv`)
- Tab-separated (`.txt`)
- Space-separated (`.txt`)
- Column headers in first row or as a `#` comment line — both detected automatically

**Example (Eskdalemuir BGS data, 4 columns):**

```
# Date, H, D, Z, F
2011-01-01, 18432.1, -2.34, 47821.6, 51234.8
2011-01-02, 18441.7, -2.31, 47819.2, 51238.1
...
```

---

## Output Files

### Standard MIDI (`.mid`)
Produced by the combo converter. Import into REAPER, Ableton, Logic, or any DAW.  
Each pitch column becomes a separate MIDI track.

### Deluge Song XML (`.XML`)
Produced by both tools.  
Copy to the `SONGS/` folder on your Deluge SD card.

**Combo converter** — produces synth clips with embedded soundParams automation.  
The named preset must exist in `SYNTHS/` on the SD card, or use the embedded default synth option.

**Deluge notes standalone** — produces a MIDI clip.  
Assign the clip's MIDI channel to a synth or external instrument on the Deluge.

---

## Session Persistence

Both tools save settings automatically on close and restore them on next launch.

| Tool | Prefs file |
|------|------------|
| Combo converter | `scb_midi_prefs.json` |
| Deluge notes standalone | `scb_deluge_notes_prefs.json` |

These files are created in the same folder as the scripts. They are not included in the distribution and can be safely deleted to reset all settings to defaults.

---

## Scales

| Scale | Intervals |
|-------|-----------|
| Chromatic | All 12 semitones |
| Ionian (Major) | 0 2 4 5 7 9 11 |
| Dorian | 0 2 3 5 7 9 10 |
| Phrygian | 0 1 3 5 7 8 10 |
| Lydian | 0 2 4 6 7 9 11 |
| Mixolydian | 0 2 4 5 7 9 10 |
| Aeolian (Minor) | 0 2 3 5 7 8 10 |
| Locrian | 0 1 3 5 6 8 10 |
| Pentatonic Major | 0 2 4 7 9 |
| Pentatonic Minor | 0 3 5 7 10 |

Data values are mapped to the nearest scale degree. Chromatic includes all semitones (no quantisation).

---

## Deluge Automation Targets (Combo Converter)

Parameters available for soundParams automation:

| Target | Polarity |
|--------|----------|
| Volume | Unipolar |
| Pan | Bipolar |
| LPF Frequency | Unipolar |
| LPF Resonance | Unipolar |
| HPF Frequency | Unipolar |
| HPF Resonance | Unipolar |
| LPF Morph | Unipolar |
| HPF Morph | Unipolar |
| Osc A Pitch | Bipolar |
| Osc A Volume | Unipolar |
| Osc A Pulse Width | Bipolar |
| Osc A Wavetable Pos | Unipolar |
| Osc B Volume | Unipolar |
| Osc B Pulse Width | Bipolar |
| Delay Rate | Unipolar |
| Delay Feedback | Unipolar |
| Reverb Amount | Unipolar |
| Mod FX Rate | Unipolar |
| Mod FX Depth | Unipolar |
| Mod FX Feedback | Unipolar |
| Bit Crush | Unipolar |
| Sample Rate Reduction | Unipolar |
| Wave Fold | Unipolar |
| Stutter Rate | Unipolar |
| Noise Volume | Unipolar |
| Portamento | Unipolar |
| Arpeggiator Gate | Unipolar |
| Arpeggiator Rate | Unipolar |
| LFO 1 Rate | Unipolar |
| LFO 2 Rate | Unipolar |
| MIDI CC (custom) | — |

**Bipolar** parameters sweep the full negative-to-positive range (e.g. pan left to right).  
**Unipolar** parameters sweep from minimum to maximum (e.g. reverb off to full).

---

## Pre-processing (Combo Converter)

Located in the **Settings** tab. Applies globally to all automation columns before normalisation.

**Normal mode** — values are normalised directly. Default.

**Intense mode** — soft-knee downward compression is applied first, then normalised.  
Use this when your data has outlier spikes that pull the normalisation ceiling up, making typical variation appear subtle. Compression squashes the spikes, allowing the everyday movement to breathe across the full parameter range.

| Control | Range | Description |
|---------|-------|-------------|
| Threshold % | 0–300 | % of std dev above mean where compression starts |
| Ratio | 1–20:1 | Compression ratio above threshold |
| Knee | 0–1 | Softness of transition into compression |

---

## MIDI Note Reference

```
C2  = 36    C3  = 48    C4  = 60 (Middle C)
C5  = 72    C6  = 84    C7  = 96
```

---

## Companion Tools

- **Geomagnetic Data Processor** (`geomag_processor_v7_0.py`) — processes raw BGS observatory data into clean CSVs
- **Geomagnetic Automation** (`Geomagnetic_Automation_v2_5.lua`) — REAPER Lua script for applying geomagnetic data as REAPER automation
- **REAPER** — DAW for importing MIDI output and spatial audio production

---

## Project Context

The Magnet Opus toolkit was developed for a geomagnetic sonification project using data from Eskdalemuir Geomagnetic Observatory (BGS), rendered as First Order Ambisonics in REAPER with an 8-channel speaker cube. Supported by Arts Council England DYCP funding; presented at Full of Noises festival.

---

## Version History

| Version | Date | Notes |
|---------|------|-------|
| scb_data_to_midi_v1_4 | 2026 | Pre-processing, preview guide lines, editable output filename, full unipolar range fix |
| scb_data_to_midi_v1_3 | 2026 | Persistent header bar, session persistence, per-column preview graphs, Reset button |
| scb_data_to_midi_v1_2 | 2026 | Deluge XML output, automation columns, soundParams encoding |
| scb_data_to_midi_v1_1 | 2026 | Scales, mapping modes, amplitude/offset controls |
| scb_data_to_midi_v1_0 | 2026 | Initial release — MIDI notes only |
| scb_data_to_deluge_notes_v1_0 | 2026 | Standalone Deluge MIDI clip generator |

---

*SCB Magnet Opus Toolkit — Simon Bradley*
