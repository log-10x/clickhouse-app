# 10x for ClickHouse — Grafana app plugin

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

A Grafana app plugin that adds a **Pattern Explorer** and **pre-built dashboards** on top of the [tenx-for-clickhouse](../../README.md) decoder. Surfaces compact log volume by template, ranks templates by estimated cost, and lets users filter dashboard queries by `templateHash` in one click.

Companion to the SQL decoder. Both are MIT.

## What it shows

- **Pattern Explorer page** — top-N templates by estimated cost (event count × compact payload size) in the selected time range, with optional container/namespace filters and a one-click "copy templateHash filter" button.
- **Template cost attribution dashboard** — pre-built dashboard showing templates known, compact events in range, distinct templates, top-25 templates by bytes, event volume by container, and top-5 templates over time.

## Prerequisites

| Requirement | Notes |
|---|---|
| Grafana 10.4+ | App plugins use the AppRootProps / AppPlugin API |
| ClickHouse data source | Either [Grafana's official ClickHouse data source](https://grafana.com/grafana/plugins/grafana-clickhouse-datasource/) or [Altinity's clickhouse-grafana](https://grafana.com/grafana/plugins/vertamedia-clickhouse-datasource/) |
| `tenx-for-clickhouse` schema applied | The [decoder install.sql](../../tenx-for-clickhouse/install.sql) must have run against the database this plugin queries |

This plugin does **not** install a data source. It queries the customer's existing one. No new connection setup, no credential management.

## Install

### Development (unsigned, local Grafana)

```bash
# From this directory
npm install
npm run build

# Symlink into Grafana's plugins directory
ln -s "$(pwd)/dist" /var/lib/grafana/plugins/log10x-tenx-app

# Allow unsigned plugins for local dev
echo 'allow_loading_unsigned_plugins = log10x-tenx-app' >> /etc/grafana/grafana.ini

# Restart Grafana
systemctl restart grafana-server
```

Then in Grafana:
1. **Configuration → Plugins → 10x for ClickHouse → Enable**
2. Open the **Configuration** page and enter the UID of your ClickHouse data source
3. Open the **Pattern Explorer** page from the left nav
4. Optional: import the bundled dashboard from **Dashboards → New → Import** → upload `src/dashboards/template-cost.json`

### Production (signed)

Plugin signing via Grafana's plugin signing process is on the roadmap. Until then, install with `allow_loading_unsigned_plugins`.

## Configuration

| Setting | Description |
|---|---|
| `clickhouseDataSourceUid` | UID of the ClickHouse data source the app should query |
| `database` | Database name where the `tenx.*` tables live (default: `tenx`) |

Stored in Grafana's plugin settings, not in `.ini` files.

## How it works

The Pattern Explorer page queries the customer's ClickHouse data source via Grafana's backend proxy (`/api/datasources/proxy/uid/<dsUid>/`), running SQL directly against `tenx.encoded_events` and joining with `tenx.templates`. No new server, no agent, no separate service. Everything runs inside Grafana's existing data path.

The query pattern is:

```sql
SELECT e.templateHash, t.template, count() AS events, sum(length(e.raw)) AS bytes, any(e.container) AS sampleContainer
FROM tenx.encoded_events AS e
LEFT JOIN tenx.templates AS t USING (templateHash)
WHERE <time range> AND e.templateHash != ''
GROUP BY e.templateHash, t.template
ORDER BY bytes DESC
LIMIT 25
```

This hits the materialized columns on `encoded_events` (indexed, sub-50ms even on millions of rows) and joins the template text from the in-memory dictionary at the end.

## Roadmap

- **v0.2**: Click-to-add-filter directly to current dashboard variables (eliminates the copy-paste step)
- **v0.3**: Query rewriter — intercepts `LIKE '%text%'` queries in dashboard panels and rewrites to `templateHash IN (...)` for matching patterns. Hybrid: safe-rewrite when the literal can only appear in template literals[]; raw-scan fall-back otherwise.
- **v0.4**: Anomaly detection on template volume (alert when a previously-quiet template spikes >5x within an hour)
- **v0.5**: Cross-link from pattern explorer to the upstream Log10x Receiver dashboard for end-to-end attribution

## License

MIT. Same license as the [tenx-for-clickhouse](../../README.md) decoder.

The Log10x Receiver (the upstream component that produces the compact events this plugin reads) is a separate, commercially-licensed product. See [log10x.com](https://www.log10x.com/?utm_source=github&utm_medium=readme&utm_campaign=clickhouse-app&utm_content=inline) for pricing.

## Support

- Issues: [GitHub Issues on clickhouse-app](https://github.com/log-10x/clickhouse-app/issues)
- Direct: [support@log10x.com](mailto:support@log10x.com)
