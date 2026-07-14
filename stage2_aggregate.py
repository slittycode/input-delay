#!/usr/bin/env python3
"""Aggregate inputLagTimer results across multiple clips into median + spread.

Single button-to-photon measurements are noisy (camera framerate quantization, panel
response variance, exactly which frame motion crosses threshold). Recording several clips
and pooling every detected latency event gives a defensible central value and spread.

Reads the <video>.result.json sidecars written by our patched inputLagTimer.py.

Usage:
    python3 stage2_aggregate.py clips/                 # scan a directory
    python3 stage2_aggregate.py a.mp4.result.json b.mp4.result.json
    (no args) -> scans ./clips
"""
import glob
import json
import os
import statistics
import sys


def find_results(args):
    if not args:
        args = ["clips"]
    files = []
    for a in args:
        if os.path.isdir(a):
            files += glob.glob(os.path.join(a, "*.result.json"))
        elif a.endswith(".result.json") and os.path.isfile(a):
            files.append(a)
        elif os.path.isfile(a):  # a video path -> its sidecar
            side = a + ".result.json"
            if os.path.isfile(side):
                files.append(side)
    return sorted(set(files))


def main():
    files = find_results(sys.argv[1:])
    if not files:
        print("No *.result.json files found.")
        print("Measure clips first (stage2_measure.sh), or pass a directory/files.")
        sys.exit(1)

    pooled = []          # every individual latency event across all clips
    per_clip = []        # (name, count, median) per clip

    print("=" * 66)
    print("Per-clip results")
    print("=" * 66)
    print(f"{'clip':<34}{'n':>4}{'median':>10}{'stdev':>10}")
    for f in files:
        with open(f) as fh:
            d = json.load(fh)
        lat = d.get("latencies_ms", [])
        if not lat:
            continue
        pooled += lat
        med = statistics.median(lat)
        sd = statistics.pstdev(lat) if len(lat) > 1 else 0.0
        per_clip.append((os.path.basename(d.get("video", f)), len(lat), med))
        name = os.path.basename(d.get("video", f))
        print(f"{name[:33]:<34}{len(lat):>4}{med:>9.1f}m{sd:>9.1f}m")

    if not pooled:
        print("\nResult files exist but contain no latency measurements.")
        sys.exit(1)

    pooled.sort()
    n = len(pooled)
    med = statistics.median(pooled)
    mean = statistics.mean(pooled)
    sd = statistics.pstdev(pooled) if n > 1 else 0.0
    # interquartile range = robust spread
    q1 = statistics.quantiles(pooled, n=4)[0] if n >= 4 else pooled[0]
    q3 = statistics.quantiles(pooled, n=4)[2] if n >= 4 else pooled[-1]

    print("\n" + "=" * 66)
    print(f"POOLED across {len(per_clip)} clip(s), {n} latency events")
    print("=" * 66)
    print(f"  Median            : {med:6.1f} ms   <- headline button-to-photon latency")
    print(f"  Mean              : {mean:6.1f} ms")
    print(f"  Std dev           : {sd:6.1f} ms   <- spread (measurement + real variance)")
    print(f"  IQR (Q1-Q3)       : {q1:6.1f} - {q3:.1f} ms   <- robust spread")
    print(f"  Min / Max         : {min(pooled):6.1f} / {max(pooled):.1f} ms")
    print("=" * 66)
    print("Note: this is END-TO-END button-to-photon latency (Stage 2), a different and")
    print("larger quantity than the Stage 1 polling interval. It includes controller report")
    print("time + USB/BT + OS + game + render + display response. Compare clips taken under")
    print("identical camera/lighting/threshold settings only.")


if __name__ == "__main__":
    main()
