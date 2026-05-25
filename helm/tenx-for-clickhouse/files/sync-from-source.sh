#!/usr/bin/env bash
#
# sync-from-source.sh — copy the canonical install.sql into the Helm chart's
# files/ directory so the chart is self-contained when packaged.
#
# Run after editing tenx-for-clickhouse/install.sql; CI verifies the two
# files match and fails if they don't.

set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$(cd "$CHART_DIR/../../tenx-for-clickhouse" && pwd)/install.sql"
TARGET="$CHART_DIR/files/install.sql"

cp "$SOURCE" "$TARGET"
echo "Synced: $SOURCE -> $TARGET"
