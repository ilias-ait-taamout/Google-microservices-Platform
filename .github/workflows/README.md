# Intégration continue

Ce dossier contient la chaîne d'intégration continue du projet. Il remplace
le README d'origine de Google, qui décrivait des runners auto-hébergés sur GCE
et un cluster GKE de test — aucun des deux n'existe dans ce projet.

| Fichier | Rôle |
|---|---|
| `build-push.yml` | la chaîne complète : construire, scanner, publier, signer, vérifier, puis écrire le nouveau tag dans l'overlay `dev` |
| `install-dependencies.sh` | hérité du dépôt amont, non utilisé par cette chaîne |

## Ce que fait `build-push.yml`

```
push sur develop  (uniquement si src/** ou ce fichier a changé)
   │
   ├─ job « changes »   quels services ont réellement changé ?
   │                    comparaison avec le PUSH PRÉCÉDENT
   │
   ├─ job « build »     une exécution par service, max 1 à la fois
   │                    construire en local → scanner → VERROU
   │                    → publier → signer → VÉRIFIER → déposer un marqueur
   │
   └─ job « bump »      ramasser les marqueurs, écrire les tags dans
                        l'overlay dev, UN seul commit, et le pousser
```

ArgoCD lit ensuite ce commit et synchronise le cluster. La CI n'a **aucun
accès au cluster** : elle écrit dans Git, c'est tout.

## Les décisions qui expliquent la forme du fichier

**Toutes les actions sont épinglées par empreinte de commit complète.** Le
19 mars 2026, un attaquant a réécrit par force 76 des 77 étiquettes de version
de `aquasecurity/trivy-action` vers un code d'exfiltration d'identifiants
(GHSA-69fq-xp46-6x23). Quiconque était épinglé sur une étiquette a reçu le code
malveillant sans modifier une ligne de son workflow. Une étiquette est un
pointeur mobile, une empreinte de commit n'en est pas un. La version reste en
commentaire de fin de ligne, pour les humains et pour Dependabot.

**L'ordre est construire → scanner → publier.** L'image est construite
localement (`load: true`, `push: false`) et n'est publiée qu'après le verrou.
L'ordre inverse rendrait une image vulnérable tirable par n'importe qui pendant
tout l'intervalle entre la publication et la découverte.

**Le verrou est une expression `jq` en pleine lumière**, pas un paramètre caché
dans les entrées d'une action : HIGH ou CRITICAL, **et** un correctif existe en
amont. Un constat sans version corrective ne peut pas être traité, et bloquer
dessus n'apprendrait qu'une chose aux équipes — désactiver le scan.

**Le champ `FixedVersion` est affiché en entier.** Il peut contenir plusieurs
versions, une par ligne de version maintenue. N'en garder qu'une masque
l'existence d'un correctif dans la ligne que le projet utilise réellement : ce
défaut a existé ici, et il a fait conclure à tort qu'une migration de version
majeure était nécessaire pour Netty.

**La signature porte sur le digest, jamais sur le tag**, et sans clé privée :
GitHub émet un jeton OIDC, Fulcio le convertit en certificat de dix minutes, la
signature part dans le journal de transparence Rekor. La vérification qui suit
est **fatale** — une signature invérifiable transforme la signature en théâtre.

**`cosign login` avant de signer.** cosign n'hérite pas des identifiants de
`docker/login-action` : sans ce login il interroge Docker Hub en anonyme et
tombe sous la limite de 100 requêtes par 6 h, **partagée par adresse IP** avec
les autres runners GitHub.

**`max-parallel: 1`.** Chaque lecture de manifeste par cosign compte comme un
pull. Onze services signant simultanément épuisent le quota du registre ; en
séquentiel, chacun dialogue seul avec Fulcio, Rekor et Docker Hub. Le coût est
du temps d'horloge : les couches sont en cache, c'est la signature qui prend le
temps.

**Un seul job `bump`, pas onze.** Les sorties de job ne survivent pas à une
matrice — chaque exécution écraserait la précédente — donc chaque service
dépose un **artefact marqueur**, et `bump` les ramasse. Onze commits
voudraient dire onze synchronisations ArgoCD pour un seul changement de code.

**Un service bloqué par le verrou ne dépose pas de marqueur**, donc son tag
n'est pas bougé et l'overlay garde l'image précédente. C'est ce qui rend le
déploiement service par service possible, et c'est arrivé en vrai : un service
dont la signature avait échoué est resté sur sa dernière image vérifiée,
pendant que les dix autres avançaient.

**Les compteurs sortent en annotations `::error` et `::notice`.** C'est la
seule sortie de CI que l'API publique de GitHub sert **sans identifiant** sur
un dépôt public : les journaux de job, les résumés d'étape et les artefacts en
exigent tous. Sans cela, analyser onze services demande d'ouvrir onze pages à
la main.

## Lire les résultats sans identifiants

```bash
R=ilias-ait-taamout/Google-microservices-Platform
A="Accept: application/vnd.github+json"

curl -sS -H "$A" "https://api.github.com/repos/$R/actions/runs?per_page=5"
curl -sS -H "$A" "https://api.github.com/repos/$R/actions/runs/<RUN>/jobs?per_page=50"
curl -sS -H "$A" "https://api.github.com/repos/$R/check-runs/<JOB_ID>/annotations"
```

## Workflows supprimés à la clôture de la phase 3

`bump-go-deps.yml`, `bump-python-deps.yml`, `diagnose-node-deps.yml` et
`resolve-digests.yml` ont servi à la campagne de remédiation puis au
diagnostic. Ils sont supprimés : un dépôt qui conserve son outillage jetable
devient illisible. Dependabot est la réponse durable à la montée des
dépendances, et il relève de la phase 4.

## Secrets et variables attendus

| Nom | Type | Usage |
|---|---|---|
| `DOCKERHUB_USERNAME` | **variable** | propriétaire des images |
| `DOCKERHUB_TOKEN` | **secret** | publication |

`DOCKERHUB_USERNAME` est une variable et non un secret, et ce n'est pas un
détail : classé en secret, GitHub le masque partout — les journaux affichent
`***/frontend` — et **refuse de transmettre la sortie d'un job** qui pourrait
le contenir, ce dont Trivy et Cosign ont tous deux besoin. Surclasser une
donnée non sensible a un coût opérationnel réel.
