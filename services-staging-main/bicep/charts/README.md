# Bundled Helm Charts

For air-gapped deployments, package chart `.tgz` files here.

## How to package charts (on a connected machine)

```bash
# Pull the chart
helm repo add jfrog https://charts.jfrog.io
helm pull jfrog/jfrog-platform --version 10.12.0

# Option A: Push to ACR as OCI artifact (recommended)
helm push jfrog-platform-10.12.0.tgz oci://<ACR_NAME>.azurecr.us/helm

# Option B: Bundle in this repo for fully offline deploy
cp jfrog-platform-10.12.0.tgz bicep/charts/
```

## Deploy modes

| Mode | helmSource | When to use |
|---|---|---|
| `repo` | Internet Helm repo | Connected environments |
| `oci` | ACR OCI registry | Air-gapped with ACR access (recommended) |
| `local` | Chart .tgz in this repo | Fully offline, no ACR |

Set `helmSource` in your `.bicepparam` file.