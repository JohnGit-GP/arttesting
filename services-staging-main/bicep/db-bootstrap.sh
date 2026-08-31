#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# Phase 2.5 — PostgreSQL user bootstrap
#
# Reads databases[] from services/<svc>.json, creates the app
# users and assigns database ownership on the Flex PG server.
#
# Runs the SQL from an ephemeral Kubernetes pod so it works
# even when the local machine has no network path to PG (common
# in Gov Cloud with restricted egress).
#
# Idempotent — safe to re-run. Missing declarations are a no-op.
#
# Usage: ./bicep/db-bootstrap.sh <service> <env>
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env/azure.env"

SERVICE="${1:?Usage: db-bootstrap.sh <service> <env>}"
ENV="${2:?Usage: db-bootstrap.sh <service> <env>}"

SERVICE_JSON="${SCRIPT_DIR}/services/${SERVICE}.json"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

for file in "$SERVICE_JSON" "$ENV_FILE"; do
  [ -f "$file" ] || { echo -e "${RED}ERROR: Missing $file${NC}"; exit 1; }
done

# shellcheck disable=SC1090
source "$ENV_FILE"

DATABASES=$(jq -c '.databases // []' "$SERVICE_JSON")
DB_COUNT=$(echo "$DATABASES" | jq 'length')

if [ "$DB_COUNT" -eq 0 ]; then
  echo "  No databases[] declared in ${SERVICE}.json — skipping."
  exit 0
fi

# ── Dependencies ──
for cmd in az jq kubectl openssl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo -e "${RED}ERROR: '$cmd' is required.${NC}"; exit 1;
  }
done

# ── Discover PG server ──
PG_SERVER_NAME=$(az postgres flexible-server list \
  -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || echo "")

if [ -z "$PG_SERVER_NAME" ]; then
  echo -e "${YELLOW}  WARNING: No PostgreSQL server found in ${RESOURCE_GROUP} — skipping bootstrap.${NC}"
  exit 0
fi

PG_FQDN=$(az postgres flexible-server list \
  -g "$RESOURCE_GROUP" --query "[0].fullyQualifiedDomainName" -o tsv)

PG_ADMIN_USER=$(az postgres flexible-server show \
  -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" \
  --query "administratorLogin" -o tsv)

if [ -z "${KEY_VAULT_NAME:-}" ]; then
  echo -e "${RED}ERROR: KEY_VAULT_NAME not set in azure.env.${NC}"
  exit 1
fi

PG_ADMIN_PASSWORD=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" \
  --name "${SERVICE}-pg-admin-password" --query value -o tsv 2>/dev/null || echo "")

if [ -z "$PG_ADMIN_PASSWORD" ]; then
  echo -e "${RED}ERROR: Secret '${SERVICE}-pg-admin-password' not found in Key Vault ${KEY_VAULT_NAME}${NC}"
  echo -e "${RED}       Run Phase 1 (wizard) first: ./bicep/deploy.sh ${SERVICE} ${ENV} --confirm --secrets${NC}"
  exit 1
fi

echo "  Server:      ${PG_SERVER_NAME}"
echo "  FQDN:        ${PG_FQDN}"
echo "  Admin user:  ${PG_ADMIN_USER}"

# ── Ensure AKS egress IP is allowed through PG firewall ──
# Pods launched via kubectl exit via the cluster's outbound IP. If that IP
# isn't in the PG firewall, the pod's psql will hang on connect.
AKS_EGRESS_IP=$(az aks show \
  -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" \
  --query "networkProfile.loadBalancerProfile.effectiveOutboundIPs[0].id" -o tsv 2>/dev/null | \
  xargs -I{} az resource show --ids {} --query "properties.ipAddress" -o tsv 2>/dev/null || echo "")

if [ -n "$AKS_EGRESS_IP" ]; then
  EXISTING_IP=$(az postgres flexible-server firewall-rule list \
    -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" \
    --query "[?name=='aks-egress'].startIpAddress | [0]" -o tsv 2>/dev/null || echo "")

  if [ "$EXISTING_IP" != "$AKS_EGRESS_IP" ]; then
    echo "  Updating PG firewall rule 'aks-egress' → ${AKS_EGRESS_IP}"
    az postgres flexible-server firewall-rule create \
      -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" \
      --rule-name aks-egress \
      --start-ip-address "$AKS_EGRESS_IP" \
      --end-ip-address "$AKS_EGRESS_IP" \
      --output none 2>/dev/null || \
    az postgres flexible-server firewall-rule update \
      -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" \
      --rule-name aks-egress \
      --start-ip-address "$AKS_EGRESS_IP" \
      --end-ip-address "$AKS_EGRESS_IP" \
      --output none
  else
    echo "  PG firewall rule 'aks-egress' already current (${AKS_EGRESS_IP})"
  fi
fi

# ── Build SQL ──
# Use PostgreSQL dollar-quoted strings with a random tag so the password
# doesn't need shell escaping. As long as the password doesn't literally
# contain '$<tag>$', which is vanishingly unlikely with a 12-hex-char tag.
QTAG="q$(openssl rand -hex 6)"
SQL=""

mapfile -t DB_ARR < <(echo "$DATABASES" | jq -c '.[]')
for db in "${DB_ARR[@]}"; do
  APP_USER=$(echo "$db" | jq -r '.user')
  PW_VAR=$(echo "$db" | jq -r '.passwordVar')
  CREATEDB=$(echo "$db" | jq -r '.createDb // false')

  # Resolve password from KV
  KV_SECRET="${SERVICE}-$(echo "$PW_VAR" | tr '[:upper:]_' '[:lower:]-')"
  APP_PW=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" \
    --name "$KV_SECRET" --query value -o tsv 2>/dev/null || echo "")

  if [ -z "$APP_PW" ]; then
    echo -e "${RED}ERROR: Secret '${KV_SECRET}' not found in Key Vault.${NC}"
    exit 1
  fi

  # Guard against passwords that collide with our dollar-quote tag
  if [[ "$APP_PW" == *"\$${QTAG}\$"* ]]; then
    echo -e "${RED}ERROR: Password for '${APP_USER}' collides with dollar-quote tag. Re-run to get a new tag.${NC}"
    exit 1
  fi

  CREATEDB_OPT=""
  [ "$CREATEDB" = "true" ] && CREATEDB_OPT="CREATEDB"

  # Validate identifier (reject anything that isn't a safe PostgreSQL identifier)
  if ! [[ "$APP_USER" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    echo -e "${RED}ERROR: Invalid role name '${APP_USER}' (must match [a-z_][a-z0-9_]*).${NC}"
    exit 1
  fi

  SQL+="-- ── Role: ${APP_USER} ──
DO \$BOOT\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_USER}') THEN
    EXECUTE format('CREATE ROLE ${APP_USER} WITH LOGIN ${CREATEDB_OPT} PASSWORD %L', \$${QTAG}\$${APP_PW}\$${QTAG}\$);
  ELSE
    EXECUTE format('ALTER ROLE ${APP_USER} WITH LOGIN ${CREATEDB_OPT} PASSWORD %L', \$${QTAG}\$${APP_PW}\$${QTAG}\$);
  END IF;
END
\$BOOT\$;
"

  # Ownership assignments
  OWNED_DBS=$(echo "$db" | jq -r '.ownsDatabases[]? // empty')
  for odb in $OWNED_DBS; do
    if ! [[ "$odb" =~ ^[a-z_][a-z0-9_]*$ ]]; then
      echo -e "${RED}ERROR: Invalid database name '${odb}'.${NC}"
      exit 1
    fi
    SQL+="ALTER DATABASE ${odb} OWNER TO ${APP_USER};
\\connect ${odb}
ALTER SCHEMA public OWNER TO ${APP_USER};
GRANT ALL ON SCHEMA public TO ${APP_USER};
GRANT CREATE ON SCHEMA public TO ${APP_USER};
\\connect postgres
"
  done
  SQL+="
"
done

# ── Run SQL via ephemeral pod ──
POD_NS="default"
POD_NAME="pg-bootstrap-${SERVICE}-$$"

# Ensure kubeconfig is current
az aks get-credentials \
  --resource-group "$AKS_RESOURCE_GROUP" \
  --name "$AKS_CLUSTER_NAME" \
  --overwrite-existing >/dev/null 2>&1

echo "  Applying SQL via ephemeral pod ${POD_NAME} (namespace: ${POD_NS})..."

# Feed SQL via stdin to avoid writing secrets to disk
if echo "$SQL" | kubectl run "$POD_NAME" -n "$POD_NS" --rm -i --restart=Never \
    --image=postgres:16 \
    --env="PGPASSWORD=$PG_ADMIN_PASSWORD" -- \
    psql "host=${PG_FQDN} dbname=postgres user=${PG_ADMIN_USER} sslmode=require" -v ON_ERROR_STOP=1; then
  echo -e "  ${GREEN}Database users bootstrapped.${NC}"
else
  echo -e "${RED}  ERROR: Bootstrap SQL failed. See pod output above.${NC}"
  exit 1
fi