# Phase 3, tâche 21 — base de référence sécurité v2

Relevée le 22 octobre 2026 sur les trois overlays rendus, après la tâche 19
(suppression des Services NodePort au profit des Ingress Traefik).

À comparer avec [`docs/phase2/baseline/`](../../phase2/baseline/README.md).

**Mêmes outils, mêmes versions qu'en phase 2** — kube-score 1.20.0, checkov
3.3.29 — ce qui est la condition pour que les deux relevés soient comparables.
Changer de version d'outil entre deux mesures aurait rendu tout écart
ininterprétable. Aucun cluster n'est impliqué : les deux outils lisent du YAML
statique, donc le contrôle est reproductible à tout moment et à coût nul.

## Reproduire

```bash
kubectl kustomize kustomize/overlays/<env> > render-<env>.yaml
kube-score score render-<env>.yaml
checkov -f render-<env>.yaml --framework kubernetes --compact --quiet --skip-download
```

## Comparaison v1 → v2

| | dev | staging | prod |
|---|---|---|---|
| kube-score CRITICAL | 62 → **62** | 46 → **46** | 45 → **45** |
| kube-score WARNING | 23 → **22** | 23 → **22** | 22 → **21** |
| checkov échecs | 78 → **78** | 55 → **55** | 55 → **55** |
| checkov réussites | 1024 → **1027** | 956 → **959** | 956 → **959** |
| ressources | 36 → **36** | 46 → **46** | 47 → **47** |

## Tout l'écart est imputé, sans résidu

**kube-score : un seul contrôle change, `Service Type`, −1 par environnement.**
C'est exactement ce que la tâche 19 visait. Le composant
`non-public-frontend` supprime le Service `frontend-external`, et avec lui le
seul Service de type NodePort de chaque rendu. Aucun autre contrôle ne bouge :
le diff par (niveau, intitulé) ne contient que cette ligne.

Le nombre de ressources est inchangé, à 36 / 46 / 47 : un Service en moins, un
Ingress en plus. L'exposition a changé de nature sans que rien d'autre ne soit
touché.

**checkov : la liste des échecs est strictement identique**, et le compteur de
réussites monte de 3 dans chaque environnement.

## Le compteur de réussites monte, et ce n'est toujours pas une preuve

C'est la deuxième fois que ce compteur induit en erreur sur ce projet, et dans
la direction opposée à la première.

En phase 2, la suppression d'une `NetworkPolicy` orpheline avait **fait
baisser** le compteur de réussites de 2 — les contrôles que le ServiceAccount
supprimé satisfaisait — alors que la qualité montait. Ici, il **monte de 3**
pour une raison tout aussi étrangère à la qualité : l'`Ingress` est une
ressource de plus, elle passe trois contrôles, et le total augmente
mécaniquement.

Dans les deux cas, le compteur suit le **nombre de ressources évaluées**, pas
leur qualité. La seule lecture utile reste le nombre d'échecs et leur nature.
C'est le piège classique des tableaux de bord de sécurité, rencontré deux fois
ici avec deux signes opposés.

## Ce qui reste ouvert, et pourquoi

Les constats restants viennent tous de `kustomize/base/`, que la décision C
interdit de modifier. Ils sont inchangés depuis la phase 2, ce qui est
attendu : la phase 3 portait sur la chaîne de production, pas sur le
durcissement des manifestes.

| Constat | Traitement prévu |
|---|---|
| pas de `runAsUser` / `runAsGroup` > 10000 (11×) | OPA Gatekeeper, phase 4 |
| pas de `seccompProfile` (11×) | OPA Gatekeeper, phase 4 |
| jeton de `ServiceAccount` monté partout (11×) | `automountServiceAccountToken: false` par admission |
| `imagePullPolicy` ≠ `Always` | sans objet dès que les images sont déployées par digest |
| images par tag et non par digest | la chaîne CI/CD produit des tags immuables ; le passage au digest reste à faire |
| pas de requête ni limite d'`ephemeral-storage` | politique d'admission |
| sondes de vivacité et de disponibilité identiques (`frontend`, `redis-cart`) | à séparer |

Les corriger un par un dans les overlays serait possible, mais les appliquer à
l'**admission** est la bonne réponse à la décision C : un nouveau `Deployment`
ne pourra pas être admis sans eux, qu'il vienne de notre base ou d'ailleurs.

## Un constat que la tâche 19 a créé et qu'il faut nommer

L'`Ingress` ne déclare **aucun TLS**. checkov ne le signale pas, mais c'est une
absence réelle : les trois environnements sont servis en HTTP clair. Le port
443 n'est volontairement pas ouvert dans le groupe de sécurité tant qu'il n'y
a pas de certificat à présenter — ouvrir un port qui ne sert à rien serait une
surface offerte sans contrepartie. cert-manager relève de la phase 4, et c'est
là que ce point se ferme.
