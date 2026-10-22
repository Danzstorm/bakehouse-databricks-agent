#!/usr/bin/env bash
# Stops everything that bills while idle. Run when you finish a session.
#   level "pause"  : delete only the Vector Search index+endpoint (the main idle cost, 4 DBU/h)
#   level "all"    : also delete serving endpoint, app, and the whole Azure resource group
# Usage: scripts/teardown.sh pause|all [profile]
set -euo pipefail
export MSYS_NO_PATHCONV=1
LEVEL="${1:?pause|all}"; P="--profile ${2:-returns-agent}"
EP=agents_dbw_returns_agent-bakehouse_agent-bakehouse_agent

databricks vector-search-indexes delete-index dbw_returns_agent.bakehouse_agent.reviews_index $P || true
databricks vector-search-endpoints delete-endpoint bakehouse-vs $P || true

if [ "$LEVEL" = "all" ]; then
  databricks apps delete bakehouse-analyst $P || true
  databricks serving-endpoints delete $EP $P || true
  az group delete -n rg-returns-agent --yes --no-wait   # removes the workspace and its managed RG
fi
