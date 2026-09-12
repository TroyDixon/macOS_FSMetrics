"""
Capacity + per-user usage collector.

APFS has no native per-user quota system (unlike ZFS/HFS+ with quotas), so
"per-user quotas" here means: walk the target paths, attribute bytes to the
owning UID via `os.stat().st_uid`, and let the alert engine apply soft
thresholds ourselves (config-defined, not kernel-enforced).

This uses only POSIX stdlib (os.scandir + os.stat), so unlike health.py and
performance.py it runs and is fully testable on Linux too -- st_uid/getpwuid
are POSIX, not Darwin-specific. On macOS this is the same approach `du` and
Finder's "Get Info" use under the hood, just aggregated by owner instead of
by directory.

For large trees this is O(files) and can be slow; the daemon runs it on a
longer interval (capacity_scan_interval_seconds) than the health/perf polls,
and real deployments should bound `scan_paths` to per-user home directories
rather than walking an entire multi-TB volume from the root.
"""
from __future__ import annotations

import os
import pwd
from collections import defaultdict
from typing import Optional

from .store import Metric


def username_for_uid(uid: int) -> str:
    try:
        return pwd.getpwuid(uid).pw_name
    except (KeyError, OverflowError):
        return str(uid)


def scan_usage_by_uid(paths: list[str], follow_symlinks: bool = False) -> dict[int, int]:
    """
    Walk `paths` and return {uid: total_bytes_owned}.
    Skips paths it can't read (permissions) rather than crashing -- a
    monitoring tool should degrade gracefully, not take down the scan
    because one user's home directory is 700.
    """
    totals: dict[int, int] = defaultdict(int)

    for root_path in paths:
        for dirpath, dirnames, filenames in os.walk(root_path, onerror=lambda e: None):
            for fname in filenames:
                fpath = os.path.join(dirpath, fname)
                try:
                    st = os.lstat(fpath) if not follow_symlinks else os.stat(fpath)
                except (FileNotFoundError, PermissionError, OSError):
                    continue
                totals[st.st_uid] += st.st_size

    return dict(totals)


def largest_paths(paths: list[str], top_n: int = 10) -> list[tuple[str, int]]:
    """Bonus metric: biggest individual files under the scanned paths, useful
    for admins chasing down what's actually eating capacity."""
    sizes: list[tuple[str, int]] = []
    for root_path in paths:
        for dirpath, _, filenames in os.walk(root_path, onerror=lambda e: None):
            for fname in filenames:
                fpath = os.path.join(dirpath, fname)
                try:
                    st = os.lstat(fpath)
                except (FileNotFoundError, PermissionError, OSError):
                    continue
                sizes.append((fpath, st.st_size))
    sizes.sort(key=lambda t: t[1], reverse=True)
    return sizes[:top_n]


def collect(host: str, volume_label: str, scan_paths: list[str], simulate: bool = False) -> list[Metric]:
    if simulate:
        return _simulate(host, volume_label)

    usage = scan_usage_by_uid(scan_paths)
    metrics = []
    for uid, total_bytes in usage.items():
        metrics.append(Metric(
            host, volume_label, "capacity.user_bytes", float(total_bytes), "bytes",
            uid=str(uid), username=username_for_uid(uid),
        ))
    return metrics


def _simulate(host: str, volume_label: str) -> list[Metric]:
    import random
    fake_users = [("501", "alice"), ("502", "bob"), ("503", "carol"), ("504", "dave")]
    metrics = []
    for uid, name in fake_users:
        bytes_used = random.uniform(5e9, 4e11)
        metrics.append(Metric(host, volume_label, "capacity.user_bytes", bytes_used, "bytes", uid=uid, username=name))
    return metrics
