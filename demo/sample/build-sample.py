#!/usr/bin/env python3
"""
build-sample.py — generate a small (<1 MB) self-contained embedded sample
                  from the full OpenTelemetry-demo dataset.

The goal: produce templates.json + encoded.log + otel-sample.log files small
enough to check into the repo (the full set is 200+ MB which is impractical
for git). The trimmed sample preserves the variety of template shapes so the
demo + tests exercise zero-slot, value-slot, timestamp-slot, and multi-slot
templates.

Usage (one-shot):
  python3 build-sample.py \
      --src-templates  /path/to/full/templates.json \
      --src-encoded    /path/to/full/encoded.log \
      --src-raw        /path/to/full/otel-sample-200mb.log \
      --target-events  500
"""
import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).parent


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--src-templates', required=True)
    ap.add_argument('--src-encoded', required=True)
    ap.add_argument('--src-raw', required=True)
    ap.add_argument('--target-events', type=int, default=500)
    args = ap.parse_args()

    # Take first N encoded lines
    enc_lines = []
    used_hashes = set()
    with open(args.src_encoded, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            if len(enc_lines) >= args.target_events:
                break
            enc_lines.append(line)
            try:
                obj = json.loads(line)
                log = obj.get('log', '')
                if log.startswith('~'):
                    comma = log.find(',', 1)
                    h = log[1:comma] if comma > 0 else log[1:]
                    used_hashes.add(h)
            except Exception:
                pass

    # Keep templates referenced by the kept events (+ a few more for variety)
    tmpl_lines = []
    extra_quota = 50  # also keep some unreferenced templates for variety
    with open(args.src_templates, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            h = obj.get('templateHash', '')
            if h in used_hashes:
                tmpl_lines.append(line)
            elif extra_quota > 0:
                tmpl_lines.append(line)
                extra_quota -= 1

    # Take first N raw lines (matched 1:1 with encoded; the demo uses raw for
    # round-trip verification only)
    raw_lines = []
    with open(args.src_raw, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            if len(raw_lines) >= args.target_events:
                break
            raw_lines.append(line)

    # Write outputs
    (HERE / 'templates.json').write_text(''.join(tmpl_lines), encoding='utf-8')
    (HERE / 'encoded.log').write_text(''.join(enc_lines), encoding='utf-8')
    (HERE / 'otel-sample.log').write_text(''.join(raw_lines), encoding='utf-8')

    print(f"templates.json:  {len(tmpl_lines)} templates "
          f"({os.path.getsize(HERE / 'templates.json'):,} bytes)")
    print(f"encoded.log:     {len(enc_lines)} events "
          f"({os.path.getsize(HERE / 'encoded.log'):,} bytes)")
    print(f"otel-sample.log: {len(raw_lines)} events "
          f"({os.path.getsize(HERE / 'otel-sample.log'):,} bytes)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
