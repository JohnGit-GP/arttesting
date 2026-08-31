#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# Jumpbox Preflight Check
# Verifies tooling, auth, permissions, networking, and repo state
# before running deploy.sh on a fresh jumpbox.
#
# Usage:
#   ./bicep/preflight.sh <service> <env>
#   ./bicep/preflight.sh artifactory dev
#
# Exits non-zero on any critical failure. Warnings don't block.
# ══════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env/azure.env"

SERVICE="${1:-artifactory}"
ENV="${2:-dev}"
PARAM_FILE="${SCRIPT_DIR}/params/${SERVICE}.${ENV}.bicepparam"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

FAIL_COUNT=0
WARN_COUNT=0

pass()  { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
fail()  { printf "  ${RED}✗${NC} %s\n" "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn()  { printf "  ${YELLOW}!${NC} %s\n" "$1"; WARN_COUNT=$((WARN_COUNT + 1)); }
info()  { printf "  ${CYAN}i${NC} %s\n" "$1"; }
hdr()   { echo ""; echo -e "${BOLD}── $1 ──${NC}"; }

# ──────────────────────────────────────────────
hdr "1. Required tooling"
# ──────────────────────────────────────────────
for tool in az kubectl helm jq curl git openssl envsubst; do
  if command -v "$tool" &>/dev/null; then
    VERSION=$("$tool" --version 2>&1 | head -1 | awk '{print $NF}' || echo "?")
    pass "$tool present ($VERSION)"
  else
    fail "$tool not found"
  fi
done

# ──────────────────────────────────────────────
hdr "2. Azure cloud + authentication"
# ──────────────────────────────────────────────
CLOUD=$(az cloud show --query name -o tsv 2>/dev/null || echo "")
if [ "$CLOUD" = "AzureUSGovernment" ]; then
  pass "az cloud set to AzureUSGovernment"
else
  fail "az cloud is '$CLOUD', expected AzureUSGovernment (fix: az cloud set --name AzureUSGovernment)"
fi

SUB_ID=$(az account show --query id -o tsv 2>/dev/null || echo "")
if [ -n "$SUB_ID" ]; then
  SUB_NAME=$(az account show --query name -o tsv 2>/dev/null || echo "")
  USER=$(az account show --query user.name -o tsv 2>/dev/null || echo "")
  pass "logged in as $USER"
  info "subscription: $SUB_NAME ($SUB_ID)"
else
  fail "not logged in to Azure (fix: az login --use-device-code)"
fi

# ──────────────────────────────────────────────
hdr "3. Environment file"
# ──────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  pass "azure.env present: $ENV_FILE"
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  for var in SUBSCRIPTION_ID RESOURCE_GROUP AKS_RESOURCE_GROUP AKS_CLUSTER_NAME \
             VNET_NAME VNET_RESOURCE_GROUP ACR_NAME; do
    if [ -n "${!var:-}" ]; then
      pass "$var = ${!var}"
    else
      fail "$var is empty in azure.env"
    fi
  done

  # PE_SUBNET_NAME: critical only if bicepparam has deployPrivateEndpoints=true
  PRIV_ENDPOINTS="unknown"
  if [ -f "$PARAM_FILE" ]; then
    if grep -qE '^param\s+deployPrivateEndpoints\s*=\s*true' "$PARAM_FILE"; then
      PRIV_ENDPOINTS="true"
    elif grep -qE '^param\s+deployPrivateEndpoints\s*=\s*false' "$PARAM_FILE"; then
      PRIV_ENDPOINTS="false"
    fi
  fi
  if [ "$PRIV_ENDPOINTS" = "true" ] && [ -z "${PE_SUBNET_NAME:-}" ]; then
    fail "PE_SUBNET_NAME empty but bicepparam has deployPrivateEndpoints=true (fix: set in azure.env)"
  elif [ -n "${PE_SUBNET_NAME:-}" ]; then
    pass "PE_SUBNET_NAME = $PE_SUBNET_NAME"
  else
    info "PE_SUBNET_NAME empty (OK when deployPrivateEndpoints=false)"
  fi
else
  fail "azure.env not found at $ENV_FILE (run: ./bicep/env/populate-env.sh)"
fi

# ──────────────────────────────────────────────
hdr "4. Bicepparam file"
# ──────────────────────────────────────────────
if [ -f "$PARAM_FILE" ]; then
  pass "bicepparam present: $PARAM_FILE"
  info "deployPrivateEndpoints = $PRIV_ENDPOINTS"
else
  fail "bicepparam not found: $PARAM_FILE"
fi

# ──────────────────────────────────────────────
hdr "5. Identity permissions"
# ──────────────────────────────────────────────
if [ -n "$SUB_ID" ] && [ -n "${RESOURCE_GROUP:-}" ]; then
  ME=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
  if [ -z "$ME" ]; then
    # Fall back to SP / managed identity
    ME=$(az account show --query user.name -o tsv 2>/dev/null || echo "")
  fi

  # Contributor (or higher) on the application RG
  ROLES=$(az role assignment list --assignee "$ME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "[].roleDefinitionName" -o tsv 2>/dev/null)
  if echo "$ROLES" | grep -qE '^(Contributor|Owner|User Access Administrator)$'; then
    pass "has Contributor-equivalent on $RESOURCE_GROUP"
  else
    warn "no Contributor/Owner on $RESOURCE_GROUP (roles: ${ROLES:-none}) — deploy may fail"
  fi

  # AKS admin
  if [ -n "${AKS_CLUSTER_NAME:-}" ] && [ -n "${AKS_RESOURCE_GROUP:-}" ]; then
    AKS_ROLES=$(az role assignment list --assignee "$ME" \
      --scope "/subscriptions/$SUB_ID/resourceGroups/$AKS_RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$AKS_CLUSTER_NAME" \
      --query "[].roleDefinitionName" -o tsv 2>/dev/null)
    if echo "$AKS_ROLES" | grep -qE 'Azure Kubernetes Service Cluster (Admin|User) Role'; then
      pass "has AKS access role"
    else
      warn "no direct AKS role assignment (may still work via RBAC inheritance)"
    fi
  fi
else
  warn "skipping role check (need SUB_ID + RESOURCE_GROUP first)"
fi

# ──────────────────────────────────────────────
hdr "6. Network reachability"
# ──────────────────────────────────────────────
if timeout 5 curl -sIf https://management.usgovcloudapi.net >/dev/null 2>&1; then
  pass "Azure management plane reachable (443)"
else
  fail "cannot reach management.usgovcloudapi.net (check jumpbox egress / NSG)"
fi

JUMPBOX_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$JUMPBOX_IP" ]; then
  pass "jumpbox private IP: $JUMPBOX_IP"
else
  warn "could not determine jumpbox private IP"
fi

# Privatelink zone linkage (for the AKS VNet — jumpbox should ideally share or peer)
if [ -n "${VNET_RESOURCE_GROUP:-}" ]; then
  for zone in privatelink.vaultcore.usgovcloudapi.net \
              privatelink.blob.core.usgovcloudapi.net \
              privatelink.postgres.database.usgovcloudapi.net; do
    ZONE_EXISTS=$(az network private-dns zone show -g "$VNET_RESOURCE_GROUP" -n "$zone" \
                    --query name -o tsv 2>/dev/null || echo "")
    if [ -n "$ZONE_EXISTS" ]; then
      LINK_COUNT=$(az network private-dns link vnet list -g "$VNET_RESOURCE_GROUP" -z "$zone" \
                     --query "length(@)" -o tsv 2>/dev/null || echo 0)
      if [ "$LINK_COUNT" -gt 0 ]; then
        pass "$zone exists, $LINK_COUNT VNet link(s)"
      else
        warn "$zone exists but has 0 VNet links (DNS won't resolve privately)"
      fi

      # Check for stale A records (point to IPs that may no longer exist)
      STALE=$(az network private-dns record-set a list -g "$VNET_RESOURCE_GROUP" -z "$zone" \
                --query "[?name!='@'].name" -o tsv 2>/dev/null | wc -l)
      if [ "$STALE" -gt 0 ]; then
        info "$zone has $STALE A record(s) — verify they match current PEs"
      fi
    else
      info "$zone does not exist yet (Bicep will create)"
    fi
  done
fi

# ──────────────────────────────────────────────
hdr "7. AKS access"
# ──────────────────────────────────────────────
if [ -n "${AKS_CLUSTER_NAME:-}" ] && [ -n "${AKS_RESOURCE_GROUP:-}" ]; then
  # Try to merge creds (idempotent)
  if az aks get-credentials -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" \
       --overwrite-existing --only-show-errors >/dev/null 2>&1; then
    pass "az aks get-credentials succeeded"
    # Test API reachability
    if timeout 10 kubectl get --raw /readyz >/dev/null 2>&1; then
      pass "AKS API server reachable via kubectl"
      NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
      pass "$NODE_COUNT node(s) visible"
    else
      warn "kubectl can't reach AKS API (private API server? jumpbox not peered?)"
    fi
  else
    warn "az aks get-credentials failed (missing AKS role?)"
  fi
else
  warn "skipping AKS check (AKS_CLUSTER_NAME or AKS_RESOURCE_GROUP empty)"
fi

# ──────────────────────────────────────────────
hdr "8. Helm repo"
# ──────────────────────────────────────────────
if command -v helm &>/dev/null; then
  if [ -f "$SCRIPT_DIR/services/${SERVICE}.json" ]; then
    REPO_NAME=$(jq -r '.helm.repoName // empty' "$SCRIPT_DIR/services/${SERVICE}.json" 2>/dev/null)
    REPO_URL=$(jq -r '.helm.repoUrl // empty' "$SCRIPT_DIR/services/${SERVICE}.json" 2>/dev/null)
    if [ -n "$REPO_NAME" ] && helm repo list 2>/dev/null | grep -q "^$REPO_NAME\s"; then
      pass "helm repo '$REPO_NAME' already added"
    elif [ -n "$REPO_NAME" ]; then
      info "helm repo '$REPO_NAME' not added yet (fix: helm repo add $REPO_NAME $REPO_URL)"
    fi
  fi
fi

# ──────────────────────────────────────────────
hdr "Summary"
# ──────────────────────────────────────────────
if [ $FAIL_COUNT -eq 0 ] && [ $WARN_COUNT -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}All checks passed. Ready to deploy.${NC}"
  exit 0
elif [ $FAIL_COUNT -eq 0 ]; then
  echo -e "  ${YELLOW}${BOLD}$WARN_COUNT warning(s), no failures. Review and proceed with caution.${NC}"
  exit 0
else
  echo -e "  ${RED}${BOLD}$FAIL_COUNT failure(s), $WARN_COUNT warning(s). Fix failures before deploying.${NC}"
  exit 1
fi
