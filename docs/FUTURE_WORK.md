# Future Work

The app is a working v1: a menu-bar app that collects health, performance,
capacity, and per-user metrics into a local SQLite file and draws the
dashboard. These are the directions worth taking next, roughly in order.

## Fleet-scale deployment
Today one collector writes to one SQLite file on one Mac. To manage a rack
of Mac Studios/Minis:
- Push samples to a shared store (Postgres/TimescaleDB) so one dashboard can
  show every host, or expose a small HTTP endpoint per host that the
  dashboard polls.
- Ship a Developer ID-signed, notarized build with a real installer, instead
  of the ad-hoc signed bundle plus LaunchAgent workaround.

## Local model and OpenClaw workloads
Most of the machines this targets run local models (Ollama, LM Studio,
Hugging Face caches) and OpenClaw instances. Today we just watch whatever
paths the config lists.
- Recognize common model directories as first-class paths, so hundreds of GB
  of weights don't read as user growth.
- Treat OpenClaw workspace and session-log writes as a known workload, with
  thresholds tuned to catch a runaway agent without firing on routine model
  downloads.
- Attribute throughput to the process doing it (see below), so alerts can say
  "ollama wrote 40 GB this hour" instead of "a user did."

## Retention and rollups
The `metric` table grows forever. Add a job that downsamples old samples into
hourly/daily min/max/avg, keeping raw resolution only for a recent window,
like RRDtool or Prometheus retention.

## Per-process I/O attribution
We aggregate by volume and user today. `fs_usage` can attribute writes to a
specific process, but it needs root (Endpoint Security needs an Apple
entitlement), so this would come with a small privileged helper.

IOKit integration, remodel

## Trend-based health
`health.smart_ok` is a snapshot. Tracking NVMe wear-leveling and
percentage-used-reserve over time would let us warn on trend before SMART
actually flips to failing.
