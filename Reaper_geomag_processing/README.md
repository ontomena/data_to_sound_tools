# Geomagnetic Sonification Toolkit

**Reaper Lua scripts for mapping geomagnetic field data to audio automation**

Three scripts for converting time-series geomagnetic data (CSV) into Reaper envelope automation, take envelope automation, and MIDI CC events. Developed as part of the *Magnet Opus* project — a geomagnetic sonification work using data from magnetic observatories. The work was funded by Arts Council England, Develop your Creative Practice (DYCP) grant.Presented at Full of Noises sharing event, Barrow, 21st March, 2026.

---

## Contents

- [`Geomagnetic_Automation_v2_5.lua`](#1-track-automation-v25) — Track-level envelope automation
- [`Geomagnetic_TakeAutomation_Audio_v3_0.lua`](#2-take-automation-audio-v30) — Audio item take envelope automation
- [`Geomagnetic_MIDI_CC_v2_0.lua`](#3-midi-cc-automation-v20) — MIDI CC event generation

See [`WORKFLOW.md`](WORKFLOW.md) for the full pipeline from raw data to Reaper, with worked examples.

---

## Requirements

- **Reaper** (any recent version)
- **ReaImGui extension** — required by all three scripts. Install via [ReaPack](https://reapack.com/) → search for `ReaImGui`
- **Python 3.7+** — only required if using the companion data processor (`geomag_processor_v7_0.py`)

---

## Installation

1. Copy the `.lua` files to your Reaper scripts folder:
   - **macOS/Linux:** `~/Library/Application Support/REAPER/Scripts/` (macOS) or `~/.config/REAPER/Scripts/` (Linux)
   - **Windows:** `%APPDATA%\REAPER\Scripts\`
2. In Reaper: **Actions → Show action list → New action → Load ReaScript**
3. Browse to each `.lua` file and load it
4. Optionally assign each script to a toolbar button or keyboard shortcut

---

## Input Data Format

All three scripts accept CSV or plain-text files with:

- **Numeric columns** — any number of floating-point values per row
- **Optional header row** — column names detected automatically
- **Optional non-numeric columns** — e.g. datetime strings; skipped silently
- **Delimiters** — comma, tab, or space; auto-detected from first line
- **NaN values** — converted to 0 with a warning (pre-clean in Python if needed)

**Example format** (geomagnetic field components with datetime):
```
H,D,Z,F,datetime
17607.9,-1.3,46668.2,49879.4,2022-01-05 00:00:00
17608.1,-1.4,46669.0,49880.1,2022-01-05 01:00:00
```

The scripts will import the four numeric columns (H, D, Z, F) and ignore the datetime column automatically.

---

## 1. Track Automation v2.5

**`Geomagnetic_Automation_v2_5.lua`**

Maps data columns to **track-level envelopes** — volume, pan, FX parameters, ReaSurroundPan channels, or any other track envelope.

### Quick Start

1. **Select a track** in Reaper's arrange view
2. Run the script — the panel opens
3. **Load Data File** — browse to your CSV
4. **Assign envelopes** — expand each column, click `+ Add Envelope`, select from the dropdown
5. Set **Duration** and **Start Position**
6. Click **APPLY**

### UI Sections

**Track Selection** — auto-detects the currently selected track; click a different track to switch.

**Data File** — load, reload, save/load settings. Remembers last folder. Shows row/column count on load.

**Named Presets** — save and recall complete column-to-envelope configurations as JSON files, stored in `[Reaper Resource Path]/GeomagAutomation_Presets/`. Useful for reusing the same mapping across different data files or sessions. Presets are portable — copy the JSON folder to another machine.

**Pre-processing** — collapsible section. Two modes:
- *Normal* — normalises data to envelope range
- *Intense* — applies soft-knee compression before normalising (Threshold %, Ratio, Knee)

Includes a live preview graph (grey = raw data, cyan = processed) for each enabled column.

**Column → Envelope** — up to 5 columns displayed at once; navigate with `◄ ►` if the file has more. For each column:
- Enable/disable with checkbox
- Assign one or more envelopes (multiple envelopes per column supported)
- Per-assignment controls: **Mapping** (Centred / Bottom-up / Inverted), **Amplitude** (0–1 scale), **Offset** (±1 shift)

**Duration** — three modes:
- *Fixed* — enter seconds directly or use the slider
- *Use Last* — repeats the most recently applied duration
- *Points/Rate* — set a rate (points per second/minute/hour); duration is calculated from row count. Quick presets and a calculated duration preview included.

Tempo Sync mode distributes points across bars instead of fixed time.

**Start Position** — at 0.0 / at cursor / at selected item start.

**Direction** — Forward / Reverse / Palindrome.

**Options** — curve shaping (Linear, Square, Slow Start/End, Fast Start, Fast End, Bezier, Sine), interpolation steps for non-linear curves, console logging toggle.

**Apply** — writes automation points to all assigned envelopes. Supports undo.

---

## 2. Take Automation (Audio) v3.0

**`Geomagnetic_TakeAutomation_Audio_v3_0.lua`**

Maps data columns to **audio item take envelopes** — Volume, Pan, Pitch, or Mute — on selected items. Each selected item is processed independently.

### Quick Start

1. **Select one or more audio items** in the arrange view
2. Run the script
3. **Load Data File**
4. **Enable columns** and assign take envelope types (Volume / Pan / Pitch / Mute)
5. Set **Duration** and **Direction**
6. Click **APPLY**

### UI Sections

**Selected Items** — displays currently selected audio items with their lengths. Use **Refresh** to update after changing selection.

**Data File** — same as Track Automation.

**Pre-processing** — same as Track Automation (Normal / Intense, with preview graphs).

**Column → Take Envelope** — up to 5 columns. Each column maps to one or more take envelope types with Mapping, Amplitude, and Offset controls.

**Duration** — three modes:
- *Item Length (auto)* — uses each item's own length; one data point per proportional interval
- *Points/Rate* — as per Track Automation
- *Fixed* — fixed seconds applied to all items

**Direction** — Forward / Reverse / Palindrome.

**Options** — Clear existing envelope points before writing (on by default). **Show take envelope panel** button (triggers Reaper Action 41974).

**Apply** — processes each selected item independently. Supports undo.

### Creative Technique: Timestretch Reveal

Apply a long dataset (e.g. 648 data points) to a short audio item, then timestretch the item to match the data duration. The automation points, which were compressed into the item's original length, are revealed as the item expands — effectively time-bending the audio through geomagnetic time.

---

## 3. MIDI CC Automation v2.0

**`Geomagnetic_MIDI_CC_v2_0.lua`**

Maps data columns to **MIDI CC events** (or Pitch Bend) inside selected MIDI items.

### Quick Start

1. **Select one or more MIDI items**
2. Run the script
3. **Load Data File**
4. **Configure columns** — choose CC type and set min/max range
5. Set **Duration**
6. Click **APPLY**

### UI Sections

**Selected Items** — shows selected MIDI items.

**Data File** — same as other scripts.

**Pre-processing** — Normal / Intense, same as other scripts.

**Column Configuration** — for each enabled column, choose:
- **CC Type** — Pitch Bend, CC7 (Volume), CC10 (Pan), CC1 (Modulation), or any CC 0–127 from the full dropdown
- **Min / Max range** — interactive sliders set the output range for that CC
- **Mapping** — Centred / Bottom-up / Inverted

**Duration** — Item Length (auto) / Points/Rate / Fixed.

**Direction** — Forward / Reverse / Palindrome.

**Apply** — writes MIDI CC events to all selected items. Supports undo.

### Important: Project-Time CC Events

MIDI CC events are written at **project time**, not item-relative time. Moving or timestretching a MIDI item does **not** move its CC events. This differs from Take Automation, where envelope points are item-relative. Plan accordingly when rearranging MIDI items.

---

## Preset System (Track Automation)

Presets save the column-to-envelope configuration (which envelopes are assigned to which columns, mapping modes, amplitude and offset values). They do not save duration, direction, curve, or pre-processing settings.

- **Save As...** — enter a name; saved as `name.json` in `[Reaper Resource Path]/GeomagAutomation_Presets/`
- **Load Preset** — selects from the dropdown and rebuilds envelope references for the current track
- **Delete** — removes the JSON file

Presets are plain JSON and can be copied between machines.

---

## Tips

- **Multiple envelopes per column** (Track Automation) — assign the same data column to several envelopes simultaneously, e.g. H component driving both Azimuth and a filter cutoff at once.
- **Palindrome direction** — useful for creating cyclical automation without abrupt jumps at loop points.
- **Intense mode** — compresses peaks before normalising; useful when data has extreme outliers that would otherwise dominate the automation range.
- **Points/Rate mode** — use `1 point/hour` with 648 rows to produce 27 days of automation at real geomagnetic time.
- **Console Log** — enable in Options to see column stats, threshold values, and clipping counts in Reaper's console.

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

## Version History

| Version | Date | Notes |
|---|---|---|
| Track v2.5 / Take v3.0 / MIDI CC v2.0 | March 2026 | Preset system, CSV parser fixes, MIDI CC window rewrite |
| Track v2.4 / Take v2.x / MIDI CC v1.0 | 2025 | Multi-envelope support, Points/Rate mode |
| v1.x | 2024 | Initial release |

---

## Contact
Via webform at https://www.displacementactivities.org/contact/

