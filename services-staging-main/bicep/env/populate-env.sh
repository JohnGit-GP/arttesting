#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# populate-env.sh — discover SHARED Azure infrastructure for azure.env
#
# Discovers values that are common to all services in the subscription:
#   AKS cluster, VNet + PE subnet, ACR, public DNS zone, location, Istio.
#
# Does NOT touch per-service resources (Key Vault, PostgreSQL, Storage
# Account). Those are owned by deploy.sh: it creates them via Bicep and
# writes the resulting names back into azure.env on success. Auto-
# discovering them here is a footgun — `az keyvault list "[0]"` happily
# returns ANY vault in the subscription, after which deploy.sh would
# pass it to Bicep as existingKeyVaultName and write the new service's
# secrets into someone else's vault.
#
# On re-run, existing per-service values in azure.env are preserved.
#
# Usage:
#   ./bicep/env/populate-env.sh              # discover and write
#   ./bicep/env/populate-env.sh --dry-run    # show what would be written
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/azure.env"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

found() { printf "  ${GREEN}%-35s${NC} %s\n" "$1" "$2"; }
missing() { printf "  ${YELLOW}%-35s${NC} (not found)\n" "$1"; }
header() { echo ""; echo -e "${BOLD}── $1 ──${NC}"; }

# ── Verify Azure CLI ──
if ! command -v az &>/dev/null; then
  echo -e "${RED}ERROR: az CLI not found. Install it or run from a machine with az CLI.${NC}"
  exit 1
fi

CLOUD=$(az cloud show --query name -o tsv 2>/dev/null || echo "unknown")
echo -e "${BOLD}Azure Cloud:${NC} ${CLOUD}"

SUB_JSON=$(az account show --query '{name:name, id:id}' -o json 2>/dev/null || echo '{}')
SUB_NAME=$(echo "$SUB_JSON" | jq -r '.name // "unknown"')
SUB_ID=$(echo "$SUB_JSON" | jq -r '.id // empty')
echo -e "${BOLD}Subscription:${NC} ${SUB_NAME} (${SUB_ID})"

# ── Preserve per-service fields from any existing azure.env ──
# These are populated by deploy.sh's stack-output writeback and must
# survive a populate-env re-run.
PRESERVED_KEY_VAULT_NAME=""
PRESERVED_PG_SERVER_NAME=""
PRESERVED_PG_ADMIN_USER="pgadmin"
PRESERVED_STORAGE_ACCOUNT_NAME=""
if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  PRESERVED_KEY_VAULT_NAME="${KEY_VAULT_NAME:-}"
  PRESERVED_PG_SERVER_NAME="${PG_SERVER_NAME:-}"
  PRESERVED_PG_ADMIN_USER="${PG_ADMIN_USER:-pgadmin}"
  PRESERVED_STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-}"
fi

# ── Discover SHARED resources ──

# AKS
header "AKS Cluster"
AKS_JSON=$(az aks list --query "[0].{name:name, rg:resourceGroup, vnetSubnetId:agentPoolProfiles[0].vnetSubnetId}" -o json 2>/dev/null || echo "null")
AKS_CLUSTER_NAME=$(echo "$AKS_JSON" | jq -r '.name // empty')
AKS_RESOURCE_GROUP=$(echo "$AKS_JSON" | jq -r '.rg // empty')
AKS_SUBNET_ID=$(echo "$AKS_JSON" | jq -r '.vnetSubnetId // empty')

if [ -n "$AKS_CLUSTER_NAME" ]; then
  found "AKS_CLUSTER_NAME" "$AKS_CLUSTER_NAME"
  found "AKS_RESOURCE_GROUP" "$AKS_RESOURCE_GROUP"

  # Derive VNet from AKS node subnet
  if [ -n "$AKS_SUBNET_ID" ]; then
    # /subscriptions/.../resourceGroups/<RG>/providers/Microsoft.Network/virtualNetworks/<VNET>/subnets/<SUBNET>
    VNET_NAME=$(echo "$AKS_SUBNET_ID" | sed -n 's|.*/virtualNetworks/\([^/]*\)/.*|\1|p')
    VNET_RESOURCE_GROUP=$(echo "$AKS_SUBNET_ID" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')
    found "VNET_NAME (from AKS)" "$VNET_NAME"
    found "VNET_RESOURCE_GROUP" "$VNET_RESOURCE_GROUP"
  fi
else
  missing "AKS_CLUSTER_NAME"
  missing "AKS_RESOURCE_GROUP"
  AKS_CLUSTER_NAME=""
  AKS_RESOURCE_GROUP=""
fi

# VNet — find PE subnet if VNet was discovered
header "Virtual Network"
VNET_NAME="${VNET_NAME:-}"
VNET_RESOURCE_GROUP="${VNET_RESOURCE_GROUP:-}"
PE_SUBNET_NAME=""

if [ -z "$VNET_NAME" ] || [ -z "$VNET_RESOURCE_GROUP" ]; then
  # Fall back to subscription-wide VNet list (picks first — may need manual edit if multiple)
  VNET_JSON=$(az network vnet list --query "[0].{name:name, rg:resourceGroup}" -o json 2>/dev/null || echo "null")
  VNET_NAME=$(echo "$VNET_JSON" | jq -r '.name // empty')
  VNET_RESOURCE_GROUP=$(echo "$VNET_JSON" | jq -r '.rg // empty')
fi

if [ -n "$VNET_NAME" ] && [ -n "$VNET_RESOURCE_GROUP" ]; then
  found "VNET_NAME" "$VNET_NAME"
  found "VNET_RESOURCE_GROUP" "$VNET_RESOURCE_GROUP"

  PE_SUBNET_NAME=$(az network vnet subnet list \
    --resource-group "$VNET_RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --query "[?contains(name, 'private') || contains(name, 'endpoint') || contains(name, 'pe') || contains(name, 'PE')].name | [0]" \
    -o tsv 2>/dev/null || echo "")

  if [ -n "$PE_SUBNET_NAME" ]; then
    found "PE_SUBNET_NAME" "$PE_SUBNET_NAME"
  else
    ALL_SUBNETS=$(az network vnet subnet list \
      --resource-group "$VNET_RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --query "[].name" -o tsv 2>/dev/null || echo "")
    echo -e "  ${YELLOW}No PE subnet auto-matched. Available subnets:${NC}"
    echo "$ALL_SUBNETS" | sed 's/^/    /'
    echo -e "  ${YELLOW}→ Edit ${ENV_FILE} and set PE_SUBNET_NAME manually before deploying.${NC}"
  fi
else
  missing "VNET_NAME"
  missing "VNET_RESOURCE_GROUP"
fi

# ACR
header "Container Registry (ACR)"
ACR_JSON=$(az acr list --query "[0].{name:name, rg:resourceGroup}" -o json 2>/dev/null || echo "null")
ACR_NAME=$(echo "$ACR_JSON" | jq -r '.name // empty')
ACR_RESOURCE_GROUP=$(echo "$ACR_JSON" | jq -r '.rg // empty')

if [ -n "$ACR_NAME" ]; then
  found "ACR_NAME" "$ACR_NAME"
  found "ACR_RESOURCE_GROUP" "$ACR_RESOURCE_GROUP"
else
  missing "ACR_NAME"
  missing "ACR_RESOURCE_GROUP"
  ACR_NAME=""
  ACR_RESOURCE_GROUP=""
fi

# DNS (public zone — used for ingress, shared across services)
header "DNS Zone"
DNS_JSON=$(az network dns zone list --query "[0].{name:name, rg:resourceGroup}" -o json 2>/dev/null || echo "null")
DNS_ZONE_NAME=$(echo "$DNS_JSON" | jq -r '.name // empty')
DNS_RESOURCE_GROUP=$(echo "$DNS_JSON" | jq -r '.rg // empty')

if [ -n "$DNS_ZONE_NAME" ]; then
  found "DNS_ZONE_NAME" "$DNS_ZONE_NAME"
  found "DNS_RESOURCE_GROUP" "$DNS_RESOURCE_GROUP"
else
  missing "DNS_ZONE_NAME"
  missing "DNS_RESOURCE_GROUP"
  DNS_ZONE_NAME=""
  DNS_RESOURCE_GROUP=""
fi

# Istio revision
header "Istio"
ISTIO_REVISION=""
if [ -n "$AKS_CLUSTER_NAME" ]; then
  ISTIO_REVISION=$(kubectl get pods -n aks-istio-system -l app=istiod \
    -o jsonpath='{.items[0].metadata.labels.istio\.io/rev}' 2>/dev/null || echo "")
fi
if [ -n "$ISTIO_REVISION" ]; then
  found "ISTIO_REVISION" "$ISTIO_REVISION"
else
  ISTIO_REVISION="asm-1-27"
  found "ISTIO_REVISION (default)" "$ISTIO_REVISION"
fi

# ── Per-service fields (preserved, not discovered) ──
header "Per-service resources (preserved from existing azure.env)"
echo "  KEY_VAULT_NAME, PG_SERVER_NAME, STORAGE_ACCOUNT_NAME are owned by"
echo "  deploy.sh — it creates them via Bicep and writes them back here."
[ -n "$PRESERVED_KEY_VAULT_NAME" ]       && found "KEY_VAULT_NAME"       "$PRESERVED_KEY_VAULT_NAME"
[ -n "$PRESERVED_PG_SERVER_NAME" ]       && found "PG_SERVER_NAME"       "$PRESERVED_PG_SERVER_NAME"
[ -n "$PRESERVED_STORAGE_ACCOUNT_NAME" ] && found "STORAGE_ACCOUNT_NAME" "$PRESERVED_STORAGE_ACCOUNT_NAME"

# ── Determine location from AKS resource group ──
LOCATION=""
if [ -n "$AKS_RESOURCE_GROUP" ]; then
  LOCATION=$(az group show --name "$AKS_RESOURCE_GROUP" --query location -o tsv 2>/dev/null || echo "")
fi
LOCATION="${LOCATION:-usgovvirginia}"

# ── Compose env file ──
echo ""
echo -e "${BOLD}══════════════════════════════════════${NC}"

ENV_CONTENT="# ══════════════════════════════════════════════════════════════
# Azure Environment — populated by populate-env.sh (shared infra) and
# deploy.sh (per-service: KV / PG / Storage names from stack outputs).
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Cloud: ${CLOUD}
# Subscription: ${SUB_NAME}
# ══════════════════════════════════════════════════════════════

# ── Azure Subscription & Location ──
AZURE_CLOUD=\"${CLOUD}\"
LOCATION=\"${LOCATION}\"
SUBSCRIPTION_ID=\"${SUB_ID}\"

# ── Resource Groups ──
RESOURCE_GROUP=\"${AKS_RESOURCE_GROUP}\"
AKS_RESOURCE_GROUP=\"${AKS_RESOURCE_GROUP}\"
VNET_RESOURCE_GROUP=\"${VNET_RESOURCE_GROUP}\"
ACR_RESOURCE_GROUP=\"${ACR_RESOURCE_GROUP}\"

# ── AKS Cluster ──
AKS_CLUSTER_NAME=\"${AKS_CLUSTER_NAME}\"
ISTIO_REVISION=\"${ISTIO_REVISION}\"

# ── Container Registry ──
ACR_NAME=\"${ACR_NAME}\"

# ── Virtual Network ──
VNET_NAME=\"${VNET_NAME}\"
PE_SUBNET_NAME=\"${PE_SUBNET_NAME}\"

# ── DNS (public zone, shared) ──
DNS_ZONE_NAME=\"${DNS_ZONE_NAME}\"
DNS_RESOURCE_GROUP=\"${DNS_RESOURCE_GROUP}\"

# ══════════════════════════════════════════════════════════════
# Per-service resources — DO NOT auto-populate.
# deploy.sh writes these back from Bicep stack outputs after a
# successful infra deploy. Leave blank for a fresh service so a
# new dedicated resource is created. Set manually only if you are
# adopting an existing resource.
# ══════════════════════════════════════════════════════════════
KEY_VAULT_NAME=\"${PRESERVED_KEY_VAULT_NAME}\"
PG_SERVER_NAME=\"${PRESERVED_PG_SERVER_NAME}\"
PG_ADMIN_USER=\"${PRESERVED_PG_ADMIN_USER}\"
STORAGE_ACCOUNT_NAME=\"${PRESERVED_STORAGE_ACCOUNT_NAME}\"

# ══════════════════════════════════════════════════════════════
# Secrets — collected by deploy.sh --secrets at deploy time and
# pre-populated into the Key Vault by Bicep. DO NOT store here.
#
#   PG_ADMIN_PASSWORD       — PostgreSQL admin password
#   MASTER_KEY              — openssl rand -hex 32
#   JOIN_KEY                — openssl rand -hex 32
#   ARTIFACTORY_DB_PASSWORD — per-service DB user password
#   XRAY_DB_PASSWORD        — per-service DB user password
#   DISTRIBUTION_DB_PASSWORD — per-service DB user password
#   RABBITMQ_PASSWORD       — openssl rand -base64 24
#   ERLANG_COOKIE           — openssl rand -hex 32
#   STORAGE_ACCOUNT_KEY     — fetched in Phase 2.5 after storage exists
# ══════════════════════════════════════════════════════════════"

if [ "$DRY_RUN" = true ]; then
  echo -e "${BOLD}  DRY RUN — would write to: ${ENV_FILE}${NC}"
  echo -e "${BOLD}══════════════════════════════════════${NC}"
  echo ""
  echo "$ENV_CONTENT"
else
  echo "$ENV_CONTENT" > "$ENV_FILE"
  echo -e "${GREEN}${BOLD}  Written to: ${ENV_FILE}${NC}"
  echo -e "${BOLD}══════════════════════════════════════${NC}"

  # Tally shared infra only (per-service is not this script's job)
  TOTAL=9
  FOUND=0
  for val in "$AKS_CLUSTER_NAME" "$AKS_RESOURCE_GROUP" "$VNET_NAME" "$VNET_RESOURCE_GROUP" \
             "$PE_SUBNET_NAME" "$ACR_NAME" "$ACR_RESOURCE_GROUP" "$DNS_ZONE_NAME" "$DNS_RESOURCE_GROUP"; do
    [ -n "$val" ] && FOUND=$((FOUND + 1))
  done

  echo ""
  echo -e "  Shared infra: ${GREEN}${FOUND}${NC} / ${TOTAL} values found"
  if [ $FOUND -lt $TOTAL ]; then
    echo -e "  ${YELLOW}Edit ${ENV_FILE} to fill in any missing shared values${NC}"
  fi
  echo ""
  echo "  Next steps:"
  echo "    1. Review:  cat bicep/env/azure.env"
  echo "    2. Dry run: ./bicep/deploy.sh artifactory dev"
  echo "    3. Deploy:  ./bicep/deploy.sh artifactory dev --confirm --secrets"
fi