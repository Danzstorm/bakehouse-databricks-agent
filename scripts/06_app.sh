#!/usr/bin/env bash
# Creates and deploys the Streamlit chat app (Databricks Apps) with CAN_QUERY on the agent endpoint.
source "$(dirname "$0")/lib.sh"

databricks workspace import-dir app "$APP_WS" --overwrite $P

if ! databricks apps get bakehouse-analyst $P >/dev/null 2>&1; then
  databricks apps create --no-wait $P --json "{
    \"name\": \"bakehouse-analyst\",
    \"description\": \"Chat UI for the Bakehouse analyst agent\",
    \"resources\": [{\"name\": \"serving-endpoint\",
                    \"serving_endpoint\": {\"name\": \"$EP\", \"permission\": \"CAN_QUERY\"}}]}" >/dev/null
fi
while :; do
  s=$(databricks apps get bakehouse-analyst $P -o json | jq -r '.compute_status.state' | tr -d '\r')
  echo "compute: $s"
  [ "$s" = "ACTIVE" ] && break
  sleep 10
done

databricks apps deploy bakehouse-analyst --source-code-path "$APP_WS" $P >/dev/null
databricks apps get bakehouse-analyst $P -o json | jq -r '"URL: \(.url)  estado: \(.app_status.state)"'
