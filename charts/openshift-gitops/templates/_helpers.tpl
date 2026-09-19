{{/*
Common labels applied to every object this chart manages.
*/}}
{{- define "openshift-gitops.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: openshift-gitops
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
The Argo CD application controller's ServiceAccount, as the operator names it for the default
instance: <instance name>-argocd-application-controller. Measured against the Red Hat docs' grant
command, which names openshift-gitops-argocd-application-controller for the instance openshift-gitops.
*/}}
{{- define "openshift-gitops.controllerServiceAccount" -}}
{{- printf "%s-argocd-application-controller" .Values.defaultInstance.name -}}
{{- end -}}
