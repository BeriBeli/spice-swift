#!/usr/bin/env python3
"""Measure the shipped decoder with the deterministic jpeg-check.c corpus."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("harness", type=Path, help="compiled jpeg-check executable")
    parser.add_argument("output", type=Path, help="owned output directory")
    args = parser.parse_args()
    executable = args.harness.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=True)
    cases = []
    for width, height in [(1920, 1080), (3840, 2160)]:
        for sampling in [0, 2]:
            for quality in [40, 80]:
                name = f"{width}x{height}-{sampling}-q{quality}"
                jpeg = args.output / (name + ".jpg")
                pixels = args.output / (name + ".bgra")
                subprocess.run([str(executable), "generate", str(jpeg), str(width),
                    str(height), str(sampling), str(quality), "0"], check=True)
                trials = [json.loads(subprocess.check_output([str(executable), "decode",
                    str(jpeg), str(pixels), "30"], text=True)) for _ in range(5)]
                case = {"name": name, "width": width, "height": height,
                    "sampling": "444" if sampling == 0 else "420", "quality": quality,
                    "encoded_bytes": jpeg.stat().st_size,
                    "jpeg_sha256": hashlib.sha256(jpeg.read_bytes()).hexdigest(),
                    "bgra_sha256": hashlib.sha256(pixels.read_bytes()).hexdigest(),
                    "trials": trials,
                    "median_cpu_ms": statistics.median(t["cpu_ms_per_frame"] for t in trials),
                    "median_wall_ms": statistics.median(t["wall_ms_per_frame"] for t in trials)}
                cases.append(case)
                print(name, "cpu_ms", round(case["median_cpu_ms"], 3), flush=True)
    (args.output / "results.json").write_text(json.dumps({
        "warmup_frames_per_trial": 5, "timed_frames_per_trial": 30, "cases": cases,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
