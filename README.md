# openshift-gitops-helm-chart

One `helm install` that puts Red Hat OpenShift GitOps on a cluster the way the rest of this estate installs
operators: an OLM Subscription pinned to a version, an approver that approves only that version, the
default Argo CD instance the operator creates kept on, and that instance's application controller bound
to `cluster-admin` so it can manage the whole cluster. A verify Job proves all of it before the release
reports success.

| Chart | What it does | Who runs it |
|---|---|---|
| [`charts/openshift-gitops`](charts/openshift-gitops) | Namespace, OperatorGroup, Subscription (`redhat-operators` / `latest`, `installPlanApproval: Manual`, pinned `startingCSV`), the csv-reclaim and installplan-approver Jobs, `DISABLE_DEFAULT_ARGOCD_INSTANCE` and `ARGOCD_CLUSTER_CONFIG_NAMESPACES` stated on the Subscription, a ClusterRoleBinding to `cluster-admin` for `openshift-gitops/openshift-gitops-argocd-application-controller`, and a five-stage verify Job | Platform / cluster admin |

## Install

```bash
# from a clone
helm upgrade --install openshift-gitops charts/openshift-gitops -n openshift-gitops-operator --create-namespace --timeout 15m

# what it left behind
oc get subscriptions.operators.coreos.com -n openshift-gitops-operator
oc get argocds.argoproj.io -n openshift-gitops                  # phase Available
oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}{"\n"}'
oc extract secret/openshift-gitops-cluster -n openshift-gitops --keys=admin.password --to=-
```

`--timeout 15m` covers the operator install and the instance coming up: the release is gated on the verify
Job (`post-install`, weight 5), which waits for the CSV to succeed, the `ArgoCD` CR to report
`phase: Available`, the controller ServiceAccount to exist, and a `SubjectAccessReview` to answer
`allowed: true` for `*`/`*`/`*` as that ServiceAccount. Its log is where a stalled install explains itself:

```bash
oc logs -n openshift-gitops-operator job/openshift-gitops-verify
```

## The four decisions in `values.yaml`

**`operator.installPlanApproval: Manual` with `operator.startingCSV` pinned.** `latest` is a rolling
channel. Automatic approval would let a new GitOps release install itself onto the cluster that deploys
everything else, with no change in git. Manual alone would hang the first install waiting for a human, so
the `installplan-approver` Job approves exactly the pinned CSV and nothing else. To move version: bump
`startingCSV` to the exact name the catalog serves, review, merge.

```bash
oc get packagemanifest openshift-gitops-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{" -> "}{.currentCSV}{"\n"}{end}'
```

**`defaultInstance.enabled: true`.** The operator creates a ready-to-use instance in `openshift-gitops`
unless `DISABLE_DEFAULT_ARGOCD_INSTANCE` is `"true"` on its Subscription. This chart states the value
either way rather than inheriting the operator's default. With `false`, set `clusterAdmin.enabled=false`
too — the binding would name a ServiceAccount that never exists.

**`clusterAdmin.enabled: true`.** The Red Hat-documented grant for an Argo CD that manages the whole
cluster, `oc adm policy add-cluster-role-to-user cluster-admin -z openshift-gitops-argocd-application-controller -n openshift-gitops`,
as the ClusterRoleBinding that command creates — in the release, reconciled on upgrade, proved by the
verify Job. It is the right default for a lab (CRC). On a shared cluster prefer the operator's own scoping
(`operator.clusterConfigNamespaces`, which is `ARGOCD_CLUSTER_CONFIG_NAMESPACES`) plus namespace-level
`admin` grants, or a user-defined ClusterRole, and set this `false`.

**`defaultInstance.rbac.enabled: true`.** The instance's UI/API RBAC, asserted by the `rbac-patch` hook
(`oc patch argocds.argoproj.io openshift-gitops --type merge` on `spec.rbac`, which the operator renders
into `argocd-rbac-cm`), idempotent on every install and upgrade. Needed because of a measured gap
(CRC, 2026-09-19): the operator's default policy grants `role:admin` to the *groups*
`system:cluster-admins` / `cluster-admins` with `scopes: [groups]` and no default role, but Dex's
OpenShift connector puts only `system:authenticated` in a token's `groups` — kubeadmin's cluster-admin
membership is a virtual group Dex never sees — so kubeadmin's UI session had no role at all:
`PermissionDenied` on every list, empty Repositories and Applications pages while both existed. The
default policy adds `name` to the scopes and `g, kubeadmin, role:admin`; add your own OpenShift Group
objects (those do reach Dex) or users to `policy`. Log out of the UI and back in after the patch — the
role is evaluated per session.

## Ordering

| Wave | Weight | Object |
|---|---|---|
| -2 | | Namespace `openshift-gitops-operator` (kept on uninstall) |
| -1 | | OperatorGroup (AllNamespaces — the operator's only install mode) |
| 0 | | Subscription |
| 0 | -6 | csv-reclaim Job — clears a CSV a previous uninstall left behind, which would otherwise block resolution forever |
| 0 | -5 | installplan-approver Job — same wave as the Subscription deliberately; see the template for why a later wave can never become healthy |
| 1 | | ClusterRoleBinding to `cluster-admin`; the verify Job's RBAC |
| 2 | 5 | verify Job |
| 1 | | the rbac-patch Job's RBAC (get/patch on the one ArgoCD CR, by name) |
| 3 | 6 | rbac-patch Job — after the verify Job proved the instance Available |

The Argo CD instance namespace `openshift-gitops` is **not** in the chart. The operator creates it with the
instance and deletes it with the instance; a second owner would leave it behind unmanaged.

## Uninstall

`helm uninstall` removes the Subscription and the binding. OLM leaves the CSV and the operator namespace
behind (the namespace by this chart's `protectOnUninstall`); the next install's csv-reclaim Job handles
the orphaned CSV. To remove the operator entirely:

```bash
helm uninstall openshift-gitops -n openshift-gitops-operator
oc delete clusterserviceversions.operators.coreos.com -n openshift-gitops-operator -l operators.coreos.com/openshift-gitops-operator.openshift-gitops-operator=
oc delete ns openshift-gitops-operator
```

## Provenance

The approver, reclaim and verify Jobs are ports of the ones in the sibling
[`cert-manager-venafi`](https://github.com/ephico2real2/cert-manager-venafi) chart, which measured the
behaviours their comments describe (the `sort -V` traps, the plural-name discovery hazard, the stale
`Degraded` condition). What is new here is the instance/grant half of the verify Job and the two
Subscription env knobs, measured on OpenShift 4.22.7 / GitOps 1.21.4 on CRC, 2026-09-18.
