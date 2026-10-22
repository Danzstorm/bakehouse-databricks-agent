#!/usr/bin/env bash
# Copies the sample data into our own schema (no personal data) and creates the 4 UC tool functions.
source "$(dirname "$0")/lib.sh"

./scripts/run_sql.sh sql/01_data.sql "$PROFILE"
./scripts/run_sql.sh sql/02_tools.sql "$PROFILE"

databricks experimental aitools tools query \
  "SELECT (SELECT count(*) FROM $CATALOG.bakehouse_agent.transactions) AS transactions, (SELECT count(*) FROM $CATALOG.bakehouse_agent.reviews) AS reviews" $P
