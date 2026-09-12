"""
Admin dashboard: reads the same SQLite file the collector writes to.
No write access from the dashboard process -- it's read-only by design so a
compromised/buggy dashboard can never corrupt metrics.

Run with:  python3 dashboard/app.py --db ../metrics.db --port 5050
"""
from __future__ import annotations

import argparse
import os
import sys
import time

from flask import Flask, jsonify, render_template, request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from collector.store import Store  # noqa: E402

app = Flask(__name__)
STORE: Store = None  # set in main()


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/summary")
def api_summary():
    volumes = STORE.volumes()
    out = []
    for v in volumes:
        cap = STORE.latest_value("capacity.used_pct", v)
        total = STORE.latest_value("capacity.total_bytes", v)
        free = STORE.latest_value("capacity.free_bytes", v)
        smart = STORE.latest_value("health.smart_ok", v)
        writable = STORE.latest_value("health.writable", v)
        throughput = STORE.latest_value("perf.throughput_gbps", v)
        out.append({
            "volume": v,
            "used_pct": cap["value"] if cap else None,
            "total_bytes": total["value"] if total else None,
            "free_bytes": free["value"] if free else None,
            "smart_ok": bool(smart["value"]) if smart else None,
            "writable": bool(writable["value"]) if writable else None,
            "throughput_gbps": throughput["value"] if throughput else None,
            "throughput_age_sec": (time.time() - throughput["ts"]) if throughput else None,
        })
    return jsonify(out)


@app.route("/api/throughput")
def api_throughput():
    # volume names are filesystem paths (they contain "/"), so they're passed
    # as a query param rather than a URL path segment to avoid encoding pain.
    volume = request.args.get("volume", "")
    rows = STORE.latest_by_type("perf.throughput_gbps", since_seconds=3600, volume=volume)
    return jsonify([{"ts": r["ts"], "value": r["value"]} for r in rows])


@app.route("/api/capacity_history")
def api_capacity_history():
    volume = request.args.get("volume", "")
    rows = STORE.latest_by_type("capacity.used_pct", since_seconds=6 * 3600, volume=volume)
    return jsonify([{"ts": r["ts"], "value": r["value"]} for r in rows])


@app.route("/api/users")
def api_users():
    volume = request.args.get("volume", "")
    rows = STORE.latest_by_type("capacity.user_bytes", since_seconds=3600, volume=volume)
    latest_by_uid = {}
    for r in rows:
        latest_by_uid[r["uid"]] = r  # keep overwriting -> ends with latest since rows are ts ASC
    users = [{"uid": uid, "username": r["username"], "bytes": r["value"]}
              for uid, r in latest_by_uid.items()]
    users.sort(key=lambda u: u["bytes"], reverse=True)
    return jsonify(users)


@app.route("/api/alerts")
def api_alerts():
    rows = STORE.recent_alerts(limit=100)
    return jsonify([dict(r) for r in rows])


def main():
    global STORE
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default="metrics.db")
    parser.add_argument("--port", type=int, default=5050)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    STORE = Store(args.db)
    app.run(host=args.host, port=args.port, debug=False)


if __name__ == "__main__":
    main()
