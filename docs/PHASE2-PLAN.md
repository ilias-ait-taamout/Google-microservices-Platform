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
- [ ] **10.** `overlays/staging`: same structure, own namespace, own nodePort,
      plus the `without-loadgenerator` and `network-policies` components
- [ ] **11.** `overlays/prod`: **2 replicas on the frontend only** (not the 11
      services), the `without-loadgenerator` and `network-policies`
      components, and a PodDisruptionBudget on the frontend
      *(a PDB guarantees a minimum number of pods stay alive during maintenance)*
- [ ] **12.** **Capacity check**: sum the cpu/memory `requests` across all three
      namespaces and compare against what the nodes actually have free.
      Pre-computed below; confirm it against `kubectl describe nodes` in task 13

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
- [ ] **14.** Security baseline: run `kube-score` and `checkov` against all
      three rendered overlays and archive the results — the "before" picture to
      compare against in Phase 4
- [ ] **15.** README in `kustomize/overlays/` explaining the structure and the
      choices; update `CLAUDE.md` (Phase 2 done)
- [ ] **16.** `/commit-safe`, then PRs feature → develop → release → main with
      merge commits, and tag `phase2-v1.0.0`

---

Tasks 1-8 and 10-12 are local and free. The cluster is only needed for 9 and 13.
Cost while it runs: ~€0.25/h. `.\cluster.ps1 down` after each session.
