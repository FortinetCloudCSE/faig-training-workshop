{{/*
Common labels. Deliberately minimal: the existing manifests use `app: llamacpp`
and `app.kubernetes.io/name: chatbot` as SELECTOR labels, which must not change
(selectors are immutable on an existing Deployment). So these go on metadata
only — never into a selector.
*/}}
{{- define "llm-stack.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Render a component's imagePullSecrets block, or nothing when the list is empty.
Azure passes [acr-pull]; k3s passes [] because the image is side-loaded into
containerd.
Usage: {{- include "llm-stack.imagePullSecrets" .Values.chatbot | nindent 6 }}
*/}}
{{- define "llm-stack.imagePullSecrets" -}}
{{- with .imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Build an image reference. Tag precedence: component tag, then global.imageTag.
Usage: {{ include "llm-stack.image" (dict "component" .Values.chatbot "global" .Values.global) }}
*/}}
{{- define "llm-stack.image" -}}
{{- $tag := .component.image.tag | default .global.imageTag -}}
{{- if not $tag -}}
{{- fail "image tag is unset: set <component>.image.tag or global.imageTag" -}}
{{- end -}}
{{- printf "%s:%s" .component.image.repository $tag -}}
{{- end -}}

{{/*
Validate llamacpp.model.source. Both deployment.yaml and pvc.yaml branch on
this value to pick the baked-image vs PVC-fetch shape; a silent typo (e.g.
"PVC", "hostpath") would otherwise fall through to the baked shape with no
error, and the pod would CrashLoopBackOff with no model file and no signal why.
Usage: {{ include "llm-stack.llamacpp.validateModelSource" .Values.llamacpp.model.source }}
*/}}
{{- define "llm-stack.llamacpp.validateModelSource" -}}
{{- if not (has . (list "baked" "pvc")) -}}
{{- fail (printf "llamacpp.model.source must be 'baked' or 'pvc', got %q" .) -}}
{{- end -}}
{{- end -}}
