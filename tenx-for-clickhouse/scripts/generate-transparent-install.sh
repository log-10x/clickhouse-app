#!/usr/bin/env bash
#
# generate-transparent-install.sh
#
# Introspect an existing ClickHouse logs table and emit a transparent-install
# SQL script. The output preserves the original table name behind a view so
# existing dashboards, alerts, BI queries, and applications continue to work
# unchanged after switching ingestion to compact events.
#
# Usage:
#   ./generate-transparent-install.sh \
#       --table <database>.<table> \
#       --encoded-column <column> \
#       [--template-hash-column <column>] \
#       [--ch-client "clickhouse-client ..."] \
#       [--output transparent-install.sql]
#
# Examples (all output to stdout unless --output is set):
#
#   # Local CH via docker exec:
#   CH_CLIENT='docker exec my-ch clickhouse-client' \
#     ./generate-transparent-install.sh --table my_logs.events --encoded-column message
#
#   # CH Cloud:
#   CH_CLIENT='clickhouse-client --host my.cloud --port 9440 --secure --user me --password ...' \
#     ./generate-transparent-install.sh --table groundcover.events --encoded-column body
#
#   # Write to file for review:
#   CH_CLIENT='clickhouse-client' \
#     ./generate-transparent-install.sh --table my_logs.events --encoded-column message \
#         --output transparent-install.sql
#
# Verify the standard install has been applied first:
#   clickhouse-client --query "SELECT count() FROM system.functions WHERE name LIKE 'tenx%'"
#   -- expected: 6

set -euo pipefail

TABLE=""
ENCODED_COLUMN=""
TEMPLATE_HASH_COLUMN=""
OUTPUT="/dev/stdout"
CH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --table)
            TABLE="$2"; shift 2 ;;
        --encoded-column)
            ENCODED_COLUMN="$2"; shift 2 ;;
        --template-hash-column)
            TEMPLATE_HASH_COLUMN="$2"; shift 2 ;;
        --output)
            OUTPUT="$2"; shift 2 ;;
        --ch-client)
            CH="$2"; shift 2 ;;
        -h|--help)
            awk '/^# Usage:/{p=1} /^set -euo/{p=0} p' "$0" | sed 's/^# //;s/^#//'
            exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1 ;;
    esac
done

# Fall back to CH_CLIENT env var, then a plain clickhouse-client.
if [[ -z "$CH" ]]; then
    CH="${CH_CLIENT:-clickhouse-client}"
fi

if [[ -z "$TABLE" || -z "$ENCODED_COLUMN" ]]; then
    echo "ERROR: --table and --encoded-column are required." >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

if [[ "$TABLE" != *.* ]]; then
    echo "ERROR: --table must be database-qualified (e.g., my_logs.events)" >&2
    exit 1
fi

ORIG_DB="${TABLE%.*}"
ORIG_TABLE="${TABLE#*.}"

# Introspect the existing table's schema. DESCRIBE TABLE in TSV gives us
# tab-separated columns; we only need the column name (field 1).
COLUMN_LIST=$(eval "$CH" --query \"DESCRIBE TABLE \\\`$ORIG_DB\\\`.\\\`$ORIG_TABLE\\\` FORMAT TSV\" 2>&1)
if ! echo "$COLUMN_LIST" | grep -q .; then
    echo "ERROR: could not DESCRIBE $TABLE — is the table reachable and does it exist?" >&2
    echo "Output from clickhouse-client:" >&2
    echo "$COLUMN_LIST" >&2
    exit 1
fi

# Build OTHER_COLUMNS: every column except the encoded column.
# Also detect whether the original table already has the requested template-hash column.
OTHER_COLUMNS=""
HASH_COLUMN_EXISTS=0
ALL_COLUMNS=""
while IFS=$'\t' read -r col_name col_type _; do
    [[ -z "$col_name" ]] && continue
    ALL_COLUMNS+=" $col_name"
    if [[ "$col_name" == "$ENCODED_COLUMN" ]]; then
        continue
    fi
    if [[ -n "$TEMPLATE_HASH_COLUMN" && "$col_name" == "$TEMPLATE_HASH_COLUMN" ]]; then
        HASH_COLUMN_EXISTS=1
    fi
    if [[ -z "$OTHER_COLUMNS" ]]; then
        OTHER_COLUMNS="    \`$col_name\`"
    else
        OTHER_COLUMNS+=",
    \`$col_name\`"
    fi
done <<<"$COLUMN_LIST"

# Verify the encoded column actually exists.
if ! echo "$ALL_COLUMNS" | grep -wq "$ENCODED_COLUMN"; then
    echo "ERROR: column '$ENCODED_COLUMN' not found in $TABLE." >&2
    echo "Available columns:$ALL_COLUMNS" >&2
    exit 1
fi

# If --template-hash-column is provided and the column exists, use it as a
# real column reference. Otherwise, generate an inline extraction expression
# from the encoded column. This handles both schemas: ones where the hash
# is already materialized, and ones where we have to extract on the fly.
if [[ -n "$TEMPLATE_HASH_COLUMN" && "$HASH_COLUMN_EXISTS" -eq 1 ]]; then
    HASH_EXPR="\`$TEMPLATE_HASH_COLUMN\`"
    HASH_COL_NAME="$TEMPLATE_HASH_COLUMN"
    HASH_NOTE="(reusing your existing '$TEMPLATE_HASH_COLUMN' column)"
else
    # Inline extraction: the templateHash is the substring between leading '~'
    # and the first comma in the encoded payload, or empty if not encoded.
    HASH_EXPR="if(startsWith(\`$ENCODED_COLUMN\`, '~'), substring(\`$ENCODED_COLUMN\`, 2, position(\`$ENCODED_COLUMN\`, ',') - 2), '')"
    HASH_COL_NAME="templateHash"
    HASH_NOTE="(extracting templateHash inline from '$ENCODED_COLUMN' — no separate hash column required)"
fi

# Emit the SQL.
cat >"$OUTPUT" <<SQL
-- =============================================================================
-- TRANSPARENT INSTALL for ${ORIG_DB}.${ORIG_TABLE}
-- =============================================================================
-- Generated $(date -u +"%Y-%m-%dT%H:%M:%SZ") by generate-transparent-install.sh
--
-- Source table:     ${ORIG_DB}.${ORIG_TABLE}
-- Encoded column:   ${ENCODED_COLUMN}
-- Template hash:    ${HASH_NOTE}
--
-- After applying this script, every dashboard, alert, BI query, and
-- application that previously queried ${ORIG_DB}.${ORIG_TABLE} continues
-- to do so without any change. The original table name is now a VIEW that
-- decodes compact events at query time and UNIONs any legacy rows that
-- pre-date the cutover.
--
-- BEFORE APPLYING:
--   (1) Apply the standard install (install.sql) so the tenx.* objects
--       exist. Verify with:
--         SELECT count() FROM system.functions WHERE name LIKE 'tenx%';
--   (2) Stop ingestion to ${ORIG_DB}.${ORIG_TABLE} (rename happens in
--       step 1 below; ingestion will fail otherwise).
--
-- AFTER APPLYING:
--   (3) Reconfigure your ingest pipeline to write compact events to
--       ${ORIG_DB}.${ORIG_TABLE}_compact (the new table created in step 2).
--   (4) Resume ingestion. Dashboards see expanded text immediately.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- STEP 1. Rename the existing table so it can be replaced with a view.
-- -----------------------------------------------------------------------------

RENAME TABLE \`${ORIG_DB}\`.\`${ORIG_TABLE}\` TO \`${ORIG_DB}\`.\`${ORIG_TABLE}_legacy\`;

-- -----------------------------------------------------------------------------
-- STEP 2. Create the table that will receive compact events.
--
-- The schema below mirrors the columns DESCRIBE TABLE found on the legacy
-- table. Adjust the ORDER BY if your access pattern is different.
-- -----------------------------------------------------------------------------

CREATE TABLE \`${ORIG_DB}\`.\`${ORIG_TABLE}_compact\`
AS \`${ORIG_DB}\`.\`${ORIG_TABLE}_legacy\`
ENGINE = MergeTree()
ORDER BY tuple();

-- -----------------------------------------------------------------------------
-- STEP 3. Recreate the original table name as a VIEW that decodes events.
-- -----------------------------------------------------------------------------

CREATE VIEW \`${ORIG_DB}\`.\`${ORIG_TABLE}\` AS
SELECT
${OTHER_COLUMNS},
    tenx_inflate_iso(
        \`${ENCODED_COLUMN}\`,
        dictGetOrDefault('tenx.templates_dict', 'literals',
                         tuple(${HASH_EXPR}),
                         []::Array(String)),
        dictGetOrDefault('tenx.templates_dict', 'slots',
                         tuple(${HASH_EXPR}),
                         []::Array(String))
    ) AS \`${ENCODED_COLUMN}\`
FROM \`${ORIG_DB}\`.\`${ORIG_TABLE}_compact\`
UNION ALL
SELECT
${OTHER_COLUMNS},
    \`${ENCODED_COLUMN}\`
FROM \`${ORIG_DB}\`.\`${ORIG_TABLE}_legacy\`;

-- =============================================================================
-- ROLLBACK
-- =============================================================================
--   DROP VIEW \`${ORIG_DB}\`.\`${ORIG_TABLE}\`;
--   RENAME TABLE \`${ORIG_DB}\`.\`${ORIG_TABLE}_legacy\` TO \`${ORIG_DB}\`.\`${ORIG_TABLE}\`;
--   DROP TABLE \`${ORIG_DB}\`.\`${ORIG_TABLE}_compact\`;
-- =============================================================================
SQL

if [[ "$OUTPUT" != "/dev/stdout" ]]; then
    echo "Wrote transparent install SQL to: $OUTPUT" >&2
    echo "Review the script, then apply with:" >&2
    echo "  $CH --multiquery < $OUTPUT" >&2
fi
