# Changelog

## 0.3.0 (Unreleased)

**Transparent install** — keep existing dashboards working without rewrites.

- New: `tenx-for-clickhouse/transparent-install.template.sql` — a SQL template that renames the existing logs table, creates a compact-events table at a new name, and exposes a VIEW at the original name that decodes compact events on the fly and UNIONs in historical legacy rows. Existing dashboards, alerts, and BI queries continue to query the original table name and get expanded text back.
- New: `tenx-for-clickhouse/scripts/generate-transparent-install.sh` — introspects an existing table's schema via `DESCRIBE TABLE` and generates a pre-filled transparent-install SQL script with the correct column list. Supports an optional `--template-hash-column` for pipelines that already extract the hash, or falls back to inline extraction.
- New USER-GUIDE section: **Transparent install: keep existing dashboards** — documents the brownfield install path, the performance trade-offs (indexed queries stay fast; full-text LIKE scans get slower), rollback procedure, and Groundcover-specific deployment notes.
- README updated to point at the transparent install path under "What stays unchanged."

The transparent install is opt-in. The standard install (default `tenx.*` namespace) remains the recommended path for greenfield deployments.

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
- Apache 2.0. Same license as the decoder.

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
