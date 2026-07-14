#!/usr/bin/env python3
"""CrossOver / Wine log analyzer for input latency signals.

Usage:
    python3 log-analyzer/analyze.py [--logs-dir logs] [--output logs-findings.md]

Scans log files for latency-relevant signals using the detectors defined in
patterns.py. Writes structured findings to logs-findings.md.

Does NOT assume any log format — reads each file and auto-detects the format
before applying pattern matching.
"""

import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

from patterns import DETECTORS, CATEGORY_LABELS


def detect_format(lines: list[str]) -> str:
    """Auto-detect log file format from the first 200 lines."""
    sample = "".join(lines[:200])

    if re.search(r"^\d{4,6}\.\d{3,6}:trace:", sample, re.MULTILINE):
        return "wine_debug"
    if re.search(r"^trace:", sample, re.MULTILINE):
        return "wine_debug_notimestamp"
    if "D3DMetal" in sample and ("MTLCommandBuffer" in sample or "CAMetalLayer" in sample):
        return "d3dmetal"
    if "DXVK" in sample:
        return "dxvk"
    if "CrossOver" in sample or "cxbottle" in sample or "cxoffice" in sample:
        return "crossover_app"
    if re.search(r"^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}", sample):
        return "timestamped_generic"
    if "com.apple.GameController" in sample or "com.apple.IOHID" in sample:
        return "macos_unified"
    if re.search(r"fixme:|err:|warn:", sample, re.MULTILINE):
        return "wine_generic"
    return "unknown"


def scan_file(filepath: Path, detectors: list[dict]) -> list[dict]:
    """Scan a single log file with all detectors. Returns list of findings."""
    try:
        with open(filepath, "r", errors="replace") as f:
            lines = f.readlines()
    except Exception as e:
        return [{"file": str(filepath), "error": str(e)}]

    log_format = detect_format(lines)
    findings = []

    for detector in detectors:
        matches = []
        for i, line in enumerate(lines):
            for pattern in detector["patterns"]:
                if re.search(pattern, line, re.IGNORECASE):
                    matches.append({
                        "line_num": i + 1,
                        "line": line.strip()[:300],
                    })
                    break

        if matches:
            findings.append({
                "detector": detector["name"],
                "category": detector["category"],
                "relevance": detector["relevance"],
                "limitation": detector["limitation"],
                "match_count": len(matches),
                "sample_matches": matches[:5],
                "all_lines": [m["line_num"] for m in matches],
            })

    return findings, log_format


def format_findings_md(
    all_results: list[tuple[Path, str, list[dict]]],
    logs_dir: Path,
) -> str:
    """Format all findings as markdown."""
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines = []
    lines.append("# CrossOver / Wine Log Analysis: Latency Signals\n")
    lines.append(f"> Generated: {now}")
    lines.append(f"> Logs directory: `{logs_dir}`\n")

    files_analyzed = [p for p, f, _ in all_results]
    lines.append(f"## Files Analyzed ({len(files_analyzed)})")
    lines.append("")
    for fp in files_analyzed:
        try:
            size = fp.stat().st_size
            size_str = f"{size / 1024:.1f} KB" if size > 1024 else f"{size} B"
        except Exception:
            size_str = "?"
        lines.append(f"- `{fp.name}` ({size_str})")
    lines.append("")

    # Group findings by category
    by_category = defaultdict(list)
    has_errors = False

    for filepath, log_format, findings in all_results:
        for finding in findings:
            if "error" in finding:
                lines.append(f"### Error: {filepath.name}")
                lines.append(f"```\n{finding['error']}\n```\n")
                has_errors = True
                continue

    for filepath, log_format, findings in all_results:
        if not findings:
            lines.append(f"### {filepath.name} — No signals detected")
            lines.append(f"Format: `{log_format}` — no latency-relevant patterns matched.")
            lines.append("")
            continue

        lines.append(f"## {filepath.name}")
        lines.append(f"Format: `{log_format}` | Findings: {sum(1 for f in findings if 'detector' in f)}")
        lines.append("")

        by_category = defaultdict(list)
        for f in findings:
            if "detector" in f:
                by_category[f["category"]].append(f)

        for category, cat_findings in sorted(by_category.items()):
            label = CATEGORY_LABELS.get(category, category)
            lines.append(f"### {label}")
            lines.append("")

            for f in cat_findings:
                relevance_icon = {
                    "direct":   "[DIRECT]",
                    "indirect": "[indirect]",
                    "none":     "[NONE]",
                }.get(f["relevance"], "")

                lines.append(f"#### Finding: {f['detector']} {relevance_icon}")
                lines.append(f"- **Matches**: {f['match_count']} lines")
                lines.append(f"- **Line range**: {min(f['all_lines'])}–{max(f['all_lines'])}")
                lines.append("")

                lines.append("**Sample matches:**")
                lines.append("```")
                for m in f["sample_matches"]:
                    lines.append(f"  L{m['line_num']}: {m['line'][:250]}")
                lines.append("```")
                lines.append("")

                lines.append(f"**What this tells us:** {f['detector']}")
                lines.append("")
                lines.append(f"**Latency relevance:** {f['relevance']}")
                lines.append("")
                lines.append(f"**Limitation:** {f['limitation']}")
                lines.append("")

        lines.append("---")
        lines.append("")

    # ── Summary section ──────────────────────────────────────────────────
    lines.append("## Summary: What These Logs Can and Cannot Tell Us")
    lines.append("")

    lines.append("### What CAN be determined from these logs")
    lines.append("")
    lines.append(determine_capabilities(all_results))
    lines.append("")

    lines.append("### What CANNOT be determined (requires Stage 2)")
    lines.append("")
    lines.append(
        "1. **True button-to-photon latency** — the time between a physical button press "
        "and the corresponding change in screen pixels. This requires a high-speed camera "
        "or hardware latency tester (e.g., LDAT, OSRTT).\n\n"
        "2. **CrossOver input translation overhead** — the delay Wine adds between the "
        "macOS HID layer and the Windows game's XInput/dinput API. Requires the native "
        "vs in-bottle comparison (Addition A).\n\n"
        "3. **macOS input stack latency** — the delay between the Bluetooth radio receiving "
        "a controller packet and it reaching the IOKit HID layer. Requires kernel-level "
        "tracing or a hardware USB analyzer.\n\n"
        "4. **Display latency** — pixel response time, scanout rate, and any compositor "
        "buffering. Requires a photodiode or high-speed camera at the display.\n\n"
        "5. **Input-to-render pipeline depth** — how many frames of buffering exist between "
        "the game reading input and that input affecting rendered output. This varies by "
        "game engine and render pipeline configuration."
    )
    lines.append("")

    lines.append("### Recommendations for Better Data")
    lines.append("")
    lines.append(
        "To get more actionable signals from Wine logs, enable these WINEDEBUG channels:\n\n"
        "```bash\n"
        "# Input path with timestamps:\n"
        "WINEDEBUG=+timestamp,+dinput,+hid,+xinput wine game.exe 2> input-trace.log\n\n"
        "# Graphics pipeline with timestamps:\n"
        "WINEDEBUG=+timestamp,+d3d,+d3d11,+dxgi wine game.exe 2> gpu-trace.log\n\n"
        "# Full diagnostics (huge output — use for 10-30 second captures):\n"
        "WINEDEBUG=+timestamp,+dinput,+hid,+xinput,+d3d,+d3d11,+dxgi,+seh wine game.exe 2> full.log\n"
        "```\n\n"
        "See `log-analyzer/wine-debug-channels.md` for all available channels."
    )

    return "\n".join(lines)


def determine_capabilities(all_results: list) -> str:
    """Determine what we CAN tell from the logs based on actual findings."""
    all_findings = []
    for _, _, findings in all_results:
        for f in findings:
            if "detector" in f:
                all_findings.append(f)

    detector_names = {f["detector"] for f in all_findings}

    caps = []

    if any("HID" in n for n in detector_names):
        caps.append(
            "1. **Controller detection timing** — when the controller was first "
            "detected by Wine/HID. Useful for measuring initialization overhead."
        )

    if "dinput polling / GetDeviceState" in detector_names:
        caps.append(
            "2. **Game polling rate (approximate)** — the interval between "
            "successive dinput GetDeviceState/XInputGetState calls shows how "
            "fast the game is reading controller state. This is the game's poll "
            "rate, not the hardware report rate."
        )

    if "Direct3D / D3DMetal frame timing" in detector_names:
        caps.append(
            "3. **Frame boundaries** — Present/swap timestamps mark the GPU end "
            "of each frame, giving frame pacing data. Combined with input polling "
            "rate, this gives an upper bound on input latency (must be > 1 game frame)."
        )

    if any("FPS" in n or "frametime" in n for n in detector_names):
        caps.append(
            "4. **Engine-reported frame pacing** — the game's own FPS measurement. "
            "Useful as a sanity check against GPU frame timing."
        )

    if "USB / Bluetooth events" in detector_names:
        caps.append(
            "5. **Connection stability** — disconnect/reconnect events identify "
            "blips that would cause outlier latency spikes."
        )

    if not caps:
        caps.append(
            "No latency-relevant signals were found in the provided logs. "
            "Enable WINEDEBUG channels (see recommendations below) to capture "
            "input and graphics pipeline traces."
        )

    return "\n\n".join(caps)


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Analyze CrossOver/Wine logs for latency signals"
    )
    parser.add_argument(
        "--logs-dir",
        default="logs",
        help="Directory containing log files (default: logs/)",
    )
    parser.add_argument(
        "--output",
        default="logs-findings.md",
        help="Output markdown file (default: logs-findings.md)",
    )
    args = parser.parse_args()

    logs_dir = Path(args.logs_dir)
    if not logs_dir.exists():
        print(f"Error: logs directory not found: {logs_dir}", file=sys.stderr)
        sys.exit(1)

    log_files = sorted(
        f for f in logs_dir.iterdir()
        if f.is_file()
        and not f.name.startswith(".")
        and f.name != "README.md"
        and not f.name.endswith(".gitkeep")
    )

    if not log_files:
        print(f"No log files found in {logs_dir}/ (excluding README.md and .gitkeep)", file=sys.stderr)
        print("Drop CrossOver/Wine log files there and re-run.", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(log_files)} log file(s). Scanning...", file=sys.stderr)

    all_results = []
    detectors = DETECTORS

    for filepath in log_files:
        print(f"  {filepath.name} ...", file=sys.stderr, end=" ")
        findings, log_format = scan_file(filepath, detectors)
        signal_count = sum(1 for f in findings if "detector" in f)
        error_count = sum(1 for f in findings if "error" in f)
        if error_count:
            print(f"ERROR ({error_count})", file=sys.stderr)
        else:
            print(f"format={log_format}, signals={signal_count}", file=sys.stderr)
        all_results.append((filepath, log_format, findings))

    print(file=sys.stderr)
    print(f"Writing findings to {args.output} ...", file=sys.stderr)

    output = format_findings_md(all_results, logs_dir)
    Path(args.output).write_text(output)

    print(f"Done. ({args.output})", file=sys.stderr)


if __name__ == "__main__":
    main()
