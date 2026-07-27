# Changelog

## 0.2.1 (Unreleased)

**Fixed: full-table decode ran out of memory.** `tenx_inflate_core` and
`tenx_inflate_core_iso` mapped over `range(1, length(literals))` and reached the
`literals` / `slots` / `values` arrays by index, so the lambda captured those
`Array(String)` columns and ClickHouse replicated each captured column once per
mapped element: O(N^2) strings per row for a row with N slots. On the 137,418-row
demo corpus a single 818-literal template (275 rows of container dumps) was enough
to blow past the server memory limit, and any query that expanded `decoded_log`
over the whole table died with `MEMORY_LIMIT_EXCEEDED` at 7.2 GiB. The arrays are
now passed as `arrayMap` **arguments**, which is O(N).

Measured on that corpus at ClickHouse defaults (26.5.1, 8-core Apple Silicon), no
memory-limit overrides:

| Full-table decode (137,418 rows) | before | after |
|---|---|---|
| `tenx.events` (ISO) | MEMORY_LIMIT_EXCEEDED @ 7.2 GiB | 571 ms, 41 MiB peak |
| `tenx.events_native` (multiIf) | MEMORY_LIMIT_EXCEEDED @ 7.2 GiB | 658 ms, 78 MiB peak |

Decoded output is byte-identical to the old implementation across the full corpus
and the existing golden test suite.

**Fixed: `install.sql` could not be re-run, and unblocking it destroyed all stored
data.** The file opened with `DROP TABLE IF EXISTS tenx.templates` and
`DROP TABLE IF EXISTS tenx.encoded_events`. On a live install the documented upgrade
— re-run the installer — aborts on the first statement with `HAVE_DEPENDENT_OBJECTS`,
because `tenx.templates_dict` depends on the table it is trying to drop. Nothing
upgrades. Clearing that blocker the obvious way, `DROP DICTIONARY tenx.templates_dict`
(which the USER-GUIDE itself tells you to type when tuning `LIFETIME`), lets the
re-run through, and it then drops both data tables. Verified on ClickHouse 26.5.1:
templates 378 → 0, encoded_events 137,418 → 0. Every stored compact event becomes
permanently unexpandable, because expansion needs the templates.

The data tables are now `CREATE TABLE IF NOT EXISTS`, the dictionary and the views are
`CREATE OR REPLACE`, and re-running the file on a live install is safe, upgrades the
decoder in place, and is the supported upgrade path. A deliberate factory reset is
available as a commented-out `DROP DATABASE`.

**New: `tenx-for-clickhouse/upgrade-hotfix.sql`.** What an existing install runs to
pick up the decoder fix: the two core functions plus the two view recreations, no
table DDL. The views have to be recreated, because ClickHouse expands SQL function
bodies into a view's stored AST at `CREATE VIEW` time — `CREATE OR REPLACE FUNCTION`
alone leaves the old body running inside existing views and the blow-up persists
silently. Any user-created view that calls `tenx_*` directly needs the same
treatment.

**Corrected the performance claims in `install.sql`.** The "~60 ms full-table
expansion" figure came from a `SELECT count()` that ClickHouse pruned to zero decode
work (`EXPLAIN` shows no inflate node; `query_log` shows 24 bytes read). The
"~600 ms fixed cost" for the multiIf view was equally unfounded: measured, the
dispatch costs about 90 ms on the demo corpus.

**Fixed: `tenx.events` rendered `$(+%s)` / `$(epoch)` slots as a wrong instant.**
`tenx_substitute_slot_iso` was missing the two passthrough branches its `multiIf`
sibling has. Those slots carry epoch **seconds**, and the ISO function's single
format call reads its input as epoch **milliseconds**, so the default view turned
`1754101012` into `1970-01-21T07:15:01.012Z`. That is not a format normalisation,
it is the wrong point in time. Both slot kinds now pass through untouched, matching
`tenx.events_native`. Behavior change for templates that use them; every other slot
decodes byte-for-byte as before.

## 0.2.0 (Unreleased)

Post-Grok-debate architecture polish + Grafana app plugin scaffold.

**Decoder polish**:
- `tenx.events` is now the **default view**: ISO 8601 timestamps, native CH scan speed (~60 ms full-table expansion on 137K rows). The previous default (`tenx.events`, multiIf format dispatch) was renamed to **`tenx.events_native`** and documented as the compatibility view for consumers that need original timestamp format preservation.
- Dictionary hardening: `install.sql` ships with a commented-out `ReplicatedMergeTree` + `ON CLUSTER` variant for multi-replica production deployments, plus a documented status-alarm query (`SELECT count() FROM system.dictionaries WHERE status != 'LOADED'`) and a backup pattern.
- Repositioned README headline to codec-independent claim: "Reduces ClickHouse ingest CPU 25-30% and edge-to-cluster bandwidth 35%, with codec-dependent storage savings on top." Drops the inherited "over 50%" language that only applied to per-ingest-GB billing models (Splunk/Datadog).

**Grafana app plugin** (new at [grafana/tenx-for-clickhouse-app/](grafana/tenx-for-clickhouse-app/)):
- **Pattern Explorer page**: top-N templates by estimated cost in the selected time range; one-click "copy templateHash filter" for paste-into-dashboard.
- **Template cost attribution dashboard** (bundled): templates known, compact events in range, distinct templates, top-25 templates by bytes, event volume by container, top-5 templates over time.
- Sits on top of an existing ClickHouse data source (Grafana official or Altinity). Does not install a data source.
- MIT. Same license as the decoder.

## 0.1.0 (Unreleased)

Initial private release.

- **Pure SQL install.** No executable UDF, no binary, no platform-specific install path. Works identically on self-hosted ClickHouse, Altinity Cloud, and ClickHouse Cloud.
- **Two views over the same compact data**:
  - `tenx.events` — preserves original timestamp format per template (multiIf dispatch over 17 observed format patterns)
  - `tenx.events_native` — normalizes all timestamps to ISO 8601 with millisecond precision; fastest path, equals native ClickHouse scan speed
- **Template grammar support**: `$` value slots, `$(<java-fmt>)` timestamp slots, `$(epoch)` raw slots
- **Java SimpleDateFormat patterns** handled natively via `formatDateTimeInJodaSyntax`
- **Dictionary-based template lookup** with auto-refresh (`LIFETIME`)
- **Materialized columns** on the compact events table for fast filter pushdown on `container`, `templateHash`, `namespace`, `pod`, and the compact `log` payload
- Verified end-to-end on a 200 MB OpenTelemetry-demo sample (3,473 templates, 137,418 compact events)
- Measured on-disk reduction vs raw events under identical ClickHouse column codec: 42% with LZ4, 27% with ZSTD
- **pytest suite** with 21 tests (13 unit golden cases + 8 integration tests against a real ClickHouse)
- **CI matrix** on GitHub Actions: ClickHouse 24.8 (LTS), 25.3, latest
- **Helm chart starter** at `helm/tenx-for-clickhouse/` (Job-pattern install against an existing CH service)
- **Self-contained embedded demo sample** (~1 MB, 378 templates + 500 events) — no external data dependencies
- **SECURITY.md** with private vulnerability reporting policy
- **Release workflow** (tag-driven): `git tag vX.Y.Z` cuts a GitHub Release with `install.sql`, packaged tarball, and SHA256SUMS
