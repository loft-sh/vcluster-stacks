{{- define "burnin.test" -}}
{{- .Values.test | default "inventory" -}}
{{- end -}}

{{- define "burnin.labels" -}}
app.kubernetes.io/name: gpu-burn-in
app.kubernetes.io/part-of: gpu-burn-in-stack
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/component: {{ include "burnin.test" . | quote }}
{{- end -}}

{{- /* GPU tests run a tool image and request GPUs; the other steps only talk to the API server. */ -}}
{{- define "burnin.gpuTest" -}}
{{- if has (include "burnin.test" .) (list "inventory" "dcgmdiag" "nccl" "soak") }}true{{ end -}}
{{- end -}}

{{- define "burnin.soakMinutes" -}}
{{- $m := .Values.soakMinutes | default "0" | int -}}
{{- if gt $m 1440 }}1440{{ else if lt $m 0 }}0{{ else }}{{ $m }}{{ end -}}
{{- end -}}

{{- define "burnin.runTimeout" -}}
{{- if eq (include "burnin.test" .) "soak" -}}
{{- add (mul (include "burnin.soakMinutes" . | int) 60) 900 -}}
{{- else -}}
{{- .Values.runTimeoutSeconds | default "3600" -}}
{{- end -}}
{{- end -}}

{{- define "burnin.image" -}}
{{- if eq (include "burnin.test" .) "nccl" -}}
{{- .Values.ncclImage | default "nvcr.io/nvidia/pytorch:26.09-py3" -}}
{{- else -}}
{{- .Values.dcgmImage | default "nvcr.io/nvidia/cloud-native/dcgm:4.5.3-1-ubuntu24.04" -}}
{{- end -}}
{{- end -}}
