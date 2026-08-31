# Known Issues & Recurring Failure Modes

Living document of the things that bite during deploys to AKS in Gov Cloud, in rough order of how often they bite.

---

## 1. Key Vault data-plane unreachable from the deploying machine

**Symptom**: `az keyvault secret list / show / set` hangs for minutes (or until our `timeout 30` wrapper fires). Phase 2.5 stalls; Phase 3 stalls at `[3/6] Reading secrets from Key Vault`. The TCP connection to the resolved KV IP never establishes.

**Why this happens**: in this environment the privatelink zones (`privatelink.vaultcore.usgovcloudapi.net`, `.postgres.database.usgovcloudapi.net`, `.blob.core.usgovcloudapi.net`) are **centrally linked** to the VNet. Once a privatelink zone is linked, every public hostname under that service (`<vault>.vault.usgovcloudapi.net`) gets a CNAME to the privatelink form (`<vault>.privatelink.vaultcore.usgovcloudapi.net`), and DNS resolution for that name comes from the private zone. If the private zone has no A-record for *this* vault, you get a CNAME with no terminal address, or a stale 10.x address, or both.

**What we've observed**:
- DNS returns a 10.x address that doesn't actually correspond to a live PE.
- `az network private-dns record-set a list` against the zone returns empty for our deploying user (likely because the central zone is in a subscription/RG we don't have read on).
- A PE for the KV exists (`pe-kv-artifactory`, state `Succeeded`), but no A-record for it appears in any zone we can see.
- TCP to whatever IP DNS gives us is BLOCKED.

**Diagnostic path**: see `CHEATSHEET.md` "Quick reachability tests."

**Required platform-team grants** to make this go away durably:
- `Private DNS Zone Contributor` on each central privatelink zone (vaultcore, postgres, blob, plus azurecr.us if the ACR is private). Scope: the zone itself, not the parent RG.
- Pass each zone's full ARM resource ID to Bicep via `existingPrivateDnsZoneId{Pg,Blob,Kv}` (or via the `EXISTING_DNS_ZONE_ID_*` env vars that `deploy.sh` discovers and forwards). With these set, Bicep skips local zone creation and points the PE's `dnsZoneGroup` at the central zone — A-record registration then becomes automatic on every deploy.

**Workarounds while you wait for the role grant**:
- **`/etc/hosts` unblock** on the jumpbox if TCP to the actual PE IP works. See cheatsheet.
- **Manual A-record** added by the platform team after each PE creation.

---

## 2. Soft-deleted Key Vault blocks redeploy under the same name

**Symptom**: After `--teardown`, redeploying with the same KV name fails — Bicep refuses to create a vault that conflicts with the soft-deleted one.

**Why**: `enablePurgeProtection: true` is the default in `keyvault.bicep`. Once a vault soft-deletes, the name is reserved for **90 days**, no purge possible. Some Azure Policies require purge protection on, so flipping it off is not always an option.

**Workarounds**:
- **Recover** the soft-deleted vault and continue using it:
  ```bash
  az keyvault recover --name "$KEY_VAULT_NAME" --location "$LOCATION"
  ```
- **Use a fresh name** for the next deploy:
  ```bash
  export NEW_KEY_VAULT_NAME="kv-art-dev2"
  ./bicep/deploy.sh artifactory dev --confirm --secrets
  ```

---

## 3. Stale `azure.env` per-service refs after teardown (FIXED)

**Symptom (historical)**: After `--teardown`, the next deploy failed with `ResourceNotFound` (PG) and `ParentResourceNotFound` (Storage) because `azure.env` still pointed at the deleted resources, and `deploy.sh` passed those names to Bicep as `existing*` params.

**Status**: Fixed in `d4642ec`. `--teardown` now clears `KEY_VAULT_NAME`, `PG_SERVER_NAME`, `PG_SERVER_FQDN`, `STORAGE_ACCOUNT_NAME`, `BLOB_ENDPOINT_SUFFIX` from `azure.env`.

**If you see it again** (e.g. someone tore down with an older script):
```bash
for v in KEY_VAULT_NAME PG_SERVER_NAME PG_SERVER_FQDN STORAGE_ACCOUNT_NAME BLOB_ENDPOINT_SUFFIX; do
  sed -i "s|^${v}=.*|${v}=\"\"|" bicep/env/azure.env
done
```

---

## 4. Managed identity is unused — image pulls go through the AKS kubelet identity

**Status**: Resolved by deletion. `main.bicep` no longer instantiates `modules/managed-identity.bicep`. The module file is kept on disk but unreferenced.

**Why we removed it**: the module created a User-Assigned MI plus role assignments (`AcrPull` on ACR, `Cluster User` on AKS, `Contributor` on the deploy RG). Three problems:

1. Creating those role assignments requires `Owner` / `User Access Administrator` at the AKS and ACR scopes — the deployer identity in this environment doesn't have that, and the entire Bicep stack fails at the `Microsoft.Authorization/roleAssignments` step.
2. The MI was orphaned: no federated identity credential, no K8s ServiceAccount annotation in any chart values. Granting it `AcrPull` did nothing for actual image pulls.
3. The `Contributor on RG` assignment had **no `scope:` property**, so it landed on the deploy RG (not the AKS RG as the comment claimed), and Contributor is wildly more access than needed for `az aks get-credentials`.

**How image pulls work now**: The **AKS kubelet identity** (an MI separate from anything Bicep creates) is what pulls images from ACR. The platform team grants this once per cluster:

```bash
az aks update -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --attach-acr "$ACR_NAME"
```

That single command grants `AcrPull` to the kubelet identity on the ACR. All services on the cluster benefit. No per-service MI needed.

**Authentication from pods**: Artifactory and the other services authenticate to PG / KV / Storage with passwords held in K8s secrets (synced from Key Vault by `helm-deploy.sh` at deploy time). No runtime Azure RBAC is needed. Workload identity / federated credentials are an option for future services that want token-based auth, but adding them now would be premature.

---

## 5. PostgreSQL Flexible Server CLI hits API-version mismatch in Gov

**Symptom (historical)**: `az postgres flexible-server list` failed with API-version errors in Gov Cloud (CLI uses `2026-01-01-preview`, Gov supports up to `2025-08-01`).

**Status**: We avoided the typed CLI in `populate-env.sh` (now uses `az resource list` with explicit `--api-version` where needed) and `deploy.sh` (relies on Bicep stack outputs writeback rather than CLI lookups).

**If you need to query PG directly**:
```bash
az resource list --resource-type Microsoft.DBforPostgreSQL/flexibleServers \
  --api-version 2024-08-01 -o table
```

---

## 6. `populate-env.sh` "[0]" first-in-subscription footgun (FIXED)

**Symptom (historical)**: `populate-env.sh` ran `az keyvault list --query "[0]"` and wrote whatever vault appeared first into `azure.env` as `KEY_VAULT_NAME`. `deploy.sh` then passed it as `existingKeyVaultName=...` and Bicep wrote the new service's secrets into someone else's vault.

**Status**: Fixed in `b61e9b5`. `populate-env.sh` no longer auto-discovers per-service resources (KV, PG, Storage). Those are owned by `deploy.sh` and written back from Bicep stack outputs.

---

## 7. Subchart enables vs Phase-1 questions inconsistency (FIXED)

**Symptom (historical)**: Answering "no" to "Enable Xray?" only suppressed `XRAY_DB_PASSWORD` generation. The `xray.enabled: true` was still hardcoded in the values template, so the subchart started anyway and crashed without its secret.

**Status**: Fixed in `a87a640`. `values-templates/artifactory.values.yaml` now uses `${ENABLE_XRAY}` / `${ENABLE_RABBITMQ}` / `${ENABLE_DISTRIBUTION}` for `.enabled`. `helm-deploy.sh` resolves these from env (or JSON default) and normalizes y/n to YAML booleans before envsubst.

---

## 8. `--secrets` rerun rotated MASTER_KEY, bricked the cluster (FIXED)

**Symptom (historical)**: Re-running `deploy.sh --secrets` regenerated every prompt/hex32/base64_24 secret unconditionally. For a running Artifactory cluster, rotating `MASTER_KEY` makes existing data unreadable.

**Status**: Fixed in `65ece9f`. Phase 1 now reads existing values from KV by name and reuses them. Use `--rotate-secrets` to opt into regeneration.

---

## 9. Deploying user lacks KV access (FIXED)

**Symptom (historical)**: `deploy.sh` Phase 1 reuse check, Phase 2.5 storage-key write, and `helm-deploy.sh` secret-list all required `az keyvault set-policy` to be run out-of-band.

**Status**: Fixed in `c1bd280` + this PR. `keyvault.bicep` accepts a `deployerObjectId` param and adds the deploying user/SP to access policies on both new and existing vaults. `deploy.sh` resolves the objectId via `az ad signed-in-user show` (or SP fallback). When neither resolves, `deploy.sh` now exits 1 with a clear error rather than emitting a yellow warning and continuing with a silent KV-403 ahead.

**Override** when auto-resolution fails:
```bash
./bicep/deploy.sh artifactory dev --confirm --secrets \
  --deployer-object-id=<your-aad-object-id>
# or
DEPLOYER_OBJECT_ID=<your-aad-object-id> ./bicep/deploy.sh ...
```

---

## 10. Hardcoded Gov FQDN suffix in helm-deploy.sh (FIXED)

**Symptom (historical)**: `helm-deploy.sh` constructed `${PG_SERVER_NAME}.postgres.database.usgovcloudapi.net` regardless of cloud.

**Status**: Fixed in `c1bd280`. `helm-deploy.sh` prefers `PG_SERVER_FQDN` / `BLOB_ENDPOINT_SUFFIX` / `ACR_LOGIN_SERVER` from env (written back by `deploy.sh` from Bicep outputs) and falls back to a `az cloud show`-keyed cloud table.

---

## Reference: commit timeline

| Commit | What it fixed |
|---|---|
| `830b209` | Phase-1 secrets buffered to JSON, Bicep seeds KV atomically |
| `b61e9b5` | populate-env.sh stops auto-discovering per-service resources |
| `65ece9f` | Idempotent `--secrets` rerun, `--rotate-secrets` flag |
| `c1bd280` | Y/n normalization, FQDN/suffix from Bicep, deployer KV access |
| `a87a640` | Subchart toggles wired to questions, `--deployer-object-id` flag |
| `52ffd0d` | KV/storage data-plane calls wrapped in `timeout` |
| `d4642ec` | `--teardown` clears per-service refs from azure.env |
| `1a26d9b` | helm-deploy.sh KV calls wrapped in `timeout` |