# ADR-004 — Who commits the image tag bump, and to which branch

**Status:** accepted · **Date:** 19 October 2026 · **Phase:** 3

## Context

ADR-002 fixes the image convention: every CI build produces
`<user>/<service>:sha-<git-sha-7>`, immutable, with `latest` forbidden in
staging and prod. ADR-003 makes Git the single source of truth, with ArgoCD
syncing automatically in dev, automatically after a PR in staging, and
manually in prod.

Decision F (Phase 3) maps one Git branch to each environment: `develop` -> dev,
`release` -> staging, `main` -> prod.

Put together, these create a concrete problem. CI builds on a push to
`develop`, then has to write the new tag into
`kustomize/overlays/dev/kustomization.yaml` — **on `develop`**. But `CLAUDE.md`
states: *never push directly to `main`, `develop` or `release`*.

## Options considered

**1. CI pushes the bump straight to the environment branch.** The workflow
commits the one-line change to `develop` with `[skip ci]` in the message so it
does not retrigger itself.

**2. CI opens a pull request for every bump, including dev.** Fully consistent
with the no-direct-push rule.

**3. ArgoCD Image Updater writes to Git itself.** A component in the cluster
watches the registry and commits the new tag.

## Decision

**Option 1 for `develop`, with the exception written down here.**
`release` and `main` keep the pull-request route.

## Rationale

Option 2 contradicts ADR-003. "dev: automatic sync, no approval" cannot
coexist with a pull request to merge for every dev deployment — that is a
manual gate by another name, and it would make the phase demonstrate the
opposite of what it claims.

The no-direct-push rule exists to stop a **human** bypassing review. A bot
incrementing the tag of an image it has just built, scanned with Trivy and
signed with Cosign is not that act: the content was already reviewed when the
source commit was merged, and the bump is a derived fact, not a new decision.
Recording the exception explicitly is what keeps the rule meaningful rather
than quietly broken.

Option 3 moves the problem into the cluster instead of solving it — the commit
still has to land on a protected branch — and adds a component to operate for
no gain at this scale.

**`main` needs no mechanism at all.** Its ruleset requires a pull request, so
CI *cannot* push to it even if a workflow tried. ADR-003's "manual approval for
prod" is therefore enforced by branch protection already in place. This is the
main argument for decision F over "everything on `main`, one folder per
environment": the protection boundary and the environment boundary are the
same line.

## Consequences

- The `develop` branch protection must allow a push from the workflow
  identity. If a ruleset blocks it, the bypass is granted to that actor
  explicitly — not by loosening the rule for everyone.
- **`[skip ci]` is mandatory** in the bump commit message. Without it the
  bump triggers a build, which produces a bump, which triggers a build. Verify
  this on the very first run rather than trusting it.
- The bump commit must be attributed to a bot identity, not to Ilias, so
  `git log --author` stays meaningful and the generated commits are
  distinguishable from authored ones.
- The workflow needs `contents: write`. Keep its permissions block minimal and
  explicit rather than relying on the repository default.
- Promotion dev -> staging -> prod stays an ordinary GitFlow merge: the tag
  travels with the overlay file. No separate promotion tooling.
- Only the overlays' `images:` transformer is ever edited. `base/` is never
  touched (decision C), so a service CI has not built yet keeps Google's
  image and the cluster stays deployable throughout the rollout.
