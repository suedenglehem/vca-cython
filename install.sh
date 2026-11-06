#!/usr/bin/env bash
# vca installer — findable entry name; runs setup.sh from the repo root with
# all arguments passed through. See setup.sh (or README) for the flags.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup.sh" "$@"
