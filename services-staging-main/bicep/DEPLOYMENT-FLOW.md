# Deployment Flow & Current Blockers

Visualizes the full path from `deploy.sh` on the jumpbox to running pods, with the two platform-team prerequisites that gate end-to-end success called out explicitly. See [ISSUES.md](./ISSUES.md) for the failure-mode index and [CHEATSHEET.md](./CHEATSHEET.md) for the day-to-day commands.

```mermaid
flowchart TD
    classDef blocked stroke:#d33,stroke-width:3px,fill:#fee,color:#000
    classDef platform stroke:#36a,stroke-width:2px,fill:#dde,color:#000
    classDef fixed stroke:#393,stroke-width:2px,fill:#dfd,color:#000
    classDef resource fill:#fff,stroke:#666

    %% ── Deployer side ──
    JB[Jumpbox in VNet]:::resource
    JB --> DSH["deploy.sh artifactory dev<br/>--confirm --secrets"]

    subgraph PHASE1["Phase 1 — Wizard"]
        Q1["Ask questions"]
        Q2["Buffer secrets to JSON"]
    end
    DSH --> Q1 --> Q2

    subgraph PHASE2["Phase 2 — Bicep stack"]
        STACK["az stack group create<br/>main.bicep"]
        KV[(Key Vault)]:::resource
        PG[(PostgreSQL Flex)]:::resource
        SA[(Storage Account)]:::resource
        PE_KV[/PE&nbsp;·&nbsp;vault/]:::resource
        PE_PG[/PE&nbsp;·&nbsp;postgres/]:::resource
        PE_SA[/PE&nbsp;·&nbsp;blob/]:::resource
    end
    Q2 --> STACK
    STACK --> KV & PG & SA
    KV --- PE_KV
    PG --- PE_PG
    SA --- PE_SA

    %% ── Central DNS (platform-team-owned) ──
    subgraph DNS["Central privatelink zones (platform-team-owned)"]
        Z_KV["privatelink.vaultcore.<br/>usgovcloudapi.net"]:::platform
        Z_PG["privatelink.postgres.database.<br/>usgovcloudapi.net"]:::platform
        Z_SA["privatelink.blob.core.<br/>usgovcloudapi.net"]:::platform
    end
    PE_KV -. "register A-record<br/>⛔ needs Private DNS Zone Contributor" .-> Z_KV
    PE_PG -. "register A-record<br/>⛔ needs Private DNS Zone Contributor" .-> Z_PG
    PE_SA -. "register A-record<br/>⛔ needs Private DNS Zone Contributor" .-> Z_SA

    %% ── Phase 2.5 + helm ──
    STACK --> P25["Phase 2.5: write storage_key to KV"]
    P25 -.-> KV
    P25 --> HELM["helm-deploy.sh"]

    subgraph PHASE3["Phase 3 — Helm + workload"]
        HELM
        K8S_SECRETS["K8s secrets<br/>(rendered from KV)"]:::resource
        PODS[Artifactory pods]:::resource
    end
    HELM -- "az keyvault secret list/show" --> KV
    HELM --> K8S_SECRETS --> PODS

    %% ── ACR pulls ──
    KUBELET[AKS kubelet identity]:::resource
    ACR[(ACR · azurecr.us)]:::resource
    PODS --> KUBELET
    KUBELET -. "image pull<br/>⛔ needs az aks update --attach-acr" .-> ACR

    %% ── Runtime DNS lookups ──
    PODS -.->|DNS for KV/PG/blob| Z_KV
    PODS --> KV
    PODS --> PG
    PODS --> SA

    %% ── Blockers callout ──
    BLOCK1{{"⛔ BLOCKER 1<br/>DNS A-records can't register<br/>= KV/PG/blob unreachable"}}:::blocked
    BLOCK2{{"⛔ BLOCKER 2<br/>kubelet has no AcrPull<br/>= every pod ImagePullBackOff"}}:::blocked
    Z_KV --- BLOCK1
    KUBELET --- BLOCK2

    %% ── PR #1 fixes ──
    FIX{{"✅ Fixed in PR #1<br/>• Gov privatelink zone names<br/>• existingPrivateDnsZoneId* params<br/>• KV/Storage publicNetworkAccess: Disabled<br/>• PG networkAccess: private<br/>• kvSecretsExisting dependsOn race<br/>• DEPLOYER_OBJECT_ID hard fail<br/>• ACR_LOGIN_SERVER cloud-aware"}}:::fixed
    STACK --- FIX
```

## How to read it

- **Blue boxes** are owned by the platform team. The deployer can't write to them with PIM-Contributor on the deploy RG.
- **Red dashed lines + ⛔ callouts** are the two unresolved blockers. Both clear with one platform-team action each; neither is a code issue.
- **Green callout** lists what `PR #1` ships. Code-side this is done; deploy still won't succeed end-to-end until both ⛔ items clear.

## Story in one sentence

`deploy.sh` from the jumpbox creates KV / PG / Storage and their PEs cleanly with PIM-Contributor — but the PEs can't register their DNS A-records (blocker 1), so pods can't resolve the resources, and even if DNS resolved, kubelet can't pull the images that run those pods (blocker 2).

## Platform-team asks (paste-ready)

1. **`Private DNS Zone Contributor`** on the four central privatelink zones (vaultcore, postgres, blob, plus `azurecr.us` if ACR is private). Scope: the zone itself, not its parent RG.
2. **One-time** `az aks update -g <AKS_RG> -n <CLUSTER> --attach-acr <ACR>` so the kubelet identity gets `AcrPull` on the ACR.

Both items unblock every service on the cluster, not just artifactory — once granted, they don't need to be re-granted per-deploy.