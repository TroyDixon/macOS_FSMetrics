"""
Performance collector: filesystem I/O throughput in GB/s.

Data source (macOS only): `iostat -d -c 2 <disk>` which, on macOS, prints a
header line followed by columns "KB/t tps MB/s" per configured device, e.g.:

              disk0
    KB/t  tps  MB/s
   128.00   45  5.62
   256.00   12  3.00

iostat is asked for 2 samples (`-c 2`); the first sample is a since-boot
average which we discard, keeping only the live second sample.

For per-process attribution (useful in the "nefarious user" story) macOS
`fs_usage` can be layered in -- it requires root and is noisy, so it's kept
as an optional, separate function rather than part of the default poll loop.
"""
from __future__ import annotations

import re
import subprocess
from typing import Optional

from .store import Metric


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, timeout=15, check=True).stdout.decode()


_ROW_RE = re.compile(r"^\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*$")


def parse_iostat(raw: str) -> list[dict[str, float]]:
    """
    Parse macOS `iostat -d -c N <disk>` output into a list of samples
    (one dict per repeated sample block) with keys kb_per_transfer, tps, mb_per_s.
    Header/device-name lines are skipped; only numeric rows are captured.
    """
    samples = []
    for line in raw.splitlines():
        m = _ROW_RE.match(line)
        if m:
            kb_t, tps, mb_s = (float(x) for x in m.groups())
            samples.append({"kb_per_transfer": kb_t, "tps": tps, "mb_per_s": mb_s})
    return samples


def collect(host: str, volume_path: str, disk_id: str, simulate: bool = False) -> list[Metric]:
    """
    Collect a live throughput sample for `disk_id` (e.g. "disk0" or "disk3s1").
    Uses -c 2 and keeps the last sample so the number reflects "now", not the
    since-boot average iostat reports as sample 1.
    """
    if simulate:
        return _simulate(host, volume_path)

    raw = run(["iostat", "-d", "-c", "2", disk_id])
    samples = parse_iostat(raw)
    if not samples:
        return []

    last = samples[-1]
    gb_per_s = last["mb_per_s"] / 1024.0

    return [
        Metric(host, volume_path, "perf.throughput_gbps", gb_per_s, "GB/s"),
        Metric(host, volume_path, "perf.transfers_per_sec", last["tps"], "tps"),
        Metric(host, volume_path, "perf.kb_per_transfer", last["kb_per_transfer"], "KB"),
    ]


def collect_fs_usage_sample(volume_path: str, duration_seconds: float = 2.0) -> Optional[str]:
    """
    Optional deeper sample: raw `fs_usage` output for the given time window.
    Requires root. Returns raw text for the alert engine / dashboard to grep
    for per-process bursts; parsing is intentionally left loose since
    fs_usage's format varies by macOS version.
    """
    try:
        proc = subprocess.run(
            ["timeout", str(duration_seconds), "fs_usage", "-f", "filesys"],
            capture_output=True,
        )
        return proc.stdout.decode(errors="ignore")
    except Exception:
        return None


def _simulate(host: str, volume_path: str) -> list[Metric]:
    import random
    gb_per_s = random.uniform(0.05, 1.8)
    return [
        Metric(host, volume_path, "perf.throughput_gbps", gb_per_s, "GB/s"),
        Metric(host, volume_path, "perf.transfers_per_sec", random.uniform(5, 300), "tps"),
        Metric(host, volume_path, "perf.kb_per_transfer", random.uniform(32, 512), "KB"),
    ]
