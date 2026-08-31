#!/usr/bin/env bash
# ============================================================
# Helm deployment script for AKS
# Runs inside a Microsoft.Resources/deploymentScripts container
# All variables are passed as environment variables from Bicep
#
# Supports 3 chart sources (set via HELM_SOURCE):
#   repo  — pull from internet Helm repo (default)
#   oci   — pull from ACR as OCI artifact (air-gapped)
#   local — use chart .tgz bundled in the repo (fully offline)
# ============================================================
set -euo pipefail

HELM_SOURCE="${HELM_SOURCE:-repo}"

echo "=== Helm Deployment Script ==="
echo "Service:  ${HELM_RELEASE_NAME}"
echo "Namespace: ${HELM_NAMESPACE}"
echo "Source:   ${HELM_SOURCE}"
echo "Chart:    ${HELM_CHART_REF} v${HELM_CHART_VERSION}"

# --- Install helm ---
echo "--- Installing Helm ---"
if command -v helm &>/dev/null; then
  echo "  Helm already available: $(helm version --short)"
else
  # For air-gapped: helm binary must be in the deploymentScript container
  # or pre-installed in a custom container image
  if [ "$HELM_SOURCE" = "local" ] || [ "$HELM_SOURCE" = "oci" ]; then
    echo "  WARNING: Attempting to download helm — may fail in air-gapped environments"
    echo "  If this fails, use a custom container image with helm pre-installed"
  fi
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- Get AKS credentials ---
echo "--- Getting AKS credentials ---"
az aks get-credentials \
  --resource-group "${AKS_RESOURCE_GROUP}" \
  --name "${AKS_CLUSTER_NAME}" \
  --overwrite-existing

# --- Create namespace with Istio label ---
echo "--- Creating namespace ${HELM_NAMESPACE} ---"
kubectl create namespace "${HELM_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${HELM_NAMESPACE}" "istio.io/rev=${ISTIO_REVISION}" --overwrite

# --- Create Kubernetes secrets ---
echo "--- Creating K8s secrets ---"

kubectl create secret generic artifactory-master-key \
  --from-literal=master-key="${MASTER_KEY}" \
  -n "${HELM_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic artifactory-join-key \
  --from-literal=join-key="${JOIN_KEY}" \
  -n "${HELM_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic artifactory-db-creds \
  --from-literal=db-admin-user="${PG_ADMIN_USER}" \
  --from-literal=db-admin-password="${PG_ADMIN_PASSWORD}" \
  -n "${HELM_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic azure-blob-creds \
  --from-literal=account-name="${STORAGE_ACCOUNT_NAME}" \
  --from-literal=account-key="${STORAGE_ACCOUNT_KEY}" \
  -n "${HELM_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- Create ExternalName services (if needed) ---
if [ -n "${EXTERNAL_NAME_SERVICES:-}" ]; then
  echo "--- Creating ExternalName services ---"
  # Format: "svcName:targetFqdn,svcName2:targetFqdn2"
  IFS=',' read -ra SVC_PAIRS <<< "${EXTERNAL_NAME_SERVICES}"
  for pair in "${SVC_PAIRS[@]}"; do
    IFS=':' read -r svc_name target_fqdn <<< "${pair}"
    cat <<EOSVC | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${svc_name}
  namespace: ${HELM_NAMESPACE}
spec:
  type: ExternalName
  externalName: ${target_fqdn}
EOSVC
    echo "  Created ExternalName: ${svc_name} -> ${target_fqdn}"
  done
fi

# --- Render values template ---
echo "--- Rendering Helm values ---"
echo "${VALUES_TEMPLATE}" | envsubst > /tmp/values-rendered.yaml

# --- Resolve chart source ---
CHART_TARGET=""

case "${HELM_SOURCE}" in
  repo)
    echo "--- Adding Helm repo (internet) ---"
    helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}"
    helm repo update
    CHART_TARGET="${HELM_CHART_REF}"
    ;;

  oci)
    # Pull from ACR OCI registry — no internet needed
    # HELM_CHART_REF should be: oci://<acr>.azurecr.us/helm/<chart-name>
    echo "--- Pulling chart from OCI registry ---"
    # Login to ACR using managed identity
    az acr login --name "${ACR_LOGIN_SERVER%%.*}" 2>/dev/null || true
    CHART_TARGET="${HELM_CHART_REF}"
    ;;

  local)
    # Chart .tgz is bundled in the repo and passed as base64 via HELM_CHART_BUNDLE
    echo "--- Using bundled chart ---"
    if [ -n "${HELM_CHART_BUNDLE:-}" ]; then
      echo "${HELM_CHART_BUNDLE}" | base64 -d > /tmp/chart.tgz
      CHART_TARGET="/tmp/chart.tgz"
    else
      echo "ERROR: HELM_SOURCE=local but HELM_CHART_BUNDLE is empty"
      echo "Bundle the chart: base64 -w0 charts/<chart>.tgz"
      exit 1
    fi
    ;;

  *)
    echo "ERROR: Unknown HELM_SOURCE: ${HELM_SOURCE}"
    echo "Valid values: repo, oci, local"
    exit 1
    ;;
esac

# --- Install/upgrade ---
echo "--- Installing/upgrading Helm release ---"
HELM_ARGS=(
  upgrade --install "${HELM_RELEASE_NAME}" "${CHART_TARGET}"
  --namespace "${HELM_NAMESPACE}"
  -f /tmp/values-rendered.yaml
  --timeout 15m
  --wait
)

# --version flag is required for repo/oci but not for local .tgz
if [ "${HELM_SOURCE}" != "local" ]; then
  HELM_ARGS+=(--version "${HELM_CHART_VERSION}")
fi

helm "${HELM_ARGS[@]}"

# --- Output status ---
echo "--- Deployment status ---"
kubectl get pods -n "${HELM_NAMESPACE}" -o wide

# Write output for Bicep to read
echo "{\"status\": \"success\", \"release\": \"${HELM_RELEASE_NAME}\", \"namespace\": \"${HELM_NAMESPACE}\", \"source\": \"${HELM_SOURCE}\"}" > "${AZ_SCRIPTS_OUTPUT_DIRECTORY}/result.json"

echo "=== Deployment complete ==="