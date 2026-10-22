#!/usr/bin/env bash
# Uploads the agent code, runs the smoke test, then logs/registers/deploys the agent to Model Serving.
source "$(dirname "$0")/lib.sh"

WH="$(warehouse_id)"
echo "Warehouse: $WH"

databricks workspace mkdirs "$WS" $P
for f in agent test_agent log_and_deploy evaluate; do
  databricks workspace import "$WS/$f.py" --file "agent/$f.py" --format RAW --overwrite $P
done

submit_job agent/job_test.json
submit_job agent/job_deploy.json

# Ready means ready == READY AND config_update == NOT_UPDATING (during a version swap "ready" alone is misleading).
while :; do
  st=$(databricks serving-endpoints get "$EP" $P -o json | jq -r '"\(.state.ready) \(.state.config_update)"' | tr -d '\r')
  echo "endpoint $EP: $st"
  [ "$st" = "READY NOT_UPDATING" ] && break
  sleep 20
done

databricks api post "/serving-endpoints/$EP/invocations" $P \
  --json '{"input":[{"role":"user","content":"¿Cuáles son las 3 franquicias con más ingresos?"}]}' \
  | jq -r '.output[-1].content[0].text'
