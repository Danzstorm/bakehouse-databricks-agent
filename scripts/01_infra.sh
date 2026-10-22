#!/usr/bin/env bash
# Creates the Azure resource group and Databricks workspace, the CLI profile and the catalog grant.
source "$(dirname "$0")/lib.sh"

az extension add -n databricks --only-show-errors >/dev/null 2>&1 || true
az group create -n "$RG" -l "$LOCATION" -o none
az databricks workspace create -g "$RG" -n "$WORKSPACE_NAME" -l "$LOCATION" --sku premium -o none
URL=$(az databricks workspace show -g "$RG" -n "$WORKSPACE_NAME" --query workspaceUrl -o tsv | tr -d '\r')
echo "Workspace: https://$URL"

CFG="$HOME/.databrickscfg"
if grep -q "^\[$PROFILE\]" "$CFG" 2>/dev/null; then
  grep -A3 "^\[$PROFILE\]" "$CFG" | grep -q "$URL" || {
    echo "El perfil [$PROFILE] de $CFG apunta a otro host. Editalo para usar https://$URL o cambia PROFILE en config.local." >&2
    exit 1
  }
else
  printf '\n[%s]\nhost = https://%s\nauth_type = azure-cli\n' "$PROFILE" "$URL" >> "$CFG"
fi

databricks current-user me $P | jq -r '.userName'

# The workspace catalog belongs to the admins group; registering the model from a job needs an explicit grant.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if databricks experimental aitools tools query "GRANT ALL PRIVILEGES ON CATALOG $CATALOG TO \`$DBX_USER\`" $P; then
    break
  fi
  echo "El catalogo aun no esta disponible (intento $attempt); reintentando en 30 s..."
  sleep 30
done
