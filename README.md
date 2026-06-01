# tenx-for-clickhouse

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Lossless [compact](https://doc.log10x.com/run/transform/#compact) log decoding for ClickHouse. Reduces ClickHouse ingest CPU 25-30% and edge-to-cluster bandwidth 35%, with roughly 70-78% on-disk reduction on a typical structured-log workload under ZSTD column compression (codec-dependent; LZ4 narrower). Drops in as a single SQL file. Existing Grafana dashboards, alerts, and SQL queries keep working against the compact data without modification, via a `tenx.events` view.

Companion to [tenx-for-splunk](https://github.com/log-10x/splunk-app) and [tenx-for-elasticsearch](https://github.com/log-10x/elasticsearch-plugin). Apache 2.0.

## How it works

The [Receiver](https://doc.log10x.com/apps/receiver/) running in [Compact mode](https://doc.log10x.com/apps/receiver/compact/) extracts repeating template patterns from your logs and ships a compact stream of templates plus compact events. ClickHouse holds both pieces side by side: a templates dictionary loaded into memory and an compact events table on disk. A view stitches them back together at query time.

```
Receiver  ─┬─►  tenx.templates        (small; ~1 row per pattern)
           │            │
           │            ▼
           │     tenx.templates_dict   (in-memory hashed lookup)
           │            │
           └─►  tenx.encoded_events    (bulk; encoded payloads)
                        │
                        ▼
                 tenx.events           ◄── SELECT * FROM tenx.events
                 (view; expands per row)    returns full original text
```

## One product, one install

Pure SQL. No binary, no compilation, no platform-specific install. Works on self-hosted ClickHouse, Altinity Cloud, and ClickHouse Cloud — identically.

```bash
clickhouse-client --multiquery < tenx-for-clickhouse/install.sql
```

That's the install. Three CREATE statements for tables and dictionary, six CREATE FUNCTION statements for the decoder, two CREATE VIEW statements for the user-facing query surface. Nothing else.

## Quickstart

```bash
# 1. Start a ClickHouse server (any 24.x+ supported; skip if you already have one)
docker run -d --name my-clickhouse \
  -p 8123:8123 -p 9000:9000 \
  clickhouse/clickhouse-server:latest

# 2. Apply the schema
docker exec -i my-clickhouse clickhouse-client --multiquery \
    < tenx-for-clickhouse/install.sql

# 3. Load your Receiver output
docker exec my-clickhouse bash -c \
    "clickhouse-client --query 'INSERT INTO tenx.templates (templateHash, template) FORMAT JSONEachRow' < /path/to/templates.json"
docker exec my-clickhouse bash -c \
    "clickhouse-client --query 'INSERT INTO tenx.encoded_events (raw) FORMAT LineAsString' < /path/to/encoded.log"
docker exec my-clickhouse clickhouse-client --query "SYSTEM RELOAD DICTIONARY tenx.templates_dict"

# 4. Query the expansion view as a normal table
docker exec my-clickhouse clickhouse-client --query \
    "SELECT container, decoded_log FROM tenx.events WHERE templateHash != '' LIMIT 10"

# 5. Verify
./tenx-for-clickhouse/scripts/health-check.sh my-clickhouse
```

For ClickHouse Cloud, replace `docker exec my-clickhouse clickhouse-client` with a `clickhouse-client --host <your-cloud-host> --secure ...` invocation. The install file and queries are unchanged.

See the full [USER-GUIDE.md](USER-GUIDE.md) for production-grade install, codec tuning, query patterns, and troubleshooting.

## Two views, default is fast

The install creates two views over the same compact data.

| View | Timestamp output | Speed | When to use |
|---|---|---|---|
| `tenx.events` | ISO 8601 (`2025-10-02T01:28:24.000Z`) | Native CH scan (~60 ms full-table) | **Default.** New dashboards, BI tools, anything that accepts ISO 8601 |
| `tenx.events_native` | Preserves the original format per template (e.g. `2025-10-02 01:28:24`) | ~600 ms fixed cost from multiIf dispatch | Regex matchers that depend on a specific format, compliance log-format preservation |

Both views expose identical column shape: `container`, `namespace`, `pod`, `templateHash`, `encoded_log`, `decoded_log`. Switching is a one-identifier query change.

## What you get on disk

Measured on a 200 MB OpenTelemetry-demo log sample (197,430 events compacted into 137,418 compact events and 3,473 templates):

| Codec | Raw events on disk | Encoded events on disk | On-disk reduction |
|---|---|---|---|
| LZ4 (ClickHouse default) | 10.83 MiB | 6.23 MiB | 42% |
| ZSTD (level 3) | 3.37 MiB | 2.45 MiB | 27% |

Storage savings vary with codec choice because ClickHouse's own compression overlaps with the templating layer. See [docs/architecture.md](docs/architecture.md) for the full measurement methodology.

INNER reduction against raw bodies also varies with log body size. Measured under ZSTD column compression on force-merged single-segment indices:

| Log body size | INNER vs raw (ZSTD) |
|---|---|
| Tiny (~60 B body) | ~7% |
| Typical (~225 B body) | ~74% |
| Large (~1.1 KB body) | ~79% |

The 200MB-sample numbers and the body-size numbers measure different baselines (the 200MB sample groups across many templates; the body-size table is per-event INNER-vs-raw on force-merged single-segment indices). Real customer pre-encoding text can differ by about 10 percentage points on the absolute figures, since the measurement used synthesized bodies at roughly 2.5x inner-body length. The plugin requires INNER encode mode; OUTER encode is not supported on ClickHouse because the materialized envelope columns and primary key depend on parseable JSON. See [Receiver-side configuration](USER-GUIDE.md#receiver-side-configuration) in the user guide.

## What stays unchanged

- **Lossless expansion**: every compact event expands back to its original text. Compliance and forensic workflows are preserved.
- **Existing dashboards keep working**: the [transparent install path](USER-GUIDE.md#transparent-install-keep-existing-dashboards) creates a view at your existing logs-table name. Dashboards, alerts, and BI queries continue to query the same table and get back expanded text — no rewrites. Works on self-hosted CH, Altinity, ClickHouse Cloud, and **Groundcover BYOC** (where you have admin access to the underlying CH cluster).
- **No new infrastructure**: pure SQL. No control plane, no separate template service, no binary to ship, no platform-specific install path.
- **Identical on Cloud and self-hosted**: same install file, same query surface, same behavior.

## Architecture

| Splunk app component | ClickHouse equivalent |
|---|---|
| Splunk KV Store of templates | `tenx.templates` table + `tenx.templates_dict` Dictionary |
| Scheduled `consume_kv` search | `LIFETIME(MIN 60 MAX 120)` dictionary auto-refresh |
| Splunk compact events index | `tenx.encoded_events` MergeTree table |
| `tenx-inflate` SPL macro | `tenx.events` view + `tenx_inflate` SQL UDF |
| Splunk JS search hook | Not needed — the view is the user surface |

The ClickHouse port is architecturally simpler than the Splunk app because ClickHouse exposes native primitives (Dictionary, view, SQL UDF) for every concern the Splunk app implements as a custom layer.

## Prerequisites

| Component | Required version | Notes |
|---|---|---|
| **ClickHouse** | 24.x or later (tested through 26.x) | Self-hosted, Altinity Cloud, ClickHouse Cloud — all supported with the same install |
| **[Log10x Receiver](https://doc.log10x.com/apps/receiver/) (Compact mode)** | Latest stable | Produces the `templates.json` and `encoded.log` inputs |

## Compatibility

| Surface | Status |
|---|---|
| ClickHouse self-hosted | Supported |
| ClickHouse Cloud | Supported (same install) |
| Altinity Cloud | Supported (same install) |
| ClickHouse on Kubernetes (via Helm) | Supported — starter chart in [helm/tenx-for-clickhouse/](helm/tenx-for-clickhouse/) |

CI tests the install against ClickHouse 24.8 (LTS), 25.3, and latest on every PR.

## Repo layout

```
clickhouse-app/
├── LICENSE                           Apache 2.0
├── NOTICE                            Copyright notice
├── SECURITY.md                       Vulnerability reporting policy
├── README.md                         This file
├── CHANGELOG.md                      Version history
├── USER-GUIDE.md                     Full install + codec + troubleshooting
├── pytest.ini                        Test runner config
├── tenx-for-clickhouse/
│   ├── install.sql                          Standard install (tenx.* namespace)
│   ├── transparent-install.template.sql     Brownfield install: keep existing table name + dashboards
│   └── scripts/
│       ├── health-check.sh                  End-to-end verification (SQL-only)
│       └── generate-transparent-install.sh  Generates brownfield install from your schema
├── helm/tenx-for-clickhouse/         Kubernetes Job-pattern install chart
├── grafana/tenx-for-clickhouse-app/  Grafana app plugin (pattern explorer + dashboards)
├── demo/                             Copy-paste 60-second walkthrough
├── docs/architecture.md              Decode flow, performance notes, design
├── tests/                            pytest suite (unit + integration)
└── .github/workflows/                CI (matrix: CH 24.8 / 25.3 / latest) + release
```

## Documentation

- [USER-GUIDE.md](USER-GUIDE.md) — complete install, codec selection, query patterns, troubleshooting
- [docs/architecture.md](docs/architecture.md) — expansion flow, performance characteristics, design choices
- [demo/](demo/) — 60-second copy-paste walkthrough on the included otel sample
- [Log10x documentation](https://doc.log10x.com/) — Receiver (Compact mode) setup and product reference

## License

This repository is licensed under the [Apache License 2.0](LICENSE).

### Important: Log10x Receiver requires a commercial license

This repository contains the ClickHouse-side decoder for Log10x compact events. While the decoder is open source, **using the Log10x Receiver to compact events requires a commercial license**.

| Component | License |
|---|---|
| This repository (ClickHouse decoder) | Apache 2.0 (open source) |
| Log10x Receiver | Commercial license required |

**What this means:**
- You can freely use, modify, and distribute this decoder
- The Receiver that produces compact events requires a paid subscription
- A valid Log10x license is required to run the Receiver in production

**Get started:**
- [Log10x pricing](https://log10x.com/pricing)
- [Documentation](https://doc.log10x.com)
- [Contact sales](mailto:sales@log10x.com)

## Contributing

Contributions are welcome. Run the test suite locally before opening a PR:

```bash
# Start a ClickHouse for testing
docker run -d --name ch-test -p 18123:8123 -p 19000:9000 \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
  clickhouse/clickhouse-server:latest

# Install test deps + run pytest
python3 -m venv .venv
source .venv/bin/activate
pip install -r tests/requirements-test.txt
CH_HOST=localhost CH_PORT=18123 pytest -v
```

See the architecture notes in [docs/architecture.md](docs/architecture.md) for context on expansion-flow design choices. If you change `tenx-for-clickhouse/install.sql`, also run `helm/tenx-for-clickhouse/files/sync-from-source.sh` so the chart's bundled copy stays in sync (CI enforces this).

## Support

- Issues and feature requests: [GitHub Issues](https://github.com/log-10x/clickhouse-app/issues)
- Direct support: [support@log10x.com](mailto:support@log10x.com)
