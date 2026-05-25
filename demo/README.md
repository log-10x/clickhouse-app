# Demo: 60-second walkthrough

A copy-paste demo that brings up ClickHouse, loads a tiny sample of Log10x compact OpenTelemetry data, and runs expansion queries. About one minute end-to-end on a warm Docker.

## What you need

- Docker 20.x or later
- About 2 GB of disk
- A clone of this repo

## Run it

```bash
cd demo
docker compose up -d
./run.sh
```

When the script finishes, point your browser at `http://localhost:18123/play` (ClickHouse Play UI) and try:

```sql
-- Top patterns by event count
SELECT templateHash, count() AS hits
FROM tenx.events
WHERE templateHash != ''
GROUP BY templateHash
ORDER BY hits DESC
LIMIT 10;

-- Decoded events from the accounting service
SELECT decoded_log
FROM tenx.events
WHERE container = 'accounting'
LIMIT 10;

-- Storage comparison: raw vs compact
SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) AS on_disk
FROM system.parts
WHERE database = 'tenx' AND active
GROUP BY table;
```

## Tear down

```bash
docker compose down -v
```

The `-v` removes the volume so the next `up` starts from scratch.

## What's in the sample

- 200 MB of raw OpenTelemetry-demo logs (`otel-sample-200mb.log`)
- 130 MB of Log10x compact events (`encoded.log`)
- 3,473 templates (`templates.json`)

Same dataset used in the performance measurements in [../README.md](../README.md) and [../docs/architecture.md](../docs/architecture.md).

## Note on sample data files

The `sample/` directory contains symlinks to the canonical OpenTelemetry test data inside the Log10x monorepo (not checked into this repo to keep the clone small). For a public release, replace the symlinks with either:

- A smaller embedded sample (a few MB) covering the same template variety
- A download script that fetches the larger sample from a CDN

The walkthrough commands work identically against any properly-shaped `templates.json` + `encoded.log` pair produced by the Receiver in [Compact mode](https://doc.log10x.com/apps/receiver/compact/).
