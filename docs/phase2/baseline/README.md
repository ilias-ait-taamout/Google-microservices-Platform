# Phase 2 task 14 — security baseline

Recorded 16 October 2026 against the three rendered overlays in
`docs/phase2/{dev,staging,prod}-render.yaml`. **No cluster involved**: both
tools read static YAML, so this is reproducible at any time without paying for
EC2.

This is the **"before" picture for Phase 4** (OPA Gatekeeper, Falco, hardened
`securityContext`), which will be measured against these numbers.

## How to reproduce

```bash
kube-score score docs/phase2/<env>-render.yaml
checkov -f docs/phase2/<env>-render.yaml --framework kubernetes --compact --quiet --skip-download
```

kube-score 1.20.0, checkov 3.3.29, kustomize 5.8.1 (the version embedded in
kubectl 1.36.1, so a standalone `kustomize build` and `kubectl kustomize` agree).
Both tools ran on Linux; checkov has a large Python dependency tree and belongs
in CI (Phase 3), not on a workstation. `--skip-download` suppresses an attempt
to fetch online guidelines, which fails behind a proxy and buries the report in
a traceback. **Both tools exit non-zero when they find anything** — expected
here, and not to be read as a tool failure.

## Current numbers

| | dev | staging | prod |
|---|---|---|---|
| kube-score CRITICAL | **62** | 46 | **45** |
| kube-score WARNING | 23 | 23 | 22 |
| checkov failed | **78** | 55 | 55 |
| checkov passed | 1024 | 956 | 956 |
| resources | 36 | 46 | 47 |

## What the components bought, measured

The whole dev-to-staging delta is explained, with nothing left over.

**checkov: 78 - 55 = 23 fewer failures.**

| Cause | Count |
|---|---|
| `CKV2_K8S_6` pods lacking an associated NetworkPolicy — closed by `network-policies` | 12 |
| the 5 per-container checks, for the Deployment `without-loadgenerator` removes | 5 |
| `CKV_K8S_8/9/10/11/12/13` probes and resources, all on `Deployment.dev.loadgenerator` | 6 |
| **total** | **23** |

**kube-score `Pod NetworkPolicy`: 12 -> 0.** One CRITICAL per uncovered pod in
dev, none in staging or prod.

That is the defensible version of "we added NetworkPolicies": not a claim, a
counter that falls to zero and whose residue is fully accounted for.

## The measure -> fix -> re-measure loop

The first run of this baseline turned up a finding worth acting on:

```
networking.k8s.io/v1/NetworkPolicy loadgenerator in prod    CRITICAL
    NetworkPolicy targets Pod
        · The NetworkPolicys selector doesn't match any pods
```

`components/without-loadgenerator` deletes the **Deployment** only, so the
loadgenerator `NetworkPolicy` (from `components/network-policies`) and its
`ServiceAccount` (from `base/`) survived in staging and prod as orphans. Both
are now removed by `delete-loadgenerator-orphans.yaml` in each overlay, using
`$patch: delete`. That works because kustomize applies a kustomization's own
`patches` **after** its `components`, so the NetworkPolicy exists by the time
the patch runs.

| | staging before | staging after | prod before | prod after |
|---|---|---|---|---|
| resources | 48 | **46** | 49 | **47** |
| NetworkPolicy | 13 | **12** | 13 | **12** |
| ServiceAccount | 11 | **10** | 11 | **10** |
| kube-score CRITICAL | 47 | **46** | 46 | **45** |
| checkov failed | 55 | **55** | 55 | **55** |
| checkov passed | 958 | **956** | 958 | **956** |

Read that last pair of rows carefully, because it is the most instructive
result in this whole report. The fix removed **one kube-score CRITICAL and
zero checkov failures**, and *lowered* checkov's passed count by 2 — the two
checks that the now-deleted ServiceAccount used to pass.

In other words: **checkov never saw the problem.** It evaluates each resource
against rules about its own contents, and a NetworkPolicy selecting nothing is
a perfectly well-formed NetworkPolicy. kube-score cross-references selectors
against the workloads present in the same render, so it can see that nothing
matches. Neither tool is a superset of the other, and a rising "passed" count
is not by itself evidence of improvement. Both go in the Phase 3 CI.

## Real gaps, to close in Phase 4

11 occurrences each in staging/prod (12 in dev) — one per Deployment. They
come from Google's `base/`, which we do not modify (decision C), so they must
be fixed by an overlay patch or enforced by an admission policy.

| Finding | Tool | Why it matters |
|---|---|---|
| no `runAsUser` / `runAsGroup` above 10000 | both (`CKV_K8S_40`) | containers run with low UIDs that can collide with host users; the most serious item here |
| no `seccompProfile` | checkov (`CKV_K8S_31`) | no syscall filtering at all |
| ServiceAccount token mounted everywhere | checkov (`CKV_K8S_38`) | every pod can reach the API server; 10 of the 11 never need to |
| `imagePullPolicy` not `Always` | both (`CKV_K8S_15`) | a mutable tag can be served from a stale node cache |
| images by tag, not digest | checkov (`CKV_K8S_43`) | `v0.10.5` is not immutable; Cosign in Phase 4 wants digests |
| no ephemeral-storage request or limit | kube-score | one pod can fill a node's disk |

## Accepted as-is, with reasons

Not noise to be silenced blindly — each is a decision already recorded in
`docs/PHASE2-PLAN.md`.

| Finding | Why it stays |
|---|---|
| `Deployment has PodDisruptionBudget` (10-11x) | deliberate: only the frontend gets one, see task 11 |
| `Deployment Replicas` wants >= 2 (10-11x) | the capacity table says 3 nodes x 2 vCPU will not hold it |
| `host PodAntiAffinity` (11x) | same capacity constraint; meaningful only once prod is multi-replica |
| `Service Type` dislikes NodePort (1x) | the security group opens 30000-32767 to `admin_cidr`, not 80; revisited in Phase 3 with an Ingress |
| `Container Resources` on the busybox init container (dev only, 1x) | upstream's `frontend-check`; dev-only, and the container exits in seconds |

## One finding worth fixing cheaply

`Pod Probes Identical` — CRITICAL on `frontend` and `redis-cart` in all three
environments: their liveness and readiness probes are the same. The
consequence is concrete. A readiness failure removes a pod from the Service's
endpoints; a liveness failure **kills and restarts it**. When both probes are
identical, a pod that is merely slow under load gets killed instead of being
temporarily taken out of rotation, which turns a load spike into a restart
loop. Worth splitting them in Phase 3, when the frontend actually takes
traffic.
