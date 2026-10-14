#!/usr/bin/env python3
"""Keep partner Sample and starter integrations on ordinary SDK imports."""
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[2]
failed = []
for directory in ('Sample/HotMicPlayerDemo', 'Examples'):
    for path in (root / directory).rglob('*.swift'):
        if not path.name.endswith('Tests.swift') and re.search(r'@(?:_spi|testable)\b', path.read_text()):
            failed.append(str(path.relative_to(root)))
if failed:
    raise SystemExit('Partner sources require public imports: ' + ', '.join(failed))
print('Partner Sample and Examples use public imports.')
