-- tenx-for-clickhouse — UPGRADE HOTFIX for the O(N^2) decode blow-up.
--
-- Run this ON AN EXISTING INSTALL:
--   clickhouse-client --multiquery < upgrade-hotfix.sql
--
-- It replaces the two core inflate functions and recreates the two views, and
-- touches nothing else. No table DDL: tenx.templates and tenx.encoded_events
-- are not dropped, not altered, not reloaded. No data is lost.
--
-- WHAT IT FIXES
-- The previous tenx_inflate_core / tenx_inflate_core_iso mapped over
-- range(1, length(literals)) and reached the literals/slots/values arrays by
-- index, so the lambda CAPTURED those columns and ClickHouse replicated each
-- captured column once per mapped element: O(N^2) strings per row for a row
-- with N slots. A single wide template (818 literals, on real container-dump
-- logs) is enough to exhaust many GiB, and a full-table decode dies with
-- MEMORY_LIMIT_EXCEEDED. The replacements pass the arrays as arrayMap
-- ARGUMENTS instead, which is O(N). See install.sql section 6 for why the
-- nested arrayResize is load-bearing.
--
-- WHY THE VIEWS ARE RECREATED HERE
-- ClickHouse expands SQL function bodies into a view's stored AST at
-- CREATE VIEW time (verify with SHOW CREATE VIEW tenx.events -- the expanded
-- lambda is visible inline). CREATE OR REPLACE FUNCTION alone leaves the OLD
-- body running inside existing views and the blow-up persists silently.
--
-- IF YOU BUILT YOUR OWN VIEWS
-- Any view, materialized view, or transparent-install view of yours that calls
-- tenx_* functions directly holds its own inlined copy of the old body.
-- Recreate those too. To find them:
--   SELECT database, name FROM system.tables
--   WHERE engine LIKE '%View%' AND create_table_query LIKE '%tenx_%';

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

-- Atomic replace: no window where the view does not exist.
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
