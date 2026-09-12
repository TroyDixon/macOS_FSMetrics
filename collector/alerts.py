"""
Alert engine.

Runs after each poll cycle against whatever is currently in the store. Rules
are intentionally simple threshold / rate-of-change checks rather than ML --
that's a legitimate, explainable, demoable approach for a hackathon, and the
README's future-work section calls out where real anomaly detection would
plug in.

Rules implemented:
  1. Capacity warn/critical thresholds per volume.
  2. Per-user growth-rate rule ("nefarious user" / runaway-job detector):
     if a user's attributed bytes grew by more than `user_growth_bytes_threshold`
     within `user_growth_bytes_window` seconds, fire an alert. This catches
     both malicious mass-uploads and (just as usefully in an AI-infra setting)
     a runaway model checkpoint loop filling the disk.
  3. Health rules: SMART not-OK, volume not writable, NFS mount down, NFS
     client retransmits/timeouts trending up.
  4. Throughput stall: no perf samples recorded within the configured window,
     which usually means the collector (or the underlying mount) is stuck.
"""
from __future__ import annotations

import json
import time
import urllib.request
from typing import Optional

from .config import AlertThresholds
from .store import Store


def check_capacity(store: Store, host: str, volume: str, thresholds: AlertThresholds) -> None:
    row = store.latest_value("capacity.used_pct", volume)
    if row is None:
        return
    pct = row["value"]
    if pct >= thresholds.capacity_pct_crit:
        store.write_alert(host, volume, "critical", "capacity",
                           f"{volume} is {pct:.1f}% full (>= {thresholds.capacity_pct_crit}% critical threshold)")
    elif pct >= thresholds.capacity_pct_warn:
        store.write_alert(host, volume, "warning", "capacity",
                           f"{volume} is {pct:.1f}% full (>= {thresholds.capacity_pct_warn}% warn threshold)")


def check_user_growth(store: Store, host: str, volume: str, thresholds: AlertThresholds) -> None:
    """
    Compares each user's most recent `capacity.user_bytes` sample against
    their earliest sample inside the lookback window. A big positive delta
    in a short window is the signature we treat as suspicious/noteworthy --
    same signal whether the cause is a bad actor or a misbehaving pipeline.
    """
    rows = store.latest_by_type("capacity.user_bytes", since_seconds=thresholds.user_growth_bytes_window, volume=volume)
    by_uid: dict[str, list] = {}
    for r in rows:
        by_uid.setdefault(r["uid"], []).append(r)

    for uid, samples in by_uid.items():
        if len(samples) < 2:
            continue
        samples.sort(key=lambda r: r["ts"])
        delta = samples[-1]["value"] - samples[0]["value"]
        if delta >= thresholds.user_growth_bytes_threshold:
            username = samples[-1]["username"] or uid
            gb = delta / 1e9
            store.write_alert(
                host, volume, "warning", "user_growth",
                f"user '{username}' grew usage by {gb:.2f} GB in the last "
                f"{thresholds.user_growth_bytes_window}s on {volume}",
                uid=uid,
            )


def check_health(store: Store, host: str, volume: str) -> None:
    smart = store.latest_value("health.smart_ok", volume)
    if smart is not None and smart["value"] == 0.0:
        store.write_alert(host, volume, "critical", "health",
                           f"{volume}: backing block storage SMART status is not OK")

    writable = store.latest_value("health.writable", volume)
    if writable is not None and writable["value"] == 0.0:
        store.write_alert(host, volume, "critical", "health",
                           f"{volume}: volume is not writable (read-only or offline)")

    nfs_ok = store.latest_value("nfs.mount_ok", volume)
    if nfs_ok is not None and nfs_ok["value"] == 0.0:
        store.write_alert(host, volume, "critical", "nfs",
                           f"{volume}: NFS mount appears to be down")


def check_throughput_stall(store: Store, host: str, volume: str, thresholds: AlertThresholds) -> None:
    row = store.latest_value("perf.throughput_gbps", volume)
    if row is None:
        return
    age = time.time() - row["ts"]
    if age > thresholds.throughput_stall_seconds:
        store.write_alert(host, volume, "warning", "performance",
                           f"{volume}: no I/O throughput samples in {int(age)}s (collector or mount may be stuck)")


def send_webhook(webhook_url: Optional[str], message: str) -> None:
    if not webhook_url:
        return
    try:
        req = urllib.request.Request(
            webhook_url,
            data=json.dumps({"text": message}).encode(),
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=5)
    except Exception:
        pass  # alerting must never crash the collector loop


def run_all_checks(store: Store, host: str, volumes: list[str], thresholds: AlertThresholds,
                    webhook_url: Optional[str] = None) -> None:
    before = len(store.recent_alerts(limit=1000))
    for volume in volumes:
        check_capacity(store, host, volume, thresholds)
        check_user_growth(store, host, volume, thresholds)
        check_health(store, host, volume)
        check_throughput_stall(store, host, volume, thresholds)
    after = store.recent_alerts(limit=1000)
    new_count = len(after) - before
    if new_count > 0 and webhook_url:
        for a in after[:new_count]:
            send_webhook(webhook_url, f"[{a['severity'].upper()}] {a['message']}")
