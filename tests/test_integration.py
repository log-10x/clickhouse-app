"""
Integration tests: load the embedded sample dataset into the test database
and assert the view returns sensible decoded output.
"""
from __future__ import annotations

import pytest


pytestmark = pytest.mark.integration


def test_templates_loaded(ch, sample_loaded, ch_database):
    n = ch.query(f"SELECT count() FROM {ch_database}.templates").first_row[0]
    assert n > 100, f"expected >100 templates from embedded sample, got {n}"


def test_encoded_events_loaded(ch, sample_loaded, ch_database):
    n = ch.query(f"SELECT count() FROM {ch_database}.encoded_events").first_row[0]
    assert n > 100, f"expected >100 encoded events from embedded sample, got {n}"


def test_dictionary_loaded(ch, sample_loaded, ch_database):
    status = ch.query(
        f"SELECT status FROM system.dictionaries "
        f"WHERE database = %(d)s AND name = 'templates_dict'",
        parameters={"d": ch_database},
    ).first_row[0]
    assert status == "LOADED", f"dictionary not loaded: {status}"


def test_view_returns_decoded_rows(ch, sample_loaded, ch_database):
    rows = ch.query(
        f"SELECT decoded_log FROM {ch_database}.events "
        f"WHERE templateHash != '' LIMIT 5"
    ).result_rows
    assert len(rows) == 5, f"expected 5 decoded rows, got {len(rows)}"
    for (decoded,) in rows:
        # Decoded text shouldn't still look like the encoded ~hash,vals form
        assert not decoded.startswith("~"), \
            f"row appears not decoded: {decoded[:80]!r}"


def test_iso_view_renders_iso_timestamps(ch, sample_loaded, ch_database):
    # Find a row whose template includes a timestamp slot; assert the ISO
    # variant produces an ISO 8601 timestamp.
    rows = ch.query(
        f"""
        SELECT decoded_log
        FROM {ch_database}.events_iso
        WHERE templateHash IN (
            SELECT templateHash FROM {ch_database}.templates
            WHERE hasAny(slots, ['$(yyyy-MM-dd HH:mm:ss)',
                                  '$(yyyy-MM-dd''T''HH:mm:ss.SSS''Z'')'])
        )
        LIMIT 5
        """
    ).result_rows
    if not rows:
        pytest.skip("no timestamp templates in embedded sample to verify")
    for (decoded,) in rows:
        # ISO 8601: 4-digit year, "T", ends in "Z" somewhere
        assert "T" in decoded and "Z" in decoded, \
            f"expected ISO 8601 timestamp in {decoded[:80]!r}"


def test_filter_pushdown_on_materialized_columns(ch, sample_loaded, ch_database):
    # Aggregation on a materialized column should NOT trigger decode.
    # Verifies the column is queryable without going through the inflate functions.
    rows = ch.query(
        f"SELECT container, count() FROM {ch_database}.events "
        f"GROUP BY container ORDER BY count() DESC LIMIT 5"
    ).result_rows
    assert len(rows) > 0, "expected at least one container in aggregation"


def test_unknown_hash_falls_through_to_encoded(ch, sample_loaded, ch_database):
    # When the dictionary doesn't know a hash, the view should surface the raw
    # encoded payload rather than producing garbage or erroring.
    result = ch.query(
        f"""
        SELECT tenx_inflate_iso(
            '~SOMEUNKNOWNHASH,a,b',
            dictGetOrDefault('{ch_database}.templates_dict', 'literals',
                             tuple('SOMEUNKNOWNHASH'), []::Array(String)),
            dictGetOrDefault('{ch_database}.templates_dict', 'slots',
                             tuple('SOMEUNKNOWNHASH'), []::Array(String))
        )
        """
    ).first_row[0]
    assert result == "~SOMEUNKNOWNHASH,a,b", \
        f"expected raw passthrough for unknown hash, got {result!r}"


def test_compression_meaningful(ch, sample_loaded, ch_database):
    # Sanity check: encoded_events table should compress at least 2x with default
    # codec on this sample. Not a strict performance test; just makes sure we
    # didn't accidentally land a schema that fails to compress.
    row = ch.query(
        f"""
        SELECT
          sum(data_uncompressed_bytes) AS u,
          sum(data_compressed_bytes)   AS c
        FROM system.parts
        WHERE database = %(d)s AND table = 'encoded_events' AND active
        """,
        parameters={"d": ch_database},
    ).first_row
    if row[0] > 0 and row[1] > 0:
        ratio = row[0] / row[1]
        assert ratio > 2.0, f"compression ratio too low: {ratio:.2f}"
