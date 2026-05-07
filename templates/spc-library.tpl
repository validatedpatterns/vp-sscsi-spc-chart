{{/*
Expand the name of the chart.
*/}}
{{- define "vp_sscsi_spc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Stable unique name for namespaced resources when this chart is used as a library dependency.
*/}}
{{- define "vp_sscsi_spc.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else if .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-vp-sscsi-spc" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Determines if the current cluster is a hub cluster.
Usage: {{ include "vp_sscsi_spc.ishubcluster" . }}
Returns: "true" or "false" as a string
*/}}
{{- define "vp_sscsi_spc.ishubcluster" -}}
{{- if and (hasKey .Values.clusterGroup "isHubCluster") (not (kindIs "invalid" .Values.clusterGroup.isHubCluster)) -}}
  {{- .Values.clusterGroup.isHubCluster | toString -}}
{{- else if $.Values.global.hubClusterDomain -}}
  {{- $localDomain := coalesce $.Values.global.localClusterDomain $.Values.global.hubClusterDomain -}}
  {{- if eq $localDomain $.Values.global.hubClusterDomain -}}
true
  {{- else -}}
false
  {{- end -}}
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Resolves app-scoped CSI workload auth attributes from clusterGroup.applications.
Returns a YAML object with:
- namespace
- serviceAccountName
- explicitRoleName (from entry roleName/role, if any)
- roleSlug (from entry roleSlug/role_slug, if any; SecretProviderClass adds <vaultKubernetesMountPath>-sscsi-<slug>)
*/}}
{{- define "vp_sscsi_spc.workloadauth" -}}
{{- $appKey := .Values.ocpSecretsStoreCsiVault.applicationKey | default "" | trim -}}
{{- $appCfg := dict -}}
{{- if and (ne $appKey "") .Values.clusterGroup .Values.clusterGroup.applications (hasKey .Values.clusterGroup.applications $appKey) -}}
  {{- $appCfg = (index .Values.clusterGroup.applications $appKey) -}}
{{- end -}}
{{- $spcNamespace := .Values.ocpSecretsStoreCsiVault.secretProviderClass.namespace | default "" | trim -}}
{{- $appNamespace := "" -}}
{{- if and $appCfg (hasKey $appCfg "namespace") -}}
  {{- $appNamespace = (index $appCfg "namespace" | default "" | toString | trim) -}}
{{- end -}}
{{- $entry := dict -}}
{{- $entryIdx := .Values.ocpSecretsStoreCsiVault.workloadAuthIndex | default 0 | int -}}
{{- if lt $entryIdx 0 -}}
  {{- $entryIdx = 0 -}}
{{- end -}}
{{- if and $appCfg (hasKey $appCfg "ssCsiWorkloadAuth") -}}
  {{- $entries := (index $appCfg "ssCsiWorkloadAuth") -}}
  {{- if and (kindIs "slice" $entries) (gt (len $entries) $entryIdx) -}}
    {{- $entry = (index $entries $entryIdx) -}}
  {{- end -}}
{{- end -}}
{{- $serviceAccountName := "" -}}
{{- if and $entry (hasKey $entry "serviceAccount") -}}
  {{- $serviceAccountName = (index $entry "serviceAccount" | default "" | toString | trim) -}}
{{- end -}}
{{- if and (eq $serviceAccountName "") $entry (hasKey $entry "serviceAccountName") -}}
  {{- $serviceAccountName = (index $entry "serviceAccountName" | default "" | toString | trim) -}}
{{- end -}}
{{- $explicitRoleName := "" -}}
{{- if and $entry (hasKey $entry "roleName") -}}
  {{- $explicitRoleName = (index $entry "roleName" | default "" | toString | trim) -}}
{{- end -}}
{{- if and (eq $explicitRoleName "") $entry (hasKey $entry "role") -}}
  {{- $explicitRoleName = (index $entry "role" | default "" | toString | trim) -}}
{{- end -}}
{{- $roleSlug := "" -}}
{{- if and $entry (hasKey $entry "roleSlug") -}}
  {{- $roleSlug = (index $entry "roleSlug" | default "" | toString | trim) -}}
{{- end -}}
{{- if and (eq $roleSlug "") $entry (hasKey $entry "role_slug") -}}
  {{- $roleSlug = (index $entry "role_slug" | default "" | toString | trim) -}}
{{- end -}}
{{- $entryNamespace := "" -}}
{{- if and $entry (hasKey $entry "namespace") -}}
  {{- $entryNamespace = (index $entry "namespace" | default "" | toString | trim) -}}
{{- end -}}
{{- $resolvedNamespace := coalesce $spcNamespace $entryNamespace $appNamespace .Release.Namespace -}}
namespace: {{ $resolvedNamespace | quote }}
serviceAccountName: {{ $serviceAccountName | quote }}
explicitRoleName: {{ $explicitRoleName | quote }}
roleSlug: {{ $roleSlug | quote }}
{{- end }}

{{/*
Path to the CA file mounted by **openshift-sscsi-vault** (CNO-injected cluster/proxy bundle vs PEM key).
Driven by `ocpSecretsStoreCsiVault.tls.projectedClusterCa` — keep in sync with that chart's `syncProviderCaConfigMap`.
Usage: {{ include "vp_sscsi_spc.projectedVaultCACertPath" . }}
*/}}
{{- define "vp_sscsi_spc.projectedVaultCACertPath" -}}
{{- $tls := .Values.ocpSecretsStoreCsiVault.tls | default dict }}
{{- $p := $tls.projectedClusterCa | default dict }}
{{- $mount := $p.mountDir | default "/etc/pki/vault-ca" | trim | trimSuffix "/" }}
{{- $inject := true }}
{{- if and (hasKey $p "injectTrustedCabundle") (kindIs "bool" $p.injectTrustedCabundle) }}
{{- $inject = $p.injectTrustedCabundle }}
{{- end }}
{{- if $inject }}
{{- $key := $p.trustedCabundleDataKey | default "ca-bundle.crt" | trim }}
{{- printf "%s/%s" $mount $key }}
{{- else }}
{{- $key := $p.keyInConfigMap | default "vault-tls-ca.pem" | trim }}
{{- printf "%s/%s" $mount $key }}
{{- end }}
{{- end }}

{{/*
SecretProviderClass for Vault CSI provider (namespaced).
Expects standard Helm root context with .Values.ocpSecretsStoreCsiVault, .Values.clusterGroup, .Values.global.
*/}}
{{- define "vp_sscsi_spc.secretproviderclass" -}}
{{- if .Values.ocpSecretsStoreCsiVault.secretProviderClass.enabled }}
{{- $workloadAuth := include "vp_sscsi_spc.workloadauth" . | fromYaml }}
{{- $hashicorp_vault_found := false }}
{{- if and .Values.clusterGroup .Values.clusterGroup.applications }}
{{- range $_, $app := .Values.clusterGroup.applications }}
  {{- if $app }}
    {{- if eq $app.chart "hashicorp-vault" }}
      {{- $hashicorp_vault_found = true }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}
{{- $isHubStyleAuth := or (eq (include "vp_sscsi_spc.ishubcluster" .) "true") $hashicorp_vault_found }}
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: {{ .Values.ocpSecretsStoreCsiVault.secretProviderClass.name }}
  namespace: {{ $workloadAuth.namespace | quote }}
spec:
  provider: vault
{{- with .Values.ocpSecretsStoreCsiVault.secretObjects }}
  secretObjects:
{{- toYaml . | nindent 4 }}
{{- end }}
  parameters:
{{- $extVault := .Values.ocpSecretsStoreCsiVault.vault.externalAddress | default "" | trim }}
{{- if ne $extVault "" }}
    vaultAddress: {{ $extVault | quote }}
{{- else }}
    vaultAddress: "https://vault-vault.{{ .Values.global.hubClusterDomain }}"
{{- end }}
{{- $vaultTlsSkip := .Values.ocpSecretsStoreCsiVault.tls.vaultSkipTLSVerify | toString | trim | lower }}
{{- if eq $vaultTlsSkip "true" }}
{{- $vaultTlsSkip = "true" }}
{{- else if eq $vaultTlsSkip "false" }}
{{- $vaultTlsSkip = "false" }}
{{- else if eq $vaultTlsSkip "1" }}
{{- $vaultTlsSkip = "true" }}
{{- else if eq $vaultTlsSkip "0" }}
{{- $vaultTlsSkip = "false" }}
{{- else }}
{{- $vaultTlsSkip = "false" }}
{{- end }}
    vaultSkipTLSVerify: {{ $vaultTlsSkip | quote }}
{{- $tls := .Values.ocpSecretsStoreCsiVault.tls }}
{{- $vaultCACertPath := $tls.vaultCACertPath | default "" | trim }}
{{- $proj := $tls.projectedClusterCa | default dict }}
{{- $projEnabled := false }}
{{- if and (hasKey $proj "enabled") (kindIs "bool" $proj.enabled) }}
{{- $projEnabled = $proj.enabled }}
{{- end }}
{{- if and $projEnabled (eq $vaultCACertPath "") }}
{{- $vaultCACertPath = include "vp_sscsi_spc.projectedVaultCACertPath" . | trim }}
{{- end }}
{{- if and (ne $vaultTlsSkip "true") (ne $vaultCACertPath "") }}
    vaultCACertPath: {{ $vaultCACertPath | quote }}
{{- end }}
{{- if .Values.ocpSecretsStoreCsiVault.tls.vaultTLSServerName }}
    vaultTLSServerName: {{ .Values.ocpSecretsStoreCsiVault.tls.vaultTLSServerName | quote }}
{{- end }}
{{- $hubMountPath := .Values.ocpSecretsStoreCsiVault.vault.hubMountPath | default "" | trim }}
{{- $localDomain := coalesce $.Values.global.localClusterDomain $.Values.global.hubClusterDomain | default "" | toString | trim }}
{{- $hubDomain := $.Values.global.hubClusterDomain | default "" | trim }}
{{- $defaultHubMountPath := $.Values.global.clusterDomain | default "" | trim }}
{{- if and (ne $localDomain "") (eq $localDomain $hubDomain) }}
{{- $defaultHubMountPath = "hub" }}
{{- end }}
{{- $vaultMountPath := $.Values.global.clusterDomain | default "" | trim }}
{{- if $isHubStyleAuth }}
{{- $vaultMountPath = coalesce $hubMountPath $defaultHubMountPath "hub" }}
{{- end }}
{{- $explicit := $workloadAuth.explicitRoleName | default "" | toString | trim }}
{{- $slug := $workloadAuth.roleSlug | default "" | toString | trim }}
{{- $resolvedRole := $explicit }}
{{- if eq $resolvedRole "" }}
{{- if ne $slug "" }}
{{- $resolvedRole = printf "%s-sscsi-%s" $vaultMountPath $slug }}
{{- else if $isHubStyleAuth }}
{{- $resolvedRole = coalesce $.Values.ocpSecretsStoreCsiVault.auth.roleName "hub-role" | toString | trim }}
{{- else }}
{{- $resolvedRole = printf "%s-role" $vaultMountPath }}
{{- end }}
{{- end }}
    vaultKubernetesMountPath: {{ $vaultMountPath | quote }}
    roleName: {{ $resolvedRole | quote }}
    objects: |
{{- range .Values.ocpSecretsStoreCsiVault.objects }}
      - objectName: {{ .objectName | quote }}
        secretPath: {{ .secretPath | quote }}
        secretKey: {{ .secretKey | quote }}
{{- end }}
{{- end }}
{{- end }}
