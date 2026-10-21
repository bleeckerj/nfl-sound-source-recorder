#!/usr/bin/env python3
"""Measure a quiet-room, controlled speaker-only qualification using ffmpeg."""
import argparse
import array
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("--settle-seconds", type=float, default=3.0)
parser.add_argument("--write-report", action="store_true")
args = parser.parse_args()
ffmpeg = shutil.which("ffmpeg")
if not ffmpeg:
    parser.error("ffmpeg is required")
sources = args.directory / "mix.sources"


def decode(name):
    result = subprocess.run([ffmpeg, "-v", "error", "-i", str(sources / name),
                             "-f", "f32le", "-ac", "1", "-ar", "48000", "-"],
                            check=True, stdout=subprocess.PIPE)
    samples = array.array("f")
    samples.frombytes(result.stdout)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


app, raw, clean = [decode(name) for name in
                   ["app-audio.caf", "microphone-raw.caf", "microphone-cleaned.caf"]]
if len({len(app), len(raw), len(clean)}) != 1:
    parser.error("The three source tracks have different lengths")
block = 480
energy = [sum(x * x for x in app[i:i + block]) / block for i in range(0, len(app) - block + 1, block)]
peak = max(energy, default=0)
active = [i for i, value in enumerate(energy) if value > max(1e-7, peak / 100)]
first = active[0] if active else 0
settle = max(0, math.ceil(args.settle_seconds * 100))
selected = []
for i in active:
    # Exclude speech edges where the processor's small internal delay affects RMS.
    if i >= first + settle and i >= 5 and i + 5 < len(energy):
        if all(energy[j] > max(1e-7, peak / 100) for j in range(i - 5, i + 6)):
            selected.extend(range(i * block, (i + 1) * block))
raw_energy = sum(raw[i] * raw[i] for i in selected)
clean_energy = sum(clean[i] * clean[i] for i in selected)
reduction = 10 * math.log10(max(raw_energy, 1e-30) / max(clean_energy, 1e-30))
raw_rms = math.sqrt(raw_energy / max(1, len(selected)))
session = json.loads((sources / "session.json").read_text())
report = {
    "measurement": "RMS reduction during controlled speaker-only speech after convergence",
    "requiresQuietRoom": True,
    "measuredSeconds": len(selected) / 48000,
    "settleSeconds": args.settle_seconds,
    "rawMicrophoneRMSdBFS": 20 * math.log10(max(raw_rms, 1e-30)),
    "reductionDB": reduction,
    "targetDB": 20,
    "sourceFrames": len(raw),
    "completed": session.get("completed", False),
    "passed": bool(session.get("completed") and len(selected) >= 48000 and raw_rms >= 0.001 and reduction >= 20),
}
print(json.dumps(report, indent=2))
if args.write_report:
    (args.directory / "acoustic-analysis.json").write_text(json.dumps(report, indent=2) + "\n")
sys.exit(0 if report["passed"] else 2)
