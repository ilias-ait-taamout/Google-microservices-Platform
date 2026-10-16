# Phase 2 — preparation reference (tasks 2-4)

Recorded 13 Oct 2026. Task 8 diffs the overlay renders against this; task 12
uses the numbers below.

## Tooling (task 2)

| Tool | Version | Source |
|---|---|---|
| kubectl | v1.36.1 | bundled with Docker Desktop (`C:\Program Files\Docker\Docker\resources\bin`) |
| kustomize (embedded in kubectl) | **v5.8.1** | — |
| kustomize (standalone) | not installed | not needed |

`components:` exists since kustomize v3.7, so v5.8.1 covers tasks 10-11.
Always use `kubectl kustomize` / `kubectl apply -k`; there is no standalone
binary to drift out of sync with.

## Reference render of `kustomize/base` (task 2)

Full output: [`base-render.yaml`](base-render.yaml), regenerate with
`kubectl kustomize kustomize/base > docs/phase2/base-render.yaml`.

35 resources, **no `namespace` set on any of them**:

- 12 Deployments: adservice, cartservice, checkoutservice, currencyservice,
  emailservice, frontend, loadgenerator, paymentservice, productcatalogservice,
  recommendationservice, redis-cart, shippingservice
- 12 Services: the same names minus loadgenerator, plus `frontend-external`
- 11 ServiceAccounts: one per Deployment except redis-cart

`frontend-external` is **`type: LoadBalancer`**, port 80 → targetPort 8080.

### Images

- 11 microservices: `us-central1-docker.pkg.dev/google-samples/microservices-demo/<name>:v0.10.5`
- `redis:alpine` (redis-cart), **unpinned**
- `busybox:latest` (loadgenerator's init container `frontend-check`), **unpinned**,
  and it has **no resources block**

### Requests and limits, 1 replica each

| Deployment | cpu req | mem req | cpu lim | mem lim |
|---|---|---|---|---|
| adservice | 200m | 180Mi | 300m | 300Mi |
| cartservice | 200m | 64Mi | 300m | 128Mi |
| checkoutservice | 100m | 64Mi | 200m | 128Mi |
| currencyservice | 100m | 64Mi | 200m | 128Mi |
| emailservice | 100m | 64Mi | 200m | 128Mi |
| frontend | 100m | 64Mi | 200m | 128Mi |
| loadgenerator | 300m | 256Mi | 500m | 512Mi |
| paymentservice | 100m | 64Mi | 200m | 128Mi |
| productcatalogservice | 100m | 64Mi | 200m | 128Mi |
| recommendationservice | 100m | 220Mi | 200m | 450Mi |
| redis-cart | 70m | 200Mi | 125m | 256Mi |
| shippingservice | 100m | 64Mi | 200m | 128Mi |
| **Total per namespace** | **1570m** | **1368Mi** | | |

Without loadgenerator: 1270m / 1112Mi.

## Security group (task 3)

`infra/terraform/modules/network/main.tf`, resource
`aws_vpc_security_group_ingress_rule.nodeport_from_admin`: tcp 30000-32767
from `var.admin_cidr`. **Confirmed.**

Port 80/443 from `0.0.0.0/0` exists only behind `allow_http_from_internet`,
which `envs/dev/main.tf` hardcodes to `false`. So port 80 is closed, as
decision A/NodePort assumes.

## nodePorts (task 4)

| Namespace | Service | nodePort |
|---|---|---|
| dev | frontend-external | **30080** |
| staging | frontend-external | **30081** |
| prod | frontend-external | **30082** |

A nodePort is opened on every node, cluster-wide, regardless of namespace.
If no port is fixed, Kubernetes picks a random one for each environment:
the collision itself is avoided, but the URL changes on every deploy. Fixing
them gives stable URLs and makes it obvious when two overlays claim the same
port. The base contains no other NodePort, so these three are the only ones.
