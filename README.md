# tenx-for-clickhouse

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Search and visualize [10x-encoded](https://doc.log10x.com/run/transform/) events in ClickHouse with zero data loss. This Apache-licensed component decodes encoded events transparently at query time via a `tenx.events` view, so existing Grafana dashboards, alerts, and SQL queries continue to work against the compacted data without modification.

Companion to [tenx-for-splunk](https://github.com/log-10x/splunk-app) and [tenx-for-elasticsearch](https://github.com/log-10x/elasticsearch-plugin).

## How it works

The [Edge Optimizer](https://doc.log10x.com/apps/edge/optimizer/) extracts repeating template patterns from your logs and ships a compact stream of templates plus encoded events. ClickHouse holds both pieces side by side: a templates dictionary loaded into memory and an encoded events table on disk. A view stitches them back together at query time.

```
Edge Optimizer  ─┬─►  tenx.templates       (small; ~1 row per pattern)
                 │            │
                 │            ▼
                 │    tenx.templates_dict  (in-memory hashed lookup)
                 │            │
                 └─►  tenx.encoded_events  (bulk; encoded payloads)
                              │
                              ▼
                       tenx.events          ◄── SELECT * FROM tenx.events
                       (view; decodes per row)       returns full original text
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

# 3. Load your Edge Optimizer output
docker exec my-clickhouse bash -c \
    "clickhouse-client --query 'INSERT INTO tenx.templates (templateHash, template) FORMAT JSONEachRow' < /path/to/templates.json"
docker exec my-clickhouse bash -c \
    "clickhouse-client --query 'INSERT INTO tenx.encoded_events (raw) FORMAT LineAsString' < /path/to/encoded.log"
docker exec my-clickhouse clickhouse-client --query "SYSTEM RELOAD DICTIONARY tenx.templates_dict"

# 4. Query the decoded view as a normal table
docker exec my-clickhouse clickhouse-client --query \
    "SELECT container, decoded_log FROM tenx.events WHERE templateHash != '' LIMIT 10"

# 5. Verify
./tenx-for-clickhouse/scripts/health-check.sh my-clickhouse
```

For ClickHouse Cloud, replace `docker exec my-clickhouse clickhouse-client` with a `clickhouse-client --host <your-cloud-host> --secure ...` invocation. The install file and queries are unchanged.

See the full [USER-GUIDE.md](USER-GUIDE.md) for production-grade install, codec tuning, query patterns, and troubleshooting.

## Two views, your choice

The install creates two views over the same encoded data. Pick the one your downstream consumers expect.

| View | Timestamp output | Speed |
|---|---|---|
| `tenx.events` | Preserves the original format per template (e.g. `2025-10-02 01:28:24`) | Slower per query (~600 ms fixed cost from format dispatch) |
| `tenx.events_iso` | Normalises all timestamps to ISO 8601 (`2025-10-02T01:28:24.000Z`) | Fastest (full table decode in ~60 ms on the 200 MB sample) |

Both views expose identical column shape: `container`, `namespace`, `pod`, `templateHash`, `encoded_log`, `decoded_log`. Switching is a one-character query change.

## What you get on disk

Measured on a 200 MB OpenTelemetry-demo log sample (197,430 events compacted into 137,418 encoded events and 3,473 templates):

| Codec | Raw events on disk | Encoded events on disk | On-disk reduction |
|---|---|---|---|
| LZ4 (ClickHouse default) | 10.83 MiB | 6.23 MiB | 42% |
| ZSTD (level 3) | 3.37 MiB | 2.45 MiB | 27% |

Storage savings vary with codec choice because ClickHouse's own compression overlaps with the templating layer. See [docs/architecture.md](docs/architecture.md) for the full measurement methodology.

## What stays unchanged

- **Lossless decode**: every encoded event reconstructs to its original text. Compliance and forensic workflows are preserved.
- **Transparent SELECT**: `SELECT FROM tenx.events` returns full original text. Existing Grafana dashboards, alerts, BI queries work without modification.
- **No new infrastructure**: pure SQL. No control plane, no separate template service, no binary to ship, no platform-specific install path.
- **Identical on Cloud and self-hosted**: same install file, same query surface, same behavior.

## Architecture

| Splunk app component | ClickHouse equivalent |
|---|---|
| Splunk KV Store of templates | `tenx.templates` table + `tenx.templates_dict` Dictionary |
| Scheduled `consume_kv` search | `LIFETIME(MIN 60 MAX 120)` dictionary auto-refresh |
| Splunk encoded events index | `tenx.encoded_events` MergeTree table |
| `tenx-inflate` SPL macro | `tenx.events` view + `tenx_inflate` SQL UDF |
| Splunk JS search hook | Not needed — the view is the user surface |

The ClickHouse port is architecturally simpler than the Splunk app because ClickHouse exposes native primitives (Dictionary, view, SQL UDF) for every concern the Splunk app implements as a custom layer.

## Prerequisites

| Component | Required version | Notes |
|---|---|---|
| **ClickHouse** | 24.x or later (tested through 26.x) | Self-hosted, Altinity Cloud, ClickHouse Cloud — all supported with the same install |
| **[Log10x Edge Optimizer](https://doc.log10x.com/apps/edge/optimizer/)** | Latest stable | Produces the `templates.json` and `encoded.log` inputs |

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
│   ├── install.sql                   The whole product
│   └── scripts/
│       └── health-check.sh           End-to-end verification (SQL-only)
├── helm/tenx-for-clickhouse/         Kubernetes Job-pattern install chart
├── demo/                             Copy-paste 60-second walkthrough
├── docs/architecture.md              Decode flow, performance notes, design
├── tests/                            pytest suite (unit + integration)
└── .github/workflows/                CI (matrix: CH 24.8 / 25.3 / latest) + release
```

## Documentation

- [USER-GUIDE.md](USER-GUIDE.md) — complete install, codec selection, query patterns, troubleshooting
- [docs/architecture.md](docs/architecture.md) — decode flow, performance characteristics, design choices
- [demo/](demo/) — 60-second copy-paste walkthrough on the included otel sample
- [Log10x documentation](https://doc.log10x.com/) — Edge Optimizer setup and product reference

## License

This repository is licensed under the [Apache License 2.0](LICENSE).

### Important: Log10x Edge Optimizer requires a commercial license

This repository contains the ClickHouse-side decoder for Log10x-encoded events. While the decoder is open source, **using the Log10x Edge Optimizer to encode events requires a commercial license**.

| Component | License |
|---|---|
| This repository (ClickHouse decoder) | Apache 2.0 (open source) |
| Log10x Edge Optimizer | Commercial license required |

**What this means:**
- You can freely use, modify, and distribute this decoder
- The Edge Optimizer that produces encoded events requires a paid subscription
- A valid Log10x license is required to run the Edge Optimizer in production

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

See the architecture notes in [docs/architecture.md](docs/architecture.md) for context on decode-flow design choices. If you change `tenx-for-clickhouse/install.sql`, also run `helm/tenx-for-clickhouse/files/sync-from-source.sh` so the chart's bundled copy stays in sync (CI enforces this).

## Support

- Issues and feature requests: [GitHub Issues](https://github.com/log-10x/clickhouse-app/issues)
- Direct support: [support@log10x.com](mailto:support@log10x.com)
