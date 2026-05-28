-- =============================================================================
-- TRANSPARENT INSTALL
-- =============================================================================
--
-- Use this when an existing ClickHouse deployment already has dashboards,
-- alerts, BI queries, and applications pointing at a specific logs table —
-- and you want all of that to keep working AFTER you switch ingestion to
-- compact events. No dashboard rewrites, no alert reconfigurations, no
-- application changes.
--
-- Mechanism: rename the existing logs table out of the way, create a new
-- table for compact events, then expose a VIEW at the original table name
-- that decodes compact events at query time and (optionally) UNIONs in any
-- historical raw events that pre-date the compaction cutover.
--
-- Existing consumers continue to query the same table name. They get
-- expanded text back. They don't know anything changed.
--
-- =============================================================================
-- HOW TO USE
-- =============================================================================
--
-- (1) Replace the placeholders below with values that match your environment:
--
--     {ORIG_DB}              database that holds the existing logs table
--                            (e.g., `default`, `my_logs`, `observability`)
--
--     {ORIG_TABLE}           name of the existing logs table that dashboards
--                            currently query (e.g., `events`, `logs`)
--
--     {ENCODED_COLUMN}       column that will hold the compact-form payload
--                            once you switch to compact ingestion (often
--                            `message`, `log`, or `body`)
--
--     {TEMPLATE_HASH_COLUMN} column that holds the extracted template hash;
--                            if your compact-events table already has this
--                            as a separate column, name it here. If not,
--                            replace `{TEMPLATE_HASH_COLUMN}` with the
--                            literal extraction expression:
--                              if(startsWith({ENCODED_COLUMN}, '~'),
--                                 substring({ENCODED_COLUMN}, 2,
--                                   position({ENCODED_COLUMN}, ',') - 2),
--                                 '')
--
--     {OTHER_COLUMNS}        comma-separated list of all OTHER columns from
--                            the original table that dashboards reference
--                            (e.g., `timestamp, level, service, container,
--                            namespace, pod, k8s_node`). DESCRIBE TABLE
--                            {ORIG_DB}.{ORIG_TABLE} to list them.
--
-- (2) Verify the standard install has been applied (tenx.* objects exist):
--       SELECT name FROM system.functions WHERE name LIKE 'tenx%';
--       -- expected: tenx_inflate, tenx_inflate_iso, plus four helpers
--
-- (3) Stop ingestion to {ORIG_DB}.{ORIG_TABLE} during the rename (~seconds).
--
-- (4) Apply this script:
--       clickhouse-client --multiquery < transparent-install.sql
--
-- (5) Reconfigure your ingest pipeline to write compact events to
--     {ORIG_DB}.{ORIG_TABLE}_compact (not the original name). Resume
--     ingestion.
--
-- (6) Dashboards, alerts, BI queries — all unchanged — continue to query
--     {ORIG_DB}.{ORIG_TABLE}. They now hit the view and get expanded text.
--
-- =============================================================================
-- TRADE-OFFS YOU ARE ACCEPTING
-- =============================================================================
--
-- * Queries filtering on indexed columns (templateHash, container, time
--   range, level) stay fast or get faster.
-- * Queries that scan/grep the encoded column (e.g., LIKE '%error%') pay
--   the inflate cost on every row scanned — slower than before. Migrate
--   those queries to filter by `templateHash IN (...)` to recover speed
--   when you have bandwidth; nothing forces it.
-- * Aggregations on non-encoded columns are unaffected (no inflate
--   triggered).
-- * Historical rows (in *_legacy) are returned unchanged via the UNION.
--   Drop the UNION clause if you do not need historical data.
--
-- =============================================================================

-- -----------------------------------------------------------------------------
-- STEP 1. Move the existing table out of the way.
-- -----------------------------------------------------------------------------

RENAME TABLE {ORIG_DB}.{ORIG_TABLE} TO {ORIG_DB}.{ORIG_TABLE}_legacy;

-- -----------------------------------------------------------------------------
-- STEP 2. Create the table that will receive compact events.
--
-- The schema below MUST be a superset of the columns your dashboards use.
-- At minimum it must expose `{ENCODED_COLUMN}` (the compact-form payload)
-- and `{TEMPLATE_HASH_COLUMN}` (extracted hash). Add whatever other columns
-- your ingest pipeline produces — timestamp, level, container, etc.
-- -----------------------------------------------------------------------------

CREATE TABLE {ORIG_DB}.{ORIG_TABLE}_compact
(
    -- REQUIRED: the encoded payload. The form is `~<hash>,<v1>,<v2>,...`
    `{ENCODED_COLUMN}` String,

    -- REQUIRED: the template hash extracted from the encoded payload.
    -- If your pipeline does not emit it as a column, replace this
    -- declaration with a MATERIALIZED expression that extracts it inline:
    --   `templateHash` String MATERIALIZED
    --       if(startsWith(`{ENCODED_COLUMN}`, '~'),
    --          substring(`{ENCODED_COLUMN}`, 2,
    --                    position(`{ENCODED_COLUMN}`, ',') - 2),
    --          '')
    `{TEMPLATE_HASH_COLUMN}` String,

    -- Add the same columns your existing dashboards reference here.
    -- Keep types identical to the legacy table so the view can UNION.
    -- Example:
    --   `timestamp` DateTime,
    --   `level` LowCardinality(String),
    --   `service` LowCardinality(String),
    --   `container` LowCardinality(String),
    --   `namespace` LowCardinality(String),
    --   `pod` String
)
ENGINE = MergeTree()
ORDER BY (`{TEMPLATE_HASH_COLUMN}`);   -- adjust for your access pattern

-- -----------------------------------------------------------------------------
-- STEP 3. Recreate the original table name as a VIEW that decodes events.
--
-- The view UNIONs the new compact-form events (decoded on the fly) with
-- the historical legacy rows (returned as-is). Existing dashboards see
-- both, with expanded text in the encoded column.
-- -----------------------------------------------------------------------------

CREATE VIEW {ORIG_DB}.{ORIG_TABLE} AS
SELECT
    {OTHER_COLUMNS},
    -- New: the compact column is replaced with the expanded text.
    tenx_inflate_iso(
        `{ENCODED_COLUMN}`,
        dictGetOrDefault('tenx.templates_dict', 'literals',
                         tuple(`{TEMPLATE_HASH_COLUMN}`),
                         []::Array(String)),
        dictGetOrDefault('tenx.templates_dict', 'slots',
                         tuple(`{TEMPLATE_HASH_COLUMN}`),
                         []::Array(String))
    ) AS `{ENCODED_COLUMN}`
FROM {ORIG_DB}.{ORIG_TABLE}_compact
UNION ALL
SELECT
    {OTHER_COLUMNS},
    `{ENCODED_COLUMN}`
FROM {ORIG_DB}.{ORIG_TABLE}_legacy;

-- =============================================================================
-- ROLLBACK
-- =============================================================================
--
-- If something goes wrong and you need to revert:
--
--   DROP VIEW {ORIG_DB}.{ORIG_TABLE};
--   RENAME TABLE {ORIG_DB}.{ORIG_TABLE}_legacy TO {ORIG_DB}.{ORIG_TABLE};
--   -- {ORIG_DB}.{ORIG_TABLE}_compact still exists; drop it if no longer needed:
--   DROP TABLE {ORIG_DB}.{ORIG_TABLE}_compact;
--
-- Then reconfigure your ingest pipeline to point back at the original table.
-- =============================================================================
