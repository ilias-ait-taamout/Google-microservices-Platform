# Overlays — dev, staging, prod

Three environments for Google's Online Boutique on one self-hosted k3s cluster
on AWS. This directory is **ours**; `../base/` and `../components/` are
Google's and are never modified.

## The three decisions this structure rests on

**A — one cluster, three namespaces.** Not three clusters. Three clusters
would cost roughly €0.75/h to demonstrate the same thing, and namespace
isolation is the richer subject anyway: NetworkPolicies, ResourceQuotas and
per-namespace RBAC all attach to a namespace. Separate Terraform environments
(`envs/staging`, `envs/prod`) are postponed, not cancelled.

**B — one `frontend-external` patch per overlay**, rather than a shared
component. The patch is four lines. Factoring it out would be worth doing the
day the same patch exists in three identical copies — it does not, the
`nodePort` differs in each — and a shared component would have to be
parameterised to vary it.

**C — the upstream base is never touched.** Every environment difference is an
explicit, traceable patch in this directory. This is what lets us pull
upstream changes without a merge conflict, and it is why several findings in
the security baseline are left open rather than fixed: they live in `base/`.

## What differs between the three

| | dev | staging | prod |
|---|---|---|---|
| namespace | `dev` | `staging` | `prod` |
| nodePort | 30080 | 30081 | 30082 |
| loadgenerator | yes | no | no |
| NetworkPolicies | no | yes | yes |
| frontend replicas | 1 | 1 | **2** |
| PodDisruptionBudget | no | no | **yes** |
| resources rendered | 36 | 46 | 47 |
| CPU / memory requests | 1570m / 1368Mi | 1270m / 1112Mi | 1370m / 1176Mi |

Total across the three: **4210m CPU**, about 74 % of the ~5700m allocatable on
3 nodes x 2 vCPU. Memory is nowhere near a constraint. Full figures in
[`../../docs/PHASE2-PLAN.md`](../../docs/PHASE2-PLAN.md).

## Render and deploy

```powershell
# render only - no cluster needed, no cost
kubectl kustomize kustomize\overlays\dev

# write a render to a file: NOT with `>`, which PowerShell 5.1 writes as UTF-16
[IO.File]::WriteAllText("$PWD\docs\phase2\dev-render.yaml", (kubectl kustomize kustomize\overlays\dev | Out-String))

# deploy
kubectl apply -k kustomize\overlays\dev
```

The shop is then at `http://<any_node_public_ip>:<nodePort>`, reachable only
from `admin_cidr` — the security group opens 30000-32767 to that CIDR and does
not open 80.

## Why each pattern was chosen

**`labels:` with `includeSelectors: false`, not `commonLabels:`.**
`commonLabels` is deprecated, and more importantly it writes into selectors. A
Deployment's `spec.selector` is **immutable** after creation, so a label that
might ever change must never land there — changing it later would require
deleting and recreating the Deployment. `includeTemplates: true` still puts the
labels on the pod template, which is what makes them visible to
`kubectl get pods -l environment=prod`.

It has a second effect that matters here: it keeps `environment` out of every
`NetworkPolicy` `podSelector` and out of the `PodDisruptionBudget` selector.
Those match on `app` alone; had the overlay's labels been injected into them,
no policy would match anything.

**`components:` for the shared variations.** A Component is a kustomization of
`kind: Component`. Unlike a `resource` it can both add resources and patch what
is already there, and it is applied after the whole `resources:` block. That
ordering is what lets `without-loadgenerator` delete a Deployment that `base/`
has just created — and it is also why a kustomization's own `patches:`, applied
*after* its components, can delete a resource a component added.

**The `replicas:` transformer, not a patch**, for prod's frontend. It targets a
workload by name and changes one field, so there is no patch file to keep in
sync with the base. Note that the other ten Deployments do not get
`replicas: 1` — they get no `replicas` field at all, which the API server
defaults to 1. The difference matters later: a manifest that pins `replicas: 1`
fights a HorizontalPodAutoscaler forever, a manifest that omits the field does
not.

**Only the frontend scales in prod.** It is the single stateless HTTP entry
point, so it is the only place a second replica demonstrates anything. Scaling
the ten gRPC backends would add ~1200m of requests for no observable gain and
would leave pods `Pending`. `redis-cart` is excluded on purpose: it is one
in-memory instance with no replication, so a second replica would serve a
second, divergent cart store.

**Fixed nodePorts, not automatic ones.** A nodePort is allocated
**cluster-wide**; it is not scoped by namespace. Left unspecified, Kubernetes
picks a free port per environment — the collision is avoided, but the URL
changes on every deploy. Fixing them gives stable URLs and makes a conflict
obvious at render time instead of at apply time.

## Deliberately not done

**`components/non-public-frontend` is unusable in Phase 2.** It does not
convert `frontend-external` to a ClusterIP — it **deletes** it
(`$patch: delete`), leaving only the internal `frontend` Service. Phase 2 needs
a NodePort reachable from `admin_cidr`. The component becomes useful in Phase 3,
once an Ingress replaces `frontend-external`.

**Google's microservice images stay on `v0.10.5`.** Images built by our own CI
and pushed to DockerHub only exist from Phase 3 onward. Only the two
third-party images the base leaves floating are pinned here (`redis:alpine` ->
`7.4-alpine`, `busybox:latest` -> `1.37`).

**`imagePullPolicy`, `securityContext`, `seccompProfile` and digest pinning are
not set.** They are flagged by both scanners and they come from `base/`, which
decision C says we do not modify. They are Phase 4 work, to be done either as
overlay patches or — better — enforced cluster-wide by OPA Gatekeeper, so a new
Deployment cannot be admitted without them. Measured starting point:
[`../../docs/phase2/baseline/README.md`](../../docs/phase2/baseline/README.md).

## One question still open

`components/network-policies` installs a `deny-all` policy and then re-opens
traffic service by service, with rules of the form "only from a pod labelled
`app: frontend`". But the base's probes are **native** (`grpc:`, `httpGet:`,
`tcpSocket:`), performed by the kubelet **from the node**, not from a pod, and
no rule authorises them.

On paper, the readiness probes of the ten backend services in `staging` and
`prod` are blocked and those pods would never become `Ready`. In practice many
NetworkPolicy implementations allow traffic originating on the local node, and
k3s's embedded kube-router-based controller may well be one of them. **Which of
the two happens has not been tested yet** — it is the first thing task 13
answers, and it is a genuine finding either way.
