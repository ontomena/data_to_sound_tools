# Geomagnetic Data Processor

Cross-platform GUI tool for preparing geomagnetic observatory time-series data for sonification and analysis. It cleans raw CSV/TXT files and extracts meaningful segments — including Bartels solar-rotation cycles — producing tidy output ready for downstream use.

**Current version:** 7.0
**Part of:** the Magnet Opus Geomagnetic Sonification Toolkit
**Platforms:** macOS, Linux, Windows

---

## What It Does

Raw observatory files are large, sometimes messy (missing values, mixed delimiters, datetime columns), and rarely aligned to musically or analytically useful boundaries. This tool takes them from raw download to clean, segmented output in a single GUI.

The interface has three tabs:

- **Data Preview** — file information, detected columns, and Bartels-column detection
- **Settings** — the four-stage processing workflow (see below)
- **Output Log** — a running record of what each run produced

---

## Installation

### Requirements

- Python 3.7 or higher
- tkinter (bundled with most Python installs)

### Optional

Drag-and-drop file support:

```bash
pip install tkinterdnd2
```

### Platform notes

**Windows** — Python normally includes tkinter; no extra steps.

**macOS** — if tkinter is missing, install a Python build that includes it:

```bash
brew install python-tk
```

**Linux (Debian/Ubuntu/Mint)**:

```bash
sudo apt-get install python3-tk
```

---

## Running

**Windows** — double-click `geomag_data_processor_v7_0.py`, or run it from a terminal.

**macOS / Linux** — run from a terminal:

```bash
python3 -B geomag_data_processor_v7_0.py
```

The `-B` flag disables the bytecode cache, so source edits always take effect.

### Using the launcher (macOS / Linux)

A shell launcher is included. Make it executable once, then run it:

```bash
chmod +x launch_geomag_v7_0.sh   # first run only
./launch_geomag_v7_0.sh
```

---

## The Four-Stage Workflow

All processing is configured on the **Settings** tab, top to bottom.

### Stage 1 — File Management
Load one or more input files. Multiple files can be queued for batch work or for concatenation (see Bartels, below).

### Stage 2 — Data Cleaning
Choose how missing values (NaN/NA/blank) are handled:

- **Leave NaNs in** — process raw, no interpolation
- **Linear interpolation** — fill internal gaps smoothly
- **Forward fill** — repeat the last valid value across a gap

### Stage 3 — Select Processing Operation
Pick one of five operations:

| Operation | Purpose |
|-----------|---------|
| **Downsample** | Reduce data density, by percentage or by row count |
| **Truncate** | Extract a row range, split by row count, or split into equal parts |
| **Extract Time Range** | Pull a segment by row numbers, days from start, or Bartels rotation number |
| **Sequential Cycles** | Slice into regular periods — single cycle, a range of cycles, or auto-split every cycle into its own file |
| **Batch Process** | Run several operations in one pass |

### Stage 4 — Configure Operation
The configuration panel changes to match the operation chosen in Stage 3.

---

## Bartels Rotations

Bartels rotations are 27-day cycles aligned to the Sun's rotation as seen from Earth — a natural unit for organising geomagnetic data. One rotation of hourly data is 648 rows (27 × 24).

The processor:

- **Auto-detects** a Bartels-number column if one is present, and reports it on the Data Preview tab
- Otherwise **calculates rotations from dates**
- Can **extract a single rotation by number**, or extract **all** rotations in a batch run
- Protects boundaries: incomplete first/last rotations are handled rather than silently mis-filled

### File Concatenation

Downloads split by month usually straddle rotation boundaries, so no single month contains a whole set of clean rotations. Enabling **"Concatenate contiguous files before extraction"** in the Bartels section of Batch mode makes the processor:

1. Sort the loaded files by detected start date
2. Join them into one continuous dataset
3. Extract complete rotations across the joins, handling the partials at each end

Example: a year of monthly files → one merged series → a full set of complete Bartels rotations plus the two partials at the year's edges.

---

## Input & Output

### Input

The tool auto-detects headers, delimiters (comma/tab/space) and date formats. A typical geomagnetic file looks like:

```
H,D,Z,F,datetime
17607.9,-1.3,46668.2,49879.4,2022-01-05 00:00:00
```

- **H** — horizontal component (nT)
- **D** — declination (degrees)
- **Z** — vertical component (nT)
- **F** — total field (nT)
- **datetime** — timestamp (auto-detected; preserved or skipped as appropriate)

Non-numeric columns such as timestamps are handled automatically and do not need to be removed first.

### Output

Processed files are written with descriptive suffixes indicating the operation applied. Batch operations group related outputs together. The Output Log tab records exactly what each run wrote.

---

## Where This Fits

A typical pipeline:

```
Raw observatory files
        │
        ▼
Geomagnetic Data Processor   (clean + segment)
        │
        ├──►  DAW automation scripts (continuous envelopes / MIDI CC)
        └──►  data-to-MIDI conversion (discrete notes)
```

---

## Project Context

The Magnet Opus toolkit was developed for a geomagnetic sonification project using data from Eskdalemuir Geomagnetic Observatory (BGS), rendered as First Order Ambisonics in REAPER with an 8-channel speaker cube. Supported by Arts Council England DYCP funding; presented at Full of Noises sharing event, Barrow, 21st March, 2026.
---

## Version Summary

**v7.0** — all five operations fully implemented; multi-file concatenation for Bartels extraction across contiguous files.

Earlier lineage: v5.0 (tabbed interface, Bartels auto-detection) → v6.0 → v7.0.


---

## Disclaimer
These scripts are provided as-is, without warranty of any kind. The author accepts no responsibility for any damage to your system, data loss, or unintended behaviour within Reaper or any other software resulting from their use. Always back up your Reaper projects before applying automation scripts. Use at your own risk.

---

## Licence

**Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)**

You are free to share and adapt this work for any purpose, provided you give appropriate credit and distribute any adaptations under the same licence.

[https://creativecommons.org/licenses/by-sa/4.0/](https://creativecommons.org/licenses/by-sa/4.0/)

---

## Attribution

Developed by **Simon Bradley, PhD**
*Magnet Opus* — geomagnetic sonification project

Geomagnetic data for the original project courtesy of the British Geological Survey (BGS) Geomagnetism Team, Eskdalemuir Observatory.

---

## Contact
Via webform at https://www.displacementactivities.org/contact/

---

*SCB Magnet Opus Toolkit — Simon Bradley*

