# Bicep Deploy Runbook

Operational guide for deploying services with the `bicep/` framework. Keep this next to `deploy.sh`.

## TL;DR

```bash
./bicep/env/populate-env.sh                          # once per environment
./bicep/deploy.sh <service> <env>                    # dry run (no changes)
./bicep/deploy.sh <service> <env> --confirm --secrets  # full deploy
```

---

## 1. Prerequisites (once per machine)

```bash
az cloud set --name AzureUSGovernment
az login
az account set --subscription "<subscription-id>"

# Verify
az --version
az bicep version         # Bicep is bundled with the az CLI
helm version             # only needed for --secrets (Helm) flow
kubectl version --client # only needed for --secrets (Helm) flow
```

Deploying identity needs (at minimum):
- `Contributor` (or equivalent) on the target deploy RG.
- `Microsoft.Authorization/roleAssignments/write` on the AKS RG and ACR RG (managed-identity module grants scoped roles there).
- `Microsoft.KeyVault/vaults/accessPolicies/write` on any existing Key Vault being reused.

## 2. Populate `azure.env` (once per environment)

Auto-discovers AKS, VNet, ACR, etc. from your subscription.

```bash
./bicep/env/populate-env.sh
```

Resulting file: `bicep/env/azure.env`. Required keys: `RESOURCE_GROUP`, `AKS_CLUSTER_NAME`, `AKS_RESOURCE_GROUP`, `VNET_NAME`, `ACR_NAME`.

## 3. Dry-run

```bash
./bicep/deploy.sh <service> <env>
```

Compiles the Bicep and shows the plan. No `--confirm` = no changes.

## 4. Full deploy

```bash
# Infra only
./bicep/deploy.sh <service> <env> --confirm

# Infra + wizard + Helm
./bicep/deploy.sh <service> <env> --confirm --secrets

# Infra + wizard + ArgoCD Application
./bicep/deploy.sh <service> <env> --confirm --secrets --argocd
```

## 5. Everyday ops

```bash
./bicep/deploy.sh <service> <env> --status              # show stack resources
./bicep/deploy.sh <service> <env> --teardown --confirm  # destroy everything
```

## 6. Key params to flip (in `params/<service>.<env>.bicepparam`)

| Param | Purpose |
|---|---|
| `deployPrivateEndpoints = true` | Lock down KV/Storage to private endpoints. |
| `updateExistingInfrastructure = true` | Push PG extensions / Storage blob service config onto an existing (reused) resource. |
| `existingPrivateDnsZoneId{Pg,Blob,Kv}` | Use a shared pre-created + VNet-linked zone. |
| `existingPgServerName` / `existingStorageAccountName` / `existingKeyVaultName` | Reuse a named resource instead of creating one. |

## 7. Adding a new service

Four files — no shared-code changes:

```
bicep/services/<svc>.json                 # wizard questions, secrets, helm config
bicep/services/<svc>.conf                 # packaging config
bicep/params/<svc>.dev.bicepparam         # Azure sizing + feature flags
bicep/values-templates/<svc>.values.yaml  # Helm values with ${VAR} placeholders
```

Copy an existing service (e.g. `gitlab.*`) and edit. Then:

```bash
./bicep/package.sh <svc>
./bicep/deploy.sh <svc> dev --confirm --secrets
```

## 8. Air-gapped flow

```bash
# Connected machine
./bicep/package.sh <svc>
# Produces bicep/packages/<svc>/ with chart .tgz + images.tar

# Transfer the folder to the air-gapped machine, then:
./bicep/packages/<svc>/load.sh            # load images into ACR
./bicep/deploy.sh <svc> dev --confirm --secrets
```

---

# Troubleshooting

## Bicep compile errors

### `An error occurred reading file ... role-assignment-on-aks.bicep`
Local checkout is stale. The two sub-modules ship in commit `94bdc90`.
```bash
git fetch origin
git pull origin <your-branch>
ls bicep/modules/role-assignment-on-*.bicep  # both should exist
```
Reload the VS Code window after pulling so the Bicep language server re-indexes.

### `A resource scope must match`
Happens if you add a role assignment directly in `main.bicep` or `managed-identity.bicep` targeting a resource in a different RG. Fix: delegate to a sub-module deployed with `scope: resourceGroup(targetRg)` — see `role-assignment-on-{aks,acr}.bicep` for the pattern.

### `Type 'any' is not assignable to type 'string'`
Usually `last(split(...))` assigned directly to `name:`. Pull through a `var` and wrap in string interpolation: `name: '${nameVar}'`.

### `The property 'administratorLoginPassword' is required`
`pgAdminPassword` isn't being passed. Either set it in the `.bicepparam`, or let the wizard prompt for it (`--secrets`).

### Bicep complains about `pgVersion '17'`
Upgrade the CLI's Bicep: `az bicep upgrade`. PG 17 on Flexible Server needs a recent API version.

## `azure.env` problems

### `ERROR: azure.env not found`
Run `./bicep/env/populate-env.sh`.

### `ERROR: Missing values in azure.env`
`populate-env.sh` couldn't find a resource (wrong subscription, different RG convention). Open `bicep/env/azure.env` and fill in the missing keys manually. Re-run `az account show` to confirm you're in the right subscription.

## Deploy failures

### `DeploymentFailed: role assignment ... AuthorizationFailed`
The deploying identity lacks `Microsoft.Authorization/roleAssignments/write` on the AKS or ACR resource group. Grant `User Access Administrator` on those RGs (or have someone who has it run the deploy).

### `DeploymentFailed: A vault with the same name already exists in soft-deleted state`
A previously deleted Key Vault is blocking the new name. Either:
```bash
az keyvault purge --name <kvName> --location <region>
```
...or set `existingKeyVaultName` in the `.bicepparam` to reuse the deleted vault's name after recovery.

### `DeploymentFailed: StorageAccountAlreadyTaken`
Storage account names are globally unique. If the module-generated name clashes, bump the `serviceName` or explicitly set `existingStorageAccountName` to reuse.

### `DeploymentFailed: InvalidPostgresVersion` (Gov Cloud)
PG 17 may not yet be available in all Gov regions. Fall back to `pgVersion = '16'` in the `.bicepparam`.

### Private endpoint created but DNS doesn't resolve
The private DNS zone isn't linked to the VNet. Check:
```bash
az network private-dns link vnet list \
  --resource-group <zone-rg> \
  --zone-name privatelink.blob.core.windows.net
```
If you're using `existingPrivateDnsZoneId*`, you're responsible for the VNet link — this module does not create one for external zones.

### `Soft delete is already enabled and cannot be disabled` (Key Vault)
Expected — KV soft delete can't be turned off once on. The module leaves it on; ignore the warning.

### Role assignment works but AKS/ACR access still fails
RBAC propagation delay — takes 1–5 minutes after deploy. If still failing after 10 minutes:
```bash
az role assignment list \
  --assignee <identity-principal-id> \
  --all -o table
```

### Re-deploying existing resources silently changed config
Likely `updateExistingInfrastructure = true`. Flip it back to `false` in the `.bicepparam` if you're reusing ops-managed infra.

## Helm / ArgoCD failures

### Helm values contain unresolved `${VAR}`
A wizard secret didn't land in Key Vault. Re-run with `--secrets` and answer the prompts. Verify with:
```bash
az keyvault secret list --vault-name <kv-name> -o table
```

### `ImagePullBackOff` on AKS after deploy
AcrPull role propagation delay (see above) OR the pod isn't using the managed identity the module created. Check the pod's service account / identity binding.

### ArgoCD app stuck `OutOfSync` / `Unknown`
Not a Bicep issue — check ArgoCD's cluster access and repo credentials. `argocd app sync <service>-<env>` usually surfaces the real error.

## Stack / state issues

### `--status` shows resources you didn't expect
Someone else modified the stack outside Bicep. Either:
- re-run the full deploy (Bicep will reconcile), or
- `--teardown --confirm` then redeploy.

### Stuck deployment ("Deployment in progress")
Cancel via portal or:
```bash
az deployment group cancel \
  --resource-group <rg> \
  --name <deployment-name>
```
Then re-run. ARM deployments are idempotent.

---

## Logs & debugging

```bash
# Activity log for the last deployment
az deployment group list --resource-group <rg> --query "[0].properties.error" -o json

# Full operation list for a specific deployment
az deployment operation group list \
  --resource-group <rg> \
  --name <deployment-name> -o table

# Validate a .bicepparam compiles without deploying
az bicep build-params --file bicep/params/<svc>.<env>.bicepparam
```

---

## Contact / escalation

- Bicep module issues → bicep/ owners
- Azure quota / region availability → cloud ops
- ArgoCD / GitOps → platform team
