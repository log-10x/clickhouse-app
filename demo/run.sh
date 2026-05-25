#!/usr/bin/env bash
#
# run.sh — 60-second demo walkthrough.
#
# Waits for ClickHouse to be ready, applies the schema, loads sample data,
# runs sanity queries, prints next steps.

set -euo pipefail

CTR=tenx-demo-clickhouse
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "[demo] Waiting for ClickHouse to be ready..."
until docker exec "$CTR" clickhouse-client --query "SELECT 1" >/dev/null 2>&1; do
    sleep 1
done
echo "[demo] ClickHouse is up: $(docker exec "$CTR" clickhouse-client --query "SELECT version()")"

echo "[demo] Applying schema..."
docker exec -i "$CTR" clickhouse-client --multiquery \
    < "$REPO_DIR/tenx-for-clickhouse/install.sql"

echo "[demo] Loading templates..."
docker exec "$CTR" bash -c \
    "clickhouse-client --query 'INSERT INTO tenx.templates (templateHash, template) FORMAT JSONEachRow' < /sample/templates.json"

echo "[demo] Loading encoded events (this may take a few seconds)..."
docker exec "$CTR" bash -c \
    "clickhouse-client --query 'INSERT INTO tenx.encoded_events (raw) FORMAT LineAsString' < /sample/encoded.log"

docker exec "$CTR" clickhouse-client --query "SYSTEM RELOAD DICTIONARY tenx.templates_dict"

echo ""
echo "=== Sample decoded events (tenx.events, original timestamp format) ==="
docker exec "$CTR" clickhouse-client --query "
SELECT decoded_log
FROM tenx.events
WHERE templateHash != ''
ORDER BY rand()
LIMIT 3
FORMAT TabSeparatedRaw"

echo ""
echo "=== Same events via tenx.events_native (ISO 8601 timestamps) ==="
docker exec "$CTR" clickhouse-client --query "
SELECT decoded_log
FROM tenx.events_native
WHERE templateHash != ''
ORDER BY rand()
LIMIT 3
FORMAT TabSeparatedRaw"

echo ""
echo "=== Row counts ==="
docker exec "$CTR" clickhouse-client --query "
SELECT 'templates' AS t, count() AS rows FROM tenx.templates
UNION ALL SELECT 'encoded_events', count() FROM tenx.encoded_events
FORMAT PrettyCompact"

echo ""
echo "=== Storage on disk ==="
docker exec "$CTR" clickhouse-client --query "
SELECT table, formatReadableSize(sum(bytes_on_disk)) AS on_disk
FROM system.parts WHERE database = 'tenx' AND active
GROUP BY table FORMAT PrettyCompact"

echo ""
echo "[demo] Ready. Try queries at: http://localhost:18123/play"
echo "[demo] Tear down with: docker compose down -v"
