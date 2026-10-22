#!/usr/bin/env bash
# Runs every statement of a .sql file against the workspace, one by one.
# Usage: scripts/run_sql.sh sql/01_data.sql [profile]
# Statements must end with ';' at end of line. Lines starting with '--' are ignored.
set -euo pipefail
FILE="$1"; PROFILE="${2:-returns-agent}"
python - "$FILE" <<'PY' | while IFS= read -r -d '' STMT; do
import sys,re
txt=open(sys.argv[1],encoding="utf-8").read()
txt="\n".join(l for l in txt.splitlines() if not l.strip().startswith("--"))
for s in re.split(r";\s*(?:\n|$)",txt):
    if s.strip(): sys.stdout.write(s.strip()+"\0")
PY
  echo ">> ${STMT:0:80}..."
  databricks experimental aitools tools query "$STMT" --profile "$PROFILE" | tail -3
done
