# Phase 2 — Online Boutique with Kustomize

Working plan. Lives in the repo on purpose: a numbered list that only exists in
a chat is lost at the next `/clear`.

Read alongside `CLAUDE.md`. Tick items off as they land.

## Decisions (13 Oct 2026)

**A — One cluster, three namespaces.** Not three clusters.
Supersedes the earlier plan to create `envs/staging` and `envs/prod` in Phase 2.
Three clusters would cost ~€0.75/h to demonstrate the same thing. Namespace
isolation is also richer material: NetworkPolicies, ResourceQuotas and
per-namespace RBAC all attach to it in Phase 4. Separate Terraform environments
remain possible later — postponed, not cancelled.

**B — One `frontend-external` patch per overlay.** Not a shared component.
Factor it out the day the same patch exists in three copies, not before.

**C — Google's `base/` and `components/` stay untouched.** `overlays/` sits
beside them. The upstream base is never modified; every environment difference
is an explicit, traceable patch.

### Correction carried into CLAUDE.md
k3s ships **ServiceLB (Klipper)**, still enabled — only Traefik was disabled.
A `type: LoadBalancer` Service therefore creates an `svclb-*` DaemonSet using
hostPorts, **not an AWS ELB**. The "LoadBalancer blocks terraform destroy"
hazard only becomes real once the AWS Cloud Controller Manager or the AWS Load
Balancer Controller is installed (Phase 3). The `kubernetes.io/role/elb` subnet
tag exists for that moment.

**NodePort is still the right choice**, for a different reason: the security
group does not open port 80, while `30000-32767` is already open to
`admin_cidr`.

---

## Tasks

### Preparation — costs nothing, no cluster
- [x] **1.** Branch `feature/phase2-kustomize` from `develop`
- [x] **2.** `kubectl kustomize kustomize/base` — reference render. Record the
      kubectl and kustomize versions: `components:` (tasks 10-11) needs a recent
      one, and kubectl's embedded kustomize often lags the standalone binary.
      Note the resource names, the `frontend-external` type, and the cpu/memory
      requests — task 12 needs those numbers.
- [x] **3.** Confirm the Terraform security group opens 30000-32767 to
      `admin_cidr`. Without it the frontend is unreachable even when everything
      runs.
- [x] **4.** Fix one `nodePort` per environment — 30080 / 30081 / 30082.
      Mandatory under decision A: three namespaces share the same nodes, so an
      unfixed port means the second `apply` collides.

### Overlay dev
- [x] **5.** `overlays/dev/` skeleton: `kustomization.yaml` pointing at
      `../../base`, a `Namespace` resource, the `namespace:` field, and common
      labels (`environment`, `app.kubernetes.io/part-of`)
- [x] **6.** Patch `frontend-external` to `type: NodePort` with the port from
      task 4
- [x] **7.** Pin the `redis:alpine` and `busybox:latest` tags with an `images:`
      block, without touching the base. The microservice images stay Google's —
      DockerHub images only exist once the CI runs (Phase 3)
- [x] **8.** Verify the dev render against the task-2 reference: every resource
      in namespace `dev`, no `LoadBalancer` left, labels present
- [x] **9.** First real deployment: `up` → `kubeconfig` → `kubectl apply -k` →
      all pods `Ready` → shop reachable at `http://<node-ip>:30080` → `down`

### Task 9 result (15 Oct 2026) — DONE

Validated end to end: 12/12 pods `Running` in namespace `dev`,
`frontend-external` as `NodePort 80:30080/TCP`, and
`curl -I http://<server_public_ip>:30080` returning `HTTP/1.1 200 OK`.

One real defect was found and fixed on the way, and one false alarm:

- **Real:** `--node-external-ip` was passed to k3s on both the server and the
  agents. It advertised the public IP to in-cluster clients, so the agents
  dialled the server's public address for the k3s supervisor tunnel; the
  packet hairpinned through the IGW and arrived with a public source address
  that the security group's self-reference rule does not match. The cluster
  reported all three nodes `Ready` while `kubectl logs`, `exec` and
  `port-forward` were broken for every pod on an agent. Fixed by removing the
  flag from both templates and keeping `--tls-san` for external kubectl.
  Recorded as gotcha 5 in `CLAUDE.md`. Verified after the rebuild with
  `Remotedialer connected to proxy url="wss://10.0.1.75:6443/..."` (private
  IP) and `kubectl get --raw "/api/v1/nodes/<agent>/proxy/healthz"` → `ok`
  on both agents.
- **False alarm:** `loadgenerator`'s init container `frontend-check` in
  `CrashLoopBackOff`. It performs a single `wget` against `http://frontend:80`
  and exits non-zero if the frontend is not serving yet, so a growing backoff
  during the first minute is expected startup noise, not a defect. It reached
  `1/1 Running` at 46s on the clean run.

### Overlays staging and prod
- [x] **10.** `overlays/staging`: same structure, own namespace, own nodePort,
      plus the `without-loadgenerator` and `network-policies` components

**Task 10 render verified (15 Oct 2026).** 48 resources: 11 Deployments,
12 Services, 11 ServiceAccounts, 13 NetworkPolicies, 1 Namespace. All 47
namespaced resources in `staging`. `frontend-external` is
`NodePort 80:30081 -> 8080`. Every NetworkPolicy `podSelector` and every
`ingress.from.podSelector` still matches on `app` alone, so
`includeSelectors: false` did its job. Requests total **1270m / 1112Mi** --
exactly the figure predicted in the capacity table above.

Two deliberate orphans remain, to be settled in task 14: the `loadgenerator`
ServiceAccount (from the base) and the `loadgenerator` NetworkPolicy (from the
component). `without-loadgenerator` deletes the Deployment only. The
`busybox` entry in `images:` is also a no-op in staging, since the only
busybox container was the deleted Deployment's init container; it is kept so
the three overlays stay symmetrical.

**Still unproven:** whether the `deny-all` NetworkPolicy blocks the kubelet's
native `grpc:` / `httpGet:` / `tcpSocket:` probes, which originate from the
node rather than from a pod and are allowed by no rule. If they are blocked,
the backend pods never become `Ready`. Writing the prod overlay first is fine
-- it uses the same components, so the answer applies identically to both --
but tasks 10 and 11 cannot be called done until task 13 has run them on the
cluster.

- [x] **11.** `overlays/prod`: **2 replicas on the frontend only** (not the 11
      services), the `without-loadgenerator` and `network-policies`
      components, and a PodDisruptionBudget on the frontend
      *(a PDB guarantees a minimum number of pods stay alive during maintenance)*
- [x] **12.** **Capacity check**: sum the cpu/memory `requests` across all three
      namespaces and compare against what the nodes actually have free.
      Pre-computed below; confirm it against `kubectl describe nodes` in task 13

**Task 11 render verified (15 Oct 2026).** 49 resources, all 48 namespaced
ones in `prod`. `frontend` at `replicas: 2`; every other Deployment leaves the
field absent, so the API server defaults it to 1 -- which also means a future
HPA would not fight the manifest. `frontend-external` is
`NodePort 80:30082 -> 8080`. PDB `frontend`, `policy/v1`,
`minAvailable: 1`, selector `app: frontend`. Every selector in the render
(Deployment, NetworkPolicy, NetworkPolicy ingress-from, PDB) still matches on
`app` alone. Requests **1370m / 1176Mi** -- exactly as predicted.

**Task 12 done (15 Oct 2026), measured from the three renders rather than
estimated:**

| env | resources | Deployments | pods | CPU requests | memory requests |
|---|---|---|---|---|---|
| dev | 36 | 12 | 12 | 1570m | 1368Mi |
| staging | 48 | 11 | 11 | 1270m | 1112Mi |
| prod | 49 | 11 | 12 | 1370m | 1176Mi |
| **total** | | | **35** | **4210m** | **3656Mi** |

3 nodes x 2 vCPU = 6000m, with roughly 300m taken by the k3s system pods, so
about 5700m allocatable: the three namespaces ask for **74 %** of it, leaving
~1500m. Memory is nowhere near a constraint (3656Mi of ~15 GiB). The figures
land exactly on the 13 Oct estimate below, so the model was sound.

Still to confirm against the cluster in task 13 with
`kubectl describe nodes`: per-node allocatable differs slightly from
2000m, and the scheduler packs per node, not per cluster -- 74 % cluster-wide
can still leave one node unable to fit a particular pod.

### Capacity (computed 13 Oct 2026, from `docs/phase2/REFERENCE.md`)

Decision: the loadgenerator only makes sense in dev, so staging and prod both
drop it, and prod scales **only the frontend** to 2 replicas. The earlier plan
(loadgenerator everywhere, 2 replicas on every stateless service) came to
~5610m, which would have left prod pods `Pending`.

| Namespace | Content | CPU requests | Memory requests |
|---|---|---|---|
| dev | full base | 1570m | 1368Mi |
| staging | without loadgenerator | 1270m | 1112Mi |
| prod | without loadgenerator, frontend ×2 | 1370m | 1176Mi |
| **Total** | | **4210m** | **3656Mi** |

Against 3 nodes × 2 vCPU = 6000m (~5700m once k3s system pods are counted):
**~74 % of CPU, it fits**, with ~1500m headroom. Memory is far from a limit
(~3.6 GiB of ~15 GiB). That headroom will not cover the Phase 5 observability
stack, so revisit capacity then.

### Note: `components/non-public-frontend` is not usable in Phase 2
It does not convert `frontend-external` to ClusterIP: it **deletes** it
(`$patch: delete`), leaving only the internal `frontend` ClusterIP Service.
Phase 2 needs a NodePort reachable from `admin_cidr`, so each overlay carries
its own NodePort patch (decision B). The component becomes useful in Phase 3,
once an Ingress replaces `frontend-external`.

### Validation and close
- [ ] **13.** All three environments at once: pods `Ready` in each namespace,
      three frontends responding, NetworkPolicies proven to block a forbidden
      call (test with a throwaway pod). Then `down`, then `orphans`
- [x] **14.** Security baseline: run `kube-score` and `checkov` against all
      three rendered overlays and archive the results — the "before" picture to
      compare against in Phase 4

**Task 14 done (16 Oct 2026).** Full report and raw output in
`docs/phase2/baseline/`. kube-score 1.20.0 and checkov 3.3.29, both against
the static renders, so no cluster and no cost.

| | dev | staging | prod |
|---|---|---|---|
| kube-score CRITICAL | 62 | 47 | 46 |
| kube-score WARNING | 23 | 23 | 22 |
| checkov failed | 78 | 55 | 55 |
| checkov passed | 1024 | 958 | 958 |

The dev-to-staging delta is fully accounted for: 12 `CKV2_K8S_6` (pods with no
associated NetworkPolicy) closed by the `network-policies` component, plus 11
for the Deployment that `without-loadgenerator` removes (5 per-container
checks + 6 probe/resources checks that all hit the busybox init container).
kube-score's `Pod NetworkPolicy` goes 12 -> 0. That is the measurable version
of "we added NetworkPolicies".

**Action it produced, and carried out** (commit after `7ce56de6`, which keeps
the "before" snapshot in history): kube-score flagged the orphan
`loadgenerator` NetworkPolicy in staging and prod -- *"The NetworkPolicys
selector doesn't match any pods"*. That settled the question left open at
tasks 10-11. `delete-loadgenerator-orphans.yaml` in each overlay now removes
the NetworkPolicy and the unused ServiceAccount with `$patch: delete`, which
works because kustomize applies a kustomization's own `patches` **after** its
`components`.

| | staging before | after | prod before | after |
|---|---|---|---|---|
| resources | 48 | **46** | 49 | **47** |
| NetworkPolicy | 13 | **12** | 13 | **12** |
| ServiceAccount | 11 | **10** | 11 | **10** |
| kube-score CRITICAL | 47 | **46** | 46 | **45** |
| checkov failed | 55 | **55** | 55 | **55** |
| checkov passed | 958 | **956** | 958 | **956** |

The last two rows are the instructive part: the fix removed one kube-score
CRITICAL and **zero** checkov failures, and *lowered* checkov's passed count
by 2 -- the checks the deleted ServiceAccount used to pass. checkov never saw
the problem, because a NetworkPolicy selecting nothing is a perfectly
well-formed NetworkPolicy; only kube-score cross-references selectors against
the workloads in the render. A rising "passed" count is therefore not by
itself evidence of improvement.

Worth noting for Phase 3 CI: **checkov does not flag that orphan and
kube-score does.** checkov reasons about each resource's own contents,
kube-score cross-references selectors against the workloads in the same
render. Neither is a superset of the other -- run both.

- [x] **15.** README in `kustomize/overlays/` explaining the structure and the
      choices; update `CLAUDE.md` (Phase 2 done)

**Task 15 done (16 Oct 2026).** `kustomize/overlays/README.md` is the entry
point for a reader: the three decisions (A/B/C), a table of what differs
between the environments, render and deploy commands, and a section on *why*
each pattern was chosen rather than only what it does -- `labels` with
`includeSelectors: false` and the immutability of Deployment selectors,
`components:` and their ordering relative to `patches:`, the `replicas`
transformer versus a patch, why only the frontend scales and why `redis-cart`
must not, and why the nodePorts are fixed rather than auto-allocated. Plus a
"deliberately not done" section, so the gaps read as decisions rather than
oversights.

`CLAUDE.md` current-state section refreshed: 13 of 16 tasks done, `staging`
and `prod` render-verified but never applied, tasks 13 and 16 remaining.

- [ ] **16.** `/commit-safe`, then PRs feature → develop → release → main with
      merge commits, and tag `phase2-v1.0.0`

---

Tasks 1-8 and 10-12 are local and free. The cluster is only needed for 9 and 13.
Cost while it runs: ~€0.25/h. `.\cluster.ps1 down` after each session.
