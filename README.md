# Google Microservices Platform

> A hands-on **DevSecOps platform** built around Google's *Online Boutique* microservices demo, deployed on **AWS EKS** with a full GitOps pipeline, integrated security, observability, and two AI agents.

This repository is a personal engineering project: take a realistic 11-service application and stand up the **entire production-grade platform around it** — infrastructure as code, CI/CD, supply-chain security, runtime security, monitoring, and AI-assisted operations — the way a real Platform / DevSecOps team would.

The application code is a clone of [Google's `microservices-demo`](https://github.com/GoogleCloudPlatform/microservices-demo). Everything around it (infrastructure, pipelines, security, observability, AI agents) is built from scratch and documented here.

---

## Table of Contents

- [Why this project](#why-this-project)
- [Architecture](#architecture)
- [Tech stack](#tech-stack)
- [Repository structure](#repository-structure)
- [Environments](#environments)
- [Image versioning](#image-versioning-adr-002)
- [Branching strategy](#branching-strategy)
- [Roadmap](#roadmap)
- [Getting started](#getting-started)
- [Decisions & documentation](#decisions--documentation)

---

## Why this project

The goal is not to ship a product — it's to **learn and demonstrate the full DevSecOps lifecycle end to end** on a non-trivial, multi-service application:

- Provision a managed Kubernetes cluster from zero with Terraform
- Deploy the same app across **dev / staging / prod** without duplicating manifests
- Build a GitOps pipeline where a single commit flows from build → scan → sign → deploy
- Bake security into every layer (secrets, IaC, manifests, admission control, runtime)
- Get full visibility with metrics, logs, and traces
- Add two autonomous AI agents on top of the platform

The methodology is the **Walking Skeleton**: get a minimal end-to-end system running first, then enrich it phase by phase — rather than building each layer in isolation.

---

## Architecture

The application is Google's *Online Boutique*: an 11-service e-commerce demo where each service is independently deployable and communicates over gRPC.

```
                         Users
                           │
                     ┌─────▼─────┐
                     │  frontend │
                     └─────┬─────┘
        ┌──────────┬───────┼────────┬──────────────┐
        ▼          ▼       ▼        ▼              ▼
  productcatalog  cart  currency  checkout   recommendation
                   │                 │
                 (redis)   ┌─────────┼──────────┬──────────┐
                           ▼         ▼          ▼          ▼
                       payment   shipping     email     adservice
```

`loadgenerator` continuously drives traffic to simulate real usage.

---

## Tech stack

| Domain | Tooling |
|---|---|
| Cloud | **AWS (EKS)** |
| Infrastructure as Code | Terraform |
| Kubernetes manifests | **Kustomize** (base + overlays per environment) |
| CI | GitHub Actions |
| CD / GitOps | ArgoCD |
| Image registry | DockerHub |
| Vulnerability scanning | Trivy |
| Image signing | Cosign |
| Secret scanning (Git) | Gitleaks |
| IaC scanning | Checkov |
| K8s manifest linting | Kube-score |
| Secrets management | External Secrets + AWS Secrets Manager |
| Admission control | OPA Gatekeeper |
| Runtime security | Falco |
| Metrics | Prometheus + Grafana |
| Logs | Loki + Promtail |
| Traces | Tempo |
| AI agents | Python services calling an LLM |

---

## Repository structure

The repo currently holds the upstream application code and manifests. The DevSecOps layers below are added as each phase is completed.

```
.
├── src/                    # The 11 microservices (application source)
├── kustomize/              # Kustomize base + reusable components
├── kubernetes-manifests/   # Plain manifests (upstream reference)
├── helm-chart/             # Upstream Helm chart (reference only — we use Kustomize)
├── terraform/              # Infrastructure as Code (EKS, VPC, IAM)
├── docs/                   # Architecture Decision Records, runbooks
└── .github/                # CI/CD workflows, issue/PR templates
```

> **Note:** This project uses **Kustomize** (not Helm) for environment management — `helm-chart/` is kept only as upstream reference. Likewise, several `kustomize/components/` (e.g. `alloydb`, `spanner`, `memorystore`, `google-cloud-operations`, `shopping-assistant`) are **GCP-specific and intentionally not enabled** on this AWS deployment.

---

## Environments

Three environments are maintained from the start, each as a Kustomize overlay:

| Environment | Sync (ArgoCD) | Approval |
|---|---|---|
| `dev` | Automatic | None |
| `staging` | Automatic | PR review required |
| `prod` | Manual | Human approval required |

---

## Image versioning (ADR-002)

Images use **immutable, traceable tags** so any version can be reproduced and rolled back precisely:

```
ilias-ait-taamout/<service>:sha-<git-sha-7-chars>     # immutable CI tag (every build)
ilias-ait-taamout/<service>:v<major>.<minor>.<patch>  # manual release tag
```

**Rules**
- `latest` is **banned** in staging and prod
- Tags are **immutable** (never overwritten)
- Registry keeps **≥ 10 versions** per image
- ArgoCD always deploys via an explicit SHA tag — never a floating tag

---

## Branching strategy

Trunk-based, with protected `main`:

```
main          ← Production — protected, merge via PR only
└── dev       ← Continuous integration
    ├── feat/xxx   ← Features (short-lived, < 2 days)
    ├── fix/xxx    ← Bug fixes
    └── chore/xxx  ← Maintenance
```

---

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| **0** | Git foundations (structure, ADRs, runbooks, templates) | ✅ Done |
| **1** | Infrastructure — Terraform → AWS EKS | ⬜ |
| **2** | App deployed — Kustomize across dev/staging/prod | ⬜ |
| **3** | CI/CD + GitOps — GitHub Actions + ArgoCD + DockerHub | ⬜ |
| **4** | Security — Gitleaks, Checkov, Kube-score, External Secrets, OPA, NetworkPolicies, Falco | ⬜ |
| **5** | Observability — Prometheus, Grafana, Loki, Tempo, SLO alerts | ⬜ |
| **6** | AI agents — vulnerability analyzer + NL-to-Terraform provisioner | ⬜ |
| **7** | Finalization — architecture docs, runbooks, write-up, demo | ⬜ |

---

## Getting started

> ⚠️ Full deployment instructions are added as Phases 1–3 land. For now, this covers running the app locally against an existing cluster.

**Prerequisites**
- AWS CLI, `kubectl`, Terraform, and Kustomize installed and configured
- An EKS cluster (provisioned in Phase 1)

**Deploy a single environment with Kustomize**
```bash
# Render and apply the dev overlay
kubectl apply -k kustomize/overlays/dev

# Check everything is running
kubectl get pods
```

**Access the frontend**
```bash
kubectl get svc frontend-external   # grab the LoadBalancer hostname
```

---

## Decisions & documentation

All significant decisions are recorded as **Architecture Decision Records** under [`docs/adr/`](docs/adr/):

- **ADR-001** — Cloud provider (GCP → **AWS / EKS**)
- **ADR-002** — Docker image versioning strategy
- **ADR-003** — GitOps with ArgoCD

Operational procedures (rollback, incident response) live in [`docs/runbooks/`](docs/runbooks/).

---

## License

Application code derives from Google's *Online Boutique*, distributed under the Apache 2.0 License. Platform code and documentation in this repository are authored as part of this project.
