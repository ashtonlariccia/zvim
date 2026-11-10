#!/bin/sh
# Build zvim and launch it from inside the sandbox.
# Usage: sandbox/run.sh [args...]   (extra args are passed to zvim)
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
(cd "$root" && zig build)
cd "$root/sandbox"
exec "$root/zig-out/bin/zvim" "$@"
