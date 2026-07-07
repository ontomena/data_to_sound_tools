# Geomagnetic Sonification Toolkit — Workflow Guide

**From observatory data file to Reaper automation**

---

## Overview

The toolkit pipeline has three stages:

```
Raw data file (CSV)
        │
        ▼
[Stage 1] Python processor (geomag_processor_v7_0.py)
        │  — clean, filter, resample, extract time windows
        ▼
Processed CSV
        │
        ├──▶ [Stage 2A] Track Automation (v2.5)   → track envelope points
        ├──▶ [Stage 2B] Take Automation (v3.0)    → audio item take envelopes
        └──▶ [Stage 2C] MIDI CC Automation (v2.0) → MIDI CC events
```

The Python stage is optional — the Lua scripts will accept any well-formed CSV directly. The processor is most useful when working with large datasets, multiple files, or when you need to extract specific time windows.

---

## Stage 1 — Data Preparation

**Tool:** `geomag_processor_v7_0.py`
**Requires:** Python 3.7+, tkinter (usually bundled with Python)
**Launch:** `python geomag_processor_v7_0.py` or via the included shell launcher

### What it does

The processor handles raw observatory-format CSV files and prepares them for use in Reaper. Key operations:

| Operation | Purpose |
|---|---|
| Auto-detect headers/delimiters | Handles varying source formats |
| Downsample | Reduce data density by percentage or target row count |
| Truncate | Extract a date range or row range |
| Extract columns | Isolate specific field components |
| Sequential cycles | Split into regular intervals (e.g. 7-day or 27-day blocks) |
| Bartels rotation extraction | Extract complete 27-day solar rotation cycles |
| File concatenation | Merge multiple files before extraction |
| NaN handling | Gap-fill or leave raw |

### Input format

The processor (and all Lua scripts) accept CSV files with:

- Any number of numeric columns
- An optional header row (auto-detected)
- An optional non-numeric column such as a datetime string (skipped automatically)
- Comma, tab, or space delimiters (auto-detected)

**Example — geomagnetic field components:**
```
H,D,Z,F,datetime
17607.9,-1.3,46668.2,49879.4,2022-01-05 00:00:00
17608.1,-1.4,46669.0,49880.1,2022-01-05 01:00:00
```

Four numeric columns (H, D, Z, F) are imported; the datetime column is ignored.

A common geomagnetic data structure uses these components:
- **H** — horizontal component (northward)
- **D** — declination (angle from true north, in degrees)
- **Z** — vertical component (downward)
- **F** — total field magnitude

Data of this type is available from magnetic observatories worldwide via networks such as the [World Data Centre for Geomagnetism](http://www.wdc.bgs.ac.uk/) and the [INTERMAGNET](https://intermagnet.org/) network.

### Output

Processed CSV files, ready to load directly into any of the three Reaper scripts.

---

## Stage 2 — Reaper Automation

Three scripts serve different purposes. Choosing between them depends on what you want to automate and how you intend to work with the material compositionally.

### Which script to use

| | Track Automation v2.5 | Take Automation v3.0 | MIDI CC v2.0 |
|---|---|---|---|
| **Targets** | Track envelopes (volume, pan, FX params, spatial) | Audio item take envelopes | MIDI CC events / Pitch Bend |
| **Columns** | Up to 5 simultaneously, multiple envelopes per column | Up to 5, per-item independent | Up to 5, per-item |
| **Duration ref** | Fixed / Points/Rate / Use Last / Tempo Sync | Item Length (auto) / Points/Rate / Fixed | Item Length / Points/Rate / Fixed |
| **Timing** | Project-absolute | Item-relative | Project-absolute |
| **Presets** | Yes (JSON, named) | No | No |
| **Key feature** | Multi-envelope, spatial positioning | Timestretch reveal technique | Full CC range control |

---

## Stage 2A — Track Automation

**Best for:** spatial positioning, FX parameter modulation, shaping existing audio at track level across long timescales.

### Basic workflow

1. Prepare your track with the envelopes you want to automate (enable them in Reaper's envelope panel)
2. Select the track
3. Run the script, load your CSV
4. Assign data columns to envelopes
5. Set duration and start position
6. Apply

### Preset workflow

For recurring configurations (e.g. always mapping certain columns to the same spatial parameters):

1. Set up column assignments as above
2. Click **Save As...** → name the preset
3. On future sessions: select track, load CSV, load preset → Apply

Presets store envelope assignments by name, so they transfer to any track that has envelopes with matching names.

### Spatial audio example

With a spatial panning plugin (e.g. ReaSurroundPan) on a track, expose its parameters as FX parameter envelopes. Then assign:
- Column 1 (H — horizontal) → Azimuth
- Column 2 (Z — vertical) → Elevation
- Column 3 (F — total field) → Width or Distance

The result is a sound source whose position in space follows the geomagnetic field over time.

---

## Stage 2B — Take Automation (Audio)

**Best for:** granular control of individual sound objects; the timestretch reveal technique; item-specific processing.

### Basic workflow

1. Place audio items in the arrange view
2. Select the items you want to automate
3. Run the script, load your CSV
4. Enable columns, assign each to a take envelope type (Volume / Pan / Pitch / Mute)
5. Choose duration mode — usually *Item Length (auto)* to fill each item
6. Apply

### Timestretch reveal technique

This is the distinctive creative method enabled by item-relative envelope timing:

1. Place a short audio item (e.g. a 10-second drone)
2. Load a long dataset (e.g. 648 rows of hourly data)
3. Set Duration to *Points/Rate* → e.g. 1 point/second (= 648 seconds total)
4. Apply — automation is written into the item, compressed to its current length
5. Timestretch the item to 648 seconds (or longer)
6. The automation points expand with the item, revealing the full geomagnetic curve across the stretched audio

This produces a sound that *unfolds* through geomagnetic time — a 27-day magnetic variation expressed as a sonic journey through a single stretched recording.

---

## Stage 2C — MIDI CC Automation

**Best for:** driving synthesisers and samplers; converting field data into pitch, timbre, or dynamics; MIDI-based spatial positioning.

### Basic workflow

1. Place MIDI items with your instrument or sequencer material
2. Select the items
3. Run the script, load your CSV
4. Enable columns, select CC type and set min/max range per column
5. Set duration
6. Apply

### CC event timing

MIDI CC events are written at **project time**. Unlike Take Automation, moving or timestretching a MIDI item does not move its CC events. If you rearrange MIDI items after writing CC automation, you will need to re-apply.

### Range control

Each column has independent min/max sliders for the output CC range. For example, mapping a field component to Pitch Bend with a narrow range (±500) gives subtle pitch inflection, while the full range (±8192) gives dramatic pitch sweeps.

---

## Worked Example — 27-Day Cycle Composition

This example uses geomagnetic observatory data, but the same approach applies to any time-series dataset with comparable structure.

### Data preparation (Python)

```
Source: 12 monthly CSV files (one year of hourly data)
Operation: Concatenate → Extract Bartels rotation #N (648 rows = 27 days × 24 hours)
Output: rotation_N.csv  (648 rows, 4 numeric columns)
```

A Bartels rotation is a 27-day cycle aligned with the solar rotation period — a natural unit for geomagnetic data that often captures one full cycle of solar-driven magnetic variation.

### Track Automation (v2.5)

```
Track: Spatial audio bus with ReaSurroundPan
Preset: "SurroundPan" (saved from previous session)
Columns: H → Azimuth, Z → Elevation, F → Width
Duration: Points/Rate → 1 point/minute → 10.8 hours total
Direction: Forward
Apply → 27-day geomagnetic field variation drives spatial position
```

### Take Automation (v3.0)

```
Item: 10-second drone recording
CSV: same rotation_N.csv
Column 4 (F — total field) → Volume
Duration: Points/Rate → 1 point/second → 648 seconds
Apply → Timestretch item to 648 seconds
Result: Drone evolves with geomagnetic field intensity over 10.8 hours
```

### MIDI CC Automation (v2.0)

```
Item: MIDI pattern driving a synthesiser
CSV: same rotation_N.csv
Column 1 (H) → Pitch Bend, range: -2048 to +2048
Duration: Fixed → 648 seconds
Apply → Geomagnetic horizontal variation drives pitch
```

---

## Data Sources

The toolkit was developed using data from the **British Geological Survey (BGS) Geomagnetism Team**, Eskdalemuir Observatory, Scotland — a high-quality reference observatory with continuous records from 1908.

For your own projects, geomagnetic observatory data is freely available from:

- **BGS Geomagnetism:** [geomag.bgs.ac.uk](https://geomag.bgs.ac.uk/) — UK and global data, various formats
- **INTERMAGNET:** [intermagnet.org](https://intermagnet.org/) — global network, standardised format
- **World Data Centre for Geomagnetism:** [wdc.bgs.ac.uk](http://www.wdc.bgs.ac.uk/)

The toolkit is not limited to geomagnetic data — any time-series CSV with numeric columns can be used. Weather data, seismic data, environmental monitoring, biosignal recordings, financial data, and custom generated datasets are all valid inputs.

---

## Tips for Large Datasets

- **Downsample in Python first** — the Lua scripts handle large files, but fewer rows means faster preview refresh and snappier UI
- **Extract the window you need** — don't import a full year of hourly data if you only need one month
- **Use Points/Rate mode** — it makes the relationship between data density and musical time explicit and easy to adjust
- **Save presets early** — once you have a good column-to-envelope mapping, save it before experimenting

---

## Project Context

This toolkit was developed for **Magnet Opus** — a sonification of geomagnetic field data using First Order Ambisonics (FOA), an 8-channel speaker cube, and data from the British Geological Survey, Eskdalemuir Observatory. The project received funding from Arts Council England (DYCP award) and was presented at Full of Noises sharing event, Barrow, 21st March, 2026.

---

## Disclaimer
These scripts are provided as-is, without warranty of any kind. The author accepts no responsibility for any damage to your system, data loss, or unintended behaviour within Reaper or any other software resulting from their use. Always back up your Reaper projects before applying automation scripts. Use at your own risk.

---

## Licence

**Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)**

[https://creativecommons.org/licenses/by-sa/4.0/](https://creativecommons.org/licenses/by-sa/4.0/)

Developed by **Simon Bradley, PhD**

---

## Contact
Via webform at https://www.displacementactivities.org/contact/
