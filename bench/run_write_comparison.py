"""Write identical values through Crystal and the Rust D4 C API."""
import json
import os
import re
import statistics
import subprocess

root = os.getenv("D4_RUST_BENCH_ROOT", "/tmp/d4-rust-bin")
measure = os.getenv("D4_MEASURE_BIN", "/tmp/d4-measure")
crystal = os.getenv("D4_CRYSTAL_COMPARE_BIN", "/tmp/d4-crystal-compare")
rust_api = os.getenv("D4_RUST_COMPARE_BIN", "/tmp/d4-rust-compare")
results = []
for name, length, pattern in [("primary-8m", 8_000_000, "primary"),
                              ("alternate-1m", 1_000_000, "alternate")]:
    for language, binary in [("Crystal", crystal), ("Rust C API", rust_api)]:
        samples = []
        for attempt in range(4):
            path = f"{root}/write-{name}-{language.replace(' ', '-')}.d4"
            if os.path.exists(path):
                os.remove(path)
            measured = subprocess.run(
                [measure, binary, "generate", path, str(length), pattern],
                capture_output=True, text=True, check=True)
            values = re.search(r"measure_ms=([\d.]+) peak_rss_kb=(\d+)", measured.stderr)
            if values is None:
                raise RuntimeError(measured.stderr)
            samples.append({"ms": float(values[1]), "rss_kb": int(values[2]),
                            "file_bytes": os.path.getsize(path)})
            os.remove(path)
        kept = samples[1:]
        result = {"scenario": name, "bases": length, "program": language,
                  "warm_ms_median": statistics.median(v["ms"] for v in kept),
                  "peak_rss_kb_median": statistics.median(v["rss_kb"] for v in kept),
                  "file_bytes": kept[0]["file_bytes"], "samples": samples}
        results.append(result)
        print(result["scenario"], result["program"], result["warm_ms_median"],
              result["peak_rss_kb_median"], result["file_bytes"], flush=True)
with open(f"{root}/write-comparison.json", "w") as output:
    json.dump(results, output, indent=2)
