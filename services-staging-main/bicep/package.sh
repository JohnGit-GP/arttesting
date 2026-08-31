#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# Package a service for air-gapped deployment
# Pulls Helm chart + auto-discovers container images + saves all
# as a transferable bundle with a load script for the target side.
#
# Usage:
#   ./bicep/package.sh <service>           # package a service
#   ./bicep/package.sh <service> --dry-run  # show what would be pulled
#
# Requires: helm, podman, jq
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

SERVICE="${1:?Usage: package.sh <service> [--dry-run]}"
DRY_RUN=false
[ "${2:-}" = "--dry-run" ] && DRY_RUN=true

CONF_FILE="${SCRIPT_DIR}/services/${SERVICE}.conf"
PKG_DIR="${SCRIPT_DIR}/packages/${SERVICE}"
VALUES_FILE="${SCRIPT_DIR}/values-templates/${SERVICE}.values.yaml"

# ── Check prerequisites ──
for cmd in helm podman jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}ERROR: $cmd is required but not found${NC}"
    exit 1
  fi
done

# ── Read service config ──
if [ ! -f "$CONF_FILE" ]; then
  echo -e "${RED}ERROR: Service config not found: $CONF_FILE${NC}"
  echo ""
  echo "Create it with the upstream chart details:"
  echo ""
  cat <<'EXAMPLE'
# bicep/services/<service>.conf
HELM_REPO_NAME="jfrog"
HELM_REPO_URL="https://charts.jfrog.io"
HELM_CHART_NAME="jfrog-platform"          # chart name (without repo prefix)
HELM_CHART_REF="jfrog/jfrog-platform"     # repo/chart for helm pull
HELM_CHART_VERSION="10.12.0"
HELM_RELEASE_NAME="artifactory"
IMAGE_REGISTRY=""                          # upstream registry (empty = default)

# helm template overrides to match your deployment config
HELM_SET_FLAGS=(
  "--set postgresql.enabled=false"
  "--set pipelines.enabled=false"
  "--set jfconnect.enabled=false"
  "--set nginx.enabled=false"
  "--set xray.enabled=true"
  "--set distribution.enabled=true"
  "--set rabbitmq.enabled=true"
)
EXAMPLE
  exit 1
fi

source "$CONF_FILE"

echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${BOLD}  Packaging: ${SERVICE}${NC}"
echo -e "${BOLD}  Chart:     ${HELM_CHART_REF} v${HELM_CHART_VERSION}${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"

# ── Create output directory ──
mkdir -p "$PKG_DIR"

# ═══════════════════════════════════════
# Step 1: Pull Helm chart
# ═══════════════════════════════════════
echo ""
echo -e "${CYAN}[1/5] Pulling Helm chart...${NC}"

helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" 2>/dev/null || true
helm repo update "$HELM_REPO_NAME"

CHART_TGZ="${PKG_DIR}/${HELM_CHART_NAME}-${HELM_CHART_VERSION}.tgz"
if [ -f "$CHART_TGZ" ]; then
  echo -e "  ${GREEN}Chart already exists: $(basename "$CHART_TGZ")${NC}"
else
  helm pull "$HELM_CHART_REF" \
    --version "$HELM_CHART_VERSION" \
    --destination "$PKG_DIR"
  echo -e "  ${GREEN}Downloaded: $(basename "$CHART_TGZ")${NC}"
fi

# ═══════════════════════════════════════
# Step 2: Extract image references
# ═══════════════════════════════════════
echo ""
echo -e "${CYAN}[2/5] Extracting image references from chart...${NC}"

# Build helm template command with set flags
TEMPLATE_CMD=(helm template "$HELM_RELEASE_NAME" "$CHART_TGZ")
TEMPLATE_CMD+=("--set" "global.imageRegistry=REGISTRY_PLACEHOLDER")

for flag in "${HELM_SET_FLAGS[@]}"; do
  # Split "--set key=value" into separate args
  TEMPLATE_CMD+=(${flag})
done

# Extract images — handles both quoted and unquoted image: references
IMAGES=$("${TEMPLATE_CMD[@]}" 2>/dev/null \
  | grep -E '^\s+image:\s' \
  | sed 's/^[[:space:]]*image:[[:space:]]*//' \
  | tr -d '"' | tr -d "'" \
  | sed 's|^REGISTRY_PLACEHOLDER/||' \
  | sort -u)

# Filter out empty lines and placeholder-only entries
IMAGES=$(echo "$IMAGES" | grep -v '^$' | grep -v '^REGISTRY_PLACEHOLDER$' || true)

IMAGE_COUNT=$(echo "$IMAGES" | grep -c . || echo 0)

if [ "$IMAGE_COUNT" -eq 0 ]; then
  echo -e "  ${YELLOW}WARNING: No images extracted from chart.${NC}"
  echo "  You may need to adjust HELM_SET_FLAGS in $CONF_FILE"
  echo "  Attempting fallback: extracting from chart values directly..."

  # Fallback: grep for image references in the chart's values.yaml
  IMAGES=$(tar -xzf "$CHART_TGZ" --to-stdout '*/values.yaml' 2>/dev/null \
    | grep -E 'repository:|tag:' \
    | sed 's/^[[:space:]]*//' \
    | paste -d: - - \
    | sed 's/repository:[[:space:]]*//' \
    | sed 's/[[:space:]]*tag:[[:space:]]*//' \
    | sort -u || true)

  IMAGE_COUNT=$(echo "$IMAGES" | grep -c . || echo 0)
fi

echo -e "  Found ${GREEN}${IMAGE_COUNT}${NC} images:"
echo "$IMAGES" | while read -r img; do
  echo -e "    ${img}"
done

# ── Append EXTRA_IMAGES from service .conf ──
# Used for images that don't show up in `helm template` but are still needed
# for deployment — e.g. the postgres:16-alpine bootstrap-Job image used by
# bicep/charts/jfrog-bootstrap/.
if [ "${#EXTRA_IMAGES[@]:-0}" -gt 0 ] 2>/dev/null || \
   { declare -p EXTRA_IMAGES &>/dev/null && [ "${#EXTRA_IMAGES[@]}" -gt 0 ]; }; then
  echo ""
  echo -e "  ${CYAN}Adding ${#EXTRA_IMAGES[@]} extra image(s) from ${SERVICE}.conf:${NC}"
  for extra in "${EXTRA_IMAGES[@]}"; do
    echo -e "    ${extra}"
    IMAGES=$(printf '%s\n%s' "$IMAGES" "$extra")
  done
  IMAGE_COUNT=$(echo "$IMAGES" | grep -c . || echo 0)
fi

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo -e "${YELLOW}DRY RUN — would pull and save these ${IMAGE_COUNT} images${NC}"
  echo -e "${YELLOW}Chart: ${CHART_TGZ}${NC}"
  exit 0
fi

# ═══════════════════════════════════════
# Step 3: Pull images with podman
# ═══════════════════════════════════════
echo ""
echo -e "${CYAN}[3/5] Pulling images with podman...${NC}"

PULLED_IMAGES=()
FAILED_IMAGES=()

while IFS= read -r img; do
  [ -z "$img" ] && continue

  # Determine the full pull reference
  # If image doesn't have a registry prefix, try docker.io
  PULL_REF="$img"
  if [[ "$img" != *"/"*"/"* ]] && [[ "$img" != *"."*"/"* ]]; then
    # No explicit registry — try common registries based on image prefix
    case "$img" in
      jfrog/*) PULL_REF="releases-docker.jfrog.io/${img}" ;;
      bitnami/*) PULL_REF="docker.io/${img}" ;;
      ubi9/*) PULL_REF="registry.access.redhat.com/${img}" ;;
      *) PULL_REF="docker.io/${img}" ;;
    esac
  fi

  echo -n "  Pulling ${img}... "
  if podman pull "$PULL_REF" 2>/dev/null; then
    echo -e "${GREEN}OK${NC}"
    PULLED_IMAGES+=("$PULL_REF")
  else
    echo -e "${RED}FAILED${NC}"
    FAILED_IMAGES+=("$PULL_REF")
  fi
done <<< "$IMAGES"

if [ ${#FAILED_IMAGES[@]} -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}WARNING: ${#FAILED_IMAGES[@]} image(s) failed to pull:${NC}"
  for img in "${FAILED_IMAGES[@]}"; do
    echo -e "  ${RED}${img}${NC}"
  done
  echo "You may need to log in to the registry or adjust the image references."
fi

if [ ${#PULLED_IMAGES[@]} -eq 0 ]; then
  echo -e "${RED}ERROR: No images were pulled. Cannot create package.${NC}"
  exit 1
fi

# ═══════════════════════════════════════
# Step 4: Save images to tar
# ═══════════════════════════════════════
echo ""
echo -e "${CYAN}[4/5] Saving ${#PULLED_IMAGES[@]} images to images.tar...${NC}"

IMAGES_TAR="${PKG_DIR}/images.tar"
podman save -o "$IMAGES_TAR" "${PULLED_IMAGES[@]}"

TAR_SIZE=$(du -h "$IMAGES_TAR" | cut -f1)
echo -e "  ${GREEN}Saved: images.tar (${TAR_SIZE})${NC}"

# ═══════════════════════════════════════
# Step 5: Write manifest and load script
# ═══════════════════════════════════════
echo ""
echo -e "${CYAN}[5/5] Writing manifest and load script...${NC}"

# Build image list as JSON array
IMAGE_JSON="["
FIRST=true
while IFS= read -r img; do
  [ -z "$img" ] && continue
  # Determine the pull ref (same logic as above)
  PULL_REF="$img"
  case "$img" in
    jfrog/*) PULL_REF="releases-docker.jfrog.io/${img}" ;;
    bitnami/*) PULL_REF="docker.io/${img}" ;;
    ubi9/*) PULL_REF="registry.access.redhat.com/${img}" ;;
  esac
  if [ "$FIRST" = true ]; then
    FIRST=false
  else
    IMAGE_JSON+=","
  fi
  IMAGE_JSON+="$(jq -n --arg orig "$PULL_REF" --arg short "$img" '{original: $orig, short: $short}')"
done <<< "$IMAGES"
IMAGE_JSON+="]"

# Write manifest
cat > "${PKG_DIR}/manifest.json" <<MANIFEST
{
  "service": "${SERVICE}",
  "chartName": "${HELM_CHART_NAME}",
  "chartVersion": "${HELM_CHART_VERSION}",
  "chartFile": "${HELM_CHART_NAME}-${HELM_CHART_VERSION}.tgz",
  "imagesFile": "images.tar",
  "imageCount": ${#PULLED_IMAGES[@]},
  "images": ${IMAGE_JSON},
  "packagedAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "packagedBy": "$(whoami)@$(hostname)"
}
MANIFEST

echo -e "  ${GREEN}Written: manifest.json${NC}"

# Write load script
cat > "${PKG_DIR}/load.sh" <<'LOADSCRIPT'
#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# Load packaged service images into target ACR
# Run this on the air-gapped machine after transferring the package
#
# Usage:
#   ./load.sh                    # load, tag, and push to ACR
#   ./load.sh --load-only        # just load images into podman (no push)
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/manifest.json"
ENV_FILE="${SCRIPT_DIR}/../../env/azure.env"
LOAD_ONLY=false
[ "${1:-}" = "--load-only" ] && LOAD_ONLY=true

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

if [ ! -f "$MANIFEST" ]; then
  echo -e "${RED}ERROR: manifest.json not found in $(pwd)${NC}"
  exit 1
fi

SERVICE=$(jq -r '.service' "$MANIFEST")
CHART_FILE=$(jq -r '.chartFile' "$MANIFEST")
CHART_VERSION=$(jq -r '.chartVersion' "$MANIFEST")
IMAGE_COUNT=$(jq -r '.imageCount' "$MANIFEST")

echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${BOLD}  Loading: ${SERVICE}${NC}"
echo -e "${BOLD}  Chart:   ${CHART_FILE}${NC}"
echo -e "${BOLD}  Images:  ${IMAGE_COUNT}${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"

# ── Load images ──
echo ""
echo -e "${CYAN}[1/3] Loading images from images.tar...${NC}"
podman load -i "${SCRIPT_DIR}/images.tar"
echo -e "  ${GREEN}Loaded ${IMAGE_COUNT} images${NC}"

if [ "$LOAD_ONLY" = true ]; then
  echo ""
  echo -e "${GREEN}Images loaded into local podman. Skipping ACR push.${NC}"
  exit 0
fi

# ── Read ACR from env ──
if [ ! -f "$ENV_FILE" ]; then
  echo -e "${RED}ERROR: azure.env not found at $ENV_FILE${NC}"
  echo "Run ./bicep/env/populate-env.sh first, or create azure.env manually."
  exit 1
fi

source "$ENV_FILE"

if [ -z "${ACR_NAME:-}" ]; then
  echo -e "${RED}ERROR: ACR_NAME is empty in azure.env${NC}"
  exit 1
fi

ACR_FQDN="${ACR_NAME}.azurecr.us"
echo ""
echo -e "${CYAN}[2/3] Tagging and pushing images to ${ACR_FQDN}...${NC}"

# Login to ACR
az acr login --name "$ACR_NAME" 2>/dev/null || {
  echo -e "${RED}WARNING: az acr login failed. Trying podman login...${NC}"
  podman login "$ACR_FQDN" || true
}

# Tag and push each image
IMAGE_SHORTS=$(jq -r '.images[].short' "$MANIFEST")
IMAGE_ORIGINALS=$(jq -r '.images[].original' "$MANIFEST")

paste <(echo "$IMAGE_ORIGINALS") <(echo "$IMAGE_SHORTS") | while IFS=$'\t' read -r original short; do
  TARGET="${ACR_FQDN}/${short}"
  echo -n "  ${short} -> ${ACR_FQDN}/... "
  podman tag "$original" "$TARGET" 2>/dev/null && \
  podman push "$TARGET" 2>/dev/null && \
  echo -e "${GREEN}OK${NC}" || \
  echo -e "${RED}FAILED${NC}"
done

# ── Push Helm chart to ACR as OCI ──
echo ""
echo -e "${CYAN}[3/3] Pushing Helm chart to OCI registry...${NC}"
helm push "${SCRIPT_DIR}/${CHART_FILE}" "oci://${ACR_FQDN}/helm" 2>/dev/null && \
  echo -e "  ${GREEN}Pushed: oci://${ACR_FQDN}/helm/${CHART_FILE%.tgz}${NC}" || \
  echo -e "  ${RED}FAILED — you may need: az acr login --name ${ACR_NAME}${NC}"

# ── Done ──
echo ""
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Package loaded successfully!${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo ""
echo "  Next steps:"
echo "    cd $(dirname "${SCRIPT_DIR}/..")"
echo "    ./deploy.sh ${SERVICE} dev --confirm --secrets"
LOADSCRIPT

chmod +x "${PKG_DIR}/load.sh"
echo -e "  ${GREEN}Written: load.sh${NC}"

# ── Summary ──
CHART_SIZE=$(du -h "$CHART_TGZ" | cut -f1)
echo ""
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Package complete!${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo ""
echo "  Output: ${PKG_DIR}/"
echo "    $(basename "$CHART_TGZ")    (${CHART_SIZE})"
echo "    images.tar          (${TAR_SIZE})"
echo "    manifest.json"
echo "    load.sh"
echo ""
echo "  Transfer the ${PKG_DIR}/ directory to the target machine, then run:"
echo "    ./bicep/packages/${SERVICE}/load.sh"