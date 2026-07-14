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
-- timestamps) and tenx.events_native (compatibility; preserves the original
-- timestamp format per template, at a small extra cost for the multiIf
-- format dispatch). Measured numbers are in section 8.
--
-- UPGRADING
-- ---------
-- Re-running this file on a live install is safe and is the supported upgrade
-- path. It never drops tenx.templates or tenx.encoded_events; functions, the
-- dictionary, and the views are replaced in place.
--
-- The views MUST be recreated whenever a tenx_* function changes. ClickHouse
-- expands SQL function bodies into each view's stored AST at CREATE VIEW time,
-- so CREATE OR REPLACE FUNCTION on its own leaves the old body running inside
-- existing views (verify with SHOW CREATE VIEW tenx.events -- the expanded
-- lambda is visible inline). Re-running this file does that for tenx.events
-- and tenx.events_native. If you built your own views, materialized views, or
-- transparent-install views that call tenx_* functions directly, recreate
-- those too.
--
-- To upgrade the decoder WITHOUT touching any table DDL, run upgrade-hotfix.sql
-- instead: it replaces the two core functions and recreates the two views.
--
-- Factory reset (DESTROYS ALL DATA -- templates and every stored event; compact
-- events cannot be expanded without their templates). Deliberately commented
-- out; uncomment only if you mean it:
-- DROP DATABASE IF EXISTS tenx SYNC;

CREATE DATABASE IF NOT EXISTS tenx;

-- ---------------------------------------------------------------------------
-- 1. Templates source table with parsed columns materialized at INSERT.
--    literals[N+1] and slots[N] interleave: literals[i] sits before slots[i],
--    literals[N+1] is the trailing fragment after the last slot.
--
--    IF NOT EXISTS, never DROP: re-running this file on a live install must
--    not destroy the templates. Without them, every stored compact event is
--    permanently unexpandable.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tenx.templates
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
--    OR REPLACE, not DROP + CREATE: the replacement is atomic, so an upgrade
--    never opens a window where queries hit a missing dictionary.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DICTIONARY tenx.templates_dict
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
--
--    IF NOT EXISTS, never DROP: see section 1.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tenx.encoded_events
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
--
--    The $(+%s) and $(epoch) slots pass through untouched, exactly as they do
--    in section 4. Those slots carry epoch SECONDS, and this function's one
--    format call reads its input as epoch MILLISECONDS, so formatting them
--    would not normalise a format, it would report a wrong instant:
--    1754101012 came out as 1970-01-21T07:15:01.012Z.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tenx_substitute_slot_iso AS (value, slot) ->
    multiIf(
      slot = '$',                              value,
      value = '' OR toInt64OrZero(value) = 0,  value,
      slot = '$(+%s)',                         value,
      slot = '$(epoch)',                       value,
      formatDateTimeInJodaSyntax(
          fromUnixTimestamp64Milli(toInt64(value)),
          'yyyy-MM-dd''T''HH:mm:ss.SSS''Z''',
          'UTC'));

-- ---------------------------------------------------------------------------
-- 6. Core inflate: interleave literals[] with substituted slot values.
--    Two versions, one per substitute function.
--
--    All three arrays are passed as ARGUMENTS to arrayMap, never captured by
--    the lambda. This is load-bearing, not style. A lambda that indexes into
--    the arrays (literals[i]) while mapping over range(1, length(literals))
--    has to CAPTURE literals/slots/values, and ClickHouse replicates every
--    captured column once per mapped element: a row with N slots materialises
--    N copies of its N-element arrays, i.e. O(N^2) strings per row. On real
--    data one 818-literal template is enough to exhaust many GiB and kill a
--    full-table decode. Array *arguments* are consumed element-wise: O(N).
--
--    The two arrayResize calls normalise the arrays to equal length (a
--    multi-array arrayMap requires it) and subsume the trailing literal:
--
--      inner: arrayResize(values, length(slots), '') normalises values to
--             exactly one per slot. It TRUNCATES surplus fields -- a value
--             that itself contains a comma splits into extra fields -- and
--             PADS missing ones with '', which is exactly what the old
--             i <= length(slots) range and i <= length(values) guard did.
--             The truncation is what guarantees the pad position added by the
--             outer resize is really '' and not a surplus field. DO NOT
--             "simplify" this to a single arrayResize(values, length(literals)):
--             that is a known bug, and it corrupts any row whose last slot
--             value contains a comma.
--      outer: padding slots and values to length(literals) appends one ''
--             pair at the last position (literals always has exactly one more
--             element than slots, by construction of the templates table).
--             tenx_substitute_slot('', '') = '', so the trailing literal is
--             emitted with nothing after it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tenx_inflate_core AS (literals, slots, values) ->
    arrayStringConcat(
      arrayMap((lit, slot, val) -> concat(lit, tenx_substitute_slot(val, slot)),
        literals,
        arrayResize(slots, length(literals), ''),
        arrayResize(arrayResize(values, length(slots), ''), length(literals), '')),
      '');

CREATE OR REPLACE FUNCTION tenx_inflate_core_iso AS (literals, slots, values) ->
    arrayStringConcat(
      arrayMap((lit, slot, val) -> concat(lit, tenx_substitute_slot_iso(val, slot)),
        literals,
        arrayResize(slots, length(literals), ''),
        arrayResize(arrayResize(values, length(slots), ''), length(literals), '')),
      '');

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
--                         format, fully vectorised. Use this view for new
--                         dashboards and any consumer that accepts ISO 8601
--                         timestamps (most Grafana time pickers, BI tools,
--                         application clients).
--
--    tenx.events_native - Preserves the original timestamp format per template
--                         via multiIf dispatch over 17 observed format patterns.
--                         Use when downstream consumers require the original
--                         log timestamp format (regex matchers, compliance
--                         log-format preservation).
--
--    Measured: full-table decode (SELECT decoded_log, 137,418 rows of the
--    OpenTelemetry demo corpus, ClickHouse 26.5.1, 8-core Apple Silicon,
--    server defaults, no memory-limit overrides):
--
--      tenx.events         571 ms wall (median of 7), 41 MiB peak memory
--      tenx.events_native  658 ms wall (median of 7), 78 MiB peak memory
--
--    The multiIf dispatch in events_native costs roughly 90 ms on that corpus,
--    not the "~600 ms fixed cost" earlier revisions of this file claimed. Both
--    views decode inside 100 MiB; neither one needs a raised max_memory_usage.
--
--    OR REPLACE, not DROP + CREATE: readers never see a missing view during an
--    upgrade. The views MUST be recreated whenever a tenx_* function changes
--    (see the UPGRADING note at the top of this file).
-- ---------------------------------------------------------------------------

-- Primary view: ISO timestamps
CREATE OR REPLACE VIEW tenx.events AS
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
CREATE OR REPLACE VIEW tenx.events_native AS
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
