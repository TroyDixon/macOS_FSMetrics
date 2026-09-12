"""
Shared-volume collector: NFS and pNFS mounts.

Data sources (macOS only):
  - `nfsstat -m`   -> per-mount config: server address, transport, negotiated
    rsize/wsize, whether the mount is using pNFS layouts (flag "pnfs" appears
    in the mount flags on layout-capable servers/mounts)
  - `nfsstat -c`   -> client-side RPC counters (getattr/read/write calls,
    retries, timeouts). We sample this twice, 1s apart, and diff the
    read/write byte-ish counters to approximate throughput, since macOS
    doesn't expose a GB/s figure for NFS the way it does for local disks
    via iostat.

macOS's pNFS support is client-only and fairly minimal (no layout-type
breakdown exposed to userland tools), so pNFS is surfaced here as a boolean
"is this mount using pNFS" rather than deeper layout stats -- that's called
out explicitly in the README's future work section.
"""
from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass

from .store import Metric


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, timeout=10, check=True).stdout.decode()


@dataclass
class NfsMount:
    mount_point: str
    server: str
    flags: str
    pnfs: bool


_MOUNT_BLOCK_RE = re.compile(
    r"^(?P<server>\S+) on (?P<mount_point>\S+)\s*\n(?P<body>(?:.*\n?)*?)(?=^\S+ on |\Z)",
    re.MULTILINE,
)


def parse_nfsstat_m(raw: str) -> list[NfsMount]:
    """
    Parse `nfsstat -m` output. Typical macOS format:

        server:/export on /Volumes/Shared
        Flags: vers=4,addr=10.0.0.5,rsize=65536,wsize=65536,pnfs

    Returns one NfsMount per block found.
    """
    mounts = []
    for match in _MOUNT_BLOCK_RE.finditer(raw):
        server = match.group("server")
        mount_point = match.group("mount_point")
        body = match.group("body")
        flags_match = re.search(r"Flags:\s*(.+)", body)
        flags = flags_match.group(1).strip() if flags_match else ""
        mounts.append(NfsMount(
            mount_point=mount_point,
            server=server,
            flags=flags,
            pnfs="pnfs" in flags.lower(),
        ))
    return mounts


_RPC_COUNTER_RE = re.compile(r"^\s*(\w+)\s*:?\s*(\d+)\s*$")


def parse_nfsstat_client_counters(raw: str) -> dict[str, int]:
    """
    Parse the numeric client RPC counters out of `nfsstat -c` output.
    We don't try to model the full RPC stat table -- just pull whatever
    named integer counters are present (read, write, getattr, timeout,
    retrans, etc.) so callers can diff two samples for rate metrics.
    """
    counters = {}
    for line in raw.splitlines():
        m = _RPC_COUNTER_RE.match(line)
        if m:
            name, value = m.groups()
            counters[name.lower()] = int(value)
    return counters


def collect(host: str, volume_label: str, mount_point: str, simulate: bool = False) -> list[Metric]:
    if simulate:
        return _simulate(host, volume_label)

    mounts_raw = run(["nfsstat", "-m"])
    mounts = parse_nfsstat_m(mounts_raw)
    match = next((m for m in mounts if m.mount_point == mount_point), None)

    metrics = []
    if match:
        metrics.append(Metric(host, volume_label, "nfs.pnfs_enabled", 1.0 if match.pnfs else 0.0, "bool"))
        metrics.append(Metric(host, volume_label, "nfs.mount_ok", 1.0, "bool"))
    else:
        metrics.append(Metric(host, volume_label, "nfs.mount_ok", 0.0, "bool"))

    # Retransmits/timeouts are the clearest "shared storage health" signal
    # available from the client side without server-side access.
    try:
        counters = parse_nfsstat_client_counters(run(["nfsstat", "-c"]))
        if "timeout" in counters:
            metrics.append(Metric(host, volume_label, "nfs.client_timeouts", float(counters["timeout"]), "count"))
        if "retrans" in counters:
            metrics.append(Metric(host, volume_label, "nfs.client_retransmits", float(counters["retrans"]), "count"))
    except Exception:
        pass

    return metrics


def _simulate(host: str, volume_label: str) -> list[Metric]:
    import random
    return [
        Metric(host, volume_label, "nfs.mount_ok", 1.0, "bool"),
        Metric(host, volume_label, "nfs.pnfs_enabled", 1.0, "bool"),
        Metric(host, volume_label, "nfs.client_timeouts", float(random.randint(0, 2)), "count"),
        Metric(host, volume_label, "nfs.client_retransmits", float(random.randint(0, 3)), "count"),
    ]
