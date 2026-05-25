# Architecture

This document covers the expansion flow, the design choices behind the ClickHouse port, and the measured performance characteristics that back the value-prop claims in the [README](../README.md).

## Goals

The tenx-for-clickhouse port replicates the same architectural pattern as [tenx-for-splunk](https://github.com/log-10x/splunk-app) and [tenx-for-elasticsearch](https://github.com/log-10x/elasticsearch-plugin):

1. Decode Log10x-compact events transparently at query time
2. Preserve full original log text via a view that downstream tools read from as a normal table
3. Run without adding new infrastructure beyond a few SQL objects
4. Work identically on self-hosted ClickHouse, Altinity Cloud, and ClickHouse Cloud

## Decode flow

```
┌──────────────────────┐
│ Receiver       │  (separate Log10x product)
│ extracts templates,  │
│ emits compact events │
└──────────────────────┘
        │
        ├────► templates.json    ──► INSERT into tenx.templates ──┐
        │                                                          │
        │                                                          ▼
        │                                              ┌─────────────────────────┐
        │                                              │ tenx.templates_dict     │
        │                                              │ COMPLEX_KEY_HASHED      │
        │                                              │ in-memory, LIFETIME 60s │
        │                                              │ exposes literals[],     │
        │                                              │   slots[] arrays        │
        │                                              └─────────────────────────┘
        │                                                          ▲
        │                                                          │ dictGetOrDefault
        │                                                          │
        └────► encoded.log       ──► INSERT into tenx.encoded_events
                                              │
                                              │ raw String (JSON envelope)
                                              │ log MATERIALIZED JSONExtractString
                                              │ templateHash MATERIALIZED
                                              │ container MATERIALIZED
                                              │ namespace MATERIALIZED
                                              │ pod MATERIALIZED
                                              ▼
                                     ┌─────────────────────────┐
                                     │ tenx.events     (VIEW)  │
                                     │ tenx.events_native (VIEW)  │
                                     │ tenx_inflate(...)       │
                                     └─────────────────────────┘
                                              ▲
                                              │ SELECT * FROM tenx.events[_iso]
                                              │
                            ┌─────────────────┴─────────────────┐
                            │                                   │
                       Grafana,                            applications,
                       BI tools,                           SQL clients,
                       Cloud Console                       custom code
```

## Architecture mapping vs the Splunk app

| Splunk app component | ClickHouse equivalent | Why different |
|---|---|---|
| Splunk KV Store (MongoDB-backed) | `tenx.templates` table + `tenx.templates_dict` Dictionary | ClickHouse Dictionary is an in-process in-memory hash table backed by a regular table. No external KV system, no cross-system join at search time. |
| Scheduled `consume_kv` search | `LIFETIME(MIN 60 MAX 120)` auto-refresh | Native ClickHouse feature; no scheduled job to maintain |
| Splunk compact events index | `tenx.encoded_events` MergeTree | Standard ClickHouse columnar storage with materialized columns for filter pushdown |
| `tenx-inflate` SPL macro | `tenx.events` view + `tenx_inflate` SQL UDF | The view is the user surface; no macro language to extend |
| JS search hook | Not needed | The view IS the query surface; no in-flight query rewriting |
| Alert action for KV population | Not needed | Dictionary auto-refreshes from source table |
| Python search command | Not needed | Pure SQL throughout |

The ClickHouse architecture is structurally simpler because ClickHouse exposes native primitives (Dictionary, view, lambda UDF) for every concern the Splunk app implements as a custom layer.

## Why pure SQL

An earlier iteration of this port shipped a Rust executable UDF alongside the SQL implementation, on the assumption that a compiled binary would outperform pure SQL. Benchmarks proved the opposite: the SQL ISO-only path expands the full 137K-row sample in ~60 ms versus the Rust UDF's 5.8 s, because the SQL path stays inside ClickHouse's vectorized execution engine while the Rust path pays per-row stdin/stdout IPC.

The Rust UDF retained one narrow advantage — slightly lower per-query setup cost on small queries with format preservation — but the cost in operational complexity (multi-arch binaries, platform-specific install scripts, separate Cloud/self-hosted paths, Cargo build pipeline in CI) was disproportionate to the marginal performance edge.

The pure-SQL path also collapses the Cloud-vs-self-hosted distinction. ClickHouse Cloud blocks executable UDFs; self-hosted allows them. With SQL-only, the same `install.sql` works everywhere.

## The `formatDateTimeInJodaSyntax` constant-format constraint

ClickHouse's `formatDateTime` and `formatDateTimeInJodaSyntax` functions both **require the format-string argument to be a compile-time constant**. They reject a column or row-varying value with `Code: 44. Argument at index 1 must be constant`.

This is a problem because Log10x templates carry per-slot format patterns (e.g. `$(yyyy-MM-dd HH:mm:ss)` vs `$(yyyy-MM-dd'T'HH:mm:ss.SSS'Z')`). The decoder needs to apply a different format per slot per row.

Two valid SQL-only solutions, both implemented in `install.sql`:

### Solution A: `multiIf` dispatch with constant per branch

```sql
multiIf(
  slot = '$(yyyy-MM-dd HH:mm:ss)',
    formatDateTimeInJodaSyntax(ts, 'yyyy-MM-dd HH:mm:ss', 'UTC'),
  slot = '$(yyyy-MM-dd''T''HH:mm:ss.SSS''Z'')',
    formatDateTimeInJodaSyntax(ts, 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''', 'UTC'),
  ...17 branches covering the observed format patterns...
)
```

Each branch passes a constant. ClickHouse compiles each call independently. **Preserves the original format per template.** Pays a ~600 ms fixed cost per query because of the multiIf evaluation overhead. Exposed as `tenx.events`.

### Solution B: single constant format for all timestamps

```sql
formatDateTimeInJodaSyntax(ts, 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''', 'UTC')
```

One constant, fully vectorized. **All timestamps render as ISO 8601** regardless of original template. No per-row dispatch. Exposed as `tenx.events_native`.

Both views ship by default; the customer queries whichever matches their downstream consumer's expectations.

## Measured performance

All measurements taken on the included demo data (200 MB raw OpenTelemetry log, 130 MB compact, 1.2 MB templates) on an 8-core Apple Silicon Mac running ClickHouse 26.5 in Docker.

### Storage (on-disk after ClickHouse compression)

Identical schema, same data, four compression configurations:

| Table | Rows | On disk | Compression ratio |
|---|---|---|---|
| `raw_lz4` (original logs, LZ4) | 197,430 | 10.83 MiB | 19.3x |
| `enc_lz4` (compact logs, LZ4) | 137,418 | 6.23 MiB | 21x |
| `raw_zstd` (original logs, ZSTD-3) | 197,430 | 3.37 MiB | 64x |
| `enc_zstd` (compact logs, ZSTD-3) | 137,418 | 2.45 MiB | 55.2x |

**Apples-to-apples on-disk savings (same codec):**

- LZ4: 10.83 → 6.23 MiB = **42% reduction**
- ZSTD: 3.37 → 2.45 MiB = **27% reduction**

**Per-row savings (templating contribution, excluding row count drop):**

- LZ4: ~17% smaller per row
- ZSTD: ~0% (compact form slightly *larger* per row; ZSTD's pattern detection overlaps the templating layer)

### Decode throughput

| Workload | `tenx.events` (multiIf) | `tenx.events_native` (ISO 8601) |
|---|---|---|
| Decode 100 rows | 620 ms | 82 ms |
| Decode 10,000 rows | 2.26 s | 66 ms |
| Decode full table (137,418 rows) | 6.7 s | **60 ms** |

The ISO variant achieves ~2.3M rows/sec (effectively native ClickHouse scan speed) because every operation stays inside the vectorized engine. The multiIf variant pays a per-query setup cost from format dispatch but preserves original timestamp formats.

### Transport (edge → ClickHouse)

35% fewer wire bytes (200 MB raw → 130 MB compact), independent of codec. This is the most defensible reduction number because it applies to network and ingest before ClickHouse's compression runs.

## Codec interaction insight

The on-disk measurements show a non-obvious result: **ZSTD's pattern detection overlaps significantly with the templating layer's pattern extraction**. After templating removes the structural redundancy in log text, ZSTD has less to work with. The compact form has a marginally lower per-byte reduction ratio than the raw form.

Under LZ4 (weaker compression), templating contributes more incremental savings because LZ4 misses patterns that ZSTD would catch.

Practical implication: **storage savings vary by codec**. The savings story works best on LZ4 customers (the ClickHouse default on hot tiers). For ZSTD customers, the templating layer's storage contribution is small; most savings come from event count reduction via the Receiver's grouping module.

Other value drivers — transport, ingest CPU, background merge CPU, query speed via `templateHash` filtering — are codec-independent.

## Where ClickHouse cannot push down filters

Filters on the `decoded_log` column trigger the inflate functions for every candidate row (those functions are opaque to the query optimizer). The materialized columns (`templateHash`, `container`, `namespace`, `pod`, `log`) are indexed and support standard pushdown.

Query-hygiene rule for users: **always filter on the materialized columns first**, then let the surviving rows expand.

```sql
-- FAST: filter pushes down on indexed columns, only matching rows expand
SELECT decoded_log FROM tenx.events
WHERE container = 'accounting' AND templateHash = '-L3!]kPjVal'
LIMIT 100;

-- SLOW: filter operates after expansion, every row gets expanded
SELECT decoded_log FROM tenx.events
WHERE decoded_log LIKE '%error%'
LIMIT 100;
```

This is the same pattern that applies to any computed column in ClickHouse and is not specific to tenx-for-clickhouse.

## Design choices not taken

For completeness, options considered and rejected:

| Option | Why not |
|---|---|
| Ship a Rust executable UDF | Pure SQL benchmarks faster on bulk workloads; binary install adds disproportionate operational complexity for narrow performance gains |
| Materialize the expanded column at INSERT time | Defeats the storage savings; expanded form is 3x larger than compact |
| Pre-translate Java SimpleDateFormat to ClickHouse format codes at INSERT time | Joda syntax already accepts Java patterns natively; translation is unnecessary work |
| Use ClickHouse's built-in JSON column type for the envelope | Would parse the envelope eagerly per row; the materialized columns approach extracts only the fields needed for filter pushdown |
| Implement edge-side pre-aggregation (emit metrics + sampled raw) | Out of scope for the decoder; would change the product's lossless guarantee. Separate roadmap discussion. |
| Store templates in a `LowCardinality(String)` column rather than a Dictionary | LowCardinality is per-column; Dictionary is a reusable lookup. Dictionary fits the access pattern and supports `LIFETIME` auto-refresh. |

## References

- [ClickHouse Dictionary documentation](https://clickhouse.com/docs/en/sql-reference/dictionaries)
- [ClickHouse SQL UDF documentation](https://clickhouse.com/docs/en/sql-reference/functions/udf)
- [Joda Time pattern reference](https://www.joda.org/joda-time/apidocs/org/joda/time/format/DateTimeFormat.html) (the patterns `formatDateTimeInJodaSyntax` accepts)
- [Log10x Receiver documentation](https://doc.log10x.com/apps/receiver/)
