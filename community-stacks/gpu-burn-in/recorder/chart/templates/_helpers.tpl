{{- define "recorder.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "recorder.labels" -}}
app.kubernetes.io/name: gpu-burn-in-recorder
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/part-of: gpu-burn-in-stack
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "recorder.selector" -}}
app.kubernetes.io/name: gpu-burn-in-recorder
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}
