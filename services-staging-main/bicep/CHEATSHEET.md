# Cheatsheet

Common commands and recovery patterns for the deploy chain.

## Day-to-day

```bash
# Bootstrap shared infra refs (once per cluster/env)
./bicep/env/populate-env.sh

# Dry run to see what Bicep would change
./bicep/deploy.sh artifactory dev

# Real deploy
./bicep/deploy.sh artifactory dev --confirm --secrets

# Status of the Bicep stack
./bicep/deploy.sh artifactory dev --status

# Teardown (also clears per-service refs from azure.env)
./bicep/deploy.sh artifactory dev --teardown --confirm
```

## Re-running with overrides

```bash
# Force-regenerate all secrets (rotate MASTER_KEY etc. — bricks running cluster)
./bicep/deploy.sh artifactory dev --confirm --secrets --rotate

# Use a different KV name (e.g. previous one is soft-deleted)
export NEW_KEY_VAULT_NAME="kv-art-dev2"
./bicep/deploy.sh artifactory dev --confirm --secrets

# Provide deployer objectId explicitly when az ad lookup fails
./bicep/deploy.sh artifactory dev --confirm --secrets \
  --deployer-object-id=00000000-1111-2222-3333-444444444444
# or
DEPLOYER_OBJECT_ID=00000000-1111-2222-3333-444444444444 \
  ./bicep/deploy.sh artifactory dev --confirm --secrets
```

## Manual helm install (skip the wizard, skip Bicep)

Infra and secrets must already exist.

```bash
# Phase 3 only — pulls secrets from KV, renders values, helm install
./bicep/helm-deploy.sh artifactory dev

# Dry run
./bicep/helm-deploy.sh artifactory dev --dry-run
```

## After a teardown

If you re-deploy too soon, you'll hit:
- **KV name conflict** — soft-deleted (purge protection enforces a 90-day hold).
  ```bash
  az keyvault list-deleted --query "[].name" -o tsv
  az keyvault recover --name "$KEY_VAULT_NAME" --location "$LOCATION"
  # or use a different name:
  export NEW_KEY_VAULT_NAME="kv-art-dev2"
  ```
- **Stale per-service refs** — `--teardown` now clears these automatically. If you tore down with an older script, do it manually:
  ```bash
  for v in KEY_VAULT_NAME PG_SERVER_NAME PG_SERVER_FQDN STORAGE_ACCOUNT_NAME BLOB_ENDPOINT_SUFFIX; do
    sed -i "s|^${v}=.*|${v}=\"\"|" bicep/env/azure.env
  done
  ```

## Quick reachability tests

Run these any time `az keyvault secret ...` hangs.

```bash
source bicep/env/azure.env

# KV reachable?
timeout 8 az keyvault secret list --vault-name "$KEY_VAULT_NAME" --query "[].name" -o tsv
echo "exit: $?"   # 124 = timeout (network/DNS issue), 0 = OK

# What does DNS resolve to (private vs public)?
dig +short A "${KEY_VAULT_NAME}.vault.usgovcloudapi.net"
dig @8.8.8.8 +short A "${KEY_VAULT_NAME}.vault.usgovcloudapi.net"

# Real PE NIC IP for the KV
NIC_ID=$(az network private-endpoint show -g "$RESOURCE_GROUP" -n "pe-kv-artifactory" \
  --query "networkInterfaces[0].id" -o tsv)
PE_IP=$(az network nic show --ids "$NIC_ID" \
  --query "ipConfigurations[0].privateIPAddress" -o tsv)
echo "PE IP: $PE_IP"

# TCP test bypassing DNS
timeout 5 bash -c "</dev/tcp/${PE_IP}/443" && echo "TCP OK" || echo "TCP BLOCKED"
```

## /etc/hosts unblock when DNS is wrong but PE is reachable

```bash
source bicep/env/azure.env
NIC_ID=$(az network private-endpoint show -g "$RESOURCE_GROUP" -n "pe-kv-artifactory" \
  --query "networkInterfaces[0].id" -o tsv)
PE_IP=$(az network nic show --ids "$NIC_ID" \
  --query "ipConfigurations[0].privateIPAddress" -o tsv)
echo "$PE_IP  ${KEY_VAULT_NAME}.vault.usgovcloudapi.net" | sudo tee -a /etc/hosts
echo "$PE_IP  ${KEY_VAULT_NAME}.privatelink.vaultcore.usgovcloudapi.net" | sudo tee -a /etc/hosts

# Verify
timeout 8 az keyvault secret list --vault-name "$KEY_VAULT_NAME"

# Cleanup later
sudo sed -i "/${KEY_VAULT_NAME}/d" /etc/hosts
```

## Inspect what's in the Key Vault

```bash
source bicep/env/azure.env
az keyvault secret list --vault-name "$KEY_VAULT_NAME" --query "[].name" -o tsv
az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name artifactory-master-key --query value -o tsv
```

## Inspect the Bicep stack

```bash
az stack group show --name artifactory-dev --resource-group "$RESOURCE_GROUP" -o json
az stack group show --name artifactory-dev --resource-group "$RESOURCE_GROUP" \
  --query "outputs" -o json
```

## Force a stuck stack delete

```bash
# detach instead of delete if shared resources are blocking
az stack group delete --name artifactory-dev --resource-group "$RESOURCE_GROUP" \
  --action-on-unmanage detachAll --yes
```

## Watch the helm install in another terminal

```bash
kubectl get pods -n artifactory -w
kubectl logs -n artifactory <pod-name> -f
```

## PE / Private DNS quick refs

```bash
# All PEs in the deploy RG
az network private-endpoint list -g "$RESOURCE_GROUP" \
  --query "[].{name:name, state:provisioningState, target:privateLinkServiceConnections[0].privateLinkServiceId}" \
  -o table

# Zone group on a specific PE
az network private-endpoint dns-zone-group list -g "$RESOURCE_GROUP" \
  --endpoint-name pe-kv-artifactory -o json

# Privatelink zones the deployer can see
az network private-dns zone list \
  --query "[?starts_with(name, 'privatelink')].{name:name, rg:resourceGroup}" -o table

# A-records in a privatelink zone
az network private-dns record-set a list \
  --zone-name privatelink.vaultcore.usgovcloudapi.net \
  --resource-group "$DNS_RESOURCE_GROUP" -o table
```

## Soft-delete recovery (KV)

```bash
# List
az keyvault list-deleted --query "[].{name:name, deleted:properties.deletionDate}" -o table

# Recover
az keyvault recover --name "$KEY_VAULT_NAME" --location "$LOCATION"

# Purge (only if enablePurgeProtection=false; otherwise wait 90 days)
az keyvault purge --name "$KEY_VAULT_NAME" --location "$LOCATION"
```