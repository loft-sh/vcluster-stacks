{{/* Name of the chart, for labels. */}}
{{- define "vbox.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Name of the namespaced objects: the release name, suffixed with "-vbox" unless it already says vbox. */}}
{{- define "vbox.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else if contains (include "vbox.name" .) .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "vbox.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/* Name of the cluster-scoped objects: the namespace is part of it, so two releases with the same name in different namespaces do not collide. */}}
{{- define "vbox.clusterName" -}}
{{- printf "%s-%s" (include "vbox.fullname" .) (include "vbox.namespace" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "vbox.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vbox.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "vbox.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "vbox.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* vBox's dedicated namespace. Every namespaced object goes here, not into the release namespace, which only holds Helm's release record. */}}
{{- define "vbox.namespace" -}}
{{- .Values.namespace.name }}
{{- end }}

{{/* With the chart creating the namespace, the release record must live elsewhere: Helm writes it before creating anything, so it cannot go into a namespace the chart has yet to create, and a namespace made by --create-namespace would collide with the chart's own. */}}
{{- define "vbox.checkNamespace" -}}
{{- if and .Values.namespace.create (eq .Release.Namespace .Values.namespace.name) }}
{{- fail (printf "The chart creates the namespace %q itself, so install the release into another one, for example: helm install %s <chart> -n default. (To install into an existing %q instead, set namespace.create=false.)" .Values.namespace.name .Release.Name .Values.namespace.name) }}
{{- end }}
{{- end }}

{{- define "vbox.dataClaim" -}}
{{- .Values.persistence.existingClaim | default (printf "%s-data" (include "vbox.fullname" .)) }}
{{- end }}
