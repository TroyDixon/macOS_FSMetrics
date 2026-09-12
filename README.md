# macOS AI File System Metrics

**TTU HackWesTex 2026 — Developer Challenge submission**

A native-tooling suite for monitoring and reporting on macOS-hosted file
systems (local APFS and shared NFS/pNFS) — the kind of storage backing local
AI infrastructure (OpenClaw, Exo, and similar) where terabytes of data sit at
rest with no admin-facing tooling built for macOS.

## What it does

| Requirement from the prompt | Where it's implemented |
|---|---|
| Filesystem + backing block storage health | `collector/health.py` (diskutil SMART status, writability, `system_profiler SPNVMeDataType` controller health) |
| I/O performance (GB/s) | `collector/performance.py` (`iostat` parsing → GB/s, transfers/sec) |
| Capacity + per-user quotas | `collector/capacity.py` (per-UID byte attribution via filesystem walk, since APFS has no native quota system) |
| Local (APFS) + shared (NFS/pNFS) volumes | `collector/health.py` + `collector/nfs_shared.py` (mount health, pNFS detection, client retransmits/timeouts) |
| Admin-facing display | `dashboard/` — Flask + Chart.js, auto-refreshing |
| Alerting on nefarious users / capacity | `collector/alerts.py` — capacity thresholds + per-user growth-rate rule |
| "Other interesting metrics" | Largest files/dirs per volume, NFS client timeout/retransmit counts, throughput staleness detection |

## Architecture

```
 ┌──────────────┐   poll every N sec    ┌───────────────┐
 │ health.py    │ ─────────────────────▶│               │
 │ performance.py│ ─────────────────────▶│  SQLite store │◀── read-only ──┐
 │ capacity.py  │ ─────────────────────▶│  (metrics.db) │                │
 │ nfs_shared.py│ ─────────────────────▶│               │                │
 └──────────────┘                       └───────┬───────┘                │
        ▲                                        │                       │
        │                                alerts.py evaluates      dashboard/app.py
 collector/daemon.py                    thresholds + growth        (Flask API)
   (the scheduler)                       rate, writes alerts               │
                                                                             ▼
                                                                    templates/index.html
                                                                    (Chart.js, auto-refresh)
```

Every collector writes into **one normalized table** —
`metrics(ts, host, volume, metric_type, uid, username, value, unit)` — so the
dashboard and alert engine never need to know which collector produced a
given number. This is the contract that let us build the four collectors,
the store, the alert engine, and the dashboard independently. See
`collector/store.py` for the schema.

## Why this data model (APFS quotas)

APFS has no native per-user quota system the way ZFS or HFS+ (with
`quotacheck`) does. So "per-user quotas" here means: we attribute bytes to
the owning UID ourselves via a filesystem walk (`os.stat().st_uid`), store
that as a time series, and enforce **soft, admin-configured thresholds** in
the alert engine rather than relying on kernel enforcement. This is also
exactly the same approach macOS's own `du`/Finder "Get Info" size
calculations use under the hood — just aggregated by owner instead of by
directory.

## Build & run

Requires Python 3.10+ (ships with macOS, or `brew install python@3.12`).

```bash
git clone <this-repo>
cd macos-fs-metrics

# One-command demo (works on ANY OS — uses simulate:true in config.yaml,
# no real macOS volumes required):
make demo
# -> seeds ~6 collection cycles, then opens the dashboard at
#    http://127.0.0.1:5050
```

For real collection on macOS hardware:

```bash
# 1. Edit config.yaml:
#      - set simulate: false
#      - list the actual volumes/mounts you want monitored
#
# 2. Run the collector (needs to keep running — a separate terminal,
#    tmux pane, or a launchd job):
make run-collector

# 3. In another terminal, run the dashboard:
make run-dashboard
```

Run the test suite (pure-logic parsing tests run on any OS against recorded
macOS command-output fixtures in `tests/fixtures/`; the per-user capacity
scanner is tested against a real temp filesystem tree):

```bash
make test
```

### Manual (no Makefile) equivalent

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m unittest discover -s tests -v
python -m collector.daemon --config config.yaml --once   # one poll cycle
python dashboard/app.py --db metrics.db --port 5050
```

## Configuration

All behavior is driven by `config.yaml`: which volumes to watch, poll
intervals, and alert thresholds (capacity warn/critical %, per-user growth
rate, throughput-stall window). See the comments in that file — it's meant
to be read, not just edited blind.

## Data sources used (macOS-native, no third-party agents)

- `diskutil info -plist <volume>` — SMART status, capacity, writability, filesystem type, encryption state
- `diskutil apfs list -plist` — container/volume topology (extension point, see Future Work)
- `system_profiler SPNVMeDataType -json` — internal Apple Silicon NVMe controller health
- `iostat -d -c 2 <disk>` — live I/O throughput (KB/transfer, transfers/sec, MB/s → GB/s)
- `fs_usage -f filesys` — optional deeper per-process I/O sampling (root required; wired up but off by default due to noise/permissions)
- `nfsstat -m` — per-mount NFS/pNFS configuration and pNFS-layout detection
- `nfsstat -c` — client-side RPC counters (timeouts, retransmits) as an NFS health proxy
- `os.stat().st_uid` over configured scan paths — per-user capacity attribution (POSIX, not Darwin-specific — this is the one collector that's also fully testable on Linux/CI)

## Alerting logic ("nefarious users" + capacity)

`collector/alerts.py` runs after every poll cycle:

1. **Capacity thresholds** — warn at 80% used, critical at 95% (configurable).
2. **Per-user growth-rate rule** — if any user's attributed bytes grow by
   more than a configured amount (default 5 GB) within a configured window
   (default 10 minutes), fire a warning naming that user. This is
   deliberately framed as *rate of change*, not just *total size*, since a
   researcher legitimately storing 4 TB of data is normal, but anyone
   suddenly writing tens of GB in a few minutes — malicious or a runaway
   training/checkpoint job — is worth a human look.
3. **Health rules** — SMART not-OK, volume not writable, NFS mount down.
4. **Throughput-stall detection** — no I/O samples inside a configured
   window usually means the collector or the underlying mount is stuck.

Alerts are written to a durable `alerts` table (so the dashboard survives
restarts) and optionally POSTed to a Slack-compatible webhook.

## Repository layout

```
collector/
  config.py       # YAML config loading
  store.py        # SQLite schema + read/write interface (the shared contract)
  health.py       # filesystem + block storage health
  performance.py  # I/O throughput (GB/s)
  capacity.py     # capacity + per-user usage scan
  nfs_shared.py   # NFS/pNFS mount health + config
  alerts.py       # threshold + growth-rate alert engine
  daemon.py       # the scheduler that ties collectors together
dashboard/
  app.py                 # Flask read-only API + page server
  templates/index.html   # Chart.js admin dashboard
tests/
  fixtures/        # recorded macOS command output used by parser tests
  test_*.py        # unit + integration tests (16 tests, all passing)
config.yaml        # example config (simulate mode on by default)
Makefile           # venv/install/test/run/demo targets
docs/FUTURE_WORK.md
```

## Team task split

This repo was built around three independently-testable tracks that share
one contract (the `metrics` table schema in `collector/store.py`):

- **Health & performance** (`health.py`, `performance.py`) — SMART/block
  health + GB/s throughput.
- **Capacity, quotas & shared volumes** (`capacity.py`, `nfs_shared.py`) —
  per-user usage attribution + NFS/pNFS support.
- **Store, dashboard & alerting** (`store.py`, `alerts.py`, `dashboard/`) —
  the data contract, the admin UI, and the reporting/alerting layer.

`daemon.py` is the thin integration point that only had to be touched once
everyone's collectors existed.

## Future work

See `docs/FUTURE_WORK.md` for a fuller writeup. Highlights:
- Real kernel-enforced per-user quotas via a custom `launchd` agent + APFS role accounts
- Deeper pNFS layout-type stats (macOS's client doesn't expose these to userland today)
- SMART/NVMe wear-leveling trend lines instead of a point-in-time pass/fail
- A native SwiftUI menu-bar client instead of (or alongside) the web dashboard
- Historical rollups/retention policy for the SQLite store (currently unbounded)
