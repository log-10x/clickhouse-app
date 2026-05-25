# Changelog

## 0.1.0 (Unreleased)

Initial private release.

- **Pure SQL install.** No executable UDF, no binary, no platform-specific install path. Works identically on self-hosted ClickHouse, Altinity Cloud, and ClickHouse Cloud.
- **Two views over the same compact data**:
  - `tenx.events` — preserves original timestamp format per template (multiIf dispatch over 17 observed format patterns)
  - `tenx.events_iso` — normalizes all timestamps to ISO 8601 with millisecond precision; fastest path, equals native ClickHouse scan speed
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
