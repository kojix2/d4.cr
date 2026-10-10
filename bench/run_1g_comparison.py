"""Compare Crystal, Rust C API, and Rust CLI on pre-generated ~1 or 2 GB D4s.

Generate the files with compare.c, then run this script. The first sample for
each case warms the page cache; the JSON retains all four samples.
"""

import argparse
import json
import os
import re
import statistics
import subprocess


def measure(command):
    process = subprocess.run([MEASURE, *command], capture_output=True, text=True)
    if process.returncode:
        raise RuntimeError(f"{command}: {process.returncode}\n{process.stdout}\n{process.stderr}")
    timing = re.search(
        r"measure_ms=([\d.]+) peak_rss_kb=(\d+) user_ms=([\d.]+) system_ms=([\d.]+)",
        process.stderr,
    )
    if not timing:
        raise RuntimeError(process.stderr)
    checksum = re.search(r"checksum=(-?\d+)", process.stdout)
    if checksum:
        total = int(checksum[1])
    else:
        rows = [line.split() for line in process.stdout.splitlines() if line.startswith("chr")]
        total = sum(int(row[-1]) for row in rows)
    allocated = re.search(r"allocated_bytes=(\d+)", process.stdout)
    return {
        "ms": float(timing[1]),
        "rss_kb": int(timing[2]),
        "user_ms": float(timing[3]),
        "system_ms": float(timing[4]),
        "checksum": total,
        "allocated_bytes": int(allocated[1]) if allocated else None,
    }


parser = argparse.ArgumentParser()
parser.add_argument("--program", choices=["crystal", "rust-api", "rust-cli", "all"], default="all")
parser.add_argument("--scale", choices=[1, 2], type=int, default=1,
                    help="1 GB single-chromosome or 2 GB two-chromosome primary file")
args = parser.parse_args()

MEASURE = os.getenv("D4_MEASURE_BIN", "/tmp/d4-measure")
CRYSTAL = os.getenv("D4_CRYSTAL_COMPARE_BIN", "/tmp/d4-crystal-compare-new")
RUST_API = os.getenv("D4_RUST_COMPARE_BIN", "/tmp/d4-rust-compare")
RUST_CLI = os.getenv("D4_RUST_CLI_BIN", "/tmp/d4-rust-bin/bin/d4tools")
OUTPUT = os.getenv("D4_1G_RESULT", "/tmp/d4-1g-comparison.json")
size = args.scale
cases = [
    (f"primary-{size}g", os.getenv(f"D4_{size}G_PRIMARY", f"/tmp/d4-primary-{size}g.d4"),
     2_863_267_840, 10_021_437_440 * size, "scan-dual" if size == 2 else "scan"),
    (f"secondary-{size}g", os.getenv(f"D4_{size}G_SECONDARY", f"/tmp/d4-secondary-{size}g.d4"),
     100_000_000 * size, 150_000_000 * size, "scan"),
]
programs = ["crystal", "rust-api", "rust-cli"] if args.program == "all" else [args.program]
results = []
for name, path, length, expected, mode in cases:
    for program in programs:
        samples = []
        for attempt in range(4):
            command = (
                [RUST_CLI, "stat", "--no-index", "-s", "sum", "-t", "1", path]
                if program == "rust-cli"
                else [CRYSTAL if program == "crystal" else RUST_API, mode, path, str(length)]
            )
            sample = measure(command)
            if sample["checksum"] != expected:
                raise RuntimeError(f"wrong checksum: {name} {program} {sample}")
            samples.append(sample)
            print(name, program, attempt, sample, flush=True)
        kept = samples[1:]
        results.append({
            "scenario": name,
            "file_bytes": os.path.getsize(path),
            "bases": length,
            "program": program,
            "median_ms": statistics.median(item["ms"] for item in kept),
            "median_rss_kb": statistics.median(item["rss_kb"] for item in kept),
            "samples": samples,
        })
        with open(OUTPUT, "w") as file:
            json.dump(results, file, indent=2)
