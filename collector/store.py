"""
Storage layer: a single SQLite file holding two tables.

metrics: a generic wide-narrow time series table. Every collector (health,
performance, capacity, nfs) writes rows here through the same interface, so
the dashboard and alert engine never need to know which collector produced
a given number.

alerts: fired alert events, so the dashboard has a durable log even after
the in-memory alert engine restarts.

Schema:
    metrics(id, ts, host, volume, metric_type, uid, username, value, unit)
    alerts(id, ts, host, volume, severity, category, message, uid)
"""
from __future__ import annotations

import sqlite3
import time
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Iterable, Optional

SCHEMA = """
CREATE TABLE IF NOT EXISTS metrics (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts          REAL NOT NULL,
    host        TEXT NOT NULL,
    volume      TEXT NOT NULL,
    metric_type TEXT NOT NULL,
    uid         TEXT,
    username    TEXT,
    value       REAL NOT NULL,
    unit        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_metrics_type_ts ON metrics(metric_type, ts);
CREATE INDEX IF NOT EXISTS idx_metrics_volume_ts ON metrics(volume, ts);

CREATE TABLE IF NOT EXISTS alerts (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    ts       REAL NOT NULL,
    host     TEXT NOT NULL,
    volume   TEXT NOT NULL,
    severity TEXT NOT NULL,
    category TEXT NOT NULL,
    message  TEXT NOT NULL,
    uid      TEXT
);
CREATE INDEX IF NOT EXISTS idx_alerts_ts ON alerts(ts);
"""


@dataclass
class Metric:
    host: str
    volume: str
    metric_type: str
    value: float
    unit: str
    uid: Optional[str] = None
    username: Optional[str] = None
    ts: float = None  # filled in on write if None

    def with_ts(self) -> "Metric":
        if self.ts is None:
            self.ts = time.time()
        return self


class Store:
    def __init__(self, db_path: str):
        self.db_path = db_path
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._conn.executescript(SCHEMA)
        self._conn.commit()

    def write_metrics(self, metrics: Iterable[Metric]) -> int:
        rows = []
        for m in metrics:
            m = m.with_ts()
            rows.append((m.ts, m.host, m.volume, m.metric_type, m.uid, m.username, m.value, m.unit))
        if not rows:
            return 0
        with self._lock_and_commit():
            self._conn.executemany(
                "INSERT INTO metrics (ts, host, volume, metric_type, uid, username, value, unit) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                rows,
            )
        return len(rows)

    def write_alert(self, host: str, volume: str, severity: str, category: str,
                     message: str, uid: Optional[str] = None) -> None:
        with self._lock_and_commit():
            self._conn.execute(
                "INSERT INTO alerts (ts, host, volume, severity, category, message, uid) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (time.time(), host, volume, severity, category, message, uid),
            )

    def latest_by_type(self, metric_type: str, since_seconds: float = 3600,
                        volume: Optional[str] = None) -> list[sqlite3.Row]:
        self._conn.row_factory = sqlite3.Row
        cutoff = time.time() - since_seconds
        q = "SELECT * FROM metrics WHERE metric_type = ? AND ts >= ?"
        params: list = [metric_type, cutoff]
        if volume:
            q += " AND volume = ?"
            params.append(volume)
        q += " ORDER BY ts ASC"
        return self._conn.execute(q, params).fetchall()

    def latest_value(self, metric_type: str, volume: str, uid: Optional[str] = None) -> Optional[sqlite3.Row]:
        self._conn.row_factory = sqlite3.Row
        q = "SELECT * FROM metrics WHERE metric_type = ? AND volume = ?"
        params: list = [metric_type, volume]
        if uid is not None:
            q += " AND uid = ?"
            params.append(uid)
        q += " ORDER BY ts DESC LIMIT 1"
        return self._conn.execute(q, params).fetchone()

    def recent_alerts(self, limit: int = 50) -> list[sqlite3.Row]:
        self._conn.row_factory = sqlite3.Row
        return self._conn.execute(
            "SELECT * FROM alerts ORDER BY ts DESC LIMIT ?", (limit,)
        ).fetchall()

    def volumes(self) -> list[str]:
        rows = self._conn.execute("SELECT DISTINCT volume FROM metrics").fetchall()
        return [r[0] for r in rows]

    @contextmanager
    def _lock_and_commit(self):
        try:
            yield
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise

    def close(self):
        self._conn.close()
