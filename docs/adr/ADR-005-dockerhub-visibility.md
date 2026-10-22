# ADR-005 — DockerHub repository visibility

**Status:** accepted · **Date:** 19 October 2026 · **Phase:** 3

## Context

ADR-002 chose DockerHub as the registry. Phase 3 needs one repository per
deployed service: **11** of them (`shoppingassistantservice` has a Dockerfile
but is not in `kustomize/base/`, so it is not built).

The original requirements mentioned a *private* registry (Harbor or GHCR were
the examples given).

## Decision

**Public repositories.**

## Rationale

Docker Personal, the free plan, allows **1 private repository**. Eleven
private repositories would require a paid plan. The constraint decides this,
not a preference — and it is worth stating that way rather than presenting
public as a design choice.

Public also removes an `imagePullSecret` per namespace, which would otherwise
be the first real secret in the cluster and belongs more naturally to Phase 4
(External Secrets + AWS Secrets Manager) than to Phase 3.

## Consequences

- The images are world-readable. Nothing confidential may enter them: no
  config bundled at build time, no `.env`, no cloud credentials. Gitleaks in
  Phase 4 covers the source side; the Dockerfiles must be read with the same
  eye.
- Pull rate limits apply: **200 pulls / 6 h** authenticated, **100 / 6 h per
  IPv4** anonymous. Each node pulls ~13 DockerHub images per cluster rebuild
  (redis, busybox and our 11), so the anonymous limit is not a practical
  constraint. Google's `v0.10.5` images come from
  `us-central1-docker.pkg.dev` and do not count against it.
- Tag immutability and Cosign signatures matter more, not less, on a public
  registry: anyone can pull, so the deployment must be able to prove *which*
  artefact it is running and that CI produced it.
- Revisit if the project ever needs a private registry: GHCR offers unlimited
  private repositories on the free tier and would be the natural move, at the
  cost of changing ADR-002.
