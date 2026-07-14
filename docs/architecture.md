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
                                              │ SELECT * FROM tenx.events
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
| `tenx-inflate` SPL macro | `tenx.events` view + `tenx_inflate_iso` SQL UDF | The view is the user surface; no macro language to extend |
| JS search hook | Not needed | The view IS the query surface; no in-flight query rewriting |
| Alert action for KV population | Not needed | Dictionary auto-refreshes from source table |
| Python search command | Not needed | Pure SQL throughout |

The ClickHouse architecture is structurally simpler because ClickHouse exposes native primitives (Dictionary, view, lambda UDF) for every concern the Splunk app implements as a custom layer.

## Why pure SQL

An earlier iteration of this port is said to have shipped a Rust executable UDF alongside the SQL implementation, and earlier revisions of this document claimed a benchmark ("~60 ms SQL vs 5.8 s Rust") as the reason it was dropped. **That comparison is not reproducible and should not be relied on.** No Rust code exists in this repository or any related one, and the "~60 ms" half of it was an artifact — see [Measured performance](#measured-performance). The performance argument for pure SQL is retired; what stands is the operational one:

- ClickHouse Cloud blocks executable UDFs; self-hosted allows them. With SQL only, the same `install.sql` works everywhere, and the Cloud-vs-self-hosted distinction collapses.
- No multi-arch binaries, no platform-specific install scripts, no Cargo build pipeline in CI.
- The measured SQL numbers are good enough on their own terms: a full-table decode of the 137,418-row demo corpus runs in about 0.6 s inside 41 MiB. Whether a compiled UDF would beat that is an open question, and an unimportant one at this scale.

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

Each branch passes a constant. ClickHouse compiles each call independently. **Preserves the original format per template.** The dispatch costs about 90 ms on a full-table decode of the demo corpus (roughly 15% on top of the ISO path), not the "~600 ms fixed cost" earlier revisions of this document claimed. Exposed as `tenx.events_native`.

### Solution B: single constant format for all timestamps

```sql
formatDateTimeInJodaSyntax(ts, 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''', 'UTC')
```

One constant, fully vectorized. **All timestamps render as ISO 8601** regardless of original template. No per-row dispatch. Exposed as `tenx.events`, the default view.

`$(+%s)` and `$(epoch)` slots pass through untouched in both variants. They carry epoch seconds, while the format calls read epoch milliseconds, so formatting them would report a wrong instant rather than normalise a format.

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

Re-measured on ClickHouse 26.5.1 at **server defaults** (no `max_memory_usage` override), 137,418 compact events, median of 5 runs. Every workload below materialises `decoded_log`.

| Workload | `tenx.events` (ISO 8601, default) | `tenx.events_native` (multiIf) |
|---|---|---|
| Scan, no expansion (`encoded_log` only) | 10 ms | 10 ms |
| Decode 100 rows | 11 ms | 29 ms |
| Decode 10,000 rows | 30 ms | 61 ms |
| Filter pushdown, then decode 274 rows | 14 ms | 31 ms |
| Decode full table (137,418 rows) | **0.6 s**, 41 MiB peak | **0.7 s**, 78 MiB peak |
| Decode full table, before the O(N²) fix | `MEMORY_LIMIT_EXCEEDED` @ 7.2 GiB | `MEMORY_LIMIT_EXCEEDED` @ 7.2 GiB |

Full-table wall time varies about 0.55–0.79 s run to run on this machine; the memory figures are stable to two decimals. The multiIf dispatch costs roughly 90 ms over the full table and about 20 ms on small result sets.

#### About the numbers this table replaces

The previous version of this table claimed 60 ms for a full-table ISO decode and 6.7 s for the multiIf view. Both were wrong, in different directions.

- **The 60 ms** came from a `SELECT count()` against the view. ClickHouse prunes the unreferenced `decoded_log` expression out of the plan entirely: `EXPLAIN` shows no inflate node, and `query_log` records **24 bytes read, 1 row**. The query never decoded anything. Any benchmark of a decode path has to consume `decoded_log` — hash it, write it to `Null`, or select it.
- **The 6.7 s** understated a hard failure. Before the O(N²) capture fix, *neither* view could decode the full table at default settings; both died with `MEMORY_LIMIT_EXCEEDED` after allocating 7.2 GiB. A single 818-literal template (275 rows of 21 KB container dumps) accounted for ~97% of the materialisation, and those 275 rows on their own exhausted 6.5 GiB.

The fix (`install.sql` section 6, and `upgrade-hotfix.sql` for existing installs) passes the `literals` / `slots` / `values` arrays to `arrayMap` as **arguments** rather than letting the lambda capture them. ClickHouse replicates each captured column once per mapped element, so an indexing lambda over N slots materialises N copies of its N-element arrays. As arguments they are consumed element-wise, which is O(N).

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

## Upgrading: views inline the function body

ClickHouse expands SQL UDF bodies into a view's stored AST at `CREATE VIEW` time. `SHOW CREATE VIEW tenx.events` shows the whole lambda inline; the view does not hold a reference to the function.

Two consequences, both operational:

1. **`CREATE OR REPLACE FUNCTION` alone changes nothing for existing views.** They keep running the body they were created with. A decoder fix applied only to the functions looks applied — `SHOW CREATE FUNCTION` reports the new body — while every query through the view still executes the old one. The views must be recreated.
2. **User-created views are on their own.** Any view, materialized view, or transparent-install view that calls `tenx_*` directly holds its own inlined copy and needs recreating too:

   ```sql
   SELECT database, name FROM system.tables
   WHERE engine LIKE '%View%' AND create_table_query LIKE '%tenx_%';
   ```

Re-running `install.sql` handles the two shipped views. It is safe on a live install: the data tables are `CREATE TABLE IF NOT EXISTS`, and the dictionary and views are `CREATE OR REPLACE`. `upgrade-hotfix.sql` does the same for the decoder alone, with no table DDL at all.

## Lambdas capture columns: the O(N²) rule

Worth knowing before extending the decoder. A ClickHouse lambda that reaches an array by index has to **capture** that array, and ClickHouse replicates every captured column once per mapped element. Mapping over N elements while indexing into an N-element array therefore materialises N copies of it — O(N²) strings per row:

```sql
-- O(N^2): literals/slots/values are captured, then replicated N times
arrayMap(i -> concat(literals[i], f(values[i], slots[i])), range(1, length(literals)))

-- O(N): the arrays are arguments, consumed element-wise
arrayMap((lit, slot, val) -> concat(lit, f(val, slot)), literals, slots2, values2)
```

The captured form is what shipped through 0.2.0. It worked on narrow templates and collapsed on wide ones: one 818-literal template in the demo corpus made a full-table decode impossible at default settings. Multi-array `arrayMap` requires equal lengths, which is why the current implementation normalises with `arrayResize` — see the comment in `install.sql` section 6 for why the nested resize cannot be collapsed into one.

## Design choices not taken

For completeness, options considered and rejected:

| Option | Why not |
|---|---|
| Ship a Rust executable UDF | ClickHouse Cloud blocks executable UDFs, so it would fork the install path; multi-arch binaries and a Cargo pipeline in CI are a large operational cost. The SQL path decodes the full demo corpus in ~0.6 s, which is enough. (Earlier revisions justified this with a Rust-vs-SQL benchmark; that benchmark is not reproducible and is no longer claimed.) |
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
