#!/usr/bin/env bash
set -euo pipefail

# Includes generation consistency and the integration-specific manifest tests.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bash "$root/render.sh" --check
