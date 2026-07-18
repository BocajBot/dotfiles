#!/usr/bin/env python3
import argparse
import csv
import os
import re
import shutil
import statistics
import subprocess
import time
from pathlib import Path

PROC_NAMES = [
    "steam",
    "steamwebhelper",
    "steam-runtime-supervisor",
]

CONFIG_CANDIDATES = [
    Path.home() / ".local/share/Steam/config/config.vdf",
    Path.home() / ".steam/steam/config/config.vdf",
    Path.home() / ".steam/root/config/config.vdf",
    Path.home() / ".var/app/com.valvesoftware.Steam/.local/share/Steam/config/config.vdf",
    Path.home() / ".var/app/com.valvesoftware.Steam/.steam/steam/config/config.vdf",
]


def steam_config_path():
    for path in CONFIG_CANDIDATES:
        if path.exists():
            return path
    raise SystemExit("Could not find Steam config.vdf.")


def read_key(path, key):
    text = path.read_text(errors="replace")
    match = re.search(rf'"{re.escape(key)}"\s*"([^"]*)"', text)
    return match.group(1) if match else None


def write_key(path, key, value):
    text = path.read_text(errors="replace")
    pattern = re.compile(rf'("{re.escape(key)}"\s*)"[^"]*"')
    new_text, count = pattern.subn(lambda m: f'{m.group(1)}"{value}"', text, count=1)

    if count != 1:
        raise RuntimeError(f'Could not find "{key}" in config.vdf.')

    path.write_text(new_text)


def set_cell(path, cell):
    now = str(int(time.time()))
    write_key(path, "CellIDServerOverride", str(cell))
    write_key(path, "CurrentCellID", str(cell))

    if read_key(path, "TimeCellIDSet") is not None:
        write_key(path, "TimeCellIDSet", now)


def default_iface():
    out = subprocess.check_output(["ip", "route", "get", "1.1.1.1"], text=True)
    match = re.search(r"\bdev\s+(\S+)", out)
    if not match:
        raise SystemExit("Could not determine default interface.")
    return match.group(1)


def rx_bytes(iface):
    return int(Path(f"/sys/class/net/{iface}/statistics/rx_bytes").read_text().strip())


def stop_steam():
    uid = str(os.getuid())

    for name in PROC_NAMES:
        subprocess.run(["pkill", "-TERM", "-u", uid, "-x", name],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    time.sleep(8)

    for name in PROC_NAMES:
        subprocess.run(["pkill", "-KILL", "-u", uid, "-x", name],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def start_steam(cmd):
    subprocess.Popen([cmd, "-silent"],
                     stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL,
                     start_new_session=True)


def measure(iface, duration):
    samples = []
    start_bytes = rx_bytes(iface)
    last_bytes = start_bytes
    last_time = time.monotonic()
    end_time = last_time + duration

    while time.monotonic() < end_time:
        time.sleep(1)
        now = time.monotonic()
        current_bytes = rx_bytes(iface)
        rate = (current_bytes - last_bytes) / max(now - last_time, 0.001)
        samples.append(rate)
        last_bytes = current_bytes
        last_time = now

    total = last_bytes - start_bytes
    elapsed = max(duration, 1)

    avg = total / elapsed
    median = statistics.median(samples) if samples else 0
    peak = max(samples) if samples else 0

    return avg, median, peak


def mib_s(value):
    return value / 1024 / 1024


def mbps(value):
    return value * 8 / 1000 / 1000


def parse_cells(spec):
    cells = []

    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue

        label = None

        if ":" in item:
            left, label = item.split(":", 1)
            left = left.strip()
            label = label.strip()
        else:
            left = item

        if "-" in left:
            start, end = left.split("-", 1)
            for n in range(int(start), int(end) + 1):
                cells.append((n, f"Cell {n}"))
        else:
            n = int(left)
            cells.append((n, label or f"Cell {n}"))

    return cells


def main():
    parser = argparse.ArgumentParser(description="Benchmark Steam download CellIDs.")
    parser.add_argument("--cells", default="1-30", help='Cell IDs to test. Example: "1-30" or "1:Atlanta,2:Chicago,3:Dallas"')
    parser.add_argument("--iface", help="Network interface. Default: auto-detect")
    parser.add_argument("--duration", type=int, default=60, help="Measurement seconds per cell. Default: 60")
    parser.add_argument("--warmup", type=int, default=35, help="Warmup seconds after Steam restart. Default: 35")
    parser.add_argument("--steam-cmd", default="steam", help="Steam command. Default: steam")
    parser.add_argument("--keep-best", action="store_true", help="Leave Steam set to the fastest tested CellID.")
    parser.add_argument("--output", default="steam-cell-results.csv", help="CSV output path.")
    args = parser.parse_args()

    config = steam_config_path()
    iface = args.iface or default_iface()
    cells = parse_cells(args.cells)

    original_cell = read_key(config, "CellIDServerOverride") or read_key(config, "CurrentCellID")
    if original_cell is None:
        raise SystemExit("Could not find CellIDServerOverride or CurrentCellID in config.vdf.")

    backup = config.with_suffix(f".vdf.backup-{int(time.time())}")
    shutil.copy2(config, backup)

    print(f"Steam config:   {config}")
    print(f"Backup:         {backup}")
    print(f"Interface:      {iface}")
    print(f"Original Cell:  {original_cell}")
    print()
    print("Queue a large Steam download before running this.")
    print("Close browsers/cloud sync/package managers while testing.")
    print()

    results = []

    try:
        for cell, label in cells:
            print(f"=== Testing {label} / CellID {cell} ===")

            stop_steam()
            set_cell(config, cell)
            start_steam(args.steam_cmd)

            print(f"Warmup: {args.warmup}s")
            time.sleep(args.warmup)

            effective_cell = read_key(config, "CurrentCellID") or str(cell)

            print(f"Measuring: {args.duration}s")
            avg, med, peak = measure(iface, args.duration)

            row = {
                "label": label,
                "requested_cell": cell,
                "effective_cell": effective_cell,
                "avg_MiB_s": round(mib_s(avg), 2),
                "median_MiB_s": round(mib_s(med), 2),
                "peak_MiB_s": round(mib_s(peak), 2),
                "avg_Mbps": round(mbps(avg), 1),
                "median_Mbps": round(mbps(med), 1),
                "peak_Mbps": round(mbps(peak), 1),
            }

            results.append(row)

            print(
                f"{label}: avg {row['avg_MiB_s']} MiB/s "
                f"({row['avg_Mbps']} Mbps), peak {row['peak_MiB_s']} MiB/s, "
                f"effective cell {effective_cell}"
            )
            print()

    finally:
        if results:
            best = max(results, key=lambda r: r["avg_MiB_s"])
            final_cell = best["requested_cell"] if args.keep_best else original_cell

            stop_steam()
            set_cell(config, final_cell)
            start_steam(args.steam_cmd)

            if args.keep_best:
                print(f"Kept best CellID: {final_cell}")
            else:
                print(f"Restored original CellID: {original_cell}")

    results_sorted = sorted(results, key=lambda r: r["avg_MiB_s"], reverse=True)

    with open(args.output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "label",
            "requested_cell",
            "effective_cell",
            "avg_MiB_s",
            "median_MiB_s",
            "peak_MiB_s",
            "avg_Mbps",
            "median_Mbps",
            "peak_Mbps",
        ])
        writer.writeheader()
        writer.writerows(results_sorted)

    print()
    print("=== Ranked results ===")
    for i, row in enumerate(results_sorted, 1):
        print(
            f"{i:2}. {row['label']:<12} "
            f"cell {str(row['requested_cell']):>3}  "
            f"avg {row['avg_MiB_s']:>7} MiB/s  "
            f"median {row['median_MiB_s']:>7} MiB/s  "
            f"peak {row['peak_MiB_s']:>7} MiB/s"
        )

    print()
    print(f"CSV written to: {args.output}")


if __name__ == "__main__":
    main()
