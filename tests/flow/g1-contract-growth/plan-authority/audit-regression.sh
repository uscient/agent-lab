#!/usr/bin/env bash
# The security gate invokes every registered suite as `bash <path>`, so the
# Python reproduction needs a shell entry point. Output and exit status pass
# straight through, including the terminal marker.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/audit-regression.py"
