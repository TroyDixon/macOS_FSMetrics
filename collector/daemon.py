"""
Collector daemon: the process an admin runs (or launchd manages) that polls
every configured volume on a schedule and writes results into SQLite.

Two cadences:
  - poll_interval_seconds       : health + performance (cheap, frequent)
  - capacity_scan_interval_seconds : per-user capacity walk (expensive, less
    frequent -- this is the one that touches every file)

Run with:  python3 -m collector.daemon --config config.yaml
Stop with: Ctrl-C (SIGINT is caught for a clean shutdown message)
"""
from __future__ import annotations

import argparse
import logging
import signal
import sys
import time

from . import health, performance, capacity, nfs_shared, alerts
from .config import Config
from .store import Store

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("collector")

_running = True


def _handle_sigint(signum, frame):
    global _running
    log.info("shutdown requested, finishing current cycle...")
    _running = False


def poll_once(store: Store, cfg: Config, do_capacity_scan: bool) -> None:
    for vol in cfg.volumes:
        try:
            metrics = []
            metrics += health.collect(cfg.host_label, vol.path, simulate=cfg.simulate)

            disk_id = vol.label if cfg.simulate else _disk_id_for(vol.path)
            metrics += performance.collect(cfg.host_label, vol.path, disk_id, simulate=cfg.simulate)

            if vol.kind == "nfs":
                metrics += nfs_shared.collect(cfg.host_label, vol.path, vol.path, simulate=cfg.simulate)

            if do_capacity_scan and vol.watch_users:
                metrics += capacity.collect(cfg.host_label, vol.path, vol.scan_paths, simulate=cfg.simulate)

            n = store.write_metrics(metrics)
            log.info("volume=%s wrote %d metrics", vol.path, n)
        except Exception as e:
            log.error("collection failed for volume=%s: %s", vol.path, e)


def _disk_id_for(mount_path: str) -> str:
    """
    Best-effort mapping of a mount point to a `diskN` identifier for iostat.
    Real implementation shells out to `diskutil info -plist <mount_path>` and
    reads DeviceIdentifier; kept as a thin wrapper so it's mockable in tests.
    """
    import subprocess
    import plistlib
    out = subprocess.run(["diskutil", "info", "-plist", mount_path],
                          capture_output=True, timeout=10, check=True).stdout
    data = plistlib.loads(out)
    return data.get("ParentWholeDisk") or data.get("DeviceIdentifier") or "disk0"


def main():
    parser = argparse.ArgumentParser(description="macOS FS metrics collector daemon")
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--once", action="store_true", help="run a single poll cycle and exit")
    args = parser.parse_args()

    cfg = Config.load(args.config)
    store = Store(cfg.db_path)
    signal.signal(signal.SIGINT, _handle_sigint)

    log.info("starting collector: host=%s volumes=%d simulate=%s db=%s",
              cfg.host_label, len(cfg.volumes), cfg.simulate, cfg.db_path)

    last_capacity_scan = 0.0
    volume_paths = [v.path for v in cfg.volumes]

    while _running:
        now = time.time()
        do_capacity = (now - last_capacity_scan) >= cfg.capacity_scan_interval_seconds
        poll_once(store, cfg, do_capacity_scan=do_capacity)
        if do_capacity:
            last_capacity_scan = now

        alerts.run_all_checks(store, cfg.host_label, volume_paths, cfg.thresholds, cfg.webhook_url)

        if args.once:
            break
        time.sleep(cfg.poll_interval_seconds)

    store.close()
    log.info("collector stopped cleanly")


if __name__ == "__main__":
    sys.exit(main())
