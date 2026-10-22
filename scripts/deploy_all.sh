#!/usr/bin/env bash
# Runs every deployment step in order. Each step can also be run on its own.
set -euo pipefail
cd "$(dirname "$0")"

for step in 01_infra 02_data 03_vector_search 04_agent 05_eval 06_app; do
  echo
  echo "=== $step ==="
  ./"$step".sh
done

echo
echo "Listo. Al terminar ejecuta: ./scripts/teardown.sh pause   (o 'all')"
