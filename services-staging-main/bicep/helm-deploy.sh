#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# Generic Helm deployer — reads service JSON, creates K8s
# secrets from Key Vault, renders values, runs helm install.
# 100% service-agnostic — all service logic in the JSON file.
#
# Usage:
#   ./bicep/helm-deploy.sh <service> <env>
#   ./bicep/helm-deploy.sh <service> <env> --dry-run
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env/azure.env"

SERVICE="${1:?Usage: helm-deploy.sh <service> <env> [--dry-run]}"
ENV="${2:?Usage: helm-deploy.sh <service> <env> [--dry-run]}"
DRY_RUN=false
[ "${3:-}" = "--dry-run" ] && DRY_RUN=true

SERVICE_JSON="${SCRIPT_DIR}/services/${SERVICE}.json"
VALUES_TEMPLATE="${SCRIPT_DIR}/values-templates/${SERVICE}.values.yaml"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

# ── Validate inputs ──
for file in "$SERVICE_JSON" "$ENV_FILE"; do
  if [ ! -f "$file" ]; then
    echo -e "${RED}ERROR: Required file not found: $file${NC}"
    exit 1
  fi
done

source "$ENV_FILE"

# ── Read service config ──
HELM_REPO_NAME=$(jq -r '.helm.repoName // empty' "$SERVICE_JSON")
HELM_REPO_URL=$(jq -r '.helm.repoUrl // empty' "$SERVICE_JSON")
HELM_CHART_NAME=$(jq -r '.helm.chartName // empty' "$SERVICE_JSON")
HELM_CHART_REF=$(jq -r '.helm.chartRef // empty' "$SERVICE_JSON")
HELM_CHART_VERSION=$(jq -r '.helm.chartVersion // empty' "$SERVICE_JSON")
HELM_RELEASE_NAME=$(jq -r '.helm.releaseName // empty' "$SERVICE_JSON")
HELM_NAMESPACE=$(jq -r '.helm.namespace // empty' "$SERVICE_JSON")
HELM_SOURCE=$(jq -r '.helm.source // "oci"' "$SERVICE_JSON")
ISTIO_REVISION=$(jq -r '.istioRevision // "asm-1-27"' "$SERVICE_JSON")

# ── Resolve cloud-aware endpoint suffixes once ──
# Prefer Bicep stack outputs (cloud-aware, written back to azure.env by
# deploy.sh). Fall back to a cloud-keyed table so a manual helm-deploy.sh
# run with a partial azure.env still works. These are referenced both in
# the OCI chart-pull URL (Step 6) and in the secret-loading loop (Step 3),
# so they must be set before either block runs.
AZ_ENV_NAME=$(az cloud show --query name -o tsv 2>/dev/null || echo "AzureUSGovernment")
case "$AZ_ENV_NAME" in
  AzureUSGovernment) PG_SUFFIX="postgres.database.usgovcloudapi.net";  BLOB_SUFFIX="blob.core.usgovcloudapi.net";  ACR_SUFFIX="azurecr.us" ;;
  AzureCloud)        PG_SUFFIX="postgres.database.azure.com";          BLOB_SUFFIX="blob.core.windows.net";        ACR_SUFFIX="azurecr.io" ;;
  *)                 PG_SUFFIX="postgres.database.usgovcloudapi.net";  BLOB_SUFFIX="blob.core.usgovcloudapi.net";  ACR_SUFFIX="azurecr.us" ;;
esac

export PG_ADMIN_USER="${PG_ADMIN_USER:-pgadmin}"
export PG_SERVER_FQDN="${PG_SERVER_FQDN:-${PG_SERVER_NAME:+${PG_SERVER_NAME}.${PG_SUFFIX}}}"
export STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-}"
export ACR_LOGIN_SERVER="${ACR_LOGIN_SERVER:-${ACR_NAME:+${ACR_NAME}.${ACR_SUFFIX}}}"
export BLOB_ENDPOINT_SUFFIX="${BLOB_ENDPOINT_SUFFIX:-$BLOB_SUFFIX}"

echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${BOLD}  Helm Deploy: ${SERVICE}${NC}"
echo -e "${BOLD}  Chart:       ${HELM_CHART_REF} v${HELM_CHART_VERSION}${NC}"
echo -e "${BOLD}  Namespace:   ${HELM_NAMESPACE}${NC}"
echo -e "${BOLD}  Source:      ${HELM_SOURCE}${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}DRY RUN — showing what would happen${NC}"
fi

# ═══════════════════════════════════════
# Step 1: Get AKS credentials
# ═══════════════════════════════════════
echo ""
echo -e "${CYAN}[1/6] Getting AKS credentials...${NC}"
if [ "$DRY_RUN" != true ]; then
  az aks get-credentials \
    --resource-group "${AKS_RESOURCE_GROUP}" \
    --name "${AKS_CLUSTER_NAME}" \
    --overwrite-existing
fi

# ═══════════════════════════════════════
# Step 2: Create namespace + Istio label
# ═══════════════════════════════════════
echo -e "${CYAN}[2/6] Creating namespace ${HELM_NAMESPACE}...${NC}"
if [ "$DRY_RUN" != true ]; then
  kubectl create namespace "${HELM_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${HELM_NAMESPACE}" "istio.io/rev=${ISTIO_REVISION}" --overwrite
fi

# ═══════════════════════════════════════
# Step 3: Pull secrets from Key Vault → create K8s secrets
# ═══════════════════════════════════════
echo -e "${CYAN}[3/6] Creating K8s secrets from Key Vault...${NC}"

K8S_SECRETS=$(jq -c '.k8sSecrets // []' "$SERVICE_JSON")
SECRET_COUNT=$(echo "$K8S_SECRETS" | jq 'length')

if [ "$SECRET_COUNT" -gt 0 ]; then
  # Cloud-aware suffix exports (PG_SERVER_FQDN, ACR_LOGIN_SERVER, etc.)
  # already happened at the top of this script. Variables referenced below
  # are guaranteed set, regardless of whether the service has k8sSecrets.

  # Resolve question answers — prefer env (set by deploy.sh Phase 1),
  # fall back to the JSON default. Convert y/n synonyms to YAML booleans
  # so the values template can use them directly: `enabled: ${ENABLE_X}`.
  while IFS= read -r q; do
    qvar=$(echo "$q" | jq -r '.var')
    qdef=$(echo "$q" | jq -r '.default // "yes"')
    qval="${!qvar:-$qdef}"
    case "$(echo "$qval" | tr '[:upper:]' '[:lower:]')" in
      y|yes|true|1|on) export "$qvar"="true" ;;
      *)               export "$qvar"="false" ;;
    esac
  done < <(jq -c '.questions // [] | .[]' "$SERVICE_JSON")

  # Pull secret values from Key Vault
  # Each az data-plane call is wrapped in `timeout` so an unreachable KV
  # (network drop, missing PE, missing DNS A-record) fails fast with a
  # clear error instead of stalling helm-deploy.sh on az's retry/backoff.
  if [ -n "${KEY_VAULT_NAME:-}" ]; then
    echo "  Reading secrets from Key Vault: ${KEY_VAULT_NAME}"
    KV_SECRETS=$(timeout 30 az keyvault secret list --vault-name "${KEY_VAULT_NAME}" \
      --query "[?starts_with(name, '${SERVICE}-')].name" -o tsv 2>/dev/null || echo "")
    if [ -z "$KV_SECRETS" ]; then
      echo -e "  ${YELLOW}WARNING: Key Vault returned no secrets (or call timed out).${NC}"
      echo -e "  ${YELLOW}Verify reachability: timeout 8 az keyvault secret list --vault-name ${KEY_VAULT_NAME}${NC}"
    fi

    for secret_name in $KV_SECRETS; do
      # Convert KV secret name to env var name: <service>-my-secret → MY_SECRET
      env_var=$(echo "$secret_name" | sed "s/^${SERVICE}-//" | tr '[:lower:]-' '[:upper:]_')
      value=$(timeout 30 az keyvault secret show --vault-name "${KEY_VAULT_NAME}" \
        --name "$secret_name" --query value -o tsv 2>/dev/null || echo "")
      if [ -n "$value" ]; then
        export "$env_var"="$value"
        echo "  Loaded: ${secret_name} → \$${env_var}"
      fi
    done
  fi

  # Create each K8s secret from the JSON definition
  echo "$K8S_SECRETS" | jq -c '.[]' | while read -r secret; do
    SECRET_NAME=$(echo "$secret" | jq -r '.name')
    echo -n "  Creating secret: ${SECRET_NAME}... "

    # Build --from-literal args by resolving ${VAR} references in data values
    KUBECTL_ARGS=()
    for data_key in $(echo "$secret" | jq -r '.data | keys[]'); do
      raw_value=$(echo "$secret" | jq -r ".data[\"$data_key\"]")
      # Resolve ${VAR} references using current environment
      resolved_value=$(echo "$raw_value" | envsubst)
      KUBECTL_ARGS+=("--from-literal=${data_key}=${resolved_value}")
    done

    if [ "$DRY_RUN" != true ]; then
      kubectl create secret generic "$SECRET_NAME" \
        "${KUBECTL_ARGS[@]}" \
        -n "${HELM_NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
      echo -e "${GREEN}OK${NC}"
    else
      echo -e "${YELLOW}(dry run)${NC}"
    fi
  done
else
  echo "  No K8s secrets defined for this service"
fi

# ═══════════════════════════════════════
# Step 4: Create ExternalName services
# ═══════════════════════════════════════
echo -e "${CYAN}[4/6] Creating ExternalName services...${NC}"

EXT_SERVICES=$(jq -c '.externalNameServices // []' "$SERVICE_JSON")
EXT_COUNT=$(echo "$EXT_SERVICES" | jq 'length')

if [ "$EXT_COUNT" -gt 0 ]; then
  echo "$EXT_SERVICES" | jq -c '.[]' | while read -r svc; do
    SVC_NAME=$(echo "$svc" | jq -r '.name')
    SVC_TARGET=$(echo "$svc" | jq -r '.target')
    echo -n "  ${SVC_NAME} → ${SVC_TARGET}... "

    if [ "$DRY_RUN" != true ]; then
      cat <<EOSVC | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${SVC_NAME}
  namespace: ${HELM_NAMESPACE}
spec:
  type: ExternalName
  externalName: ${SVC_TARGET}
EOSVC
      echo -e "${GREEN}OK${NC}"
    else
      echo -e "${YELLOW}(dry run)${NC}"
    fi
  done
else
  echo "  No ExternalName services defined"
fi

# ═══════════════════════════════════════
# Step 5: Render values template
# ═══════════════════════════════════════
echo -e "${CYAN}[5/6] Rendering Helm values...${NC}"

if [ -f "$VALUES_TEMPLATE" ]; then
  envsubst < "$VALUES_TEMPLATE" > /tmp/values-rendered-${SERVICE}.yaml
  echo "  Rendered: /tmp/values-rendered-${SERVICE}.yaml"
else
  echo -e "  ${YELLOW}No values template found at ${VALUES_TEMPLATE}${NC}"
  touch /tmp/values-rendered-${SERVICE}.yaml
fi

# ═══════════════════════════════════════
# Step 5.5: Bootstrap chart (PG users/grants/extensions)
# Runs before main chart. Helm pre-install hook Job creates per-product
# users, sets ownership, runs CREATE EXTENSION pg_trgm in xraydb.
# Uses K8s Secret created in Step 3 (no Workload Identity needed).
# Convention: if charts/${SERVICE}-bootstrap exists, run it first.
# ═══════════════════════════════════════
BOOTSTRAP_CHART_DIR="${SCRIPT_DIR}/charts/${SERVICE}-bootstrap"
# Backwards-compat: artifactory uses charts/jfrog-bootstrap (chart is product-named).
[ ! -d "$BOOTSTRAP_CHART_DIR" ] && [ "$SERVICE" = "artifactory" ] && \
  BOOTSTRAP_CHART_DIR="${SCRIPT_DIR}/charts/jfrog-bootstrap"

if [ -d "$BOOTSTRAP_CHART_DIR" ]; then
  echo -e "${CYAN}[5.5/6] Running pre-install bootstrap chart...${NC}"
  echo "  Chart: ${BOOTSTRAP_CHART_DIR}"

  # Allow override for non-air-gap deploys (internet-on test, dev cluster).
  # When ACR isn't yet populated, set BOOTSTRAP_IMAGE_REGISTRY=docker.io
  BOOTSTRAP_IMAGE_REGISTRY="${BOOTSTRAP_IMAGE_REGISTRY:-${ACR_LOGIN_SERVER}}"

  # Validate prerequisites for the bootstrap chart
  if [ -z "${BOOTSTRAP_IMAGE_REGISTRY}" ]; then
    echo -e "  ${RED}ERROR: BOOTSTRAP_IMAGE_REGISTRY (or ACR_LOGIN_SERVER) is empty${NC}"
    exit 1
  fi
  if [ -z "${PG_SERVER_FQDN:-}" ]; then
    echo -e "  ${RED}ERROR: PG_SERVER_FQDN is empty — bootstrap can't reach PG${NC}"
    exit 1
  fi

  BOOTSTRAP_RELEASE="${HELM_RELEASE_NAME}-bootstrap"
  BOOTSTRAP_ARGS=(
    upgrade --install "$BOOTSTRAP_RELEASE" "$BOOTSTRAP_CHART_DIR"
    --namespace "${HELM_NAMESPACE}"
    --set image.registry="${BOOTSTRAP_IMAGE_REGISTRY}"
    --set postgres.host="${PG_SERVER_FQDN}"
    --set databases.xray.enabled="${ENABLE_XRAY:-true}"
    --set databases.distribution.enabled="${ENABLE_DISTRIBUTION:-true}"
    --timeout 5m
    --wait
  )

  if [ "$DRY_RUN" = true ]; then
    BOOTSTRAP_ARGS+=(--dry-run)
    helm "${BOOTSTRAP_ARGS[@]}"
    echo -e "  ${YELLOW}(dry run — bootstrap chart not actually applied)${NC}"
  else
    if helm "${BOOTSTRAP_ARGS[@]}"; then
      echo -e "  ${GREEN}Bootstrap chart applied. PG users + extensions ready.${NC}"
    else
      echo -e "  ${RED}Bootstrap failed. Inspect the Job pod for SQL errors:${NC}"
      echo -e "  ${RED}  kubectl logs -n ${HELM_NAMESPACE} job/${BOOTSTRAP_RELEASE}-pg-bootstrap${NC}"
      exit 1
    fi
  fi
else
  echo -e "${CYAN}[5.5/6] No bootstrap chart for ${SERVICE} — skipping${NC}"
fi

# ═══════════════════════════════════════
# Step 6: Helm install/upgrade
# ═══════════════════════════════════════
echo -e "${CYAN}[6/6] Installing/upgrading Helm release...${NC}"

# Resolve chart source
CHART_TARGET=""
case "${HELM_SOURCE}" in
  repo)
    helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" 2>/dev/null || true
    helm repo update "$HELM_REPO_NAME"
    CHART_TARGET="${HELM_CHART_REF}"
    ;;
  oci)
    # ACR_LOGIN_SERVER is set at the top of the script — Bicep stack output
    # if available, else <ACR_NAME>.<ACR_SUFFIX> from the cloud table.
    OCI_REF="oci://${ACR_LOGIN_SERVER}/helm/${HELM_CHART_NAME}"
    az acr login --name "${ACR_NAME}" 2>/dev/null || true
    CHART_TARGET="${OCI_REF}"
    ;;
  local)
    LOCAL_TGZ="${SCRIPT_DIR}/packages/${SERVICE}/${HELM_CHART_NAME}-${HELM_CHART_VERSION}.tgz"
    if [ ! -f "$LOCAL_TGZ" ]; then
      echo -e "${RED}ERROR: Local chart not found: ${LOCAL_TGZ}${NC}"
      exit 1
    fi
    CHART_TARGET="${LOCAL_TGZ}"
    ;;
esac

HELM_ARGS=(
  upgrade --install "${HELM_RELEASE_NAME}" "${CHART_TARGET}"
  --namespace "${HELM_NAMESPACE}"
  -f "/tmp/values-rendered-${SERVICE}.yaml"
  --timeout 15m
  --wait
)

if [ "${HELM_SOURCE}" != "local" ]; then
  HELM_ARGS+=(--version "${HELM_CHART_VERSION}")
fi

if [ "$DRY_RUN" = true ]; then
  HELM_ARGS+=(--dry-run)
fi

helm "${HELM_ARGS[@]}"

# ── Done ──
echo ""
echo -e "${BOLD}══════════════════════════════════════════${NC}"
if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}${BOLD}  Dry run complete${NC}"
else
  echo -e "${GREEN}${BOLD}  Helm deploy complete: ${SERVICE}${NC}"
  kubectl get pods -n "${HELM_NAMESPACE}" -o wide
fi
echo -e "${BOLD}══════════════════════════════════════════${NC}"