#!/bin/bash
# Launcher for Geomagnetic Data Processor v7.0
# Mac/Linux compatible

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Launch the Python script with no bytecode cache
cd "$SCRIPT_DIR"
python3 -B geomag_data_processor_v7_0.py

# Alternative if python3 not found:
# python -B geomag_data_processor_v7_0.py
