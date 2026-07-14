# tenx-for-clickhouse User Guide

This guide covers the full workflow for using tenx-for-clickhouse to search Log10x compact data in ClickHouse.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Loading data](#loading-data)
4. [Querying](#querying)
5. [Choosing between the two views](#choosing-between-the-two-views)
6. [Codec selection](#codec-selection)
7. [Performance characteristics](#performance-characteristics)
8. [Operating the templates dictionary](#operating-the-templates-dictionary)
9. [Configuration reference](#configuration-reference)
10. [Troubleshooting](#troubleshooting)
11. [Upgrading](#upgrading)

---

## Prerequisites

- **ClickHouse 24.x or later** (tested through 26.x; self-hosted, Altinity Cloud, and ClickHouse Cloud all work identically)
- **[Log10x Receiver](https://doc.log10x.com/apps/receiver/)** producing two files:
  - `templates.json` — one JSON object per line: `{"templateHash":"<hash>","template":"<pattern>"}`
  - `encoded.log` — one compact event per line, format: `{...envelope...,"log":"~<hash>[,<v1>,<v2>,...]",...}`

That's the entire dependency list. No Rust toolchain, no Python, no binary to install, no platform-specific anything.

## Installation

One file, one command, one install path for every ClickHouse deployment.

### Self-hosted (Docker)

```bash
docker exec -i my-clickhouse clickhouse-client --multiquery \
    < tenx-for-clickhouse/install.sql
```

### Self-hosted (direct)

```bash
clickhouse-client --multiquery < tenx-for-clickhouse/install.sql
```

### ClickHouse Cloud

Open the Cloud Console SQL editor and paste the contents of `tenx-for-clickhouse/install.sql`, then execute. Or via a local client:

```bash
clickhouse-client --host <your-cloud-host>.clickhouse.cloud \
                  --port 9440 --secure \
                  --user <your-user> --password <your-password> \
                  --multiquery < tenx-for-clickhouse/install.sql
```

### Kubernetes (Helm)

A starter Helm chart is included at `helm/tenx-for-clickhouse/`. It applies `install.sql` to an existing ClickHouse service via a one-shot Job (the chart does not install ClickHouse itself).

```bash
helm install my-tenx ./helm/tenx-for-clickhouse \
  --set clickhouse.host=my-clickhouse.namespace.svc.cluster.local \
  --set clickhouse.user=default \
  --set clickhouse.password=...
```

For production, use a Kubernetes Secret for credentials. See [helm/tenx-for-clickhouse/README.md](helm/tenx-for-clickhouse/README.md) for full values reference.

### What the install creates

- Database `tenx`
- Table `tenx.templates` (templates source, with `literals[]` and `slots[]` materialized at INSERT time)
- Dictionary `tenx.templates_dict` (in-memory hashed lookup, auto-refreshes every 60-120 seconds)
- Table `tenx.encoded_events` (compact events with materialized columns for filter pushdown)
- Six SQL functions composing the expansion path
- Two views: `tenx.events` (preserves original timestamp format) and `tenx.events_native` (faster, ISO 8601 timestamps)

### Verify the install

```bash
./tenx-for-clickhouse/scripts/health-check.sh my-clickhouse
```

Or against any remote ClickHouse:

```bash
CLICKHOUSE_CLIENT="clickhouse-client --host my.cloud --secure --user me --password ..." \
    ./tenx-for-clickhouse/scripts/health-check.sh
```

You should see four `PASS` lines. If any fail, see [Troubleshooting](#troubleshooting).

## Loading data

Standard ClickHouse INSERT.

### Loading templates

```bash
clickhouse-client --query "INSERT INTO tenx.templates (templateHash, template) FORMAT JSONEachRow" \
    < templates.json
```

After loading, refresh the dictionary so query-time lookups pick up the new templates:

```bash
clickhouse-client --query "SYSTEM RELOAD DICTIONARY tenx.templates_dict"
```

By default the dictionary auto-refreshes every 60-120 seconds (controlled by `LIFETIME(MIN 60 MAX 120)` in the schema). For high-throughput workloads where templates are continuously added, tighten this to `LIFETIME(MIN 5 MAX 15)`.

### Loading compact events

```bash
clickhouse-client --query "INSERT INTO tenx.encoded_events (raw) FORMAT LineAsString" \
    < encoded.log
```

The materialized columns on `encoded_events` (`log`, `templateHash`, `container`, `namespace`, `pod`) are computed at INSERT time and are available for fast filter pushdown.

### Streaming ingest

For continuous ingest from a log shipper (fluent-bit, vector, otel-collector), point the shipper at the ClickHouse HTTP endpoint:

```
http://<your-clickhouse>:8123/?query=INSERT%20INTO%20tenx.encoded_events%20(raw)%20FORMAT%20LineAsString
```

The body is the raw NDJSON / line-delimited compact events.

## Querying

### Basic query

```sql
SELECT container, decoded_log
FROM tenx.events
WHERE templateHash != ''
LIMIT 10;
```

`decoded_log` returns the full original log text reconstructed from the template plus encoded values.

### Filtering for speed

ClickHouse cannot push filters down through the expansion functions, so filter on **the cheap pre-materialized columns first** to avoid expanding events you don't need:

```sql
-- FAST: filter pushes down on indexed columns
SELECT decoded_log FROM tenx.events
WHERE container = 'accounting'
  AND templateHash = '-L3!]kPjVal'
LIMIT 100;

-- SLOW: filter has to expand every event first
SELECT decoded_log FROM tenx.events
WHERE decoded_log LIKE '%error%'
LIMIT 100;
```

For full-text search across expanded logs, consider a downstream pipeline that materializes searchable text into a separate index, or use the [Log10x Search MCP](https://github.com/log-10x/log10x-mcp) for pattern-aware queries.

### Aggregating on cheap columns

Aggregations over the pre-extracted columns are native ClickHouse speed (no expansion triggered):

```sql
SELECT container, count() AS hits
FROM tenx.events
GROUP BY container
ORDER BY hits DESC
LIMIT 10;

SELECT templateHash, count() AS occurrences
FROM tenx.events
WHERE templateHash != ''
GROUP BY templateHash
ORDER BY occurrences DESC
LIMIT 20;
```

## Choosing between the two views

The install creates two views over the same compact data. They differ only in timestamp output.

| View | Timestamp output | Performance |
|---|---|---|
| `tenx.events` (default) | Normalizes to ISO 8601 (`2025-10-02T01:28:24.000Z`) regardless of template | Fastest: 11 ms for 100 rows, 0.6 s for the full 137,418-row sample |
| `tenx.events_native` | Preserves the original format per template (e.g. `2025-10-02 01:28:24`) | The multiIf format dispatch adds roughly 20 ms on small result sets and 90 ms over the full table |

Switching is one identifier change in your query. Same columns, same shape.

**Use `tenx.events` when:**
- Your downstream tooling parses ISO 8601 (most Grafana time pickers, most BI tools, most application code)
- Query latency matters
- You don't have regex matchers that depend on a specific timestamp format

**Use `tenx.events_native` when:**
- You have alerts or regex matchers that look for a specific date format string
- Compliance requires that log format be preserved end-to-end
- Your templates use `$(+%s)` or `$(epoch)` slots and you want the raw epoch value untouched (both views pass those through since 0.2.1)

If you can't decide, start with `tenx.events`. It's the default, it's faster, and most consumers prefer ISO.

## Codec selection

ClickHouse's column compression codec (LZ4 default, ZSTD optional) interacts with the templating layer. Both work, but on-disk savings differ.

Measured on a 200 MB OpenTelemetry-demo sample:

| Codec | Raw events on disk | Encoded events on disk | Templating-only savings (per row) |
|---|---|---|---|
| LZ4 | 10.83 MiB | 6.23 MiB | ~17% |
| ZSTD (level 3) | 3.37 MiB | 2.45 MiB | ~0% (slightly worse per row) |

Total reduction including the row count drop from grouping: **42% on LZ4, 27% on ZSTD**.

**Why the difference**: ZSTD's pattern detection overlaps significantly with the templating layer. After templating, less structural redundancy remains for ZSTD to find. LZ4 is weaker, so templating contributes more incremental savings.

To configure codec on a column:

```sql
CREATE TABLE tenx.encoded_events
(
    raw String CODEC(ZSTD(3))  -- or CODEC(LZ4), or leave default (LZ4)
)
ENGINE = MergeTree() ORDER BY ...;
```

Storage savings are one of several cost components. The codec choice does not affect:
- Edge-to-ClickHouse network transport savings (~35%)
- Ingest + background merge CPU savings (~25-35%)
- Query-time speed when filtering on `templateHash`

## Performance characteristics

Measured on the 200 MB sample (197,430 raw events → 137,418 compact events + 3,473 templates):

Measured on ClickHouse 26.5.1 at server defaults (no `max_memory_usage` override), median of 5 runs, every workload materializing `decoded_log`:

| Workload | `tenx.events` (ISO 8601, default) | `tenx.events_native` (multiIf) |
|---|---|---|
| Baseline scan, no expansion | 10 ms | 10 ms |
| Decode 100 rows | 11 ms | 29 ms |
| Decode 10,000 rows | 30 ms | 61 ms |
| Filter pushdown then expand (274 rows) | 14 ms | 31 ms |
| Decode full table (137,418 rows) | **0.6 s**, 41 MiB peak | **0.7 s**, 78 MiB peak |

Full-table wall time varies about 0.55-0.79 s run to run; the memory figures are stable.

Both views stay inside ClickHouse's vectorized execution engine. The multiIf variant adds a format-dispatch cost — around 20 ms on small result sets, 90 ms over the full table — and preserves original timestamp formats in exchange.

> Releases before 0.2.1 could not decode the full table at all: the inflate functions were O(N^2) in the slot count and died with `MEMORY_LIMIT_EXCEEDED` at 7.2 GiB. If a full-table decode runs out of memory, apply `tenx-for-clickhouse/upgrade-hotfix.sql`.

For interactive observability queries that filter on cheap columns (`container`, `templateHash`, `namespace`, time range) before expanding, both views complete in sub-second time on typical result sets.

## Operating the templates dictionary

### Refresh cadence

The dictionary auto-refreshes from the source table on the `LIFETIME(MIN 60 MAX 120)` schedule. ClickHouse picks a random refresh time in that window to avoid thundering herd across replicas.

Force an immediate refresh:

```sql
SYSTEM RELOAD DICTIONARY tenx.templates_dict;
```

Check refresh status:

```sql
SELECT name, status, element_count, last_successful_update_time
FROM system.dictionaries
WHERE name = 'templates_dict';
```

### Capacity

The dictionary lives in memory. Each template is roughly:
- 10-15 bytes for the hash
- 100-500 bytes for the template text
- Two arrays (literals + slots) computed from the template
- Constant overhead per entry (~200 bytes)

For 100,000 unique templates, expect ~100 MB of memory. Most observability workloads have a few thousand templates, so this is small.

If templates grow into the millions, consider switching the dictionary `LAYOUT` from `COMPLEX_KEY_HASHED` to `COMPLEX_KEY_SSD_CACHE` (disk-backed, much larger capacity, slower lookups).

### Backup and recovery

**The templates table is critical infrastructure.** Compact events cannot be expanded without it. Treat it like an authentication database:

- Back it up at least daily
- Replicate it across availability zones
- Test restore procedures
- Monitor `system.dictionaries` for status changes

Recommended schema for the templates table on a replicated cluster:

```sql
CREATE TABLE tenx.templates ON CLUSTER '{cluster}'
(
    templateHash String,
    template     String,
    literals     Array(String) MATERIALIZED splitByRegexp('\\$\\([^)]*\\)|\\$', template),
    slots        Array(String) MATERIALIZED extractAll(template, '\\$\\([^)]*\\)|\\$')
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/templates', '{replica}')
ORDER BY templateHash;
```

## Configuration reference

| Setting | Default | Where to change | Effect |
|---|---|---|---|
| Dictionary refresh window | `LIFETIME(MIN 60 MAX 120)` | `install.sql` | How quickly new templates become queryable |
| Encoded events `ORDER BY` | `(container, templateHash)` | `install.sql` | Filter pushdown speed |
| Encoded events codec | LZ4 (ClickHouse default) | `CODEC(...)` clause on column | On-disk size vs query CPU trade |
| View choice (multiIf vs ISO) | both views created | Query the view you want | Format fidelity vs query speed |

To extend the multiIf view with a new timestamp format pattern, add a branch to the `tenx_substitute_slot` function in `install.sql` following the pattern of the existing 17 branches, and re-apply the install (the `CREATE OR REPLACE FUNCTION` is idempotent).

## Troubleshooting

### "Function 'tenx_inflate' is not registered"

The install script did not complete, or you connected to a different database. Verify:

```sql
SELECT name FROM system.functions WHERE name LIKE 'tenx%';
-- Expected: 6 functions (tenx_inflate, tenx_inflate_iso, tenx_inflate_core,
--                        tenx_inflate_core_iso, tenx_substitute_slot, tenx_substitute_slot_iso)
```

If any are missing, re-apply the install:

```bash
clickhouse-client --multiquery < tenx-for-clickhouse/install.sql
```

### Decoded events contain `~hash,vals` instead of readable text

The template for that hash is missing from `tenx.templates_dict`. Check:

```sql
-- Confirm the template exists in the source table
SELECT count() FROM tenx.templates WHERE templateHash = '<the-hash>';

-- Confirm the dictionary is loaded
SELECT status FROM system.dictionaries WHERE name = 'templates_dict';

-- Force a refresh
SYSTEM RELOAD DICTIONARY tenx.templates_dict;
```

If the template isn't in the source table, it was never produced by the Receiver for that event. Check the Receiver logs.

### A full-table decode fails with MEMORY_LIMIT_EXCEEDED

You are on a decoder older than 0.2.1. The inflate functions were O(N^2) in the slot count, and one wide template is enough to exhaust the server memory limit. Apply `tenx-for-clickhouse/upgrade-hotfix.sql` — it replaces the two core functions and recreates the two views, touches no table DDL, and loses no data. Do not raise `max_memory_usage` to work around it.

The views have to be recreated, which is what the hotfix does: ClickHouse expands SQL function bodies into a view's stored AST at `CREATE VIEW` time, so replacing the function alone leaves the old body running inside the view. Any view of your own that calls `tenx_*` directly needs recreating too:

```sql
SELECT database, name FROM system.tables
WHERE engine LIKE '%View%' AND create_table_query LIKE '%tenx_%';
```

### Decoded timestamps look wrong on `tenx.events`

`tenx.events` renders all timestamps as ISO 8601 with millisecond precision in UTC, regardless of the original template's format. This is by design. If you need the original format preserved, use `tenx.events_native`.

Exception: `$(+%s)` and `$(epoch)` slots. Those carry epoch **seconds**, not milliseconds, and before 0.2.1 the ISO view formatted them as milliseconds — `1754101012` came back as `1970-01-21T07:15:01.012Z`, a wrong instant rather than a reformatted one. Both views now pass those slots through untouched. If you see 1970 dates, upgrade.

### Dictionary not updating after template inserts

The dictionary auto-refresh runs every 60-120 seconds. To force immediate visibility:

```sql
SYSTEM RELOAD DICTIONARY tenx.templates_dict;
```

For high-throughput ingest where new templates appear frequently, lower the LIFETIME:

```sql
DROP DICTIONARY tenx.templates_dict;
-- Recreate with tighter window
CREATE DICTIONARY tenx.templates_dict (...) ... LIFETIME(MIN 5 MAX 15);
```

### "Argument at index 1 for function formatDateTimeInJodaSyntax must be constant"

This shouldn't happen with the supplied install. If you've modified the schema, ensure every `formatDateTimeInJodaSyntax` call has a string literal as the format argument. ClickHouse cannot accept a column or row-varying value for that parameter; this is why the multiIf dispatch exists.

## Upgrading

### From a previous version of tenx-for-clickhouse

Releases use semantic versioning. The install file is idempotent for functions and views (`CREATE OR REPLACE`), so applying a new version is:

```bash
clickhouse-client --multiquery < tenx-for-clickhouse/install.sql
```

The `DROP TABLE / CREATE TABLE` statements for `tenx.templates` and `tenx.encoded_events` in the install are destructive. For upgrades against an existing install with data you want to preserve, comment out those statements and run only the function and view updates.

### Upgrading ClickHouse itself

This component is forward-compatible with ClickHouse 24.x through 26.x. Newer versions are expected to work without changes; report any compatibility issues at the GitHub Issues tracker.
