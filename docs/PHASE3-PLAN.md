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
- [ ] **5.** `.github/workflows/build-push.yml` on `frontend` only: build,
      tag `sha-<7>` per ADR-002, push to DockerHub. Triggered on pushes to
      `develop` touching `src/frontend/**`
- [ ] **6.** Trivy scan with a severity threshold that **fails** the job.
      Decide the threshold and whether unfixed vulnerabilities count — a scan
      that never fails proves nothing
- [ ] **7.** Cosign signature, keyless via GitHub's OIDC token: no private key
      to store, the signature is tied to the workflow identity
- [ ] **8.** Verify the chain by hand: image on DockerHub, `cosign verify`
      passes, Trivy report archived as a workflow artifact

### CI — generalise
- [ ] **9.** Matrix over the 11 services with `dorny/paths-filter`, so an
      unchanged service is not rebuilt. Exclude `shoppingassistantservice`
- [ ] **10.** Tag-bump workflow per ADR-004, writing into the overlay's
      `images:` block

### CD
- [ ] **11.** `kustomize/argocd/` — ArgoCD as a remote base (decision E),
      **pinned to an exact version**, with our patches
- [ ] **12.** Install it, reach the UI, change the admin password
- [ ] **13.** Three ArgoCD `Application`s per decision F and ADR-003:
      dev/`develop` auto-sync, staging/`release` auto-sync, prod/`main` manual
- [ ] **14.** Full pipeline test: push to `src/frontend`, watch the image get
      built, scanned, signed, bumped, and deployed to dev with no manual step
- [ ] **15.** Rollback test: `git revert` the bump, confirm ArgoCD rolls back.
      That is the whole point of an immutable tag — prove it

### Ingress (decision G)
- [ ] **16.** Remove `--disable traefik` from `control-plane.sh.tftpl`. This
      changes `user_data`, so the instances are replaced on the next `up`
- [ ] **17.** Open **port 80 from `admin_cidr`** in the security group. The
      `allow_http_from_internet` variable exists but `envs/dev/main.tf`
      hardcodes it to `false`, and it would open 80 to `0.0.0.0/0` anyway —
      a separate rule scoped to `admin_cidr` is the right fix
- [ ] **18.** One `Ingress` per overlay on `<env>.<node-ip>.sslip.io`.
      Traefik's Service is type `LoadBalancer`, which k3s's ServiceLB binds to
      host ports 80/443 on every node — hence task 17
- [ ] **19.** Switch the overlays to `components/non-public-frontend`, which
      deletes `frontend-external`, and drop the NodePort patches. Re-run
      kube-score and checkov: the `Service Type` finding should disappear

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
