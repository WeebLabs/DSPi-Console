#!/usr/bin/env python3
"""
Generate autoeq_database.json from AutoEQ repository.

This creates a complete local database with all profile data embedded,
eliminating the need for network requests.

Usage:
    git clone --depth 1 https://github.com/jaakkopasanen/AutoEq.git /tmp/autoeq
    python3 generate_index.py /tmp/autoeq/results > autoeq_database.json
"""

import os
import sys
import json
import re
from pathlib import Path
from datetime import datetime, timezone

# Source folders and priority (lower = better)
# Keys must match actual folder names in AutoEQ repo (case-sensitive)
# Values are (priority, normalized_name for JSON)
SOURCE_INFO = {
    'oratory1990': (1, 'oratory1990'),
    'crinacle': (2, 'crinacle'),
    'Rtings': (3, 'rtings'),
    'Innerfidelity': (3, 'innerfidelity'),
    'Headphone.com Legacy': (4, 'headphone.com'),
}

# Filter type mapping from AutoEQ format to our format
FILTER_TYPES = {
    'PK': 'peaking',
    'PEQ': 'peaking',
    'LSC': 'lowShelf',
    'LSB': 'lowShelf',
    'LS': 'lowShelf',
    'HSC': 'highShelf',
    'HSB': 'highShelf',
    'HS': 'highShelf',
    'LP': 'lowPass',
    'LPQ': 'lowPass',
    'HP': 'highPass',
    'HPQ': 'highPass',
}

def detect_form_factor(target_folder):
    """Detect form factor from target folder name."""
    target_lower = target_folder.lower()
    if 'in-ear' in target_lower or 'in_ear' in target_lower or 'iem' in target_lower:
        return 'in-ear'
    elif 'earbud' in target_lower:
        return 'earbud'
    else:
        return 'over-ear'

def parse_headphone_name(folder_name):
    """Extract manufacturer and model from folder name like 'HIFIMAN HE400se'"""
    manufacturers = [
        'AKG', 'Audio-Technica', 'Audeze', 'Bang & Olufsen', 'Beats', 'Beyerdynamic',
        'Bose', 'Campfire Audio', 'Dan Clark Audio', 'Denon', 'FiiO', 'Final',
        'Focal', 'Grado', 'HarmonicDyne', 'HIFIMAN', 'JBL', 'Koss', 'Massdrop',
        'Meze', 'Moondrop', 'Philips', 'Pioneer', 'Sennheiser', 'Shure', 'Sony',
        'SteelSeries', 'STAX', 'Tin HiFi', 'V-MODA', 'ZMF', '64 Audio', '7Hz',
        'Anker', 'Apple', 'AFUL', 'BLON', 'CCA', 'Dunu', 'Empire Ears', 'Etymotic',
        'FatFreq', 'Hidizs', 'HiBy', 'iBasso', 'JVC', 'KZ', 'Letshuoer', 'Linsoul',
        'Noble Audio', 'QKZ', 'Samsung', 'See Audio', 'Simgot', 'SoftEars',
        'Tangzu', 'Thieaudio', 'Tinhifi', 'Tripowin', 'TRN', 'Truthear',
        'Unique Melody', 'Westone', 'Yanyin', 'BGVP', 'CCZ'
    ]

    for mfr in manufacturers:
        if folder_name.lower().startswith(mfr.lower()):
            if folder_name.lower().startswith(mfr.lower() + ' ') or folder_name.lower() == mfr.lower():
                model = folder_name[len(mfr):].strip()
                return mfr, model if model else folder_name

    parts = folder_name.split(' ', 1)
    if len(parts) == 2:
        return parts[0], parts[1]
    return folder_name, ''

def parse_profile(file_path):
    """Parse ParametricEQ.txt file and return profile data."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception:
        return None

    preamp = 0.0
    filters = []

    for line in content.split('\n'):
        line = line.strip()

        # Parse preamp
        if line.lower().startswith('preamp:'):
            match = re.search(r'-?\d+\.?\d*', line)
            if match:
                preamp = float(match.group())
            continue

        # Parse filter lines
        if 'Filter' not in line or ':' not in line:
            continue

        upper_line = line.upper()
        if ' ON ' not in upper_line:
            continue

        # Detect filter type
        filter_type = None
        for code, ftype in FILTER_TYPES.items():
            if f' {code} ' in upper_line:
                filter_type = ftype
                break

        if not filter_type:
            continue

        # Extract frequency
        freq = 1000.0
        fc_match = re.search(r'Fc\s+(\d+\.?\d*)', line, re.IGNORECASE)
        if fc_match:
            freq = float(fc_match.group(1))

        # Extract gain
        gain = 0.0
        gain_match = re.search(r'Gain\s+(-?\d+\.?\d*)', line, re.IGNORECASE)
        if gain_match:
            gain = float(gain_match.group(1))

        # Extract Q
        q = 0.707
        q_match = re.search(r'\sQ\s+([\d.]+)', line, re.IGNORECASE)
        if q_match:
            q = float(q_match.group(1))

        filters.append({
            'type': filter_type,
            'freq': freq,
            'q': q,
            'gain': gain
        })

    return {
        'preamp': preamp,
        'filters': filters
    }

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 generate_index.py /path/to/autoeq/results", file=sys.stderr)
        sys.exit(1)

    results_path = Path(sys.argv[1])
    if not results_path.exists():
        print(f"Error: {results_path} does not exist", file=sys.stderr)
        sys.exit(1)

    # Collect all headphones
    all_entries = {}  # Key: (manufacturer, model) -> best entry

    for source_folder, (priority, source_name) in SOURCE_INFO.items():
        source_path = results_path / source_folder
        if not source_path.exists():
            continue

        for target_folder in os.listdir(source_path):
            target_path = source_path / target_folder
            if not target_path.is_dir():
                continue

            form_factor = detect_form_factor(target_folder)

            for headphone_folder in os.listdir(target_path):
                headphone_path = target_path / headphone_folder
                if not headphone_path.is_dir():
                    continue

                peq_file = headphone_path / f"{headphone_folder} ParametricEQ.txt"
                if not peq_file.exists():
                    continue

                # Parse the profile
                profile = parse_profile(peq_file)
                if not profile or not profile['filters']:
                    continue

                manufacturer, model = parse_headphone_name(headphone_folder)
                key = (manufacturer.lower(), model.lower())

                entry = {
                    'id': f"{source_name}/{headphone_folder}",
                    'manufacturer': manufacturer,
                    'model': model,
                    'source': source_name,
                    'formFactor': form_factor,
                    'preamp': profile['preamp'],
                    'filters': profile['filters']
                }

                if key not in all_entries or priority < all_entries[key]['_priority']:
                    entry['_priority'] = priority
                    all_entries[key] = entry

    # Remove priority field and convert to list
    entries = []
    for entry in all_entries.values():
        del entry['_priority']
        entries.append(entry)

    # Sort by manufacturer, then model
    entries.sort(key=lambda x: (x['manufacturer'].lower(), x['model'].lower()))

    # Build database with metadata
    database = {
        'version': 1,
        'generatedAt': datetime.now(timezone.utc).isoformat(),
        'entryCount': len(entries),
        'entries': entries
    }

    # Output JSON
    print(json.dumps(database, indent=2))

    print(f"Generated {len(entries)} entries", file=sys.stderr)

if __name__ == '__main__':
    main()
