# CIS Kubernetes Benchmark — extrait des contrôles de la section 5 (Policies)

> ⚠️ **Avertissement important**
> Ce fichier est un **résumé rédigé à des fins de démonstration**, pas le
> document officiel. La numérotation des contrôles **varie selon la version**
> du benchmark (v1.7, v1.8, v1.9...) et selon la distribution (EKS, GKE, AKS
> ont leurs propres benchmarks avec une numérotation différente).
>
> **En usage réel, remplacer ce fichier par le PDF officiel** de la version
> exactement ciblée, téléchargé depuis cisecurity.org, et adapter
> `ingest.py` pour parser le PDF. C'est précisément l'intérêt du RAG :
> la source de vérité est un document externe remplaçable, pas la mémoire
> du modèle.

---

## CIS 5.1.1 — N'utiliser cluster-admin que là où c'est indispensable

Le rôle `cluster-admin` accorde des permissions illimitées sur l'ensemble du
cluster. Une liaison de ce rôle à un ServiceAccount utilisé par un pod
applicatif signifie qu'une compromission de ce pod donne un contrôle total du
cluster : lecture de tous les secrets, création de pods sur tous les nœuds,
modification des politiques d'admission.

**Vérification :** lister les ClusterRoleBindings dont le `roleRef.name` vaut
`cluster-admin` et dont les sujets sont des ServiceAccounts applicatifs.

**Correctif :** créer un Role ou ClusterRole dédié n'accordant que les verbes
et ressources strictement nécessaires, puis remplacer la liaison.

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]   # jamais de wildcard "*"
```

---

## CIS 5.1.3 — Éviter les wildcards dans les Roles et ClusterRoles

Un `verbs: ["*"]` ou `resources: ["*"]` accorde implicitement des droits sur
des ressources qui n'existent pas encore : toute CRD installée plus tard sera
automatiquement couverte. C'est une escalade de privilèges différée dans le
temps, invisible lors de la revue initiale.

**Correctif :** énumérer explicitement les verbes et les ressources.

---

## CIS 5.1.6 — Ne monter les tokens de ServiceAccount que si nécessaire

Par défaut, Kubernetes monte un token d'API dans chaque pod, à
`/var/run/secrets/kubernetes.io/serviceaccount/token`. Un pod qui n'appelle
jamais l'API Kubernetes — c'est-à-dire la grande majorité des applications —
n'a aucun besoin de ce token. Sa présence offre à un attaquant ayant obtenu
l'exécution de code dans le conteneur une identité authentifiée auprès de
l'apiserver.

**Correctif :**

```yaml
spec:
  automountServiceAccountToken: false
```

À poser sur le ServiceAccount ou sur le pod.

---

## CIS 5.2.2 — Interdire l'admission de conteneurs privilégiés

Un conteneur en `privileged: true` désactive l'essentiel de l'isolation :
il obtient toutes les capabilities Linux, un accès aux périphériques du nœud,
et peut monter le système de fichiers de l'hôte. L'évasion de conteneur vers
le nœud est directe et documentée.

**Vérification :** `securityContext.privileged == true` sur un conteneur.

**Correctif :**

```yaml
securityContext:
  privileged: false
  capabilities:
    drop: ["ALL"]
```

Faire appliquer par les Pod Security Standards (niveau `restricted`) ou par
une politique OPA Gatekeeper / Kyverno en admission.

---

## CIS 5.2.3 — Interdire le partage du namespace PID de l'hôte

`hostPID: true` permet au conteneur de voir et de signaler tous les processus
du nœud. Combiné à une capability comme `SYS_PTRACE`, cela autorise
l'inspection mémoire d'autres processus, y compris des processus système,
et donc le vol de secrets en clair.

**Correctif :** `hostPID: false` (valeur par défaut).

---

## CIS 5.2.5 — Interdire le partage du namespace réseau de l'hôte

`hostNetwork: true` place le pod directement sur la pile réseau du nœud.
Conséquences : les NetworkPolicies ne s'appliquent plus à ce pod, il peut
écouter sur les ports du nœud, et il accède aux services locaux du nœud,
dont l'endpoint de métadonnées du cloud provider (169.254.169.254) — qui peut
livrer des credentials IAM.

**Correctif :** `hostNetwork: false` et exposition via un Service.

---

## CIS 5.2.6 — Interdire allowPrivilegeEscalation

`allowPrivilegeEscalation: true` autorise un processus à acquérir plus de
privilèges que son parent, typiquement via des binaires setuid. C'est le
mécanisme qui transforme une exécution de code en tant qu'utilisateur non
privilégié en exécution root à l'intérieur du conteneur.

Attention : la valeur par défaut de Kubernetes est **permissive** quand le
champ n'est pas défini. Une absence de configuration équivaut donc à
`true` dans la plupart des cas.

**Correctif :**

```yaml
securityContext:
  allowPrivilegeEscalation: false
```

---

## CIS 5.2.7 — Interdire l'admission de conteneurs root

Un conteneur tournant en `runAsUser: 0` exécute ses processus en root. En
cas d'évasion, et particulièrement si des capabilities ou un hostPath sont
présents, ce root est le root du nœud.

**Correctif :**

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  readOnlyRootFilesystem: true
```

`runAsNonRoot: true` fait échouer le démarrage du pod si l'image tente de
tourner en root : c'est une garantie appliquée par le kubelet, pas une
convention.

---

## CIS 5.2.12 — Interdire l'admission de volumes hostPath

Un volume `hostPath` monte un chemin du système de fichiers du nœud dans le
conteneur. Monter `/` ou `/var/run/docker.sock` équivaut à donner le contrôle
du nœud : lecture des secrets des autres pods, modification des binaires
système, création de conteneurs privilégiés via le socket runtime.

**Vérification :** présence de `spec.volumes[].hostPath`.

**Correctif :** remplacer par un `emptyDir`, une `PersistentVolumeClaim`, ou
un ConfigMap selon le besoin réel.

---

## CIS 5.3.2 — Définir des NetworkPolicies dans tous les namespaces

Sans NetworkPolicy, le modèle réseau de Kubernetes est **entièrement ouvert** :
tout pod peut joindre tout autre pod du cluster, sur tout port. Un pod
compromis peut donc scanner et attaquer latéralement l'ensemble des services,
y compris les bases de données d'autres namespaces.

**Correctif — commencer par un deny-all en ingress :**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}        # {} vide = tous les pods du namespace
  policyTypes: ["Ingress"]
```

Puis ajouter les autorisations explicites service par service.
Prévoir également une politique d'egress, sans oublier d'autoriser le DNS
(port 53 vers kube-dns) sous peine de tout casser.

---

## CIS 5.7.3 — Appliquer un securityContext aux pods et conteneurs

L'absence de `securityContext` signifie que tous les défauts permissifs de
Kubernetes s'appliquent. Le contexte de sécurité doit être explicite, pas
implicite : un audit ne peut pas distinguer « choisi » de « oublié » si le
champ est absent.

**Référence minimale recommandée :**

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

---

## CIS 5.7.4 — Ne pas utiliser le namespace default

Le namespace `default` ne peut pas être supprimé, reçoit fréquemment des
déploiements accidentels, et rend l'application de politiques par namespace
inopérante. Il complique aussi l'attribution des ressources et la revue des
droits.

**Correctif :** créer des namespaces explicites par application et par
environnement, et y appliquer les Pod Security Standards.
