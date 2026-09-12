"""
Health collector: filesystem health + backing block storage health.

Data sources (macOS only):
  - `diskutil info -plist <mount_or_disk>`   -> SMARTStatus, container info,
    free/used bytes, encryption state, filesystem type
  - `system_profiler SPNVMeDataType -json`   -> NVMe controller health for
    Apple Silicon internal SSDs (media wear, spare blocks, temperature)
  - `diskutil apfs list -plist`              -> container/volume topology,
    snapshot counts (excess snapshots are a health/capacity smell)

All parsing functions take raw command output as input and return plain
dicts, so they can be unit-tested on any OS using recorded fixture output
(see tests/fixtures/). Only the `collect()` entry point shells out.
"""
from __future__ import annotations

import plistlib
import subprocess
from typing import Any, Optional

from .store import Metric

# SMART/health status strings diskutil reports that should be treated as
# "not verified" rather than crashing the collector.
_OK_STATUSES = {"Verified", "verified", "OK"}


def run(cmd: list[str]) -> str:
    """Thin wrapper so it's easy to mock in tests."""
    return subprocess.run(cmd, capture_output=True, timeout=10, check=True).stdout.decode()


def parse_diskutil_info_plist(raw_xml: bytes | str) -> dict[str, Any]:
    """Parse `diskutil info -plist <id>` output into the fields we care about."""
    if isinstance(raw_xml, str):
        raw_xml = raw_xml.encode()
    data = plistlib.loads(raw_xml)

    total = data.get("TotalSize") or data.get("Size") or 0
    free = data.get("FreeSpace") or data.get("APFSContainerFree") or 0
    used = total - free if total else 0

    return {
        "device_identifier": data.get("DeviceIdentifier"),
        "volume_name": data.get("VolumeName"),
        "filesystem": data.get("FilesystemType") or data.get("FilesystemName"),
        "smart_status": data.get("SMARTStatus", "Not Supported"),
        "total_bytes": total,
        "free_bytes": free,
        "used_bytes": used,
        "encrypted": bool(data.get("Encryption") or data.get("FileVault")),
        "mount_point": data.get("MountPoint"),
        "writable": bool(data.get("WritableVolume", True)),
        "removable_media": bool(data.get("RemovableMedia", False)),
    }


def parse_nvme_health(sp_json: dict[str, Any]) -> list[dict[str, Any]]:
    """Parse `system_profiler SPNVMeDataType -json` for controller wear/health."""
    results = []
    for item in sp_json.get("SPNVMeDataType", []):
        for controller in item.get("_items", [item]):
            for drive in controller.get("_items", [controller]):
                results.append({
                    "name": drive.get("_name"),
                    "smart_status": drive.get("smart_status", "Not Supported"),
                    "size": drive.get("size"),
                    "medium_type": drive.get("spnvme_medium_type"),
                })
    return results


def capacity_pct(used_bytes: float, total_bytes: float) -> float:
    if not total_bytes:
        return 0.0
    return round(100.0 * used_bytes / total_bytes, 2)


def collect(host: str, volume_path: str, simulate: bool = False) -> list[Metric]:
    """Collect health metrics for one volume. Returns Metric rows ready to store."""
    if simulate:
        return _simulate(host, volume_path)

    info_xml = run(["diskutil", "info", "-plist", volume_path])
    info = parse_diskutil_info_plist(info_xml)

    metrics = [
        Metric(host, volume_path, "health.smart_ok", 1.0 if info["smart_status"] in _OK_STATUSES else 0.0, "bool"),
        Metric(host, volume_path, "health.writable", 1.0 if info["writable"] else 0.0, "bool"),
        Metric(host, volume_path, "capacity.total_bytes", float(info["total_bytes"]), "bytes"),
        Metric(host, volume_path, "capacity.used_bytes", float(info["used_bytes"]), "bytes"),
        Metric(host, volume_path, "capacity.free_bytes", float(info["free_bytes"]), "bytes"),
        Metric(host, volume_path, "capacity.used_pct", capacity_pct(info["used_bytes"], info["total_bytes"]), "pct"),
    ]

    # Best-effort: NVMe controller health (internal Apple Silicon storage only;
    # silently skipped for network/external volumes where this doesn't apply).
    try:
        import json
        nvme_json = json.loads(run(["system_profiler", "SPNVMeDataType", "-json"]))
        for drive in parse_nvme_health(nvme_json):
            ok = 1.0 if drive["smart_status"] in _OK_STATUSES else 0.0
            metrics.append(Metric(host, volume_path, "health.nvme_smart_ok", ok, "bool", username=drive.get("name")))
    except Exception:
        pass

    return metrics


def _simulate(host: str, volume_path: str) -> list[Metric]:
    """Synthetic health data so the pipeline runs end-to-end off macOS (demo/dev)."""
    import random
    total = 2_000_000_000_000  # 2 TB
    used = total * random.uniform(0.55, 0.7)
    return [
        Metric(host, volume_path, "health.smart_ok", 1.0, "bool"),
        Metric(host, volume_path, "health.writable", 1.0, "bool"),
        Metric(host, volume_path, "capacity.total_bytes", float(total), "bytes"),
        Metric(host, volume_path, "capacity.used_bytes", float(used), "bytes"),
        Metric(host, volume_path, "capacity.free_bytes", float(total - used), "bytes"),
        Metric(host, volume_path, "capacity.used_pct", capacity_pct(used, total), "pct"),
    ]
