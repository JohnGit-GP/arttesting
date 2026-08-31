# Bicep IaC — AKS Service Deployments

Service-agnostic framework for deploying services to AKS in Azure Government Cloud. Bicep handles Azure infra. Helm or ArgoCD handles app deployment. All service logic lives in config files; shared code is generic.

## Architecture

```
deploy.sh <service> <env> --confirm --secrets
  │
  ├─ Phase 1: Interactive wizard (no Azure writes)
  │   Reads services/<service>.json
  │   Asks service questions (Y/n normalized: Yes, YES, y, true → yes)
  │   Generates/prompts secrets, BUFFERS to a JSON object
  │   On rerun: reads existing secret values from the live KV and reuses
  │            them so MASTER_KEY etc. don't rotate.
  │
  ├─ Phase 2: Azure infrastructure (Bicep stack)
  │   Auto-discovers existing privatelink DNS zones in your VNet
  │   Resolves the deploying user/SP objectId for KV access
  │   Hands the buffered secrets to Bicep as `keyVaultSecrets`
  │   Bicep creates KV + populates secrets atomically
  │   Writes back PG_SERVER_NAME, PG_SERVER_FQDN, STORAGE_ACCOUNT_NAME,
  │            BLOB_ENDPOINT_SUFFIX, KEY_VAULT_NAME to azure.env
  │
  ├─ Phase 2.5: Post-infra secrets
  │   Storage account didn't exist during Phase 1, so storage_key was
  │   deferred. Now fetched from Azure mgmt plane and stored in KV.
  │   All KV/storage data-plane calls have 30s timeout (fail fast on
  │   network issues instead of hanging on `az` retry/backoff).
  │
  └─ Phase 3: Application deployment
      --secrets         → helm-deploy.sh   (Helm install)
      --secrets --argocd → argocd-deploy.sh (ArgoCD Application CRD)
```

## File Tree

```
bicep/
  deploy.sh                          # 3-phase orchestrator
  helm-deploy.sh                     # Generic Helm deployer (KV reads via timeout)
  argocd-deploy.sh                   # Generic ArgoCD deployer
  package.sh                         # Pull chart + images, push to ACR
  main.bicep                         # Azure infra orchestrator
  env/
    azure.env                        # Shared infra refs (per-service refs written by deploy.sh)
    populate-env.sh                  # Discovers SHARED infra only — does NOT touch KV/PG/Storage
  modules/
    managed-identity.bicep           # User-assigned MI (role assignments commented — needs owner)
    keyvault.bicep                   # KV with deployerObjectId access policy
    postgresql.bicep                 # PG flex server, public + PE compatible
    storage-account.bicep            # Storage account, public + PE compatible
    private-dns-zone.bicep           # Privatelink zone + VNet link
    private-endpoint.bicep           # PE + dnsZoneGroup
  services/                          # Per-service definitions
    <service>.json                   # Helm config, questions, secrets, k8sSecrets
    <service>.conf                   # Packaging config for package.sh
  packages/                          # Output of package.sh (gitignored)
  params/
    <service>.<env>.bicepparam       # Per-service Azure infra params
  values-templates/
    <service>.values.yaml            # Helm values with ${VAR} placeholders
```

## Per-Service Files (4 files per service)

| File | Purpose |
|---|---|
| `services/<service>.json` | Service definition: Helm config, wizard questions, secrets, K8s secrets, ExternalName services, ArgoCD config |
| `services/<service>.conf` | Packaging config for `package.sh` |
| `params/<service>.<env>.bicepparam` | Azure infra sizing and feature flags |
| `values-templates/<service>.values.yaml` | Helm values with `${VAR}` placeholders |

## Commands

```bash
# Bootstrap shared infra refs (one-shot per cluster/env)
./bicep/env/populate-env.sh

# Package chart + images for ACR
./bicep/package.sh <service>

# Deploy
./bicep/deploy.sh <service> <env>                              # dry run
./bicep/deploy.sh <service> <env> --confirm                    # infra only
./bicep/deploy.sh <service> <env> --confirm --secrets          # full deploy (Helm)
./bicep/deploy.sh <service> <env> --confirm --secrets --rotate # force-regen all secrets
./bicep/deploy.sh <service> <env> --confirm --secrets --argocd # full deploy (ArgoCD)

# Manage
./bicep/deploy.sh <service> <env> --status                     # show stack
./bicep/deploy.sh <service> <env> --teardown --confirm         # destroy + clear azure.env

# Optional flag for environments where `az ad signed-in-user show` fails
./bicep/deploy.sh <service> <env> --confirm --secrets \
  --deployer-object-id=<your-aad-object-id>
# or set DEPLOYER_OBJECT_ID env var
```

## Secrets Flow (post-fix)

```
Phase 1 wizard
  ├─ Reuse from KV (if KEY_VAULT_NAME set, --rotate not given)
  └─ Generate / prompt → buffer into JSON
                             ↓
Phase 2: Bicep gets keyVaultSecrets={...}
                             ↓
KV created/updated AND secrets seeded in one stack deploy
                             ↓
Phase 2.5: storage_key fetched from Azure → set in KV
                             ↓
Phase 3 helm-deploy.sh: az keyvault secret list → env vars → envsubst
                             ↓
                          values.yaml → helm install
```

## Adding a New Service

1. Create the 4 config files (no shared code changes):
   - `services/<service>.json`
   - `services/<service>.conf`
   - `params/<service>.dev.bicepparam`
   - `values-templates/<service>.values.yaml`
2. Package: `./bicep/package.sh <service>`
3. Deploy: `./bicep/deploy.sh <service> dev --confirm --secrets`

## Key Design Notes

- **Per-service resources (KV/PG/Storage) are owned by `deploy.sh`.** `populate-env.sh` does *not* auto-discover them anymore (the previous `[0]`-first-in-subscription approach was a footgun that could write the new service's secrets into someone else's vault).
- **Secrets are passed to Bicep, not written by the wizard.** Avoids the chicken-and-egg of needing a KV that doesn't exist yet on first deploy.
- **Reruns are idempotent.** Phase 1 reads existing secret values from the live KV and reuses them. Use `--rotate-secrets` to force regeneration.
- **Deployer gets KV access via Bicep.** No out-of-band `az keyvault set-policy` needed.
- **Cloud-aware FQDN/suffix.** PG FQDN, blob endpoint, ACR login server come from Bicep stack outputs and fall back to a `az cloud show`-driven detection in `helm-deploy.sh`.
- **Timeouts on KV/storage data-plane calls** so unreachable endpoints fail fast (30s) instead of stalling for minutes on `az`'s internal retry.
- **`--teardown` clears per-service refs from azure.env** so the next deploy starts clean.

## ArgoCD Transition

Same wizard, same Bicep, same Key Vault secrets. Add `--argocd`:

```bash
./bicep/deploy.sh myservice dev --confirm --secrets --argocd
```

ArgoCD then manages the Helm release lifecycle with sync and self-heal.

## Known Open Issues

See [ISSUES.md](./ISSUES.md) for diagnostics and workarounds for the ongoing items (KV data-plane reachability, MI role assignments, central privatelink zone permissions).

## Cheatsheet

See [CHEATSHEET.md](./CHEATSHEET.md) for common commands, recovery patterns, and one-liners.