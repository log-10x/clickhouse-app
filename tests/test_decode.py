"""
Unit tests: feed (encoded, template) directly into the SQL inflate functions
and assert the decoded result. No data loading required (uses literals).
"""
from __future__ import annotations

import pytest


pytestmark = pytest.mark.unit


# ---------------------------------------------------------------------------
# tenx_inflate_iso golden cases (single constant format, fast path)
# ---------------------------------------------------------------------------

ISO_CASES = [
    # description, encoded, literals, slots, expected
    (
        "zero-slot template passes through unchanged",
        "~-8C[!8[2gt4",
        ["Accounting service started"],
        [],
        "Accounting service started",
    ),
    (
        "multi value-slot template substitutes in order",
        "~5M0RE:*$6R,CORECLR,918728DD,259F,4A6A,AC2B,B85E1B658318",
        ["[", "_PROFILER, {", "-", "-", "-", "-", "}]"],
        ["$", "$", "$", "$", "$", "$"],
        "[CORECLR_PROFILER, {918728DD-259F-4A6A-AC2B-B85E1B658318}]",
    ),
    (
        "value slot with single value",
        "~ABC,worker-7",
        ["info: ", " starting"],
        ["$"],
        "info: worker-7 starting",
    ),
    (
        "timestamp slot renders as ISO 8601 ms in UTC",
        "~XYZ,1759349233741",
        ["", " event"],
        ["$(yyyy-MM-dd HH:mm:ss)"],
        # ISO variant ignores the slot format and renders ISO 8601 ms
        "2025-10-01T20:07:13.741Z event",
    ),
    (
        "passthrough when encoded does not start with ~",
        "plain log line not encoded",
        ["whatever"],
        [],
        "plain log line not encoded",
    ),
    (
        "passthrough when literals are empty (unknown template)",
        "~UNKNOWN,a,b",
        [],
        [],
        "~UNKNOWN,a,b",
    ),
]


@pytest.mark.parametrize("desc,encoded,literals,slots,expected", ISO_CASES,
                         ids=[c[0] for c in ISO_CASES])
def test_inflate_iso(ch, desc, encoded, literals, slots, expected):
    sql = (f"SELECT tenx_inflate_iso({ch.sql_str(encoded)}, "
           f"{ch.sql_str_array(literals)}, {ch.sql_str_array(slots)})")
    result = ch.query(sql).first_row[0]
    assert result == expected, f"[{desc}] got {result!r}, want {expected!r}"


# ---------------------------------------------------------------------------
# tenx_inflate golden cases (multiIf, preserves original timestamp format)
# ---------------------------------------------------------------------------

FORMAT_CASES = [
    (
        "yyyy-MM-dd HH:mm:ss",
        "~A,1759400774000",
        ["", " event"],
        ["$(yyyy-MM-dd HH:mm:ss)"],
        "2025-10-02 10:26:14 event",
    ),
    (
        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
        "~B,1759349233741",
        ["", " end"],
        ["$(yyyy-MM-dd'T'HH:mm:ss.SSS'Z')"],
        "2025-10-01T20:07:13.741Z end",
    ),
    (
        "yyyy/MM/dd HH:mm:ss",
        "~C,1759367841000",
        ["", " posted"],
        ["$(yyyy/MM/dd HH:mm:ss)"],
        "2025/10/02 01:17:21 posted",
    ),
    (
        "HH:mm:ss only",
        "~D,1759400774000",
        ["", ""],
        ["$(HH:mm:ss)"],
        "10:26:14",
    ),
    (
        "unknown format falls through to raw epoch ms",
        "~E,1759400774000",
        ["", " ms"],
        ["$(some-unknown-format)"],
        "1759400774000 ms",
    ),
]


@pytest.mark.parametrize("desc,encoded,literals,slots,expected", FORMAT_CASES,
                         ids=[c[0] for c in FORMAT_CASES])
def test_inflate_preserves_format(ch, desc, encoded, literals, slots, expected):
    sql = (f"SELECT tenx_inflate({ch.sql_str(encoded)}, "
           f"{ch.sql_str_array(literals)}, {ch.sql_str_array(slots)})")
    result = ch.query(sql).first_row[0]
    assert result == expected, f"[{desc}] got {result!r}, want {expected!r}"


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

def test_empty_string_value_passes_through(ch):
    # A '$' slot with no value should not error; the substitute returns ''
    sql = (f"SELECT tenx_inflate_iso({ch.sql_str('~A')}, "
           f"{ch.sql_str_array(['before ', ' after'])}, "
           f"{ch.sql_str_array(['$'])})")
    result = ch.query(sql).first_row[0]
    assert result == "before  after" or result == "before $ after", \
        f"unexpected: {result!r}"


def test_extreme_epoch_clamps_at_max_datetime(ch):
    # ClickHouse's fromUnixTimestamp64Milli clamps values past its DateTime64
    # max to the max representable date (year 2299). This is a CH behavior;
    # the SQL UDF does not (yet) add explicit out-of-range protection like
    # the prior Rust/Python reference UDFs did. Documented behavior: very
    # large ms inputs render as a date near year 2299 rather than falling
    # back to the raw value.
    sql = (f"SELECT tenx_inflate_iso({ch.sql_str('~A,99999999999999999')}, "
           f"{ch.sql_str_array(['', ' end'])}, "
           f"{ch.sql_str_array(['$(yyyy-MM-dd HH:mm:ss)'])})")
    result = ch.query(sql).first_row[0]
    # Either falls through to raw OR clamps to the CH max (~2299).
    # Both are acceptable; the bad case is a crash or wrong-looking date.
    assert "99999999999999999" in result or "2299" in result or "2262" in result, \
        f"unexpected output for extreme epoch: {result!r}"
