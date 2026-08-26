#!/usr/bin/env python3
"""
=============================================================================
 TEST DE FUMÉE — à lancer EN PREMIER
=============================================================================
 Vérifie indépendamment les trois connexions, pour ne pas déboguer trois
 problèmes en même temps :

     1. API Anthropic   (clé valide, réseau, crédit)
     2. API Kubernetes  (cluster joignable, droits suffisants)
     3. Base RAG        (index construit)

 Utilisation :
     python test_connexion.py
=============================================================================
"""

import os
import sys
from pathlib import Path

OK = "  [OK]  "
KO = "  [KO]  "
resultats = []


def titre(texte: str) -> None:
    print(f"\n{'=' * 62}\n {texte}\n{'=' * 62}")


# =============================================================================
# 0. Chargement du .env
# =============================================================================
titre("0. Fichier .env")
try:
    from dotenv import load_dotenv
    chemin = Path(__file__).resolve().parent / ".env"
    if chemin.exists():
        load_dotenv(chemin)
        print(OK + f".env chargé depuis {chemin}")
    else:
        print(KO + ".env absent — utilise les variables d'environnement du shell")
        print("         (cp .env.example .env puis remplis-le)")
except ImportError:
    print(KO + "python-dotenv non installé (pip install -r requirements.txt)")


# =============================================================================
# 1. API Anthropic
# =============================================================================
titre("1. Connexion API Anthropic")
cle = os.environ.get("ANTHROPIC_API_KEY", "")

if not cle:
    print(KO + "ANTHROPIC_API_KEY non définie")
    resultats.append(False)
elif cle.startswith("REPLACE_ME"):
    print(KO + "ANTHROPIC_API_KEY vaut encore REPLACE_ME — mets ta vraie clé")
    resultats.append(False)
else:
    # On n'affiche jamais la clé en entier, même dans un script de test.
    print(f"         clé détectée : {cle[:14]}...{cle[-4:]}")
    try:
        from anthropic import Anthropic

        client = Anthropic(timeout=30.0)
        r = client.messages.create(
            model="claude-sonnet-4-6",   # <-- vérifie l'ID dans la doc si erreur
            max_tokens=16,
            messages=[{"role": "user", "content": "réponds exactement: pong"}],
        )
        print(OK + f"réponse reçue : {r.content[0].text.strip()!r}")
        print(f"         tokens : {r.usage.input_tokens} in / "
              f"{r.usage.output_tokens} out")
        resultats.append(True)
    except Exception as exc:
        print(KO + f"{type(exc).__name__} : {exc}")
        print("         401 -> clé invalide | 404 -> identifiant de modèle "
              "incorrect | connexion -> réseau/proxy")
        resultats.append(False)


# =============================================================================
# 2. API Kubernetes
# =============================================================================
titre("2. Connexion API Kubernetes")
try:
    from kubernetes import client as k8s, config
    from kubernetes.config import ConfigException

    try:
        config.load_incluster_config()
        mode = "in-cluster (ServiceAccount)"
    except ConfigException:
        config.load_kube_config()
        mode = "kubeconfig local"
    print(f"         mode : {mode}")

    v1 = k8s.CoreV1Api()
    namespaces = [n.metadata.name for n in v1.list_namespace().items]
    print(OK + f"{len(namespaces)} namespaces : {', '.join(namespaces[:6])}"
          + (" ..." if len(namespaces) > 6 else ""))

    if "demo-audit" in namespaces:
        pods = v1.list_namespaced_pod("demo-audit").items
        print(OK + f"namespace demo-audit présent, {len(pods)} pods")
    else:
        print(KO + "namespace demo-audit absent")
        print("         kubectl apply -f demo/vulnerable-workloads.yaml")
    resultats.append(True)

except Exception as exc:
    print(KO + f"{type(exc).__name__} : {exc}")
    print("         cluster éteint ? -> kind create cluster --name audit-demo")
    resultats.append(False)


# =============================================================================
# 3. Base RAG
# =============================================================================
titre("3. Base de connaissances RAG")
try:
    import chromadb

    chemin_db = Path(__file__).resolve().parent / "rag" / "chroma_db"
    if not chemin_db.exists():
        print(KO + f"index absent ({chemin_db})")
        print("         python rag/ingest.py")
        resultats.append(False)
    else:
        col = chromadb.PersistentClient(path=str(chemin_db)) \
                      .get_collection("security_knowledge")
        print(OK + f"{col.count()} chunks indexés")
        res = col.query(query_texts=["conteneur privilégié"], n_results=2)
        for meta in res["metadatas"][0]:
            print(f"         -> {meta['controle']} : {meta['titre'][:50]}")
        resultats.append(True)
except ImportError:
    print(KO + "chromadb non installé (pip install -r requirements.txt)")
    resultats.append(False)
except Exception as exc:
    print(KO + f"{type(exc).__name__} : {exc}")
    resultats.append(False)


# =============================================================================
# Verdict
# =============================================================================
titre("VERDICT")
if all(resultats):
    print(" Tout est prêt. Lance maintenant :")
    print('   python agent/main.py "Audite le namespace demo-audit"')
    sys.exit(0)
else:
    print(" Corrige les points [KO] ci-dessus avant de lancer l'agent.")
    sys.exit(1)
