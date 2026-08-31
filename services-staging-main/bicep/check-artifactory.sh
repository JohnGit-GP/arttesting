#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# Read-only audit: what's needed to Helm-deploy Artifactory and
# what's already in place. Makes no changes.
#
# Usage:
#   ./bicep/check-artifactory.sh
# ══════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env/azure.env"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

OK_COUNT=0
MISSING_COUNT=0
WARN_COUNT=0

declare -a TODO=()

ok()   { echo -e "  ${GREEN}OK${NC}      $*"; OK_COUNT=$((OK_COUNT+1)); }
miss() { echo -e "  ${RED}MISSING${NC} $*"; MISSING_COUNT=$((MISSING_COUNT+1)); TODO+=("$*"); }
warn() { echo -e "  ${YELLOW}WARN${NC}    $*"; WARN_COUNT=$((WARN_COUNT+1)); }
info() { echo -e "  ${CYAN}INFO${NC}    $*"; }

section() { echo; echo -e "${BOLD}== $* ==${NC}"; }

# ── Load env ─────────────────────────────────────────────────
section "Environment file"
if [ ! -f "$ENV_FILE" ]; then
  miss "azure.env not found at $ENV_FILE"
  exit 1
fi
ok "azure.env loaded from $ENV_FILE"
set -a; source "$ENV_FILE"; set +a

# ── Prerequisite CLIs ────────────────────────────────────────
section "Local CLI tools"
for cmd in az kubectl helm jq openssl envsubst psql; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd installed"
  else
    if [ "$cmd" = "psql" ]; then
      warn "$cmd not installed (only needed to create per-service DB users)"
    else
      miss "$cmd not installed"
    fi
  fi
done

# ── Azure login ──────────────────────────────────────────────
section "Azure login"
if az account show >/dev/null 2>&1; then
  ACCT_NAME=$(az account show --query name -o tsv)
  ACCT_SUB=$(az account show --query id -o tsv)
  CLOUD=$(az cloud show --query name -o tsv)
  ok "Logged in: $ACCT_NAME ($ACCT_SUB) on $CLOUD"
  if [ "$CLOUD" != "AzureUSGovernment" ]; then
    warn "Cloud is $CLOUD, expected AzureUSGovernment"
  fi
  if [ -n "${SUBSCRIPTION_ID:-}" ] && [ "$ACCT_SUB" != "$SUBSCRIPTION_ID" ]; then
    warn "Active sub ($ACCT_SUB) differs from azure.env SUBSCRIPTION_ID ($SUBSCRIPTION_ID)"
  fi
else
  miss "Not logged in to az (run: az cloud set --name AzureUSGovernment && az login)"
fi

# ── Helper: required env vars ────────────────────────────────
section "azure.env required values"
required_vars=(RESOURCE_GROUP AKS_RESOURCE_GROUP VNET_RESOURCE_GROUP \
               AKS_CLUSTER_NAME VNET_NAME PE_SUBNET_NAME KEY_VAULT_NAME)
for v in "${required_vars[@]}"; do
  if [ -n "${!v:-}" ]; then ok "$v=${!v}"; else miss "$v not set in azure.env"; fi
done

build_vars=(PG_SERVER_NAME STORAGE_ACCOUNT_NAME)
for v in "${build_vars[@]}"; do
  if [ -n "${!v:-}" ]; then ok "$v=${!v} (already set)"
  else info "$v not set yet — will need to be created"
  fi
done

# ── Azure resource groups ────────────────────────────────────
section "Resource groups"
for rg_var in RESOURCE_GROUP AKS_RESOURCE_GROUP VNET_RESOURCE_GROUP; do
  rg="${!rg_var:-}"
  [ -z "$rg" ] && continue
  if az group show -n "$rg" >/dev/null 2>&1; then
    ok "$rg_var '$rg' exists"
  else
    miss "$rg_var '$rg' not found"
  fi
done

# ── AKS cluster ──────────────────────────────────────────────
section "AKS cluster"
if [ -n "${AKS_CLUSTER_NAME:-}" ] && [ -n "${AKS_RESOURCE_GROUP:-}" ]; then
  if AKS_JSON=$(az aks show -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" 2>/dev/null); then
    K8S_VER=$(echo "$AKS_JSON" | jq -r '.kubernetesVersion')
    POWER=$(echo "$AKS_JSON" | jq -r '.powerState.code')
    ok "AKS '$AKS_CLUSTER_NAME' exists (k8s $K8S_VER, $POWER)"
    # Service mesh profile
    MESH=$(echo "$AKS_JSON" | jq -r '.serviceMeshProfile.istio.revisions[]? // empty' 2>/dev/null)
    if [ -n "$MESH" ]; then
      ok "Istio add-on revisions enabled: $(echo "$MESH" | tr '\n' ' ')"
      if echo "$MESH" | grep -qx "${ISTIO_REVISION:-asm-1-27}"; then
        ok "Required revision ${ISTIO_REVISION:-asm-1-27} is enabled"
      else
        warn "Required revision ${ISTIO_REVISION:-asm-1-27} not in cluster ($MESH)"
      fi
    else
      miss "Istio add-on not enabled on AKS"
    fi
  else
    miss "AKS '$AKS_CLUSTER_NAME' not found in $AKS_RESOURCE_GROUP"
  fi
fi

# ── kubectl context ──────────────────────────────────────────
section "kubectl access"
if kubectl get nodes >/dev/null 2>&1; then
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  CTX=$(kubectl config current-context 2>/dev/null)
  ok "kubectl reachable, $NODE_COUNT nodes (context: $CTX)"

  # Storage class
  if kubectl get sc managed-csi-premium >/dev/null 2>&1; then
    ok "StorageClass 'managed-csi-premium' present"
  else
    warn "StorageClass 'managed-csi-premium' missing — chart references it"
  fi

  # Istio in cluster
  if kubectl get ns aks-istio-system >/dev/null 2>&1; then
    if kubectl -n aks-istio-system get pods -l "app=istiod" --no-headers 2>/dev/null | grep -q .; then
      REV=$(kubectl -n aks-istio-system get pods -l "app=istiod" -o jsonpath='{.items[*].metadata.labels.istio\.io/rev}' 2>/dev/null)
      ok "Istio control plane running (revisions: $REV)"
    else
      warn "Istio namespace exists but no istiod pods"
    fi
  else
    info "Namespace aks-istio-system not present (may be vanilla istio elsewhere)"
  fi

  # Existing artifactory namespace
  if kubectl get ns artifactory >/dev/null 2>&1; then
    info "Namespace 'artifactory' already exists"
  else
    info "Namespace 'artifactory' will be created at deploy time"
  fi
else
  miss "kubectl cannot reach cluster (run: az aks get-credentials -g $AKS_RESOURCE_GROUP -n $AKS_CLUSTER_NAME)"
fi

# ── VNet + PE subnet ─────────────────────────────────────────
section "VNet and PE subnet"
if [ -n "${VNET_NAME:-}" ] && [ -n "${VNET_RESOURCE_GROUP:-}" ]; then
  if az network vnet show -g "$VNET_RESOURCE_GROUP" -n "$VNET_NAME" >/dev/null 2>&1; then
    ok "VNet '$VNET_NAME' exists"

    if [ -n "${PE_SUBNET_NAME:-}" ]; then
      if SUBNET_JSON=$(az network vnet subnet show \
            -g "$VNET_RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$PE_SUBNET_NAME" 2>/dev/null); then
        ok "PE subnet '$PE_SUBNET_NAME' exists"

        DELS=$(echo "$SUBNET_JSON" | jq -r '.delegations[]?.serviceName // empty')
        [ -n "$DELS" ] && warn "PE subnet has delegations: $DELS" || ok "PE subnet has no delegations"

        PE_POL=$(echo "$SUBNET_JSON" | jq -r '.privateEndpointNetworkPolicies')
        [ "$PE_POL" = "Disabled" ] && ok "privateEndpointNetworkPolicies=Disabled (PEs allowed)" \
                                   || miss "privateEndpointNetworkPolicies=$PE_POL (must be Disabled)"

        SES=$(echo "$SUBNET_JSON" | jq -r '.serviceEndpoints[]?.service // empty')
        if [ -n "$SES" ]; then
          warn "PE subnet has service endpoints: $(echo "$SES" | tr '\n' ' ')(may trip policy)"
        else
          ok "PE subnet has no service endpoints"
        fi
      else
        miss "PE subnet '$PE_SUBNET_NAME' not found in VNet"
      fi
    fi
  else
    miss "VNet '$VNET_NAME' not found"
  fi
fi

# ── Key Vault ────────────────────────────────────────────────
section "Key Vault"
if [ -n "${KEY_VAULT_NAME:-}" ]; then
  if KV_JSON=$(az keyvault show -n "$KEY_VAULT_NAME" 2>/dev/null); then
    ok "Key Vault '$KEY_VAULT_NAME' exists"
    RBAC=$(echo "$KV_JSON" | jq -r '.properties.enableRbacAuthorization')
    info "Auth mode: $([ "$RBAC" = "true" ] && echo RBAC || echo "access policies")"

    # Probe write
    if az keyvault secret list --vault-name "$KEY_VAULT_NAME" --query "[0].name" -o tsv >/dev/null 2>&1; then
      ok "Can list secrets in Key Vault"
    else
      warn "Cannot list secrets — check role/policy + network rules"
    fi

    # Existing artifactory- secrets
    KV_SECRETS=$(az keyvault secret list --vault-name "$KEY_VAULT_NAME" \
      --query "[?starts_with(name,'artifactory-')].name" -o tsv 2>/dev/null)
    if [ -n "$KV_SECRETS" ]; then
      info "Existing artifactory- secrets:"
      while read -r n; do echo "          - $n"; done <<<"$KV_SECRETS"
    else
      info "No artifactory- secrets in KV yet"
    fi
  else
    miss "Key Vault '$KEY_VAULT_NAME' not found"
  fi
fi

# ── ACR (optional) ───────────────────────────────────────────
section "Container registry (optional)"
if [ -n "${ACR_NAME:-}" ]; then
  if az acr show -n "$ACR_NAME" >/dev/null 2>&1; then
    ok "ACR '$ACR_NAME' exists ($ACR_NAME.azurecr.us)"
  else
    warn "ACR '$ACR_NAME' not found — chart will pull from public registry if you blank ACR_LOGIN_SERVER"
  fi
else
  info "ACR_NAME not set — public registry will be used"
fi

# ── PostgreSQL flex ──────────────────────────────────────────
section "PostgreSQL flexible server"
if [ -n "${PG_SERVER_NAME:-}" ]; then
  if PG_JSON=$(az postgres flexible-server show -g "$RESOURCE_GROUP" -n "$PG_SERVER_NAME" 2>/dev/null); then
    PG_VER=$(echo "$PG_JSON" | jq -r '.version')
    PG_STATE=$(echo "$PG_JSON" | jq -r '.state')
    PUBLIC=$(echo "$PG_JSON" | jq -r '.network.publicNetworkAccess')
    ok "PG '$PG_SERVER_NAME' exists (v$PG_VER, $PG_STATE, public=$PUBLIC)"

    PG_FQDN="${PG_SERVER_NAME}.postgres.database.usgovcloudapi.net"
    if command -v dig >/dev/null 2>&1; then
      RESOLVED=$(dig +short "$PG_FQDN" 2>/dev/null | tail -n1)
      if [[ "$RESOLVED" =~ ^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^192\.168\. ]]; then
        ok "PG FQDN resolves privately ($RESOLVED)"
      elif [ -n "$RESOLVED" ]; then
        warn "PG FQDN resolves to $RESOLVED (not RFC1918 — DNS link missing?)"
      else
        warn "PG FQDN does not resolve from this host"
      fi
    fi

    # Databases
    DBS=$(az postgres flexible-server db list -g "$RESOURCE_GROUP" -s "$PG_SERVER_NAME" \
          --query "[].name" -o tsv 2>/dev/null || true)
    for db in artifactory xray distribution; do
      echo "$DBS" | grep -qx "$db" && ok "DB '$db' exists" || miss "DB '$db' must be created"
    done
  else
    miss "PG '$PG_SERVER_NAME' not found in $RESOURCE_GROUP — must be created"
  fi
else
  miss "PG_SERVER_NAME unset — Postgres flex must be created"
fi

# ── Storage account ──────────────────────────────────────────
section "Storage account"
if [ -n "${STORAGE_ACCOUNT_NAME:-}" ]; then
  if SA_JSON=$(az storage account show -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT_NAME" 2>/dev/null); then
    PUBLIC=$(echo "$SA_JSON" | jq -r '.publicNetworkAccess')
    ok "Storage account '$STORAGE_ACCOUNT_NAME' exists (public=$PUBLIC)"

    # Container
    if az storage container show \
         --account-name "$STORAGE_ACCOUNT_NAME" \
         --name "${STORAGE_BLOB_CONTAINER:-artifactory-data}" \
         --auth-mode login >/dev/null 2>&1; then
      ok "Container '${STORAGE_BLOB_CONTAINER:-artifactory-data}' exists"
    else
      miss "Container '${STORAGE_BLOB_CONTAINER:-artifactory-data}' must be created"
    fi
  else
    miss "Storage account '$STORAGE_ACCOUNT_NAME' not found — must be created"
  fi
else
  miss "STORAGE_ACCOUNT_NAME unset — storage account must be created"
fi

# ── Private endpoints ────────────────────────────────────────
section "Private endpoints"
if [ -n "${PG_SERVER_NAME:-}" ]; then
  PG_PE=$(az network private-endpoint list -g "$RESOURCE_GROUP" \
          --query "[?contains(privateLinkServiceConnections[0].privateLinkServiceId, '$PG_SERVER_NAME')].name" \
          -o tsv 2>/dev/null)
  [ -n "$PG_PE" ] && ok "PG private endpoint: $PG_PE" || miss "No PE attached to PG '$PG_SERVER_NAME'"
fi
if [ -n "${STORAGE_ACCOUNT_NAME:-}" ]; then
  SA_PE=$(az network private-endpoint list -g "$RESOURCE_GROUP" \
          --query "[?contains(privateLinkServiceConnections[0].privateLinkServiceId, '$STORAGE_ACCOUNT_NAME')].name" \
          -o tsv 2>/dev/null)
  [ -n "$SA_PE" ] && ok "Storage private endpoint: $SA_PE" || miss "No PE attached to storage '$STORAGE_ACCOUNT_NAME'"
fi

# ── Private DNS zones ────────────────────────────────────────
section "Private DNS zones"
DNS_RG="${DNS_RESOURCE_GROUP:-$VNET_RESOURCE_GROUP}"
for z in privatelink.postgres.database.usgovcloudapi.net \
         privatelink.blob.core.usgovcloudapi.net; do
  if az network private-dns zone show -g "$DNS_RG" -n "$z" >/dev/null 2>&1; then
    ok "Zone '$z' exists in $DNS_RG"
    LINKED=$(az network private-dns link vnet list -g "$DNS_RG" -z "$z" \
             --query "[?contains(virtualNetwork.id, '/$VNET_NAME')].name" -o tsv 2>/dev/null)
    [ -n "$LINKED" ] && ok "  linked to VNet $VNET_NAME ($LINKED)" \
                     || warn "  not linked to VNet $VNET_NAME"
  else
    miss "Zone '$z' missing in $DNS_RG"
  fi
done

# ── Helm chart reachability ──────────────────────────────────
section "Helm chart reachability"
if command -v helm >/dev/null 2>&1; then
  if curl -sfI https://charts.jfrog.io/index.yaml >/dev/null 2>&1; then
    ok "https://charts.jfrog.io reachable"
  else
    warn "Cannot reach charts.jfrog.io from this host (air-gapped? mirror to ACR.)"
  fi
fi

# ── Summary ──────────────────────────────────────────────────
echo
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Summary${NC}"
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}OK:${NC}      $OK_COUNT"
echo -e "  ${YELLOW}WARN:${NC}    $WARN_COUNT"
echo -e "  ${RED}MISSING:${NC} $MISSING_COUNT"

if [ "$MISSING_COUNT" -gt 0 ]; then
  echo
  echo -e "${BOLD}To-do before Helm install:${NC}"
  for t in "${TODO[@]}"; do echo "  - $t"; done
  exit 1
fi

echo
echo -e "${GREEN}${BOLD}Ready to deploy.${NC}"
