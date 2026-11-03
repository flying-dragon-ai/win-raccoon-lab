#!/usr/bin/env bash
# Primary benchmark: measure the win-raccoon cache map against the live host.
# Read-only. Emits METRIC name=value lines.
set -euo pipefail
cd "$(dirname "$0")"
exec powershell -NoProfile -ExecutionPolicy Bypass -File tools/raccoon-scan.ps1
