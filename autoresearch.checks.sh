#!/usr/bin/env bash
# Correctness gate: safety policy, independent re-measure, read-only scanner,
# fixture probe accuracy. Runs after every passing benchmark.
set -euo pipefail
cd "$(dirname "$0")"
exec powershell -NoProfile -ExecutionPolicy Bypass -File tools/raccoon-validate.ps1
