#!/usr/bin/env python3
"""Regression guard: supported browser lookup must never change browser preferences."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
files = [root / 'Quirky' / name for name in ('DOMExtractor.swift', 'SVGExtractor.swift', 'BrowserAutomation.swift')]
sources = [p.read_text() for p in files if p.exists()]
assert any('"com.3mpq.nothing"' in s for s in sources), 'Nothing must be a supported Chromium browser'
for p in files:
    if p.exists():
        s = p.read_text()
        assert '"/usr/bin/defaults"' not in s, f'{p.name} must not write browser settings'
        assert 'ensureJSEnabled' not in s and 'ensureSafariJSEnabled' not in s, f'{p.name} must not enable JavaScript silently'
print('PASS: Nothing supported; browser detection does not mutate preferences')
