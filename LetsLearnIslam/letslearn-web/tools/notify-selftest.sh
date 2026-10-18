#!/usr/bin/env bash
# Tests the parent-email sender (supabase/functions/notify-send) without sending anything or
# touching Supabase. Runs Deno in a throwaway Docker container, so nothing is installed on your Mac.
#   ./tools/notify-selftest.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker info >/dev/null 2>&1 || { echo "Docker is not running."; exit 30; }
docker run --rm -v "$ROOT/supabase/functions/notify-send:/app:ro" -w /app denoland/deno:alpine-2.0.6 sh -c '
  deno test --no-lock --quiet lib_test.ts && deno check --no-lock index.ts'
