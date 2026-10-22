#!/usr/bin/env bash
# Shared helpers for the numbered deployment scripts. Sourced, not executed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -f "$ROOT/config.local" ]; then
  set -a; . "$ROOT/config.local"; set +a
fi
: "${DBX_USER:?Define DBX_USER en config.local (cp config.example config.local)}"

export MSYS_NO_PATHCONV=1                     # Git Bash on Windows: keep /Workspace/... paths intact
PROFILE="${PROFILE:-returns-agent}"
RG="${RG:-rg-returns-agent}"
LOCATION="${LOCATION:-eastus2}"
# Fixed names: the SQL, agent and app files reference this catalog/workspace name.
WORKSPACE_NAME="dbw-returns-agent"
CATALOG="dbw_returns_agent"
P="--profile $PROFILE"
WS="/Workspace/Users/$DBX_USER/bakehouse-agent"
APP_WS="/Workspace/Users/$DBX_USER/bakehouse-app"
EP="agents_${CATALOG}-bakehouse_agent-bakehouse_agent"
export PROFILE

require() { command -v "$1" >/dev/null || { echo "Falta '$1' en el PATH" >&2; exit 1; }; }
for tool in az databricks jq python; do require "$tool"; done

warehouse_id() {
  databricks warehouses list $P -o json | jq -r '.[0].id' | tr -d '\r'
}

# Waits for a job run to finish, prints its output and fails if it did not succeed.
wait_run() {
  local rid="$1" state result tid
  while :; do
    state=$(databricks jobs get-run "$rid" $P -o json | jq -r '.state.life_cycle_state' | tr -d '\r')
    case "$state" in TERMINATED|INTERNAL_ERROR|SKIPPED) break ;; esac
    sleep 10
  done
  result=$(databricks jobs get-run "$rid" $P -o json | jq -r '.state.result_state' | tr -d '\r')
  tid=$(databricks jobs get-run "$rid" $P -o json | jq -r '.tasks[0].run_id' | tr -d '\r')
  databricks jobs get-run-output "$tid" $P -o json | jq -r '.logs // .error // empty'
  if [ "$result" != "SUCCESS" ]; then
    databricks jobs get-run-output "$tid" $P -o json | jq -r '.error_trace // empty' | sed 's/\x1b\[[0-9;]*m//g' | tail -20
    echo "El run $rid termino con estado: $state / $result" >&2
    return 1
  fi
}

# Fills the <TU_USUARIO> / <WAREHOUSE_ID> placeholders of a job definition, submits it and waits.
submit_job() {
  local file="$1" rendered="$ROOT/.rendered_$$.json" rid
  sed "s|<TU_USUARIO>|$DBX_USER|g; s|<WAREHOUSE_ID>|$WH|g" "$file" > "$rendered"
  rid=$(databricks jobs submit --no-wait --json @"$rendered" $P -o json | jq -r '.run_id' | tr -d '\r')
  rm -f "$rendered"
  echo "Run $rid enviado: $file"
  wait_run "$rid"
}
