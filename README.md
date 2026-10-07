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

## The decisions in `values.yaml`

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

## Argo Rollouts

`rollouts.enabled: true` deploys one `RolloutManager` named `argo-rollout` in
`openshift-rollouts`. The dedicated namespace keeps the controller separate from the
operator-owned Argo CD namespace. Consumers such as group-sync-dashboard create their
blue-green `Rollout` resources and use this controller; they do not create a RolloutManager.
Set `rollouts.enabled=false` to omit the new namespace, RBAC and hook.

Red Hat permits **only one Rollouts installation mode per cluster**, with **one
cluster-scoped RolloutManager** by default. `rollouts.namespaceScoped: false` keeps the
Subscription unchanged. Setting it to `true` adds `NAMESPACE_SCOPED_ARGO_ROLLOUTS: "true"`
to the Subscription: the controller then manages Rollouts only in `rollouts.namespace`.
That setting requires `operator.enabled=true`; rendering fails with the Red Hat mode rule
if the chart cannot configure the Subscription. The chart accepts one manager and one mode,
not a list of competing modes. Before changing mode, remove existing managers/controllers
and coordinate the cluster-wide change; an offline render cannot discover other releases
or externally installed controllers. The cluster-scoped hook also refuses to apply when it
finds any other RolloutManager. This inventory check does not serialize concurrent installs.

The `post-install,post-upgrade` hook (weight 7, Argo CD Sync wave 4) follows the existing
approver, verify and RBAC-patch hooks. It polls the OLM-provided CRD until `Established`,
server-side applies `argoproj.io/v1alpha1` / `RolloutManager` with `spec: {}`, then polls
`status.phase` until `Available`. A single `rollouts.timeoutSeconds` budget (600 seconds)
covers those steps; API requests have timeouts and the Job has a 720-second hard deadline.
This path runs on both a fresh install and an upgrade, including when the CRD was absent
at render time. It uses `verifyJob.image`, `imagePullPolicy` and `resources`, even if the
verify Job is disabled, with its own ServiceAccount and narrowly scoped RBAC.

`namespaces.create` and `namespaces.protectOnUninstall` also govern the new namespace.
When namespaces are pre-created, set `namespaces.create=false`. Choosing the existing
operator namespace reuses it; the chart never takes ownership of the default Argo CD
namespace. If choosing that operator-owned namespace, it must already exist before Helm
applies the ordinary hook RBAC (as with the existing RBAC-patch hook).

Verify with the configured namespace (defaults below):

```bash
oc get rolloutmanagers.argoproj.io -A
oc get deployment argo-rollouts -n openshift-rollouts
oc rollout status deployment/argo-rollouts -n openshift-rollouts --timeout=120s
oc logs -n openshift-rollouts job/openshift-gitops-rollouts
```

Expect manager phase `Available` and Deployment readiness `1/1`. The hook log remains for
up to an hour under Helm. The manager is applied by the Job and is not in Helm's resource
inventory: disabling Rollouts, changing its name/namespace, or uninstalling the chart does
not delete it. Remove the old manager explicitly before moving it or changing modes;
otherwise its controller remains (with the namespace protected by default).

## Ordering

| Wave | Weight | Object |
|---|---|---|
| -2 | | Namespaces `openshift-gitops-operator` and `openshift-rollouts` (kept on uninstall) |
| -1 | | OperatorGroup (AllNamespaces — the operator's only install mode) |
| 0 | | Subscription |
| 0 | -6 | csv-reclaim Job — clears a CSV a previous uninstall left behind, which would otherwise block resolution forever |
| 0 | -5 | installplan-approver Job — same wave as the Subscription deliberately; see the template for why a later wave can never become healthy |
| 1 | | ClusterRoleBinding to `cluster-admin`; the verify Job's RBAC |
| 2 | 5 | verify Job |
| 1 | | the rbac-patch Job's RBAC (get/patch on the one ArgoCD CR, by name) |
| 3 | 6 | rbac-patch Job — after the verify Job proved the instance Available |
| 1 | | Rollouts hook ServiceAccount, Role/Binding and ClusterRole/Binding |
| 4 | 7 | Rollouts Job — CRD Established, manager applied, phase Available |

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
