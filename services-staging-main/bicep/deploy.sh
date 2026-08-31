#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# Service deployment orchestrator — 3 phases:
#   Phase 1: Interactive wizard (questions + secrets → Key Vault)
#   Phase 2: Azure infra (Bicep deployment stack)
#   Phase 3: Helm deploy (manual) or ArgoCD Application
#
# 100% service-agnostic. All service logic in JSON config files.
#
# Usage:
#   deploy.sh <service> <env>                                  # dry run
#   deploy.sh <service> <env> --confirm                        # infra only
#   deploy.sh <service> <env> --confirm --secrets              # wizard + infra + helm
#   deploy.sh <service> <env> --confirm --secrets --rotate     # force-regen all secrets
#   deploy.sh <service> <env> --confirm --secrets --argocd     # wizard + infra + argocd
#   deploy.sh <service> <env> --status                         # show stack
#   deploy.sh <service> <env> --teardown --confirm             # destroy all
#
# Optional:
#   --deployer-object-id=<id>   AAD objectId to grant KV access (auto-detected
#                               from `az ad signed-in-user show` otherwise)
#                               Can also be set via DEPLOYER_OBJECT_ID env var.
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env/azure.env"

# ── Parse args ──
SERVICE="${1:?Usage: deploy.sh <service> <env> [flags]}"
ENV="${2:?Usage: deploy.sh <service> <env> [flags]}"
CONFIRM=false
PROMPT_SECRETS=false
ROTATE_SECRETS=false
TEARDOWN=false
STATUS=false
USE_ARGOCD=false
# DEPLOYER_OBJECT_ID may already be set in the environment (e.g. CI).
# CLI flag --deployer-object-id=<id> overrides it.
DEPLOYER_OBJECT_ID="${DEPLOYER_OBJECT_ID:-}"
shift 2
for arg in "$@"; do
  case "$arg" in
    --confirm) CONFIRM=true ;;
    --secrets) PROMPT_SECRETS=true ;;
    --rotate|--rotate-secrets) ROTATE_SECRETS=true ;;
    --teardown) TEARDOWN=true ;;
    --status) STATUS=true ;;
    --argocd) USE_ARGOCD=true ;;
    --deployer-object-id=*) DEPLOYER_OBJECT_ID="${arg#--deployer-object-id=}" ;;
  esac
done

STACK_NAME="${SERVICE}-${ENV}"
PARAM_FILE="${SCRIPT_DIR}/params/${SERVICE}.${ENV}.bicepparam"
MAIN_FILE="${SCRIPT_DIR}/main.bicep"
SERVICE_JSON="${SCRIPT_DIR}/services/${SERVICE}.json"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

# ── Validate env file ──
if [ ! -f "$ENV_FILE" ]; then
  echo -e "${RED}ERROR: azure.env not found. Run ./bicep/env/populate-env.sh${NC}"
  exit 1
fi

source "$ENV_FILE"

# ── Validate required env vars ──
REQUIRED_VARS=(RESOURCE_GROUP AKS_CLUSTER_NAME AKS_RESOURCE_GROUP VNET_NAME ACR_NAME)
MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    MISSING+=("$var")
  fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo -e "${RED}ERROR: Missing values in azure.env:${NC}"
  for var in "${MISSING[@]}"; do echo "  - $var"; done
  exit 1
fi

echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Service:        ${SERVICE}${NC}"
echo -e "${BOLD}  Environment:    ${ENV}${NC}"
echo -e "${BOLD}  Stack:          ${STACK_NAME}${NC}"
echo -e "${BOLD}  Resource Group: ${RESOURCE_GROUP}${NC}"
echo -e "${BOLD}  AKS Cluster:    ${AKS_CLUSTER_NAME}${NC}"
echo -e "${BOLD}  ACR:            ${ACR_NAME}${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"

# ══════════════════════════════════════════
# --status: Show stack resources
# ══════════════════════════════════════════
if [ "$STATUS" = true ]; then
  echo ""
  echo ">>> Stack: ${STACK_NAME}"
  az stack group show \
    --name "$STACK_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "{name:name, state:provisioningState}" \
    -o table 2>/dev/null || echo "Stack not found."
  echo ""
  echo "Managed resources:"
  az stack group show \
    --name "$STACK_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "resources[].{resource:id, status:status}" \
    -o table 2>/dev/null || true
  exit 0
fi

# ══════════════════════════════════════════
# --teardown: Destroy service resources
# ══════════════════════════════════════════
if [ "$TEARDOWN" = true ]; then
  echo ""
  echo -e "${RED}>>> TEARDOWN: ${SERVICE} (${ENV})${NC}"
  echo ""
  echo "This will delete:"

  az stack group show \
    --name "$STACK_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "resources[].id" \
    -o tsv 2>/dev/null | while read -r rid; do
      echo "  - $(basename "$rid")"
    done

  HELM_NAMESPACE=$(jq -r '.helm.namespace // empty' "$SERVICE_JSON" 2>/dev/null || echo "$SERVICE")
  HELM_RELEASE=$(jq -r '.helm.releaseName // empty' "$SERVICE_JSON" 2>/dev/null || echo "$SERVICE")

  echo "  - Helm release: ${HELM_RELEASE} (namespace: ${HELM_NAMESPACE})"
  echo "  - Namespace: ${HELM_NAMESPACE}"
  echo ""

  if [ "$CONFIRM" != true ]; then
    echo "Add --confirm to proceed."
    exit 0
  fi

  echo ">>> Removing Helm release..."
  az aks get-credentials \
    --resource-group "$AKS_RESOURCE_GROUP" \
    --name "$AKS_CLUSTER_NAME" \
    --overwrite-existing 2>/dev/null || true

  helm uninstall "$HELM_RELEASE" --namespace "$HELM_NAMESPACE" 2>/dev/null && \
    echo -e "  ${GREEN}Helm release uninstalled${NC}" || \
    echo "  Helm release not found (skipping)"

  # Remove ArgoCD Application if it exists
  kubectl delete application "$HELM_RELEASE" -n argocd 2>/dev/null && \
    echo -e "  ${GREEN}ArgoCD Application removed${NC}" || true

  kubectl delete namespace "$HELM_NAMESPACE" --wait=false 2>/dev/null && \
    echo -e "  ${GREEN}Namespace deletion initiated${NC}" || \
    echo "  Namespace not found (skipping)"

  echo ""
  echo ">>> Deleting deployment stack..."
  az stack group delete \
    --name "$STACK_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --action-on-unmanage deleteAll \
    --yes

  # Clear per-service refs from azure.env so the next deploy starts clean.
  # Without this, deploy.sh would pass the deleted resource names to Bicep
  # as existing* params and Bicep would fail with ResourceNotFound /
  # ParentResourceNotFound when it tries to reference them.
  echo ">>> Clearing per-service refs from azure.env..."
  for var in KEY_VAULT_NAME PG_SERVER_NAME PG_SERVER_FQDN STORAGE_ACCOUNT_NAME BLOB_ENDPOINT_SUFFIX; do
    if grep -qE "^${var}=" "$ENV_FILE"; then
      sed -i "s|^${var}=.*|${var}=\"\"|" "$ENV_FILE"
      echo "  ${var} cleared"
    fi
  done

  echo ""
  echo -e "${GREEN}>>> Teardown complete.${NC}"
  exit 0
fi

# ══════════════════════════════════════════
# Phase 1: Interactive wizard
# Collects answers + secrets. Secrets are buffered into a JSON object
# that Phase 2 hands to Bicep; Bicep then creates the Key Vault AND
# pre-populates secrets in a single deploy. Nothing is written to KV
# from this script (it doesn't exist yet on a first deploy).
# ══════════════════════════════════════════
KV_SECRETS_JSON='{}'

if [ "$PROMPT_SECRETS" = true ]; then
  if [ ! -f "$SERVICE_JSON" ]; then
    echo -e "${RED}ERROR: Service config not found: $SERVICE_JSON${NC}"
    exit 1
  fi

  echo ""
  echo -e "${CYAN}${BOLD}── Phase 1: Service Configuration ──${NC}"

  # ── Ask questions ──
  QUESTIONS=$(jq -c '.questions // []' "$SERVICE_JSON")
  Q_COUNT=$(echo "$QUESTIONS" | jq 'length')

  if [ "$Q_COUNT" -gt 0 ]; then
    echo ""
    while IFS= read -r q; do
      VAR=$(echo "$q" | jq -r '.var')
      PROMPT=$(echo "$q" | jq -r '.prompt')
      DEFAULT=$(echo "$q" | jq -r '.default // "yes"')
      read -rp "  ${PROMPT} [${DEFAULT}]: " answer < /dev/tty
      answer="${answer:-$DEFAULT}"
      # Normalize y/n synonyms so the conditional-secret check below is
      # case-insensitive and tolerant of "Y", "YES", "true", etc.
      # Non-yn inputs pass through unchanged (future free-text questions).
      case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
        y|yes|true|1|on)  answer="yes" ;;
        n|no|false|0|off) answer="no"  ;;
      esac
      export "$VAR"="$answer"
    done < <(echo "$QUESTIONS" | jq -c '.[]')
  fi

  # ── Generate/prompt secrets ──
  SECRETS=$(jq -c '.secrets // []' "$SERVICE_JSON")
  S_COUNT=$(echo "$SECRETS" | jq 'length')

  if [ "$S_COUNT" -gt 0 ]; then
    echo ""
    echo "--- Secrets ---"

    while IFS= read -r s; do
      ENV_VAR=$(echo "$s" | jq -r '.envVar')
      PROMPT_TEXT=$(echo "$s" | jq -r '.prompt')
      GEN_METHOD=$(echo "$s" | jq -r '.generate')
      CONDITION=$(echo "$s" | jq -r '.condition // "always"')

      if [ "$CONDITION" != "always" ]; then
        COND_VAL="${!CONDITION:-no}"
        if [ "$COND_VAL" != "yes" ]; then
          continue
        fi
      fi

      KV_SECRET_NAME="${SERVICE}-$(echo "$ENV_VAR" | tr '[:upper:]_' '[:lower:]-')"

      # ── Reuse from Key Vault if present (idempotent re-run) ──
      # On a true first deploy KEY_VAULT_NAME is empty, so this is a no-op
      # and we fall through to generate. On subsequent deploys the previous
      # writeback populated KEY_VAULT_NAME, so we can read existing values
      # and avoid rotating MASTER_KEY / passwords (which would brick the
      # running cluster). --rotate-secrets bypasses the reuse path.
      REUSED_VALUE=""
      if [ "$ROTATE_SECRETS" != true ] && [ -n "${KEY_VAULT_NAME:-}" ]; then
        REUSED_VALUE=$(timeout 30 az keyvault secret show \
          --vault-name "${KEY_VAULT_NAME}" \
          --name "${KV_SECRET_NAME}" \
          --query value -o tsv 2>/dev/null || echo "")
      fi

      if [ -n "$REUSED_VALUE" ]; then
        # Reuse: don't add to KV_SECRETS_JSON — Bicep won't touch the
        # existing secret. Just export so Phase 3 helm rendering sees it.
        echo "  ${PROMPT_TEXT}: (reusing existing from Key Vault)"
        export "$ENV_VAR"="$REUSED_VALUE"
        continue
      fi

      VALUE=""
      case "$GEN_METHOD" in
        prompt)
          read -rsp "  ${PROMPT_TEXT}: " VALUE < /dev/tty; echo
          if [ -z "$VALUE" ]; then
            VALUE=$(openssl rand -base64 24)
            echo "    (auto-generated)"
          fi
          ;;
        hex32)
          VALUE=$(openssl rand -hex 32)
          echo "  ${PROMPT_TEXT}: (auto-generated)"
          ;;
        base64_24)
          VALUE=$(openssl rand -base64 24)
          echo "  ${PROMPT_TEXT}: (auto-generated)"
          ;;
        storage_key)
          # Storage account doesn't exist yet on a first deploy.
          # Fetched in Phase 2.5 once Bicep has provisioned storage + KV.
          echo "  ${PROMPT_TEXT}: (deferred — fetched after storage is provisioned)"
          continue
          ;;
        skip)
          continue
          ;;
      esac

      # Buffer into the keyVaultSecrets JSON object Bicep will consume.
      # Use jq so passwords with $, quotes, backticks, etc. survive intact.
      KV_SECRETS_JSON=$(jq -nc \
        --argjson cur "$KV_SECRETS_JSON" \
        --arg k "$KV_SECRET_NAME" \
        --arg v "$VALUE" \
        '$cur + {($k): $v}')
      echo "    → queued for Key Vault as: ${KV_SECRET_NAME}"

      # Export so Phase 2 (Bicep params, e.g. pgAdminPassword) and
      # Phase 3 (helm values rendering) can read them in this same shell.
      export "$ENV_VAR"="$VALUE"
    done < <(echo "$SECRETS" | jq -c '.[]')
  fi
fi

# ══════════════════════════════════════════
# Phase 2: Azure infrastructure (Bicep)
# ══════════════════════════════════════════
echo ""
echo -e "${CYAN}${BOLD}── Phase 2: Azure Infrastructure ──${NC}"

if [ ! -f "$PARAM_FILE" ]; then
  echo -e "${RED}ERROR: Parameter file not found: $PARAM_FILE${NC}"
  exit 1
fi

# Auto-discover existing privatelink DNS zones so Bicep reuses them
# instead of creating duplicates. A VNet can only be linked to one zone
# of each name, so if the centrally-managed zone exists we MUST reuse it.
echo ""
echo ">>> Discovering existing privatelink DNS zones..."
for entry in \
  "EXISTING_DNS_ZONE_ID_PG:privatelink.postgres.database.usgovcloudapi.net" \
  "EXISTING_DNS_ZONE_ID_BLOB:privatelink.blob.core.usgovcloudapi.net" \
  "EXISTING_DNS_ZONE_ID_KV:privatelink.vaultcore.usgovcloudapi.net"; do
  var="${entry%%:*}"
  zone="${entry##*:}"
  if [ -z "${!var:-}" ]; then
    found=$(az network private-dns zone list \
      --query "[?name=='${zone}'].id | [0]" -o tsv 2>/dev/null || true)
    if [ -n "$found" ]; then
      export "$var"="$found"
      echo "  ${zone} → reusing existing zone"
    else
      echo "  ${zone} → will be created"
    fi
  fi
done

# Build override params as a bash array — preserves quoting through the
# az invocation. Avoids `eval`, which would re-parse password values that
# may contain $, backticks, single-quotes, etc.
OVERRIDE_PARAMS=(
  -p "aksClusterName=${AKS_CLUSTER_NAME}"
  -p "aksClusterResourceGroup=${AKS_RESOURCE_GROUP}"
  -p "vnetName=${VNET_NAME}"
  -p "vnetResourceGroup=${VNET_RESOURCE_GROUP:-$AKS_RESOURCE_GROUP}"
  -p "privateEndpointSubnetName=${PE_SUBNET_NAME:-default}"
  -p "acrName=${ACR_NAME}"
  -p "acrResourceGroup=${ACR_RESOURCE_GROUP:-$AKS_RESOURCE_GROUP}"
)

# Pass existing resource names (skip empty so Bicep falls back to the
# bicepparam defaults / creates new).
[ -n "${KEY_VAULT_NAME:-}" ]       && OVERRIDE_PARAMS+=(-p "existingKeyVaultName=${KEY_VAULT_NAME}")
[ -n "${PG_SERVER_NAME:-}" ]       && OVERRIDE_PARAMS+=(-p "existingPgServerName=${PG_SERVER_NAME}")
[ -n "${STORAGE_ACCOUNT_NAME:-}" ] && OVERRIDE_PARAMS+=(-p "existingStorageAccountName=${STORAGE_ACCOUNT_NAME}")

# Pass PG admin password if Phase 1 collected it.
[ -n "${PG_ADMIN_PASSWORD:-}" ] && OVERRIDE_PARAMS+=(-p "pgAdminPassword=${PG_ADMIN_PASSWORD}")

# New Key Vault name (convention: <first 3 of cluster>-<first letter of env>-kv-<service>).
# KV names cap at 24 chars, so trim hard.
if [ -z "${NEW_KEY_VAULT_NAME:-}" ]; then
  CLUSTER_PREFIX="${AKS_CLUSTER_NAME:0:3}"
  ENV_LETTER="${ENV:0:1}"
  NEW_KEY_VAULT_NAME=$(echo "${CLUSTER_PREFIX}-${ENV_LETTER}-kv-${SERVICE}" | tr '[:upper:]' '[:lower:]')
  NEW_KEY_VAULT_NAME="${NEW_KEY_VAULT_NAME:0:24}"
fi
OVERRIDE_PARAMS+=(-p "newKeyVaultName=${NEW_KEY_VAULT_NAME}")

# Grant the current az identity (user or SP) get/list/set/delete on
# the Key Vault so deploy.sh's Phase-1 reuse check, Phase-2.5 storage-key
# write, and helm-deploy.sh's secret-list call all succeed without
# needing an out-of-band access-policy grant.
#
# Resolution order:
#   1. --deployer-object-id=<id> CLI flag (or DEPLOYER_OBJECT_ID env var)
#   2. az ad signed-in-user show (interactive user)
#   3. az ad sp show via az account user.name (service principal, e.g. CI)
if [ -z "$DEPLOYER_OBJECT_ID" ]; then
  DEPLOYER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
fi
if [ -z "$DEPLOYER_OBJECT_ID" ]; then
  CURRENT_SP_APP_ID=$(az account show --query user.name -o tsv 2>/dev/null || echo "")
  if [ -n "$CURRENT_SP_APP_ID" ]; then
    DEPLOYER_OBJECT_ID=$(az ad sp show --id "$CURRENT_SP_APP_ID" --query id -o tsv 2>/dev/null || echo "")
  fi
fi
if [ -n "$DEPLOYER_OBJECT_ID" ]; then
  OVERRIDE_PARAMS+=(-p "deployerObjectId=${DEPLOYER_OBJECT_ID}")
  echo "  Granting KV access to deployer objectId: ${DEPLOYER_OBJECT_ID}"
else
  # Without a deployer policy on the KV, Phase-1 reuse, Phase-2.5 storage-key
  # write, and helm-deploy.sh's secret-list call all 403 silently — the deploy
  # appears to succeed but artifactory comes up with empty secrets and crashes.
  # Fail loud here instead of letting that play out.
  echo -e "  ${RED}ERROR: Could not resolve deployer objectId.${NC}" >&2
  echo -e "  ${RED}Without it the Key Vault access policy can't grant the deployer access,${NC}" >&2
  echo -e "  ${RED}and Phase-2.5 / helm-deploy.sh will fail to read or write secrets.${NC}" >&2
  echo -e "  ${RED}Resolution attempts that failed:${NC}" >&2
  echo -e "  ${RED}  - --deployer-object-id=<id> CLI flag (not provided)${NC}" >&2
  echo -e "  ${RED}  - DEPLOYER_OBJECT_ID env var (not set)${NC}" >&2
  echo -e "  ${RED}  - az ad signed-in-user show (no objectId returned)${NC}" >&2
  echo -e "  ${RED}  - az ad sp show via az account user.name (no objectId returned)${NC}" >&2
  echo -e "  ${RED}Provide one explicitly:${NC}" >&2
  echo -e "  ${RED}  ./bicep/deploy.sh ${SERVICE} ${ENV} --confirm --secrets --deployer-object-id=<your-aad-object-id>${NC}" >&2
  exit 1
fi

# Discovered privatelink zone IDs (skip Bicep zone creation when reusing).
[ -n "${EXISTING_DNS_ZONE_ID_PG:-}" ]   && OVERRIDE_PARAMS+=(-p "existingPrivateDnsZoneIdPg=${EXISTING_DNS_ZONE_ID_PG}")
[ -n "${EXISTING_DNS_ZONE_ID_BLOB:-}" ] && OVERRIDE_PARAMS+=(-p "existingPrivateDnsZoneIdBlob=${EXISTING_DNS_ZONE_ID_BLOB}")
[ -n "${EXISTING_DNS_ZONE_ID_KV:-}" ]   && OVERRIDE_PARAMS+=(-p "existingPrivateDnsZoneIdKv=${EXISTING_DNS_ZONE_ID_KV}")

# Hand the buffered secrets to Bicep so the KV is created AND populated
# atomically. Empty object means "no secrets" — skip the param so the
# Bicep default of {} applies.
if [ "$KV_SECRETS_JSON" != "{}" ]; then
  OVERRIDE_PARAMS+=(-p "keyVaultSecrets=${KV_SECRETS_JSON}")
fi

if [ "$CONFIRM" = true ]; then
  echo ">>> Deploying infra as stack '${STACK_NAME}'..."
  az stack group create \
    --name "$STACK_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$MAIN_FILE" \
    --parameters "$PARAM_FILE" \
    "${OVERRIDE_PARAMS[@]}" \
    --action-on-unmanage deleteAll \
    --deny-settings-mode none

  echo -e "  ${GREEN}Infrastructure deployed.${NC}"

  # ── Write resource names back to azure.env from stack outputs ──
  # Avoids needing typed CLI commands (e.g. `az postgres flexible-server list`)
  # that may break in Gov Cloud when the local CLI uses a too-new API version.
  echo ">>> Writing deployed resource names back to azure.env..."
  STACK_OUT=$(az stack group show \
    --name "$STACK_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "outputs" -o json 2>/dev/null || echo "{}")

  OUT_PG=$(echo "$STACK_OUT" | jq -r '.pgServerName.value // empty')
  OUT_PG_FQDN=$(echo "$STACK_OUT" | jq -r '.pgServerFqdn.value // empty')
  OUT_SA=$(echo "$STACK_OUT" | jq -r '.storageAccountName.value // empty')
  OUT_BLOB_SUFFIX=$(echo "$STACK_OUT" | jq -r '.blobEndpointSuffix.value // empty')
  OUT_KV=$(echo "$STACK_OUT" | jq -r '.keyVaultName.value // empty')
  OUT_ACR=$(echo "$STACK_OUT" | jq -r '.acrLoginServer.value // empty')

  for kv in \
    "PG_SERVER_NAME:$OUT_PG" \
    "PG_SERVER_FQDN:$OUT_PG_FQDN" \
    "STORAGE_ACCOUNT_NAME:$OUT_SA" \
    "BLOB_ENDPOINT_SUFFIX:$OUT_BLOB_SUFFIX" \
    "KEY_VAULT_NAME:$OUT_KV" \
    "ACR_LOGIN_SERVER:$OUT_ACR"; do
    var="${kv%%:*}"
    val="${kv##*:}"
    [ -z "$val" ] || [ "$val" = "not deployed" ] && continue
    if grep -qE "^${var}=" "$ENV_FILE"; then
      sed -i "s|^${var}=.*|${var}=\"${val}\"|" "$ENV_FILE"
    else
      echo "${var}=\"${val}\"" >> "$ENV_FILE"
    fi
    export "$var"="$val"
    echo "  ${var}=${val}"
  done

  # Re-source so Phase 3 sees the populated names this run
  set -a; source "$ENV_FILE"; set +a
else
  echo ">>> Dry run (what-if)..."
  az deployment group what-if \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$MAIN_FILE" \
    --parameters "$PARAM_FILE" \
    "${OVERRIDE_PARAMS[@]}"
  echo ""
  echo "Dry run complete. Add --confirm to deploy."
  exit 0
fi

# ══════════════════════════════════════════
# Phase 2.4: Post-infra preflight checks
# Validate DNS resolution + A-record presence + bootstrap image presence.
# Catches the 04-28 KV-hang failure mode (zone link missing → public IP →
# firewall blocks → 30-min timeout) in <5 seconds with a clear error.
# ══════════════════════════════════════════
if [ "$CONFIRM" = true ]; then
  echo ""
  echo -e "${CYAN}${BOLD}── Phase 2.4: Preflight Checks ──${NC}"

  PREFLIGHT_FAILED=false

  # ── DNS resolution: each PE-backed FQDN must return a 10.x.x.x private IP ──
  # If a public IP comes back, the spoke VNet isn't linked to the central
  # privatelink zone (or the zone has no A-record for this resource).
  declare -A DNS_TARGETS=()
  [ -n "${KEY_VAULT_NAME:-}" ]       && DNS_TARGETS["KV"]="${KEY_VAULT_NAME}.vault.usgovcloudapi.net"
  [ -n "${PG_SERVER_FQDN:-}" ]       && DNS_TARGETS["PG"]="${PG_SERVER_FQDN}"
  [ -n "${STORAGE_ACCOUNT_NAME:-}" ] && DNS_TARGETS["Storage"]="${STORAGE_ACCOUNT_NAME}.blob.core.usgovcloudapi.net"

  if [ ${#DNS_TARGETS[@]} -gt 0 ]; then
    echo "  Resolving private endpoint FQDNs..."
    for label in "${!DNS_TARGETS[@]}"; do
      fqdn="${DNS_TARGETS[$label]}"
      # nslookup returns 0 on NXDOMAIN; check actual resolved IP
      ip=$(getent hosts "$fqdn" 2>/dev/null | awk '{print $1; exit}')
      [ -z "$ip" ] && ip=$(nslookup "$fqdn" 2>/dev/null | awk '/^Address: / {print $2; exit}')

      if [ -z "$ip" ]; then
        echo -e "    ${RED}FAIL${NC}: ${label} ${fqdn} did not resolve (NXDOMAIN)"
        PREFLIGHT_FAILED=true
      elif [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || [[ "$ip" =~ ^192\.168\. ]]; then
        echo -e "    ${GREEN}OK${NC}:   ${label} ${fqdn} → ${ip}"
      else
        echo -e "    ${RED}FAIL${NC}: ${label} ${fqdn} → ${ip} (public IP — spoke VNet not linked to central zone, or zone missing A-record)"
        PREFLIGHT_FAILED=true
      fi
    done
  fi

  # ── A-record presence in central privatelink zones ──
  # PE can be in 'Succeeded' state and the A-record can still be absent if
  # the dnsZoneGroup write 403'd silently (Private DNS Zone Contributor
  # missing on the central zone). This catches that case explicitly.
  if [ -n "${EXISTING_DNS_ZONE_ID_KV:-}" ] && [ -n "${KEY_VAULT_NAME:-}" ]; then
    echo "  Validating A-records in central privatelink zones..."
    declare -A AR_TARGETS=()
    AR_TARGETS["${KEY_VAULT_NAME}"]="${EXISTING_DNS_ZONE_ID_KV}"
    [ -n "${EXISTING_DNS_ZONE_ID_PG:-}" ]   && [ -n "${PG_SERVER_NAME:-}" ]       && AR_TARGETS["${PG_SERVER_NAME}"]="${EXISTING_DNS_ZONE_ID_PG}"
    [ -n "${EXISTING_DNS_ZONE_ID_BLOB:-}" ] && [ -n "${STORAGE_ACCOUNT_NAME:-}" ] && AR_TARGETS["${STORAGE_ACCOUNT_NAME}"]="${EXISTING_DNS_ZONE_ID_BLOB}"

    for record_name in "${!AR_TARGETS[@]}"; do
      zone_id="${AR_TARGETS[$record_name]}"
      zone_rg=$(echo "$zone_id" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="resourceGroups") print $(i+1)}')
      zone_name=$(basename "$zone_id")
      found=$(az network private-dns record-set a list \
        --resource-group "$zone_rg" \
        --zone-name "$zone_name" \
        --query "[?name=='${record_name}'].name | [0]" \
        -o tsv 2>/dev/null || echo "")
      if [ -n "$found" ]; then
        echo -e "    ${GREEN}OK${NC}:   A-record '${record_name}' present in ${zone_name}"
      else
        echo -e "    ${RED}FAIL${NC}: A-record '${record_name}' missing in ${zone_name}"
        echo -e "    ${YELLOW}        → PE 'Succeeded' but dnsZoneGroup write failed (Private DNS Zone Contributor RBAC?)${NC}"
        PREFLIGHT_FAILED=true
      fi
    done
  fi

  # ── Bootstrap image presence in ACR ──
  # The jfrog-bootstrap chart Job pulls postgres:16-alpine. If it isn't
  # mirrored to ACR, the Job pod ImagePullBackOff's mid-deploy with a
  # confusing pull error rather than a clear "image not present".
  if [ "$SERVICE" = "artifactory" ] && [ -n "${ACR_NAME:-}" ]; then
    echo "  Verifying bootstrap image in ACR..."
    if az acr repository show --name "$ACR_NAME" --image "postgres:16-alpine" >/dev/null 2>&1; then
      echo -e "    ${GREEN}OK${NC}:   ${ACR_NAME}/postgres:16-alpine present"
    else
      echo -e "    ${RED}FAIL${NC}: ${ACR_NAME}/postgres:16-alpine missing — bootstrap Job will ImagePullBackOff"
      echo -e "    ${YELLOW}        → Re-run package.sh on connected machine and load.sh on jumpbox${NC}"
      PREFLIGHT_FAILED=true
    fi
  fi

  if [ "$PREFLIGHT_FAILED" = true ]; then
    echo ""
    echo -e "${RED}>>> Preflight checks failed. Fix the above before continuing.${NC}"
    echo -e "${YELLOW}    To skip preflight (NOT recommended), set SKIP_PREFLIGHT=1${NC}"
    if [ "${SKIP_PREFLIGHT:-0}" != "1" ]; then
      exit 1
    fi
    echo -e "${YELLOW}    SKIP_PREFLIGHT=1 set — continuing despite failures${NC}"
  else
    echo -e "  ${GREEN}All preflight checks passed.${NC}"
  fi
fi

# ══════════════════════════════════════════
# Phase 2.5: Post-infra secret retrieval
# Storage account didn't exist during Phase 1, so the storage_key
# secret was deferred. Now that storage + KV are both up, fetch the
# key and write it directly to KV. Reuses the existing KV value if
# present unless --rotate-secrets was passed.
#
# Each az data-plane call is wrapped in `timeout` so a hung KV
# (network drop, propagation lag, missing access policy) fails fast
# instead of stalling the deploy on az's internal retry/backoff.
# ══════════════════════════════════════════
if [ "$PROMPT_SECRETS" = true ] && [ -n "${STORAGE_ACCOUNT_NAME:-}" ] && [ -n "${KEY_VAULT_NAME:-}" ]; then
  echo ""
  echo -e "${CYAN}${BOLD}── Phase 2.5: Post-infra Secrets ──${NC}"
  KV_SAK_NAME="${SERVICE}-storage-account-key"

  EXISTING_SAK=""
  if [ "$ROTATE_SECRETS" != true ]; then
    echo "  Checking Key Vault for existing ${KV_SAK_NAME}..."
    EXISTING_SAK=$(timeout 30 az keyvault secret show \
      --vault-name "${KEY_VAULT_NAME}" \
      --name "${KV_SAK_NAME}" \
      --query value -o tsv 2>/dev/null || echo "")
  fi

  if [ -n "$EXISTING_SAK" ]; then
    export STORAGE_ACCOUNT_KEY="$EXISTING_SAK"
    echo "  → ${KV_SAK_NAME}: (reusing existing from Key Vault)"
  else
    # `az storage account keys list` is a management-plane call against
    # management.usgovcloudapi.net — it isn't routed through the privatelink
    # zones and shouldn't ever hang in this environment. No timeout wrapper.
    echo "  Fetching storage account key from Azure..."
    SAK=$(az storage account keys list \
      --resource-group "${RESOURCE_GROUP}" \
      --account-name "${STORAGE_ACCOUNT_NAME}" \
      --query "[0].value" -o tsv 2>/dev/null || echo "")
    if [ -n "$SAK" ]; then
      echo "  Writing ${KV_SAK_NAME} to Key Vault..."
      if timeout 30 az keyvault secret set \
        --vault-name "${KEY_VAULT_NAME}" \
        --name "${KV_SAK_NAME}" \
        --value "$SAK" \
        --output none 2>/dev/null; then
        echo "  → ${KV_SAK_NAME} stored in Key Vault"
      else
        echo -e "  ${YELLOW}→ Failed to store ${KV_SAK_NAME} in Key Vault (timeout or auth issue)${NC}"
        echo -e "  ${YELLOW}  Verify: az keyvault secret list --vault-name ${KEY_VAULT_NAME}${NC}"
      fi
      export STORAGE_ACCOUNT_KEY="$SAK"
    else
      echo -e "  ${YELLOW}→ Could not retrieve storage account key (timeout or auth issue)${NC}"
      echo -e "  ${YELLOW}  Verify: az storage account keys list -g ${RESOURCE_GROUP} -n ${STORAGE_ACCOUNT_NAME}${NC}"
    fi
  fi
fi

# ══════════════════════════════════════════
# Phase 3: Application deployment
# ══════════════════════════════════════════
if [ "$PROMPT_SECRETS" = true ]; then
  echo ""
  echo -e "${CYAN}${BOLD}── Phase 3: Application Deployment ──${NC}"

  if [ "$USE_ARGOCD" = true ]; then
    echo ">>> Deploying via ArgoCD..."
    "${SCRIPT_DIR}/argocd-deploy.sh" "$SERVICE" "$ENV"
  else
    echo ">>> Deploying via Helm..."
    "${SCRIPT_DIR}/helm-deploy.sh" "$SERVICE" "$ENV"
  fi
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Deployment complete: ${SERVICE} (${ENV})${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""
echo "  Commands:"
echo "    Status:   ./bicep/deploy.sh ${SERVICE} ${ENV} --status"
echo "    Teardown: ./bicep/deploy.sh ${SERVICE} ${ENV} --teardown --confirm"