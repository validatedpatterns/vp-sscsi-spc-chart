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
- roleName
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
{{- $resolvedNamespace := coalesce $spcNamespace $appNamespace .Release.Namespace -}}
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
{{- $roleName := "" -}}
{{- if and $entry (hasKey $entry "roleName") -}}
  {{- $roleName = (index $entry "roleName" | default "" | toString | trim) -}}
{{- end -}}
{{- if and (eq $roleName "") $entry (hasKey $entry "role") -}}
  {{- $roleName = (index $entry "role" | default "" | toString | trim) -}}
{{- end -}}
{{- if and (eq $roleName "") $entry (hasKey $entry "roleSlug") -}}
  {{- $roleSlug := (index $entry "roleSlug" | default "" | toString | trim) -}}
  {{- if ne $roleSlug "" -}}
    {{- $roleCluster := "hub" -}}
    {{- if and $entry (hasKey $entry "cluster") -}}
      {{- $roleCluster = (index $entry "cluster" | default "" | toString | trim) -}}
    {{- end -}}
    {{- if eq $roleCluster "" -}}
      {{- $roleCluster = "hub" -}}
    {{- end -}}
    {{- $roleName = printf "%s-sscsi-%s" $roleCluster $roleSlug -}}
  {{- end -}}
{{- end -}}
namespace: {{ $resolvedNamespace | quote }}
serviceAccountName: {{ $serviceAccountName | quote }}
roleName: {{ $roleName | quote }}
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
{{- if and (ne $vaultTlsSkip "true") (ne $vaultCACertPath "") }}
    vaultCACertPath: {{ $vaultCACertPath | quote }}
{{- end }}
{{- if .Values.ocpSecretsStoreCsiVault.tls.vaultTLSServerName }}
    vaultTLSServerName: {{ .Values.ocpSecretsStoreCsiVault.tls.vaultTLSServerName | quote }}
{{- end }}
{{- if $isHubStyleAuth }}
    vaultKubernetesMountPath: {{ .Values.ocpSecretsStoreCsiVault.vault.hubMountPath | quote }}
    roleName: {{ coalesce $workloadAuth.roleName .Values.ocpSecretsStoreCsiVault.auth.roleName "hub-role" | quote }}
{{- else }}
    vaultKubernetesMountPath: {{ $.Values.global.clusterDomain | quote }}
    roleName: {{ coalesce $workloadAuth.roleName (printf "%s-role" $.Values.global.clusterDomain) | quote }}
{{- end }}
    objects: |
{{- range .Values.ocpSecretsStoreCsiVault.objects }}
      - objectName: {{ .objectName | quote }}
        secretPath: {{ .secretPath | quote }}
        secretKey: {{ .secretKey | quote }}
{{- end }}
{{- end }}
{{- end }}
