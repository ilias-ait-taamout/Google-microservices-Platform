# Phase 3 — CI/CD and GitOps

Working plan. Lives in the repo on purpose: a numbered list that only exists in
a chat is lost at the next `/clear`.

Read alongside `CLAUDE.md`, `docs/PHASE2-PLAN.md` and
`kustomize/overlays/README.md`. Tick items off as they land.

Goal: a push produces a built, scanned, signed image, and the cluster picks it
up on its own. ADR-002 (image versioning) and ADR-003 (GitOps) already set the
rules; this phase implements them.

## Starting point

- 11 services in **6 languages**: Go x4 (frontend, checkoutservice,
  productcatalogservice, shippingservice), Python x3 (emailservice,
  recommendationservice, loadgenerator), Node x2 (currencyservice,
  paymentservice), Java/Gradle (adservice), .NET (cartservice).
- `shoppingassistantservice` has a Dockerfile but is **not** in
  `kustomize/base/` — it is not deployed and must not be built.
- `.github/workflows/` is empty; the inherited GKE workflows are parked in
  `.github/workflows-reference/`.
- `kustomize/base/` points at Google's images
  (`us-central1-docker.pkg.dev/google-samples/microservices-demo/<svc>:v0.10.5`).
- Capacity: ~1500m of CPU requests free. ArgoCD needs ~550m and Traefik ~100m,
  so this phase fits with ~850m left. Phase 5's observability stack will not.

## Decisions (16 Oct 2026)

Continuing the A/B/C lettering from Phase 2.

**D — One service end to end first, then generalise.** The full pipeline on
`frontend` alone (Go, fastest build): build, Trivy, Cosign, tag bump,
deployment. Only then a matrix over the 11 with path filters so an unchanged
service is not rebuilt. This is the walking-skeleton method from
`02-FULL-PLAN.md`: a first run over 6 languages at once fails in three places
simultaneously and tells you nothing about which.

**E — ArgoCD as a remote Kustomize base.** Its official `install.yaml`
referenced as a remote resource, with our patches on top. Consistent with the
Kustomize-not-Helm decision; versioned in Git; patchable. Installing it by
Helm would contradict a decision recorded project-wide, and `kubectl apply -f`
straight from a URL is not reproducible — which would undercut the GitOps
principle this phase exists to demonstrate.

**F — One Git branch per environment.** `develop` -> dev, `release` ->
staging, `main` -> prod. It reuses the existing GitFlow rather than inventing
a parallel structure, and it has a non-obvious benefit: `main` carries a
ruleset requiring a pull request, so CI **cannot** push an image bump to prod
directly. ADR-003's "manual approval for prod" is therefore enforced by the
branch protection already in place, with no extra configuration.

**G — Re-enable k3s's bundled Traefik.** The control-plane template currently
passes `--disable traefik`; removing that flag is the whole change. Nothing to
install, no extra CPU beyond Traefik itself. k3s deploys it through an internal
HelmChart CRD, which is k3s's own mechanism and not a Helm dependency of ours.
Hostnames via `<ip>.sslip.io`, which resolves any IP embedded in the name, so
no domain to buy and no DNS to run.

### Two consequences of D and F to settle before writing any workflow

**The image override belongs in the overlays, not the base.** Decision C says
`base/` is never modified. So the CI-built image is substituted by the
`images:` transformer in each overlay:

```yaml
images:
  - name: us-central1-docker.pkg.dev/google-samples/microservices-demo/frontend
    newName: <dockerhub-user>/frontend
    newTag: sha-abc1234
```

`name` matches what the base contains; `newName` and `newTag` are what gets
deployed. Google's images stay the default for any service CI has not built
yet, which is what makes a one-service-at-a-time rollout possible at all.

**Who commits the tag bump, and where.** This is the open question of the
phase, and task 4 exists to answer it. CI builds on a push to `develop`, then
has to write the new tag into `kustomize/overlays/dev/kustomization.yaml` —
on `develop`. But `CLAUDE.md` says never push directly to `develop`. Three
ways out:

1. CI pushes the bump straight to `develop` with `[skip ci]` in the message to
   avoid an infinite loop. Simplest; needs `develop` to accept a bot push.
2. CI opens a pull request for the bump, even for dev. Consistent with the
   rule, but a PR to merge for every dev deployment.
3. ArgoCD Image Updater writes to Git itself. Moves the problem rather than
   solving it, and adds a component.

Whichever is chosen, `main` keeps option 2 by force — that is decision F's
benefit, not a workaround.

---

## Tasks

### Preparation — costs nothing, no cluster
- [ ] **1.** Branch `feature/phase3-cicd` from `develop`
- [ ] **2.** DockerHub: account, **11 public** repositories (one per deployed
      service), Access Token with write scope. Visibility settled by ADR-005:
      the free plan allows 1 private repository, so 11 private would need a
      paid plan — the constraint decides it, not a preference
- [ ] **3.** GitHub secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`
- [x] **4.** **ADR-004** — who commits the image bump and to which branch (the
      three options above). Write it down before any workflow: it decides the
      shape of every one of them

### CI — one service first (decision D)
- [x] **5.** `.github/workflows/build-push.yml` on `frontend` only: build,
      tag `sha-<7>` per ADR-002, push to DockerHub. Triggered on pushes to
      `develop` touching `src/frontend/**`

**Task 5 done (19 Oct 2026).** `iliasroo/frontend:sha-a0f5b7a` on DockerHub,
12 MB, amd64, single manifest. First run 1m31s cold, 2s warm on the gha cache.

Two problems the first run surfaced and that are now fixed: `DOCKERHUB_USERNAME`
was a **secret**, so GitHub masked it everywhere (logs read `***/frontend`) and
refused to pass the job's `image` output downstream - which Trivy and Cosign
both need. It is a repository **variable** now; the token stays a secret.
Over-classifying a non-secret has a real cost: unreadable logs push people to
disable masking, and silently dropped outputs fail without saying why.
`runs-on` is also pinned to `ubuntu-24.04` rather than `ubuntu-latest`, for the
same reason ADR-002 forbids floating image tags.

**All actions are pinned to full commit SHAs.** On 19 March 2026 an attacker
force-pushed **76 of the 77 version tags** of `aquasecurity/trivy-action` to
credential-stealing malware (GHSA-69fq-xp46-6x23); tags 0.0.1-0.34.2 were
affected, 0.35.0 was not. Anyone pinned to a tag got the malware without
changing a line of their workflow. Aqua's own remediation advice is to pin by
SHA. The version stays in a trailing comment for humans and for Dependabot.
This is the most concrete supply-chain argument the project has: the scanner
meant to protect us was itself the vector.

- [x] **6.** Trivy scan with a severity threshold that **fails** the job.
      Decide the threshold and whether unfixed vulnerabilities count — a scan
      that never fails proves nothing
- [x] **7.** Cosign signature, keyless via GitHub's OIDC token: no private key
      to store, the signature is tied to the workflow identity

**Task 6 done (19 Oct 2026), and it blocked - which is the point.**

Build order is now build locally -> scan -> push, so a vulnerable image is
never published. Two Trivy steps: the first always succeeds and writes the full
report, the second is the gate. One step cannot do both, because a gate that
fails stops the job before any report is written. The report is archived with
`if: always()`.

Gate: `HIGH,CRITICAL` with `--ignore-unfixed`. First run: **40 findings, all
HIGH, zero CRITICAL, every one with status `fixed`** - so `--ignore-unfixed`
filtered nothing and the gate was right to block. The Debian base layer
(`gcr.io/distroless/static`, 6 packages) scored **zero**: the argument for
distroless images, measured rather than quoted.

Remediation, measured in two steps:

| | findings |
|---|---|
| initial | **40** |
| after builder `golang:1.26.2` -> `1.26.9` | **21** |
| after raising the four modules | *pending rescan* |

The 19-finding drop isolates the `stdlib` share exactly. Modules raised by
`bump-go-deps.yml`: x/crypto 0.48.0 -> 0.58.0, x/net 0.51.0 -> 0.61.0, x/text
0.34.0 -> 0.43.0, grpc 1.79.3 -> 1.84.0 - all above the required fixes, and
`go build ./...` passed, so the grpc jump broke no API.

**Gotcha found:** a push made with the default `GITHUB_TOKEN` does **not**
trigger any workflow, by GitHub's anti-loop design. The bot's commit therefore
did not rescan on its own. Harmless for task 10, because ArgoCD watches Git
directly rather than workflows, but it would matter for any workflow meant to
react to the bump.

**Task 7 done (19 Oct 2026).** Cosign keyless, through GitHub's OIDC token:
`id-token: write`, Fulcio issues a ~10-minute certificate, and the signature
plus certificate land in the public Rekor transparency log. **No private key to
store, rotate or leak** - what is proved is an identity, "this workflow in this
repository built these bytes", rather than "whoever holds the key signed
something". For a project whose Phase 4 is about secret management, not
creating a signing key to manage is the stronger position.

The signature is made over the **digest**, never the tag - a tag is a movable
pointer, the same reason every action here is pinned by SHA and the same reason
ADR-002 makes image tags immutable.

The run then verifies its own signature with `--certificate-identity-regexp`
and `--certificate-oidc-issuer`. Not circular: a signature being present and a
signature being bound to this repository's identity are different claims, and
only the second is worth anything. Those two flags are exactly what a Phase 4
admission policy will check before admitting a pod, so the step is that policy
rehearsed where it is cheap to get wrong.

- [x] **8.** Verify the chain by hand: image on DockerHub, `cosign verify`
      passes, Trivy report archived as a workflow artifact


**Task 8 done (19 Oct 2026) - the chain is verified end to end.**

`iliasroo/frontend:sha-931b803`, digest `sha256:6f121e03...`, Trivy **0
findings**, signature verified against this repository's workflow identity,
Trivy report archived as a run artifact.

Reproducibility, observed rather than claimed: `sha-af4e9d7` and `sha-931b803`
are **the same digest**. Different commits, identical service source, identical
bytes out.

#### Where cosign v3 actually stores a signature

This cost a debugging round and is worth recording.

`cosign sign` reported success, `cosign verify` answered **`no signatures
found`**, and no `.sig` tag appeared on Docker Hub. Three cosign-native probes
settled it:

- `cosign version` -> **v3.0.6**
- `cosign triangulate` -> points at the **legacy** location
  `...:sha256-<digest>.sig`, which does not exist
- `cosign tree` -> the signature is there, **attached as an OCI 1.1 referrer**

cosign v3 no longer writes the `sha256-<digest>.sig` tag. Looking for one on
Docker Hub is a dead end, and its absence is not evidence of a missing
signature.

**But that was not the failure.** The next run found **two** signatures on the
same digest - the earlier run's and its own. The first verify had run seconds
after signing, before Docker Hub's referrers index caught up. An
**eventual-consistency race**, not an incompatibility.

Handled with a retry loop (6 attempts, 10s apart) rather than by weakening the
check: verify stays fatal, because an unverifiable signature makes signing
theatre. A fresh digest will hit that window again, so the fix must wait for
the index rather than assume it away.

**A hypothesis that was half right, recorded as such.** The prediction was
"cosign v3 writes an OCI referrer instead of the .sig tag, and Docker Hub's
referrer support is incomplete, so the signature lands where verify cannot look
for it". The mechanism was right; the conclusion was wrong - Docker Hub stores
referrers fine and verify finds them. The diagnostic step existed precisely
because the hypothesis was not trusted, which is what kept a wrong conclusion
out of the fix.

**Also fixed:** the job summary printed "Signature: verified" unconditionally
while the verify step was failing two steps above it. A summary that asserts
what it has not checked is worse than no summary. It now runs only after a
successful verification, which is what makes the line true.

### CI — generalise
- [x] **9.** Matrix over the 11 services with `dorny/paths-filter`, so an
      unchanged service is not rebuilt. Exclude `shoppingassistantservice`
- [x] **10.** Tag-bump workflow per ADR-004, writing into the overlay's
      `images:` block


**Tasks 9 and 10 done (22 October 2026), and the open defect of task 9 is
fixed.**

The path filter was comparing against the DEFAULT BRANCH, not the previous
push. On a feature branch that means comparing against `main`, so everything
the branch had accumulated counted as changed -- and since `main` does not yet
contain `build-push.yml`, which every filter lists, all eleven filters matched.
Measured: `diff(main, 8292f0a)` touches ten service directories plus the
workflow file, `diff(previous push, 8292f0a)` touches four. Fixed by passing
`github.event.before` as the base, with a deliberate fallback to rebuilding
everything when no usable base exists. Proven: a later run built **one**
service, another built **four**.

Task 10 is one `bump` job, not eleven. Each build job uploads a marker
artifact for the service it actually published and verified; `bump` collects
them and produces a single commit. A service blocked by the gate leaves no
marker, so its tag is not moved and the overlay keeps Google's image -- which
is what makes the service-by-service rollout possible.

`kustomize edit set image` was chosen over `sed` after checking what it does
to the file: it re-serialises everything and drops fields left at their
default (`includeSelectors: false` disappears) but keeps comments, and
`kustomize build` is byte-identical before and after.

**Integration phase complete: 409 blocking findings at the start, 0 at the
end, eleven services out of eleven published and signed.**

### CD
- [x] **11.** `kustomize/argocd/` — ArgoCD as a remote base (decision E),
      **pinned to an exact version**, with our patches
- [x] **12.** Install it, reach the UI, change the admin password
- [x] **13.** Three ArgoCD `Application`s per decision F and ADR-003:
      dev/`develop` auto-sync, staging/`release` auto-sync, prod/`main` manual
- [x] **14.** Full pipeline test: push to `src/frontend`, watch the image get
      built, scanned, signed, bumped, and deployed to dev with no manual step
- [x] **15.** Rollback test: `git revert` the bump, confirm ArgoCD rolls back.
      That is the whole point of an immutable tag — prove it

### Ingress (decision G)
- [x] **16.** Remove `--disable traefik` from `control-plane.sh.tftpl`. This
      changes `user_data`, so the instances are replaced on the next `up`
- [x] **17.** Open **port 80 from `admin_cidr`** in the security group. The
      `allow_http_from_internet` variable exists but `envs/dev/main.tf`
      hardcodes it to `false`, and it would open 80 to `0.0.0.0/0` anyway —
      a separate rule scoped to `admin_cidr` is the right fix
- [x] **18.** One `Ingress` per overlay on `<env>.<node-ip>.sslip.io`.
      Traefik's Service is type `LoadBalancer`, which k3s's ServiceLB binds to
      host ports 80/443 on every node — hence task 17
- [ ] **19.** Switch the overlays to `components/non-public-frontend`, which
      deletes `frontend-external`, and drop the NodePort patches. Re-run
      kube-score and checkov: the `Service Type` finding should disappear


**Tasks 11, 16 and 17 done (22 October 2026) -- all three local and free, and
16-17 deliberately done BEFORE bringing the cluster up.**

Task 11: ArgoCD pinned to v3.5.6 as a remote Kustomize base. Two patches, each
closing a gap the default install leaves. Its manifest declares NO cpu at all
in 34,000 lines, and pods without requests are invisible to the scheduler --
they place regardless of node load and appear in no capacity calculation,
which would have invalidated the phase 2 study. Explicit requests total
550m / 1088Mi against ~1500m of headroom, with dex and notifications scaled to
zero (no SSO, no notifications in scope). The server is exposed on NodePort
30090 because the security group opens 30000-32767 to admin_cidr and not 80.

A kustomize trap found there and documented in the patch: the merge key of
`Service.spec.ports` is the pair (port, protocol). Omit `protocol` and the
entry matches nothing and is DROPPED SILENTLY -- the first render applied
`type: NodePort` and lost `nodePort: 30090` without a word. Reproduced in
isolation before being fixed.

Tasks 16-17: `disable_traefik = false` is now passed explicitly from
`envs/dev`, so the decision is visible at the environment level rather than
hidden in a module default, and a separate rule opens port 80 to `admin_cidr`
ALONE. The pre-existing `allow_http_from_internet` was not reused: it opens 80
to 0.0.0.0/0. 443 stays closed until there is a certificate to serve on it.

Both change `user_data`, so the instances are replaced on the next `up`. That
is why these tasks come before the cluster is started and not after.


**Tasks 12 to 15 and 18 done (22 October 2026), on a live cluster.**

ArgoCD v3.5.6 runs with five pods, not seven: dex and notifications are scaled
to zero. Three Applications, dev and staging syncing automatically, prod
`OutOfSync` until synced by hand -- ADR-003 visible on screen.

Task 14, the full chain, measured end to end: a one-line change to the
frontend footer produced a matrix of exactly ONE service, a build, a Trivy
pass, a push, a keyless signature, a verification, a one-line bump commit from
the bot carrying the skip-CI marker, an ArgoCD sync, and a pod restart. No
manual step anywhere between the push and the page changing in the browser.
That bot commit triggered no run, confirming the anti-loop design once more.

Task 15, the rollback: `git revert` of the bump put the frontend back to
sha-b66979a and the footer marker DISAPPEARED. That disappearance is the proof
the whole phase 0 argument rested on -- if tags were mutable, reverting would
restore a name rather than an artefact. Nothing was rebuilt in either
direction; only a pointer in Git moved.

`git revert` rather than ArgoCD's own rollback button, and the reason matters:
with `selfHeal: true` a rollback done in the UI makes the cluster diverge from
Git, and ArgoCD undoes it immediately. The two features contradict each other.
Git as the single source of truth is not a slogan here, it is the only
coherent way to roll back a self-healing Application.

One result worth keeping from task 13: in dev, ten services carried
sha-b66979a while adservice carried sha-a5d9478 -- the run where adservice
could not be signed left no marker, so its tag was never bumped and the
cluster kept running the last image whose signature had been verified. The
chain refused to deploy an unverified artefact on its own.

**Task 19 is deliberately deferred, with a measured reason.** The Ingress
hostnames embed the cluster's public IP through sslip.io, and that IP changes
on every rebuild. Git cannot know the address of a cluster that does not exist
yet, so after each `up` the three Ingress have to be rewritten AND committed
before ArgoCD serves the right host. The normal answers -- a real domain with
DNS, an elastic IP, ExternalDNS -- are all excluded by the project's cost
decisions. The NodePort Services are therefore kept: they stay reachable when
the hostname is stale, and a demonstration cannot depend on a commit being
pushed first. The `Service Type` finding in the security baseline stays open
for that reason, which is a trade-off rather than an oversight.

### Validation and close
- [ ] **20.** Three environments through the Ingress, three hostnames, and the
      Phase 2 NetworkPolicy tests re-run to confirm nothing regressed
- [ ] **21.** Security baseline v2 on the new renders, diffed against
      `docs/phase2/baseline/`
- [ ] **22.** README in `.github/workflows/`, update `CLAUDE.md`, PRs
      feature -> develop -> release -> main with **merge commits**, tag
      `phase3-v1.0.0`

---

Tasks 1-10 and 16-17 are local and free. The cluster is needed from task 12.
Cost while it runs: ~€0.25/h. `.\cluster.ps1 down` after each session.
