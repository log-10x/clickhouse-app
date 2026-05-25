#!/usr/bin/env bash
#
# health-check.sh — Verify a tenx-for-clickhouse install is working end-to-end.
#
# Runs four SQL checks against the installed schema. Works on self-hosted
# ClickHouse, Altinity Cloud, and ClickHouse Cloud (any deployment where
# you can run clickhouse-client).
#
# Usage (Docker):
#   ./health-check.sh <container-name-or-id>
#
# Usage (any clickhouse-client invocation):
#   CLICKHOUSE_CLIENT="clickhouse-client --host my.cloud --secure --user ..." \
#       ./health-check.sh

set -euo pipefail

if [ -n "${CLICKHOUSE_CLIENT:-}" ]; then
    CH=($CLICKHOUSE_CLIENT)
elif [ -n "${1:-}" ]; then
    CH=(docker exec "$1" clickhouse-client)
else
    echo "usage: $0 <container-name-or-id>" >&2
    echo "   or: CLICKHOUSE_CLIENT='clickhouse-client ...' $0" >&2
    exit 1
fi

PASS=0; FAIL=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS  $name"; PASS=$((PASS+1))
    else
        echo "  FAIL  $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1))
    fi
}

R=$("${CH[@]}" --query "SELECT count() FROM system.functions WHERE name IN ('tenx_inflate','tenx_inflate_iso')")
check "SQL functions registered (tenx_inflate, tenx_inflate_iso)" "$R" "2"

R=$("${CH[@]}" --query "SELECT count() > 0 FROM system.dictionaries WHERE name='templates_dict' AND status='LOADED'")
check "Templates dictionary loaded" "$R" "1"

R=$("${CH[@]}" --query "EXISTS TABLE tenx.events" 2>/dev/null || echo "0")
check "View tenx.events exists" "$R" "1"

R=$("${CH[@]}" --query "EXISTS TABLE tenx.events_native" 2>/dev/null || echo "0")
check "View tenx.events_native exists" "$R" "1"

echo ""; echo "[health-check] $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
