#!/bin/sh
# Packages only source that passes the release audit; never archives the workspace.
set -eu
cd "$(dirname "$0")/.."
exec python3 scripts/check-release.py --package "$@"
