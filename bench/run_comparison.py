"""Measure wall time and child peak RSS on one host; write raw samples as JSON."""
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile

root = sys.argv[1] if len(sys.argv) > 1 else os.getenv("D4_RUST_BENCH_ROOT", "/tmp/d4-rust-bin")
crystal = os.getenv("D4_CRYSTAL_COMPARE_BIN", "/tmp/d4-crystal-compare")
rust_api = os.getenv("D4_RUST_COMPARE_BIN", "/tmp/d4-rust-compare")
rust_cli = root + "/bin/d4tools"
measure = os.getenv("D4_MEASURE_BIN", "/tmp/d4-measure")
cases = [("rust-api-primary-8m", 8_000_000), ("rust-api-primary-64m", 64_000_000),
         ("rust-api-primary-256m", 256_000_000), ("rust-api-sparse-8m", 8_000_000),
         ("rust-api-alternate-1m", 1_000_000), ("rust-api-alternate-5m", 5_000_000),
         ("rust-api-alternate-20m", 20_000_000)]
env = dict(os.environ, RAYON_NUM_THREADS="1")


def run(command):
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        child = subprocess.Popen([measure, *command], stdout=stdout, stderr=stderr, env=env)
        _, status, _ = os.wait4(child.pid, 0)
        stdout.seek(0)
        stderr.seek(0)
        error = stderr.read(1000).decode(errors="replace").strip()
        measurements = re.search(r"measure_ms=([\d.]+) peak_rss_kb=(\d+) user_ms=([\d.]+) system_ms=([\d.]+)", error)
        if not measurements:
            raise RuntimeError(error)
        result = {"ms": float(measurements[1]), "rss_kb": int(measurements[2]),
                  "user_ms": float(measurements[3]), "system_ms": float(measurements[4]),
                  "output": stdout.read(300).decode(errors="replace").strip(),
                  "error": error,
                  "status": os.waitstatus_to_exitcode(status)}
        return result


rows = []
for name, length in cases:
    path = f"{root}/{name}.d4"
    if not os.path.exists(path):
        pattern = "primary" if "primary" in name else "sparse" if "sparse" in name else "alternate"
        subprocess.run([rust_api, "generate", path, str(length), pattern], check=True, env=env)
    operations = {
        "scan": [
            ("Crystal", [crystal, "scan", path, str(length)]),
            ("Rust C API", [rust_api, "scan", path, str(length)]),
            ("Rust CLI stat", [rust_cli, "stat", "-t", "1", "-s", "sum", path]),
        ],
        "point": [
            ("Crystal", [crystal, "point", path, str(length), "4096"]),
            ("Rust C API", [rust_api, "point", path, str(length), "4096"]),
        ],
    }
    if "primary" not in name or "256m" in name:
        del operations["point"]  # Unindexed secondary lookup can rescan large record streams.
    for operation, programs in operations.items():
        for label, command in programs:
            samples = [run(command) for _ in range(4)]
            kept = samples[1:]
            row = {"file": name, "bases": length, "operation": operation, "program": label,
                   "warm_ms_median": round(statistics.median(s["ms"] for s in kept), 3),
                   "warm_ms_range": [min(s["ms"] for s in kept), max(s["ms"] for s in kept)],
                   "peak_rss_kb_median": statistics.median(s["rss_kb"] for s in kept),
                   "samples": samples}
            rows.append(row)
            print(f"{name:20s} {operation:5s} {label:13s}: "
                  f"{row['warm_ms_median']:>9} ms  {row['peak_rss_kb_median']:>10} KiB "
                  f"{kept[0]['output']}", flush=True)
            if any(s["status"] for s in samples):
                print("ERROR", samples, flush=True)
                sys.exit(1)

with open(f"{root}/comparison.json", "w") as output:
    json.dump(rows, output, indent=2)
