"""
pytest fixtures for tenx-for-clickhouse.

The test suite assumes a ClickHouse server is already running and reachable.
The CI workflow spins one up; locally you can use the demo's docker compose
(`cd demo && docker compose up -d`) or any ClickHouse you have access to.

Configuration via environment variables:
  CH_HOST       - ClickHouse HTTP host (default: localhost)
  CH_PORT       - ClickHouse HTTP port (default: 18123)
  CH_USER       - username (default: default)
  CH_PASSWORD   - password (default: empty)
  CH_DATABASE   - test database name (default: tenx_test; recreated each session)
"""
from __future__ import annotations

import os
import re
from pathlib import Path

import clickhouse_connect
import pytest


def _split_sql(sql_text: str) -> list[str]:
    """Split a multi-statement SQL string into individual statements.

    Strips '--' line comments first (so semicolons inside comments don't
    break the split) and then splits on ';'.
    """
    no_comments = re.sub(r"--[^\n]*", "", sql_text)
    return [s.strip() for s in no_comments.split(";") if s.strip()]


REPO_ROOT = Path(__file__).parent.parent
INSTALL_SQL = REPO_ROOT / "tenx-for-clickhouse" / "install.sql"
SAMPLE_DIR = REPO_ROOT / "demo" / "sample"


def _ch_client(database: str = "default"):
    return clickhouse_connect.get_client(
        host=os.environ.get("CH_HOST", "localhost"),
        port=int(os.environ.get("CH_PORT", "18123")),
        username=os.environ.get("CH_USER", "default"),
        password=os.environ.get("CH_PASSWORD", ""),
        database=database,
    )


@pytest.fixture(scope="session")
def ch_database() -> str:
    """Return the test database name; recreate it once per session."""
    db = os.environ.get("CH_DATABASE", "tenx_test")
    admin = _ch_client()
    admin.command(f"DROP DATABASE IF EXISTS {db}")
    admin.command(f"CREATE DATABASE {db}")
    return db


@pytest.fixture(scope="session")
def ch_schema(ch_database: str):
    """Apply install.sql against the test database.

    install.sql hardcodes the `tenx` database name; we rewrite to the test
    database name on the fly so we don't clobber a production install.
    """
    sql_text = INSTALL_SQL.read_text()
    # Substitute every database reference: qualified names (tenx.X),
    # CREATE DATABASE, dictGet literal, and the Dictionary SOURCE clause's DB literal.
    sql_text = sql_text.replace("CREATE DATABASE IF NOT EXISTS tenx",
                                 f"CREATE DATABASE IF NOT EXISTS {ch_database}")
    sql_text = sql_text.replace("tenx.", f"{ch_database}.")
    sql_text = sql_text.replace("'tenx.templates_dict'",
                                 f"'{ch_database}.templates_dict'")
    sql_text = sql_text.replace("DB 'tenx'", f"DB '{ch_database}'")
    admin = _ch_client()
    for stmt in _split_sql(sql_text):
        admin.command(stmt)


def _sql_str(s: str) -> str:
    """Quote a Python string as a ClickHouse SQL literal."""
    return "'" + s.replace("\\", "\\\\").replace("'", "''") + "'"


def _sql_str_array(items: list[str]) -> str:
    """Build an explicitly-typed Array(String) literal."""
    inner = ",".join(_sql_str(s) for s in items)
    return f"[{inner}]::Array(String)"


@pytest.fixture(scope="session")
def ch(ch_schema, ch_database: str):
    """Yield a client connected to the test database, schema applied.

    Also attaches helper methods for typed-literal SQL composition. The
    Python driver doesn't preserve Array(String) typing for empty lists,
    so tests that pass `[]` for literals or slots need typed literals to
    avoid 'Illegal type Nothing' errors in the SQL UDF's lambda.
    """
    client = _ch_client(database=ch_database)
    client.sql_str = _sql_str
    client.sql_str_array = _sql_str_array
    yield client
    client.close()


@pytest.fixture(scope="session")
def sample_loaded(ch, ch_database: str):
    """Load the embedded demo sample into the test database once per session."""
    # Read templates.json + encoded.log from demo/sample/
    templates_path = SAMPLE_DIR / "templates.json"
    encoded_path = SAMPLE_DIR / "encoded.log"

    # Load templates via JSONEachRow
    with open(templates_path, "rb") as f:
        ch.command(
            f"INSERT INTO {ch_database}.templates (templateHash, template) FORMAT JSONEachRow",
            data=f.read(),
        )
    # Load encoded events via LineAsString
    with open(encoded_path, "rb") as f:
        ch.command(
            f"INSERT INTO {ch_database}.encoded_events (raw) FORMAT LineAsString",
            data=f.read(),
        )
    ch.command(f"SYSTEM RELOAD DICTIONARY {ch_database}.templates_dict")
