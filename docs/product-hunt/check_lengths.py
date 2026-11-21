#!/usr/bin/env python3
"""Counts the characters of every Product Hunt text candidate in LISTING.md.

Run: python3 docs/product-hunt/check_lengths.py

Reads each `<!-- len:KEY:LIMIT -->` marker of LISTING.md plus the quoted line (`> ...`) right below it and prints a
table (Python len(), i.e. Unicode code points). Exit code 1 if any candidate is over its limit.
"""
import pathlib
import re
import sys

text = pathlib.Path(__file__).with_name("LISTING.md").read_text(encoding="utf-8")
bad = 0
print(f"{'key':<14}{'chars':>6}{'limit':>7}  ok")
for m in re.finditer(r"^<!-- len:(\w+):(\d+) -->\s*\n> (.+)$", text, re.M):
    key, limit, body = m.group(1), int(m.group(2)), m.group(3)
    n = len(body)
    ok = n <= limit
    bad += not ok
    print(f"{key:<14}{n:>6}{limit:>7}  {'OK' if ok else 'OVER'}")
sys.exit(1 if bad else 0)
