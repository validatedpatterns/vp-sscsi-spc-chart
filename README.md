# vp-sscsi-spc

![Version: 0.1.11](https://img.shields.io/badge/Version-0.1.11-informational?style=flat-square)

Library chart for app-level Vault SecretProviderClass rendering with hub, spoke, and external Vault support. Cluster CA material is managed by a separate cluster-wide chart.

### Notable changes

* v0.1.11: On **spoke** clusters, default Kubernetes `roleName` uses **`global.clusterDomain`** (`<clusterDomain>-role` and `<clusterDomain>-sscsi-<roleSlug>`), matching openshift-external-secrets. On the **hub**, computed roles remain **`hub-role`** and **`hub-sscsi-<roleSlug>`** (always the **`hub`** prefix). `spec.parameters.vaultKubernetesMountPath` is unchanged. If `global.clusterDomain` is empty on a spoke, the role prefix falls back to the computed mount path.
* v0.1.9: Spoke `SecretProviderClass` no longer treats `clusterGroup.applications` entries with `chart: hashicorp-vault` as hub-style auth (which forced `vaultKubernetesMountPath: hub` when `localClusterDomain` was unset). On spokes, `spec.parameters.vaultKubernetesMountPath` is `global.localClusterDomain` when it differs from `global.hubClusterDomain`, and **`hub`** when they are equal; hub clusters keep hub-style mount logic.
* v0.1.8: Added arbitrary Vault connection/auth configuration through values:
  `vault.externalAddress` for custom endpoints, `auth.method` for selecting the
  provider auth type, and `auth.extraParameters` to pass provider-specific auth
  fields (for example JWT/AppRole/token). Kubernetes defaults remain unchanged,
  including hub/spoke role-name conventions based on `hub` and
  `global.clusterDomain`.

This chart is the **library for `SecretProviderClass` only**, **one dependency per application chart** that consumes Vault via SSCSI.

**Vault CSI provider DaemonSet and TLS trust on the provider** (for example projected proxy cluster CA) are installed by **`openshift-sscsi-vault`** (chart **0.2.0+**), not this library. The legacy **`vp-vault-csi-provider`** chart is superseded by **`openshift-sscsi-vault`** for new installs.

### Scope

This chart renders **only** `SecretProviderClass` YAML (named templates or optional `installDefaultManifests`). Use it from application charts that need:

- Hub-cluster Vault auth (defaults `vaultKubernetesMountPath` to `hub` when `global.localClusterDomain == global.hubClusterDomain`, else `global.clusterDomain`; optional `vault.hubMountPath` override, hub role)
- Spoke-cluster auth to centralized Vault (`global.localClusterDomain` as `vaultKubernetesMountPath`, or **`hub`** when it equals `global.hubClusterDomain`; default Kubernetes `roleName` on spokes uses **`global.clusterDomain`** as the prefix, like openshift-external-secrets — hub clusters keep **`hub`** / **`hub-role`**)
- External Vault endpoint override (`vault.externalAddress`)
- Auth method override via values (`auth.method`, default `kubernetes`) plus pass-through auth parameters (`auth.extraParameters`) for non-kubernetes schemes
- Optional reference to a pre-mounted CA path (`tls.vaultCACertPath`), or **`tls.projectedClusterCa.enabled: true`** to derive the path for **openshift-sscsi-vault**'s projected CNO/proxy bundle (same defaults as that chart's `syncProviderCaConfigMap`)
- Optional app-key driven workload auth lookup from `clusterGroup.applications[*].ssCsiWorkloadAuth`

This chart does not install the CSI provider or mount trust bundles. Either set **`tls.vaultCACertPath`** explicitly, or enable **`tls.projectedClusterCa`** so **`spec.parameters.vaultCACertPath`** points at **`/etc/pki/vault-ca/ca-bundle.crt`** (CNO-injected proxy/cluster bundle) or **`.../vault-tls-ca.pem`** when **`injectTrustedCabundle: false`**, matching **openshift-sscsi-vault** defaults. Named template **`vp_sscsi_spc.projectedVaultCACertPath`** returns that path for custom includes.

### Usage from parent charts

Merge values into this chart shape (`ocpSecretsStoreCsiVault`, `global`, `clusterGroup`) and include:

```yaml
{{- $spcCtx := dict "Chart" $sc.Chart "Capabilities" $sc.Capabilities "Release" $sc.Release "Values" $spcVals }}
{{- include "vp_sscsi_spc.secretproviderclass" $spcCtx }}

```

For standalone rendering during development/tests, set:

```yaml
ocpSecretsStoreCsiVault:
  secretProviderClass:
    installDefaultManifests: true
```

When `ocpSecretsStoreCsiVault.applicationKey` is set, the chart reads
`clusterGroup.applications[applicationKey]` and can derive:

- `metadata.namespace` from app namespace (fallback: release namespace)
- `spec.parameters.roleName` from `ssCsiWorkloadAuth`: explicit `roleName`/`role`, or on the hub **`hub-sscsi-<roleSlug>`** / **`hub-role`**, on spokes **`global.clusterDomain-sscsi-<roleSlug>`** / **`global.clusterDomain-role`** (spoke fallback to mount path if `clusterDomain` is empty). `vaultKubernetesMountPath` still follows hub/local-domain rules — not the short `cluster` label from clustergroup values

For `auth.method: kubernetes` (default), this chart emits `vaultKubernetesMountPath` and `roleName`.
For other auth methods, set `auth.method` and provide the provider-specific fields in `auth.extraParameters`.

### Argo CD ignoreDifferences recommendation

For Argo CD applications that deploy the cluster-wide provider chart used with this library (for example `openshift-sscsi-vault`), add an `ignoreDifferences` block for the provider CA ConfigMap. This follows the pattern used in `~/gitwork/multicloud-gitops` (`values-hub.yaml`, `values-group-one.yaml`), where CNO/proxy bundle injection mutates `.data` after apply.

```yaml
ignoreDifferences:
  - group: ""
    kind: ConfigMap
    name: openshift-sscsi-vault-vault-tls-ca
    namespace: vault
    jsonPointers:
      - /data
    jqPathExpressions:
      - .data
syncPolicy:
  syncOptions:
    - RespectIgnoreDifferences=true
```

If you are using proxy/cluster CA bundle injection, the `vp-cluster-truster` application (for example `vp-manage-proxy-cluster-ca`) is the common way to manage `Proxy.spec.trustedCA` and the source bundle workflow. It is recommended in that setup so the injected bundle exists consistently.

If you are not using bundle injection and instead provide `tls.vaultCACertPath` from another trust source, `vp-cluster-truster` is not mandatory for this chart.

### Workload timeouts, mount readiness, and retries

Application charts that combine this library with **CSI Secret Provider** mounts, **ConfigMaps**, and **projected** trust bundles should plan for **slow or stuck volume setup** and for **data that exists in API but is not yet usable** on disk. The following applies to **Deployments**, **ReplicaSets** (via the parent Deployment), **Pods**, **Jobs**, **CronJobs**, **StatefulSets**, and **DaemonSets** wherever a Pod template is defined.

**What blocks `ContainerCreating`**

- A **ConfigMap object that exists** usually mounts quickly. Long `ContainerCreating` is more often **image pull**, **scheduling**, or **volume plugins**. **`secrets-store.csi.k8s.io`** mounts can wait on Vault, credentials, or the network.
- **Wrong or incomplete ConfigMap or secret file content** often still completes the mount; failure appears **after** the main container starts unless you **validate earlier** (see below).
- **Liveness and readiness probes** run only **after** the container is running; they do not resolve infinite `ContainerCreating`.

**Fail fast on required files (recommended)**

For any workload with a Pod template, add an **init container** (same volumes, minimal image) that checks required paths under the CSI mount, ConfigMap mount, or projected CA path, and **`exit 1`** if anything required is missing or invalid. Optionally wrap checks with a **shell `timeout`** so the init step cannot hang indefinitely. This gives clear failures and works well with **Job `backoffLimit`** or external orchestration retries.

**Kubernetes time limits by resource**

| Goal | Knob |
|------|------|
| Rollout stuck (new Pods not becoming Ready) | **Deployment `spec.progressDeadlineSeconds`** |
| Cap total time for a **Job** | **Job `spec.activeDeadlineSeconds`**, plus **`spec.backoffLimit`** for retries |
| Bound each **Pod** attempt | **Pod `spec.activeDeadlineSeconds`** (in the Pod template) |
| CronJob run must not start too late after schedule | **CronJob `spec.startingDeadlineSeconds`** |

**ReplicaSet**: do not tune deadlines on the ReplicaSet directly; set them on the owning **Deployment** (or higher-level controller).

**StatefulSet and DaemonSet**: there is no **`progressDeadlineSeconds`**. Use **Pod `activeDeadlineSeconds`**, **init validation**, and probes (**`startupProbe`** helps slow-but-finite application start, not stuck pre-run mounts).

**CSI and projected volumes**

- Mount and retry behavior is **driver- and provider-specific**; use provider documentation for timeouts and failure modes in addition to the Kubernetes fields above.
- **`optional: true`** on a **projected** `configMap` source avoids hard failure when that source is absent but can hide “trust bundle not ready”; pair **`optional`** with **init validation** when the file is required for Vault or TLS.

**Argo**

- **Argo CD** reflects **resource health** (for example Deployment **`ProgressDeadlineExceeded`**, Pods not Ready). It does not add volume timeouts; encode limits and checks in the manifests your Application syncs.
- **Argo Workflows**: use **template `timeout`** and **`retryStrategy`** on steps so a bounded Pod or Job attempt can fail and retry at the workflow layer.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| clusterGroup.applications | object | `{}` |  |
| global | object | `{"clusterDomain":"foo.example.com","hubClusterDomain":"hub.example.com","localClusterDomain":""}` | Global values aligned with openshift-external-secrets chart patterns |
| global.localClusterDomain | string | `""` | On spokes (non-hub), rendered as `spec.parameters.vaultKubernetesMountPath` unless it equals `hubClusterDomain`, in which case the mount path is `hub`. Hub clusters use hub-style mount logic instead. Set this to the spoke apps/API domain (for example `apps.cluster.example.com`). Default Kubernetes `roleName` prefixes use `global.clusterDomain` (aligned with openshift-external-secrets), not this field. |
| ocpSecretsStoreCsiVault | object | see nested keys | Settings for app-level SecretProviderClass rendering |
| ocpSecretsStoreCsiVault.applicationKey | string | `""` | Optional key under `clusterGroup.applications` used to resolve workload auth attributes (`ssCsiWorkloadAuth`). |
| ocpSecretsStoreCsiVault.auth.extraParameters | object | `{}` | Extra auth parameters merged into `spec.parameters` for non-kubernetes methods (for example AppRole, JWT, token). Keys/values are passed through as provided. |
| ocpSecretsStoreCsiVault.auth.method | string | `"kubernetes"` | Vault auth method for SecretProviderClass `spec.parameters.authType`. Defaults to `kubernetes`. |
| ocpSecretsStoreCsiVault.auth.roleName | string | `"hub-role"` | Vault Kubernetes auth role name for hub-style auth (used when `auth.method` is `kubernetes`). |
| ocpSecretsStoreCsiVault.objects | list | example placeholder; replace with your paths | KV objects to expose as files under the CSI mount (Vault CSI `objects` list) |
| ocpSecretsStoreCsiVault.secretObjects | list | `[]` | Optional: sync mounted objects into native Kubernetes Secrets (CSI `secretObjects`) |
| ocpSecretsStoreCsiVault.secretProviderClass.enabled | bool | `true` | When true, render SecretProviderClass manifests from this chart. |
| ocpSecretsStoreCsiVault.secretProviderClass.installDefaultManifests | bool | `false` | When true, render default SPC manifests from `templates/install-default-manifests.yaml`. |
| ocpSecretsStoreCsiVault.secretProviderClass.name | string | `"vault-hub-secrets"` | metadata.name of the SecretProviderClass (referenced from pod volumeAttributes) |
| ocpSecretsStoreCsiVault.secretProviderClass.namespace | string | `""` | Namespace where the SecretProviderClass is created |
| ocpSecretsStoreCsiVault.tls | object | `{"projectedClusterCa":{"enabled":false,"injectTrustedCabundle":true,"keyInConfigMap":"vault-tls-ca.pem","mountDir":"/etc/pki/vault-ca","trustedCabundleDataKey":"ca-bundle.crt"},"vaultCACertPath":"","vaultSkipTLSVerify":"false","vaultTLSServerName":""}` | TLS options for the Vault CSI provider. This chart only references an existing trust path and does not create CA material. |
| ocpSecretsStoreCsiVault.tls.projectedClusterCa | object | `{"enabled":false,"injectTrustedCabundle":true,"keyInConfigMap":"vault-tls-ca.pem","mountDir":"/etc/pki/vault-ca","trustedCabundleDataKey":"ca-bundle.crt"}` | When `enabled` is true and `vaultCACertPath` is empty, set `vaultCACertPath` to the bundle file under **openshift-sscsi-vault** defaults (CNO proxy merge `ca-bundle.crt` vs PEM `vault-tls-ca.pem`). Align these fields with `ocpSecretsStoreCsiVault.caProvider.syncProviderCaConfigMap` on that chart. |
| ocpSecretsStoreCsiVault.tls.vaultCACertPath | string | `""` | Explicit PEM path on the CSI provider pod. When non-empty, wins over `projectedClusterCa`. |
| ocpSecretsStoreCsiVault.vault.externalAddress | string | `""` | If non-empty, used as `spec.parameters.vaultAddress` (external Vault endpoint). |
| ocpSecretsStoreCsiVault.vault.hubMountPath | string | `""` | Optional override for hub-style `vaultKubernetesMountPath`. Empty defaults to `hub` when `global.localClusterDomain == global.hubClusterDomain`, else `global.clusterDomain`. |
| ocpSecretsStoreCsiVault.workloadAuthIndex | int | `0` | Index into `clusterGroup.applications[applicationKey].ssCsiWorkloadAuth` when multiple entries are present. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
