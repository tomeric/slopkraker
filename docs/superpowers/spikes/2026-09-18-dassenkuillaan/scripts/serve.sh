#!/usr/bin/env bash
# THROWAWAY. Serves the spike worlds from a SQLite database of their own, so the dev
# database and its hand-made worlds are never touched. First run prepares the database
# (schema + the four fixture worlds); every run rebuilds the two spike worlds.
set -euo pipefail
cd "$(dirname "$0")/../../../../.."
export DATABASE_URL="sqlite3:storage/spike-dassenkuil.sqlite3"
if [ ! -f storage/spike-dassenkuil.sqlite3 ]; then
  echo "== preparing storage/spike-dassenkuil.sqlite3"
  bin/rails db:prepare
fi
exec bin/rails runner docs/superpowers/spikes/2026-09-18-dassenkuillaan/scripts/spike_server.rb
