# ADR internes — Plateforme Google Microservices

> Ces décisions d'architecture sont **propres à la plateforme** et n'existent
> dans aucun benchmark public. C'est exactement ce que le modèle ne peut pas
> deviner, et c'est la vraie valeur ajoutée du RAG : les recommandations de
> l'agent citent nos règles internes, pas seulement des standards génériques.
>
> À adapter au contenu réel de `docs/adr/` du dépôt.

---

## ADR-002 — Stratégie de versioning des images Docker

**Décision :** toute image déployée est taguée avec le SHA Git court du commit
qui l'a produite.

```
ilias-ait-taamout/<service>:sha-<git-sha-7>     # tag immuable produit par la CI
ilias-ait-taamout/<service>:v<major>.<minor>.<patch>   # release manuelle
```

**Règles opposables :**

- Le tag `latest` est **interdit en staging et en production**. Un pod dont
  l'image se termine par `:latest` constitue une violation de cette ADR :
  il rend le rollback impossible et le déploiement non reproductible.
- Les tags sont immuables : un tag publié n'est jamais réécrit.
- Rétention minimale de 10 versions par image dans le registre.
- ArgoCD déploie toujours via un tag SHA explicite, jamais un tag flottant.

**Constat d'audit associé :** un conteneur utilisant `:latest` ou aucun tag
doit être remonté en P2, avec pour correctif l'épinglage sur un tag SHA.

---

## ADR-003 — GitOps avec ArgoCD

**Décision :** Git est l'unique source de vérité. Toute modification de l'état
du cluster passe par un commit.

| Environnement | Synchronisation | Approbation |
|---|---|---|
| dev | automatique | aucune |
| staging | automatique | revue de PR requise |
| prod | manuelle | approbation humaine obligatoire |

**Conséquence pour l'audit :** une ressource présente dans le cluster mais
absente du dépôt Git est une **dérive de configuration**. Elle doit être
signalée, car elle sera écrasée au prochain sync et n'a fait l'objet
d'aucune revue.

---

## ADR-004 — Posture de sécurité des workloads applicatifs

**Décision :** tout workload applicatif déployé sur la plateforme respecte le
socle suivant, sans exception non documentée.

1. `runAsNonRoot: true` et un `runAsUser` explicite supérieur à 10000.
2. `allowPrivilegeEscalation: false` et `capabilities.drop: ["ALL"]`.
3. `readOnlyRootFilesystem: true`, les écritures passant par un `emptyDir`.
4. `automountServiceAccountToken: false`, sauf pour les composants qui
   appellent réellement l'API Kubernetes.
5. Aucun volume `hostPath`, aucun `hostNetwork`, aucun `hostPID`.
6. Chaque namespace applicatif possède au minimum une NetworkPolicy
   `default-deny-ingress`.
7. Requests et limits CPU/mémoire définies sur tous les conteneurs.

**Dérogation :** toute exception doit faire l'objet d'une ADR dédiée précisant
la justification technique, le périmètre et la date de réexamen. Une exception
non documentée est traitée comme une non-conformité de priorité P1.

---

## ADR-005 — Agents IA et principe de moindre privilège

**Décision :** aucun composant piloté par un modèle de langage ne dispose de
droits en écriture sur l'infrastructure.

**Règles :**

1. Le serveur MCP d'audit s'authentifie via un ServiceAccount dédié
   (`mcp-k8s-auditor`) lié à un ClusterRole limité aux verbes `get`, `list`
   et `watch`. La garantie est appliquée par le plan de contrôle Kubernetes,
   et ne dépend donc pas du code applicatif ni du contenu du prompt.
2. Le modèle ne détient jamais de credential : ni kubeconfig, ni token, ni
   clé cloud. Il ne peut appeler que les outils exposés par le serveur MCP.
3. La décision de bloquer un déploiement reste prise par un contrôle
   déterministe (Trivy, Checkov, OPA Gatekeeper). La sortie d'un LLM est
   **consultative** et ne constitue jamais une porte de sécurité.
4. Toute sortie du modèle citant un identifiant de contrôle est vérifiée en
   post-traitement : une citation absente du contexte récupéré est rejetée.
5. Les données provenant du cluster (noms, labels, annotations) sont traitées
   comme des données non fiables et jamais comme des instructions.

**Justification :** une garantie de sécurité exprimée en langage naturel dans
un prompt n'est pas une garantie. Seule une contrainte technique — RBAC,
NetworkPolicy, admission controller — en est une.
