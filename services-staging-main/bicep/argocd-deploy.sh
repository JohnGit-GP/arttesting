#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# Generic ArgoCD deployer — reads service JSON, creates/updates
# an ArgoCD Application CRD. Service-agnostic.
#
# Usage:
#   ./bicep/argocd-deploy.sh <service> <env>
#   ./bicep/argocd-deploy.sh <service> <env> --dry-run
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env/azure.env"

SERVICE="${1:?Usage: argocd-deploy.sh <service> <env> [--dry-run]}"
ENV="${2:?Usage: argocd-deploy.sh <service> <env> [--dry-run]}"
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

# ── Validate ──
for file in "$SERVICE_JSON" "$ENV_FILE"; do
  if [ ! -f "$file" ]; then
    echo -e "${RED}ERROR: Required file not found: $file${NC}"
    exit 1
  fi
done

source "$ENV_FILE"

# ── Read service config ──
HELM_CHART_NAME=$(jq -r '.helm.chartName // empty' "$SERVICE_JSON")
HELM_CHART_VERSION=$(jq -r '.helm.chartVersion // empty' "$SERVICE_JSON")
HELM_RELEASE_NAME=$(jq -r '.helm.releaseName // empty' "$SERVICE_JSON")
HELM_NAMESPACE=$(jq -r '.helm.namespace // empty' "$SERVICE_JSON")

ARGOCD_PROJECT=$(jq -r '.argocd.project // "default"' "$SERVICE_JSON")
ARGOCD_SYNC_POLICY=$(jq -r '.argocd.syncPolicy // "automated"' "$SERVICE_JSON")
ARGOCD_NAMESPACE=$(jq -r '.argocd.namespace // "argocd"' "$SERVICE_JSON")

OCI_REPO="oci://${ACR_NAME}.azurecr.us/helm"

echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${BOLD}  ArgoCD Deploy: ${SERVICE}${NC}"
echo -e "${BOLD}  Chart:         ${HELM_CHART_NAME} v${HELM_CHART_VERSION}${NC}"
echo -e "${BOLD}  Namespace:     ${HELM_NAMESPACE}${NC}"
echo -e "${BOLD}  ArgoCD Project: ${ARGOCD_PROJECT}${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"

# ── Render values for inline embedding ──
echo -e "${CYAN}[1/2] Rendering Helm values...${NC}"

if [ -f "$VALUES_TEMPLATE" ]; then
  # Export infra values for envsubst
  export PG_ADMIN_USER="${PG_ADMIN_USER:-pgadmin}"
  export PG_SERVER_FQDN="${PG_SERVER_NAME:+${PG_SERVER_NAME}.postgres.database.usgovcloudapi.net}"
  export STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-}"
  export ACR_LOGIN_SERVER="${ACR_NAME:+${ACR_NAME}.azurecr.us}"
  export BLOB_ENDPOINT_SUFFIX="${BLOB_ENDPOINT_SUFFIX:-blob.core.usgovcloudapi.net}"

  # Pull secrets from Key Vault for value rendering
  if [ -n "${KEY_VAULT_NAME:-}" ]; then
    KV_SECRETS=$(az keyvault secret list --vault-name "${KEY_VAULT_NAME}" \
      --query "[?starts_with(name, '${SERVICE}-')].name" -o tsv 2>/dev/null || echo "")
    for secret_name in $KV_SECRETS; do
      env_var=$(echo "$secret_name" | sed "s/^${SERVICE}-//" | tr '[:lower:]-' '[:upper:]_')
      value=$(az keyvault secret show --vault-name "${KEY_VAULT_NAME}" \
        --name "$secret_name" --query value -o tsv 2>/dev/null || echo "")
      [ -n "$value" ] && export "$env_var"="$value"
    done
  fi

  RENDERED_VALUES=$(envsubst < "$VALUES_TEMPLATE")
else
  RENDERED_VALUES=""
fi

# ── Build sync policy ──
if [ "$ARGOCD_SYNC_POLICY" = "automated" ]; then
  SYNC_BLOCK="syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true"
else
  SYNC_BLOCK="syncPolicy:
    syncOptions:
      - CreateNamespace=true"
fi

# ── Generate Application CRD ──
echo -e "${CYAN}[2/2] Creating ArgoCD Application...${NC}"

APP_MANIFEST="apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${HELM_RELEASE_NAME}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    service: ${SERVICE}
    environment: ${ENV}
spec:
  project: ${ARGOCD_PROJECT}
  source:
    chart: ${HELM_CHART_NAME}
    repoURL: ${OCI_REPO}
    targetRevision: ${HELM_CHART_VERSION}
    helm:
      releaseName: ${HELM_RELEASE_NAME}
      values: |
$(echo "$RENDERED_VALUES" | sed 's/^/        /')
  destination:
    server: https://kubernetes.default.svc
    namespace: ${HELM_NAMESPACE}
  ${SYNC_BLOCK}"

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}DRY RUN — Application manifest:${NC}"
  echo ""
  echo "$APP_MANIFEST"
  echo ""
  echo -e "${YELLOW}Would apply to namespace: ${ARGOCD_NAMESPACE}${NC}"
else
  echo "$APP_MANIFEST" | kubectl apply -f -
  echo -e "  ${GREEN}Application '${HELM_RELEASE_NAME}' created/updated in namespace '${ARGOCD_NAMESPACE}'${NC}"
  echo ""
  echo "  ArgoCD will now manage this deployment."
  echo "  Check status: argocd app get ${HELM_RELEASE_NAME}"
fi

echo ""
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ArgoCD deploy complete: ${SERVICE}${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"