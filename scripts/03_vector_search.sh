#!/usr/bin/env bash
# Creates the Vector Search endpoint and the Delta Sync index over the reviews.
# BILLING STARTS HERE: 4 DBU/hour while an index exists. Run teardown.sh when you finish.
source "$(dirname "$0")/lib.sh"

databricks vector-search-endpoints create-endpoint bakehouse-vs STANDARD --no-wait $P || echo "(el endpoint ya existia)"
while :; do
  s=$(databricks vector-search-endpoints get-endpoint bakehouse-vs $P -o json | jq -r '.endpoint_status.state' | tr -d '\r')
  echo "endpoint: $s"
  [ "$s" = "ONLINE" ] && break
  sleep 20
done

databricks vector-search-indexes create-index --json @agent/index_spec.json $P || echo "(el indice ya existia)"
while :; do
  r=$(databricks vector-search-indexes get-index "$CATALOG.bakehouse_agent.reviews_index" $P -o json | jq -r '.status.ready' | tr -d '\r')
  echo "indice listo: $r"
  [ "$r" = "true" ] && break
  sleep 30
done
