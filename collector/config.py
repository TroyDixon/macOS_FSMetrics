"""
Configuration loading for the macOS FS Metrics collector.

Config is a single YAML file (see config.yaml at repo root). Kept deliberately
small/flat so it's easy to demo and easy to judge/read.
"""
from __future__ import annotations

import dataclasses
import os
from typing import Any

import yaml


@dataclasses.dataclass
class VolumeConfig:
    path: str                      # mount point, e.g. "/" or "/Volumes/Shared"
    kind: str                      # "apfs" | "nfs"
    label: str = ""                # human label for dashboards/alerts
    watch_users: bool = True       # whether to run the per-user capacity scan
    scan_paths: list[str] = dataclasses.field(default_factory=list)  # dirs to
    # walk for per-user usage; defaults to [path] if empty

    def __post_init__(self):
        if not self.label:
            self.label = self.path
        if not self.scan_paths:
            self.scan_paths = [self.path]


@dataclasses.dataclass
class AlertThresholds:
    capacity_pct_warn: float = 80.0
    capacity_pct_crit: float = 95.0
    user_growth_bytes_window: int = 600         # seconds - the lookback window
    user_growth_bytes_threshold: float = 5e9    # 5 GB grown within the window
    io_error_count_threshold: int = 1           # any block errors => alert
    throughput_stall_seconds: int = 120         # no I/O samples => stalled/alert


@dataclasses.dataclass
class Config:
    db_path: str = "metrics.db"
    poll_interval_seconds: int = 15
    capacity_scan_interval_seconds: int = 120
    host_label: str = "unnamed-host"
    volumes: list[VolumeConfig] = dataclasses.field(default_factory=list)
    thresholds: AlertThresholds = dataclasses.field(default_factory=AlertThresholds)
    webhook_url: str | None = None
    simulate: bool = False  # if True, collectors emit synthetic data instead of
    # shelling out to macOS-only tools. Lets the whole pipeline run/demo on any OS.

    @staticmethod
    def load(path: str) -> "Config":
        with open(path, "r") as f:
            raw: dict[str, Any] = yaml.safe_load(f) or {}

        volumes = [VolumeConfig(**v) for v in raw.get("volumes", [])]
        thresholds_raw = raw.get("thresholds", {})
        thresholds = AlertThresholds(**thresholds_raw)

        return Config(
            db_path=raw.get("db_path", "metrics.db"),
            poll_interval_seconds=raw.get("poll_interval_seconds", 15),
            capacity_scan_interval_seconds=raw.get("capacity_scan_interval_seconds", 120),
            host_label=raw.get("host_label", os.uname().nodename if hasattr(os, "uname") else "host"),
            volumes=volumes,
            thresholds=thresholds,
            webhook_url=raw.get("webhook_url"),
            simulate=raw.get("simulate", False),
        )
