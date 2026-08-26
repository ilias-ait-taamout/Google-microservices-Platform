# Agent IA — Auditeur de sécurité Kubernetes

**Phase 6 · Google Microservices Platform** — agent d'analyse de posture de
sécurité au niveau du cluster, combinant **Claude**, un **serveur MCP en
lecture seule** et un **RAG** sur les référentiels CIS et les ADR internes.

---

## Le problème

`kube-bench` et Trivy produisent des dizaines de constats isolés, sans
priorisation contextuelle et sans corrélation. Un conteneur privilégié n'est
pas critique en soi ; un conteneur privilégié, dans un namespace sans
NetworkPolicy, dont le ServiceAccount est lié à `cluster-admin`, est une
compromission totale du cluster.

Cet agent automatise cette corrélation et produit un rapport priorisé où
**chaque recommandation cite son contrôle de référence**.

---

## Architecture

```
                    ┌────────────────────────────┐
   "Audite le       │  agent/main.py             │
    namespace   ───▶│  boucle de tool-calling    │
    demo-audit"     └──┬──────────────────────┬──┘
                       │ HTTPS                │ JSON-RPC (stdio)
                       ▼                      ▼
              ┌────────────────┐   ┌────────────────────────┐
              │  API Anthropic │   │  mcp_server/server.py  │
              │  (raisonne,    │   │  6 outils LECTURE SEULE│
              │   décide quel  │   │  ├─ list_pods          │
              │   outil)       │   │  ├─ list_network_pol.  │
              └────────────────┘   │  ├─ get_rbac_bindings  │
                                   │  ├─ get_service_accts  │
                                   │  ├─ list_namespaces    │
                                   │  └─ search_knowledge ──┼──▶ ChromaDB
                                   └───────────┬────────────┘     (RAG)
                                               │ ServiceAccount
                                               │ get/list uniquement
                                               ▼
                                        ┌─────────────┐
                                        │ Cluster K8s │
                                        └─────────────┘
```

**Claude n'a aucun accès réseau au serveur MCP.** Il émet une intention
d'appel sous forme de texte ; c'est l'agent qui décide de l'exécuter. Le point
de contrôle est dans le code, pas dans le modèle.

---

## Décisions d'architecture

| Décision | Justification |
|---|---|
| **Lecture seule par conception** | Un agent capable de modifier le cluster exigerait une chaîne complète d'approbation, d'audit et de rollback. Livrer sûr et utile plutôt qu'ambitieux et dangereux. |
| **Le déterministe décide, le LLM explique** | Trivy, Checkov et OPA restent les portes de sécurité. La sortie du modèle est consultative. Un composant non déterministe n'a pas sa place dans un chemin de décision de sécurité. |
| **Outils MCP à granularité fine** | Un outil générique `run_kubectl_get` exposerait toute l'API Kubernetes. Six outils spécifiques = six contrats explicites. |
| **Projection des champs** | Un pod brut pèse ~3 000 tokens de métadonnées. La projection ramène un audit de ~120 000 à ~15 000 tokens. |
| **RAG plutôt que la mémoire du modèle** | Le modèle invente des numéros de contrôle plausibles mais faux, et n'a jamais vu nos ADR. Le RAG rend les recommandations traçables. |
| **Chunking structurel** | Un découpage à taille fixe coupait les contrôles CIS en plein milieu. On découpe sur les titres de section : les documents normatifs sont déjà structurés par contrôle. |
| **Sortie JSON, pas Markdown** | Validable contre un schéma, testable, réutilisable vers Grafana ou une issue GitHub. Faire mettre en forme par un LLM réintroduit du non-déterminisme inutile. |
| **MCP plutôt que du function-calling direct** | Le serveur ignore qui l'appelle : réutilisable depuis Claude Desktop, la CI ou un autre agent. Et il constitue une frontière de sécurité unique et auditable. |

---

## Installation et test local

### Prérequis
`python 3.11+` · `kind` ou `k3d` · `kubectl` · une clé API Anthropic

### 1. Dépendances

```bash
cd k8s-security-auditor
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

### 2. Clé API

```bash
cp .env.example .env
# éditer .env et remplacer REPLACE_ME_AVEC_TA_CLE_ANTHROPIC
```

La clé se crée sur `console.anthropic.com` → *API Keys*. Prévoir quelques
euros de crédit ; un audit coûte quelques centimes.

### 3. Cluster de démonstration

```bash
kind create cluster --name audit-demo
kubectl apply -f demo/vulnerable-workloads.yaml
kubectl get pods -n demo-audit
```

### 4. Index RAG

```bash
python rag/ingest.py
```

Le premier lancement télécharge le modèle d'embedding ONNX (~80 Mo).

### 5. Vérification

```bash
python test_connexion.py
```

Teste séparément les trois connexions (Anthropic, Kubernetes, RAG) pour ne
pas déboguer trois problèmes à la fois.

### 6. Audit

```bash
python agent/main.py "Audite le namespace demo-audit"
```

La trace part sur `stderr`, le rapport JSON sur `stdout` :

```
[mcp-server] connexion Kubernetes établie en mode : kubeconfig local
[mcp] handshake OK
[mcp] 6 outils découverts : list_namespaces, list_pods, ...
[tour 0] stop_reason=tool_use | tokens in=1842 out=112
  -> list_pods({"namespace": "demo-audit"})
[tour 1] stop_reason=tool_use | tokens in=4103 out=198
  -> get_rbac_bindings({"namespace": "demo-audit"})
  -> list_network_policies({"namespace": "demo-audit"})
...
TERMINÉ en 5 tours | tokens totaux : 24817 in / 2140 out
```

---

## Jeu de test de non-régression

`demo/vulnerable-workloads.yaml` contient des défauts connus à l'avance :

| Ressource | Attendu |
|---|---|
| `pod-privilegie` | CIS 5.2.2 · `privileged: true` |
| `pod-hostpath` | CIS 5.2.12 · hostPath sur `/` |
| `pod-sa-admin` | CIS 5.1.1 · ServiceAccount `cluster-admin` |
| `pod-hostnetwork` | CIS 5.2.5 + 5.2.3 · hostNetwork et hostPID |
| namespace entier | CIS 5.3.2 · aucune NetworkPolicy |
| `nginx:latest` | ADR-002 · tag flottant interdit |
| **`pod-conforme`** | **ne doit PAS être remonté** |

La dernière ligne est la plus importante : elle mesure les **faux positifs**.
Un outil de sécurité qui crie au loup n'est plus lu par personne.

---

## Sécurité

### Ce que le modèle ne peut pas faire

Le serveur MCP s'authentifie via un ServiceAccount lié à un ClusterRole
restreint aux verbes `get` et `list` (`deploy/rbac.yaml`). Les `secrets` sont
délibérément exclus : l'agent n'a aucune raison de lire leur contenu, et le
lui interdire évite qu'une donnée sensible transite vers l'API du modèle.

```bash
kubectl auth can-i list pods   --as=system:serviceaccount:security:mcp-k8s-auditor  # yes
kubectl auth can-i delete pods --as=system:serviceaccount:security:mcp-k8s-auditor  # no
```

> **Nuance assumée :** en développement local, le kubeconfig `kind` est
> cluster-admin. La garantie ne repose alors que sur le fait que les outils
> MCP n'exposent aucun verbe d'écriture — une garantie *applicative*, donc
> faible. La garantie forte n'existe qu'une fois déployé avec le
> ServiceAccount restreint : c'est la différence entre « mon code n'écrit
> pas » et « mon code ne *peut pas* écrire ».

### Injection de prompt

Les noms de pods, labels et annotations proviennent d'utilisateurs. Deux
niveaux de traitement :

1. Le prompt système qualifie explicitement ces données comme non fiables.
2. Surtout : une injection réussie ne donne aucun pouvoir, puisque le RBAC
   est en lecture seule. *La mitigation est le prompt ; la garantie est le RBAC.*

### Hallucination de sources

Le prompt interdit de citer un contrôle absent du contexte récupéré. En
post-traitement, on peut vérifier que chaque identifiant cité figure bien dans
les chunks retournés par le retrieval, et marquer les autres comme non sourcés.

### Gestion de la clé API

| Environnement | Résolution |
|---|---|
| Local | `.env` git-ignoré, Gitleaks en pre-commit |
| CI | `${{ secrets.ANTHROPIC_API_KEY }}` |
| Cluster | External Secrets ← AWS Secrets Manager |

Le code Python ne change jamais : il lit `os.environ`.

---

## État et suite

**Fonctionnel :** serveur MCP 6 outils · boucle de tool-calling · RAG ·
manifests RBAC et de démonstration · jeu de test.

**À venir :** conteneurisation et déploiement en CronJob nocturne ·
notification Slack · transport HTTP/SSE en cluster · résolution de la clé par
External Secrets · export des findings vers le dashboard sécurité Grafana.

---

## Structure

```
k8s-security-auditor/
├── mcp_server/server.py       # serveur MCP — 6 outils lecture seule
├── agent/
│   ├── main.py                # boucle de tool-calling + client MCP
│   └── prompts.py             # prompt système (versionné à part)
├── rag/
│   ├── ingest.py              # indexation ChromaDB
│   └── knowledge/             # CIS Benchmark + ADR internes
├── demo/vulnerable-workloads.yaml
├── deploy/rbac.yaml           # ServiceAccount + ClusterRole + NetworkPolicy
├── test_connexion.py          # test de fumée des 3 connexions
├── requirements.txt
└── .env.example
```
