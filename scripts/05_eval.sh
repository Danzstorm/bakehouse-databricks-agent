#!/usr/bin/env bash
# Runs the MLflow evaluation (8 questions, 3 scorers) as a serverless job.
source "$(dirname "$0")/lib.sh"

WH="$(warehouse_id)"
submit_job agent/job_eval.json
