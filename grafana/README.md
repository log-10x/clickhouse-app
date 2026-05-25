# grafana/

Grafana-side tooling for `tenx-for-clickhouse`.

| Package | Description |
|---|---|
| [`tenx-for-clickhouse-app/`](tenx-for-clickhouse-app/) | Grafana app plugin: pattern explorer page + bundled dashboards |

The plugin is **optional**. The decoder is fully usable without it — Grafana speaks ClickHouse directly via the standard data source, and `tenx.events` looks like any other table. The plugin adds the pattern-aware experience layer described in the architecture conversation: see your log volume by template, click to filter, open the pre-built cost-attribution dashboard.

Plugin install + dev: see [tenx-for-clickhouse-app/README.md](tenx-for-clickhouse-app/README.md).
