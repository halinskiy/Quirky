#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tests/check-browser-safety.py
out=$(mktemp -d /tmp/quirky-browser-tests.XXXXXX)
trap 'rm -rf "$out"' EXIT
swiftc Quirky/BrowserAutomation.swift Quirky/DOMExtractor.swift Quirky/SVGExtractor.swift Tests/BrowserAutomationTests.swift -o "$out/tests"
"$out/tests"
