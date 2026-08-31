#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# Artifactory deployment diagnostic — checks common failure modes
# Usage: ./bicep/diagnose.sh [<namespace>]
# ══════════════════════════════════════════════════════════════
set -uo pipefail

NS="${1:-artifactory}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env/azure.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

KV="${KEY_VAULT_NAME:-}"
PG_FQDN="${PG_SERVER_NAME:+${PG_SERVER_NAME}.postgres.database.usgovcloudapi.net}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0

pass()  { printf "  ${GREEN}✓${NC} %s\n" "$1"; PASS=$((PASS+1)); }
fail()  { printf "  ${RED}✗${NC} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${RED}→${NC} %s\n" "$2"; FAIL=$((FAIL+1)); }
warn()  { printf "  ${YELLOW}⚠${NC} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${YELLOW}→${NC} %s\n" "$2"; WARN=$((WARN+1)); }
section() { printf "\n${CYAN}${BOLD}── %s ──${NC}\n" "$1"; }

# ── 1. Namespace & workloads ──
section "Kubernetes workloads"
if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  fail "Namespace '$NS' does not exist"; exit 1
else pass "Namespace '$NS' exists"; fi

for pod in $(kubectl -n "$NS" get pods -o name 2>/dev/null | awk -F/ '{print $2}'); do
  NOT_READY=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{range .status.containerStatuses[*]}{.name}={.ready};{end}' | tr ';' '\n' | grep -c "=false" || true)
  RESTARTS=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[*].restartCount}' | tr ' ' '\n' | awk '{s+=$1} END {print s+0}')
  if [ "$NOT_READY" -eq 0 ]; then pass "$pod all containers ready (total restarts: $RESTARTS)"
  elif [ "$RESTARTS" -gt 10 ]; then fail "$pod $NOT_READY containers not ready, $RESTARTS total restarts"
  else warn "$pod $NOT_READY containers not ready, $RESTARTS restarts"; fi
done

# ── 2. Recent error events ──
section "Recent error events (last 5 min)"
ERRS=$(kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null \
  | awk '$1 ~ /^[0-9]+m?s$/ { if ($1 ~ /^[0-4]m$/ || $1 ~ /s$/) print }' \
  | grep -iE "error|fail|backoff|oom" | tail -5)
if [ -z "$ERRS" ]; then pass "No recent error events"
else warn "Recent errors found:" "$(echo "$ERRS" | head -3)"; fi

# ── 3. Key Vault secrets ──
section "Key Vault secrets"
if [ -z "$KV" ]; then warn "KEY_VAULT_NAME not set in azure.env"
else
  for S in artifactory-master-key artifactory-join-key artifactory-pg-admin-password \
           artifactory-artifactory-db-password artifactory-xray-db-password \
           artifactory-distribution-db-password artifactory-rabbitmq-password \
           artifactory-erlang-cookie artifactory-storage-account-key; do
    if az keyvault secret show --vault-name "$KV" --name "$S" --query value -o tsv >/dev/null 2>&1; then
      pass "KV secret: $S"
    else fail "KV secret missing: $S"; fi
  done
fi

# ── 4. K8s secrets match KV ──
section "K8s secret ↔ KV sync"
if [ -n "$KV" ]; then
  for pair in "artifactory-master-key:master-key:artifactory-master-key" \
              "artifactory-join-key:join-key:artifactory-join-key"; do
    KS=$(echo "$pair" | cut -d: -f1); KEY=$(echo "$pair" | cut -d: -f2); KVS=$(echo "$pair" | cut -d: -f3)
    K8S_VAL=$(kubectl -n "$NS" get secret "$KS" -o jsonpath="{.data.$KEY}" 2>/dev/null | base64 -d 2>/dev/null)
    KV_VAL=$(az keyvault secret show --vault-name "$KV" --name "$KVS" --query value -o tsv 2>/dev/null)
    if [ -z "$K8S_VAL" ]; then fail "$KS not found or empty in namespace"
    elif [ "$K8S_VAL" = "$KV_VAL" ]; then pass "$KS matches KV"
    else fail "$KS does NOT match KV (value drift)"; fi
  done
fi

# ── 5. PostgreSQL ──
section "PostgreSQL"
if [ -z "$PG_FQDN" ] || [ -z "$KV" ]; then
  warn "Skipping PG checks (PG_SERVER_NAME or KV missing)"
else
  PW=$(az keyvault secret show --vault-name "$KV" --name artifactory-pg-admin-password --query value -o tsv 2>/dev/null)
  if [ -z "$PW" ]; then fail "Cannot fetch PG admin password from KV"
  else
    TMPPOD="diag-pg-$$"
    OUT=$(kubectl -n "$NS" run "$TMPPOD" --rm -i --restart=Never \
      --image=postgres:16 --labels="sidecar.istio.io/inject=false" \
      --env="PGPASSWORD=$PW" -- \
      psql "host=$PG_FQDN user=pgadmin dbname=postgres sslmode=require" -At \
      -c "SELECT current_setting('max_connections');" \
      -c "SELECT count(*) FROM pg_stat_activity;" \
      -c "SELECT rolname FROM pg_roles WHERE rolname IN ('artifactory','xray','distribution') ORDER BY rolname;" \
      -c "SELECT datname FROM pg_database WHERE datname IN ('artifactory','xray','distribution') ORDER BY datname;" \
      2>/dev/null)
    MAXC=$(echo "$OUT" | sed -n '1p')
    CURC=$(echo "$OUT" | sed -n '2p')
    ROLES=$(echo "$OUT" | sed -n '3,5p' | tr '\n' ' ')
    DBS=$(echo "$OUT" | sed -n '6,8p' | tr '\n' ' ')
    if [ -n "$MAXC" ]; then
      pass "PG reachable — max_connections=$MAXC, current=$CURC"
      [ "$CURC" -gt "$((MAXC * 80 / 100))" ] && warn "PG connections >80% of max"
    else fail "Cannot reach PG"; fi
    for R in artifactory xray distribution; do
      echo "$ROLES" | grep -qw "$R" && pass "PG role exists: $R" || fail "PG role missing: $R"
    done
    for D in artifactory xray distribution; do
      echo "$DBS" | grep -qw "$D" && pass "PG database exists: $D" || fail "PG database missing: $D"
    done
  fi
fi

# ── 6. RabbitMQ ──
section "RabbitMQ"
if kubectl -n "$NS" get pod artifactory-rabbitmq-0 >/dev/null 2>&1; then
  VHOSTS=$(kubectl -n "$NS" exec artifactory-rabbitmq-0 -- rabbitmqctl list_vhosts 2>/dev/null | tail -n +2)
  echo "$VHOSTS" | grep -qw xray && pass "RabbitMQ vhost 'xray' exists" || fail "RabbitMQ vhost 'xray' missing" "rabbitmqctl add_vhost xray"
  PERMS=$(kubectl -n "$NS" exec artifactory-rabbitmq-0 -- rabbitmqctl list_permissions -p xray 2>/dev/null)
  echo "$PERMS" | grep -qw admin && pass "Admin has perms on xray vhost" || fail "Admin missing perms on xray vhost"
else warn "artifactory-rabbitmq-0 not found"; fi

# ── 7. Binarystore XML ──
section "Binarystore"
BS=$(kubectl -n "$NS" get secret artifactory-binarystore -o jsonpath='{.data.binarystore\.xml}' 2>/dev/null | base64 -d 2>/dev/null)
if [ -z "$BS" ]; then fail "binarystore.xml secret empty or missing"
elif echo "$BS" | grep -q "azure-blob-storage"; then pass "binarystore.xml configured for Azure Blob"
elif echo "$BS" | grep -q "file-system"; then fail "binarystore.xml using file-system (wrong type)" "check artifactory.artifactory.persistence.type in values"
else warn "binarystore.xml unrecognized type"; fi

# ── 8. StatefulSet init containers ──
section "StatefulSet init containers"
for STS in $(kubectl -n "$NS" get sts -o name 2>/dev/null | awk -F/ '{print $2}'); do
  INITS=$(kubectl -n "$NS" get sts "$STS" -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null)
  if echo "$INITS" | grep -qw postgres-setup-init; then
    fail "$STS still has postgres-setup-init" "re-run helm-deploy.sh to re-apply the patch"
  else pass "$STS no postgres-setup-init ✓"; fi
done

# ── 9. Investigation of failing pods ──
section "Investigation — failing containers"

investigate_container() {
  local pod="$1" container="$2" restarts="$3"
  printf "\n  ${BOLD}%s / %s${NC} (restarts: %s)\n" "$pod" "$container" "$restarts"

  # Try previous log first (post-crash), then current
  local log=""
  if [ "$restarts" -gt 0 ]; then
    log=$(kubectl -n "$NS" logs "$pod" -c "$container" --tail=60 --previous 2>/dev/null)
  fi
  [ -z "$log" ] && log=$(kubectl -n "$NS" logs "$pod" -c "$container" --tail=60 2>/dev/null)
  [ -z "$log" ] && { printf "    (no log available)\n"; return; }

  # Pattern-match common failure modes
  local hits=""
  echo "$log" | grep -qi "permission denied for schema public" && \
    hits+="    ${RED}•${NC} PG schema permission denied — run db-bootstrap.sh or manual GRANT\n"
  echo "$log" | grep -qi "password authentication failed" && \
    hits+="    ${RED}•${NC} PG password mismatch — check KV ↔ k8s secret ↔ PG server sync\n"
  echo "$log" | grep -qi "connection slots are reserved" && \
    hits+="    ${RED}•${NC} PG out of connections — reduce pool size or bump SKU\n"
  echo "$log" | grep -qi "username or password not allowed" && \
    hits+="    ${RED}•${NC} RabbitMQ auth failure — password drift vs KV\n"
  echo "$log" | grep -qi "no access to this vhost" && \
    hits+="    ${RED}•${NC} RabbitMQ vhost missing or no perms — rabbitmqctl add_vhost / set_permissions\n"
  echo "$log" | grep -qi "OutOfMemory\|OOMKilled\|java.lang.OutOfMemoryError" && \
    hits+="    ${RED}•${NC} Out of memory — increase resources.limits.memory\n"
  echo "$log" | grep -qi "CreateOrRefreshToken.*closed the stream" && \
    hits+="    ${RED}•${NC} Access token refresh failed — likely master/join key mismatch\n"
  echo "$log" | grep -qi "Premature end of file" && \
    hits+="    ${RED}•${NC} binarystore.xml empty — persistence config not rendering\n"
  echo "$log" | grep -qi "required node services are missing" && \
    hits+="    ${YELLOW}•${NC} Router waiting on microservices — downstream startup issue\n"
  echo "$log" | grep -qi "Postgres is not reachable" && \
    hits+="    ${YELLOW}•${NC} postgres-setup-init hardcodes postgres/postgres — patch it out\n"
  echo "$log" | grep -qi "pinging artifactory.*failed" && \
    hits+="    ${YELLOW}•${NC} Frontend can't reach artifactory Tomcat — wait for jfrt, or check router\n"
  echo "$log" | grep -qi "FATAL\|PANIC\|panic:\|Critical error" && \
    hits+="    ${RED}•${NC} Fatal error in logs (see tail below)\n"

  if [ -n "$hits" ]; then
    printf "${hits}"
  else
    printf "    ${YELLOW}•${NC} No known pattern matched — inspect manually\n"
  fi

  # Last 8 lines of log for quick scan
  printf "    ${CYAN}last log lines:${NC}\n"
  echo "$log" | tail -8 | sed 's/^/      /'
}

FAILING_FOUND=0
for pod in $(kubectl -n "$NS" get pods -o name 2>/dev/null | awk -F/ '{print $2}'); do
  while IFS=$'\t' read -r cname ready restarts; do
    [ -z "$cname" ] && continue
    if [ "$ready" = "false" ] && [ "$restarts" -gt 0 ]; then
      investigate_container "$pod" "$cname" "$restarts"
      FAILING_FOUND=1
    fi
  done < <(kubectl -n "$NS" get pod "$pod" \
    -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.ready}{"\t"}{.restartCount}{"\n"}{end}')
done

[ "$FAILING_FOUND" -eq 0 ] && pass "No containers need investigation"

# ── 10. Master/Join key files on disk ──
section "Master/Join key files on PVCs"

if [ -z "$KV" ]; then
  warn "Skipping disk check (KEY_VAULT_NAME not set)"
else
  # Find PVCs and the StatefulSets holding them
  STS_TO_RESTORE=()
  declare -A ORIG_REPLICAS
  for sts in $(kubectl -n "$NS" get sts -o name 2>/dev/null | awk -F/ '{print $2}' | grep -vE "^artifactory$|rabbitmq|redis"); do
    replicas=$(kubectl -n "$NS" get sts "$sts" -o jsonpath='{.spec.replicas}')
    if [ "$replicas" -gt 0 ]; then
      ORIG_REPLICAS["$sts"]="$replicas"
      STS_TO_RESTORE+=("$sts")
    fi
  done

  if [ ${#STS_TO_RESTORE[@]} -gt 0 ]; then
    printf "  ${YELLOW}Scaling down %s to free PVCs...${NC}\n" "${STS_TO_RESTORE[*]}"
    for sts in "${STS_TO_RESTORE[@]}"; do
      kubectl -n "$NS" scale sts "$sts" --replicas=0 >/dev/null 2>&1
    done
    # Wait for pods to terminate
    for i in 1 2 3 4 5 6; do
      REMAIN=$(kubectl -n "$NS" get pods -l app.kubernetes.io/instance=artifactory 2>/dev/null \
        | grep -cE "xray|distribution" || true)
      [ "$REMAIN" -eq 0 ] && break
      sleep 5
    done
  fi

  PVCS=$(kubectl -n "$NS" get pvc -o name 2>/dev/null \
    | awk -F/ '{print $2}' | grep "^data-volume-artifactory-" | grep -vE "artifactory-0$" || true)

  if [ -z "$PVCS" ]; then
    warn "No xray/distribution PVCs found to inspect"
  else
    VOL_YAML=""; MOUNT_YAML=""
    for pvc in $PVCS; do
      short=$(echo "$pvc" | sed 's/^data-volume-artifactory-//; s/-0$//')
      VOL_YAML+="
  - name: $short
    persistentVolumeClaim:
      claimName: $pvc"
      MOUNT_YAML+="
    - name: $short
      mountPath: /$short"
    done

    POD="keys-debug-$$"
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
  labels:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  containers:
  - name: debug
    image: alpine
    command: ["sleep", "300"]
    volumeMounts:$MOUNT_YAML
  volumes:$VOL_YAML
EOF

    if kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null 2>&1; then
      KV_MASTER=$(az keyvault secret show --vault-name "$KV" --name artifactory-master-key --query value -o tsv 2>/dev/null)
      KV_JOIN=$(az keyvault secret show --vault-name "$KV" --name artifactory-join-key --query value -o tsv 2>/dev/null)

      for pvc in $PVCS; do
        short=$(echo "$pvc" | sed 's/^data-volume-artifactory-//; s/-0$//')
        for key in master join; do
          DISK=$(kubectl -n "$NS" exec "$POD" -- sh -c "cat /$short/etc/security/${key}.key 2>/dev/null | tr -d '\n\r '" 2>/dev/null)
          EXP=$([ "$key" = "master" ] && echo "$KV_MASTER" || echo "$KV_JOIN")

          if [ -z "$DISK" ]; then
            fail "$short ${key}.key MISSING or empty on disk"
          elif [ "$DISK" = "$EXP" ]; then
            pass "$short ${key}.key matches KV ($(echo -n "$DISK" | wc -c) chars)"
          else
            fail "$short ${key}.key DOES NOT match KV" "disk=$(echo "$DISK" | cut -c1-12)..., kv=$(echo "$EXP" | cut -c1-12)..."
          fi
        done
      done
    else
      warn "Debug pod failed to start"
    fi

    kubectl -n "$NS" delete pod "$POD" --grace-period=0 --force >/dev/null 2>&1 || true
  fi

  # Scale StatefulSets back up
  if [ ${#STS_TO_RESTORE[@]} -gt 0 ]; then
    printf "  ${CYAN}Restoring replicas...${NC}\n"
    for sts in "${STS_TO_RESTORE[@]}"; do
      kubectl -n "$NS" scale sts "$sts" --replicas="${ORIG_REPLICAS[$sts]}" >/dev/null 2>&1
    done
  fi
fi

# ── Summary ──
section "Summary"
printf "  ${GREEN}${PASS} passed${NC}   ${YELLOW}${WARN} warnings${NC}   ${RED}${FAIL} failed${NC}\n\n"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
