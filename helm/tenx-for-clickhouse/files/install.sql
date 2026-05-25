-- tenx-for-clickhouse — install
--
-- One file. Works identically on self-hosted ClickHouse, Altinity Cloud, and
-- ClickHouse Cloud. Uses only standard SQL (CREATE FUNCTION lambdas,
-- dictionaries, materialized columns, built-in formatDateTimeInJodaSyntax).
-- No executable UDF, no binary, no platform-specific install path.
--
-- Apply with:
--   clickhouse-client --multiquery < install.sql
--   (or paste into the Cloud Console SQL editor)
--
-- Creates: database tenx, tables (templates, encoded_events), dictionary,
-- six SQL functions, and two views: tenx.events (default; ISO 8601
-- timestamps; native scan speed) and tenx.events_native (compatibility;
-- preserves the original timestamp format per template; ~600ms fixed cost).

CREATE DATABASE IF NOT EXISTS tenx;

-- ---------------------------------------------------------------------------
-- 1. Templates source table with parsed columns materialized at INSERT.
--    literals[N+1] and slots[N] interleave: literals[i] sits before slots[i],
--    literals[N+1] is the trailing fragment after the last slot.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS tenx.templates;
CREATE TABLE tenx.templates
(
    templateHash String,
    template     String,
    literals     Array(String) MATERIALIZED
        splitByRegexp('\\$\\([^)]*\\)|\\$', template),
    slots        Array(String) MATERIALIZED
        extractAll(template, '\\$\\([^)]*\\)|\\$')
)
ENGINE = MergeTree()
ORDER BY templateHash;

-- ---------------------------------------------------------------------------
-- 2. Dictionary exposing the parsed arrays for fast query-time lookup.
-- ---------------------------------------------------------------------------
DROP DICTIONARY IF EXISTS tenx.templates_dict;
CREATE DICTIONARY tenx.templates_dict
(
    templateHash String,
    literals     Array(String),
    slots        Array(String)
)
PRIMARY KEY templateHash
SOURCE(CLICKHOUSE(TABLE 'templates' DB 'tenx'))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 60 MAX 120);

-- ---------------------------------------------------------------------------
-- 3. Encoded events table. Same shape as self-hosted: raw JSON envelope
--    plus materialized columns for the encoded payload, template hash,
--    and kubernetes envelope fields.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS tenx.encoded_events;
CREATE TABLE tenx.encoded_events
(
    raw          String,
    log          String  MATERIALIZED JSONExtractString(raw, 'log'),
    templateHash String  MATERIALIZED
        if(startsWith(log, '~'),
           if(position(log, ',') > 0,
              substring(log, 2, position(log, ',') - 2),
              substring(log, 2)),
           ''),
    container    String  MATERIALIZED JSONExtractString(raw, 'kubernetes', 'container_name'),
    namespace    String  MATERIALIZED JSONExtractString(raw, 'kubernetes', 'namespace_name'),
    pod          String  MATERIALIZED JSONExtractString(raw, 'kubernetes', 'pod_name')
)
ENGINE = MergeTree()
ORDER BY (container, templateHash);

-- ---------------------------------------------------------------------------
-- 4. Slot substitution — multiIf variant (preserves original timestamp format).
--    ClickHouse's formatDateTimeInJodaSyntax requires a compile-time constant
--    format string, so we dispatch over the observed format patterns with one
--    constant call per branch. The patterns below cover the 17 distinct
--    formats observed in OpenTelemetry-style logs. Extend by adding branches.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tenx_substitute_slot AS (value, slot) ->
    multiIf(
      slot = '$',                                              value,
      value = '' OR toInt64OrZero(value) = 0,                  value,
      slot = '$(yyyy-MM-dd HH:mm:ss)',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd HH:mm:ss', 'UTC'),
      slot = '$(yyyy-MM-dd HH:mm:ss,SSS)',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd HH:mm:ss,SSS', 'UTC'),
      slot = '$(yyyy-MM-dd HH:mm:ss.SSS)',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd HH:mm:ss.SSS', 'UTC'),
      slot = '$(yyyy/MM/dd HH:mm:ss)',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy/MM/dd HH:mm:ss', 'UTC'),
      slot = '$(HH:mm:ss)',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'HH:mm:ss', 'UTC'),
      slot = '$(dd MMM yyyy HH:mm:ss)',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'dd MMM yyyy HH:mm:ss', 'UTC'),
      slot = '$(yyyy-MM-dd''T''HH:mm:ss)',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd''T''HH:mm:ss', 'UTC'),
      slot = '$(yyyy-MM-dd''T''HH:mm:ss''Z'')',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd''T''HH:mm:ss''Z''', 'UTC'),
      slot = '$(yyyy-MM-dd''T''HH:mm:ss,SSS)',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd''T''HH:mm:ss,SSS', 'UTC'),
      slot = '$(yyyy-MM-dd''T''HH:mm:ss.SSS''Z'')',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''', 'UTC'),
      slot = '$(yyyy-MM-dd''T''HH:mm:ss.SSSSSS''Z'')',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd''T''HH:mm:ss.SSSSSS''Z''', 'UTC'),
      slot = '$(yyyy-MM-dd''T''HH:mm:ss.SSSSSSS''Z'')',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd''T''HH:mm:ss.SSSSSSS''Z''', 'UTC'),
      slot = '$(yyyy-MM-dd''T''HH:mm:ss.SSSSSSSS''Z'')',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd''T''HH:mm:ss.SSSSSSSS''Z''', 'UTC'),
      slot = '$(yyyy-MM-dd''T''HH:mm:ss.SSSSSSSSS''Z'')',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd''T''HH:mm:ss.SSSSSSSSS''Z''', 'UTC'),
      slot = '$(''I''MMdd HH:mm:ss.SSSSSS)',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          '''I''MMdd HH:mm:ss.SSSSSS', 'UTC'),
      slot = '$(''E''MMdd HH:mm:ss.SSSSSS)',
        formatDateTimeInJodaSyntax(fromUnixTimestamp64Milli(toInt64(value)),
          '''E''MMdd HH:mm:ss.SSSSSS', 'UTC'),
      slot = '$(+%s)',   value,
      slot = '$(epoch)', value,
      value
    );

-- ---------------------------------------------------------------------------
-- 5. Slot substitution — ISO-only variant (single constant format, fastest).
--    Renders ALL timestamps as ISO 8601 with millisecond precision, regardless
--    of the original template's format. Uses one constant call so ClickHouse
--    keeps everything in its vectorized execution engine.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tenx_substitute_slot_iso AS (value, slot) ->
    if(slot = '$',
       value,
       if(value = '' OR toInt64OrZero(value) = 0,
          value,
          formatDateTimeInJodaSyntax(
              fromUnixTimestamp64Milli(toInt64(value)),
              'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''',
              'UTC')));

-- ---------------------------------------------------------------------------
-- 6. Core inflate: interleave literals[] with substituted slot values.
--    Two versions, one per substitute function.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tenx_inflate_core AS (literals, slots, values) ->
    concat(
      arrayStringConcat(
        arrayMap(i ->
          concat(literals[i],
            if(i <= length(slots),
               tenx_substitute_slot(if(i <= length(values), values[i], ''), slots[i]),
               '')),
          range(1, length(literals))),
        ''),
      literals[length(literals)]);

CREATE OR REPLACE FUNCTION tenx_inflate_core_iso AS (literals, slots, values) ->
    concat(
      arrayStringConcat(
        arrayMap(i ->
          concat(literals[i],
            if(i <= length(slots),
               tenx_substitute_slot_iso(if(i <= length(values), values[i], ''), slots[i]),
               '')),
          range(1, length(literals))),
        ''),
      literals[length(literals)]);

-- ---------------------------------------------------------------------------
-- 7. Outer inflate: extract values from the encoded payload, delegate to core.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tenx_inflate AS (encoded, literals, slots) ->
    if(NOT startsWith(encoded, '~') OR empty(literals),
       encoded,
       tenx_inflate_core(
         literals, slots,
         if(position(substring(encoded, 2), ',') = 0,
            []::Array(String),
            splitByChar(',', substring(encoded, position(encoded, ',') + 1)))));

CREATE OR REPLACE FUNCTION tenx_inflate_iso AS (encoded, literals, slots) ->
    if(NOT startsWith(encoded, '~') OR empty(literals),
       encoded,
       tenx_inflate_core_iso(
         literals, slots,
         if(position(substring(encoded, 2), ',') = 0,
            []::Array(String),
            splitByChar(',', substring(encoded, position(encoded, ',') + 1)))));

-- ---------------------------------------------------------------------------
-- 8. Two views. Both expose the same column shape.
--
--    tenx.events       - **RECOMMENDED DEFAULT**. Normalises all timestamps to
--                         ISO 8601 with millisecond precision. Single constant
--                         format, fully vectorised. Full-table expansion runs
--                         at native ClickHouse scan speed (~60ms on 137K rows).
--                         Use this view for new dashboards and any consumer
--                         that accepts ISO 8601 timestamps (most Grafana time
--                         pickers, BI tools, application clients).
--
--    tenx.events_native - Preserves the original timestamp format per template
--                         via multiIf dispatch over 17 observed format patterns.
--                         Pays a ~600ms fixed cost per query from the dispatch
--                         layer. Use only when downstream consumers require
--                         the original log timestamp format (regex matchers,
--                         compliance log-format preservation).
-- ---------------------------------------------------------------------------

-- Primary view: ISO timestamps, native CH scan speed
DROP VIEW IF EXISTS tenx.events;
CREATE VIEW tenx.events AS
SELECT
    container, namespace, pod, templateHash,
    log AS encoded_log,
    tenx_inflate_iso(
        log,
        dictGetOrDefault('tenx.templates_dict', 'literals', tuple(templateHash), []::Array(String)),
        dictGetOrDefault('tenx.templates_dict', 'slots',    tuple(templateHash), []::Array(String))
    ) AS decoded_log
FROM tenx.encoded_events;

-- Compatibility view: original timestamp format preserved per template
DROP VIEW IF EXISTS tenx.events_native;
CREATE VIEW tenx.events_native AS
SELECT
    container, namespace, pod, templateHash,
    log AS encoded_log,
    tenx_inflate(
        log,
        dictGetOrDefault('tenx.templates_dict', 'literals', tuple(templateHash), []::Array(String)),
        dictGetOrDefault('tenx.templates_dict', 'slots',    tuple(templateHash), []::Array(String))
    ) AS decoded_log
FROM tenx.encoded_events;

-- ===========================================================================
-- 9. OPTIONAL: production hardening (uncomment + adjust for replicated clusters)
--
--    The templates table is critical infrastructure: compact events cannot be
--    expanded without it. For multi-replica production deployments, replace
--    the simple MergeTree with ReplicatedMergeTree so the templates survive
--    node loss and replicate to all nodes that serve queries.
--
--    Apply BEFORE loading templates, OR migrate by:
--      (1) snapshot existing templates: INSERT INTO tenx.templates_backup ...
--      (2) DROP TABLE tenx.templates SYNC
--      (3) apply the replicated CREATE below
--      (4) reload from snapshot
--      (5) SYSTEM RELOAD DICTIONARY tenx.templates_dict
-- ===========================================================================

-- DROP TABLE IF EXISTS tenx.templates SYNC;
-- CREATE TABLE tenx.templates ON CLUSTER '{cluster}'
-- (
--     templateHash String,
--     template     String,
--     literals     Array(String) MATERIALIZED splitByRegexp('\\$\\([^)]*\\)|\\$', template),
--     slots        Array(String) MATERIALIZED extractAll(template, '\\$\\([^)]*\\)|\\$')
-- )
-- ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/tenx_templates', '{replica}')
-- ORDER BY templateHash;

-- Daily backup of templates to a separate database (or to S3 via BACKUP TO):
-- INSERT INTO tenx_backup.templates_YYYYMMDD SELECT * FROM tenx.templates;
--
-- Status alarm — fire if the dictionary is not LOADED:
-- SELECT count() FROM system.dictionaries
-- WHERE database = 'tenx' AND name = 'templates_dict' AND status != 'LOADED';
-- Wire to Prometheus via clickhouse-exporter, or check from your monitoring system.
