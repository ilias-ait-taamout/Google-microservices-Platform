#!/usr/bin/env python3
"""
=============================================================================
 INGESTION RAG — construction de la base de connaissances vectorielle
=============================================================================

À LANCER UNE FOIS avant le premier audit :
    python rag/ingest.py

CE QUE FAIT CE SCRIPT
  1. lit tous les fichiers .md de rag/knowledge/
  2. les découpe en chunks (un chunk = un contrôle de sécurité)
  3. calcule un embedding pour chaque chunk
  4. stocke le tout dans ChromaDB (un simple dossier sur disque)

POURQUOI CES CHOIX
  - ChromaDB : base vectorielle en mode fichier, zéro serveur à déployer.
    Sur quelques centaines de chunks, c'est amplement suffisant. Le jour où
    l'on indexe tout un référentiel documentaire, on migre — l'abstraction
    est isolée dans ce fichier et dans l'outil MCP.
  - Embeddings : fonction par défaut de Chroma (ONNX all-MiniLM-L6-v2,
    ~80 Mo, exécuté en local sur CPU). Aucun appel API, aucun coût,
    fonctionne hors ligne.

LE PROBLÈME QU'ON RÉSOUT ICI
  Un découpage naïf à taille fixe coupait les contrôles CIS en plein milieu :
  le retrieval remontait la moitié d'un contrôle, sans son numéro ni son
  correctif. On découpe donc sur la STRUCTURE du document (titres de niveau 2)
  et non sur un nombre de caractères. Les documents normatifs sont déjà
  organisés par contrôle : il faut épouser leur structure.
=============================================================================
"""

import re
import shutil
import sys
from pathlib import Path

import chromadb

# --- Chemins ----------------------------------------------------------------
RACINE = Path(__file__).resolve().parent
DOSSIER_CONNAISSANCES = RACINE / "knowledge"
DOSSIER_CHROMA = RACINE / "chroma_db"
NOM_COLLECTION = "security_knowledge"


def decouper_en_controles(texte: str, source: str) -> list[dict]:
    """Découpe un document Markdown en chunks, un par section de niveau 2.

    Chaque chunk conserve son titre : c'est important, car le titre contient
    l'identifiant du contrôle (ex. '## CIS 5.2.2 — Conteneurs privilégiés'),
    et c'est cet identifiant que l'agent devra citer.
    """
    chunks = []

    # On coupe avant chaque '## ' en début de ligne, en gardant le séparateur.
    sections = re.split(r"\n(?=## )", texte)

    for section in sections:
        section = section.strip()
        # On ignore les sections trop courtes (titre du document, en-têtes).
        if len(section) < 80:
            continue

        premiere_ligne = section.split("\n", 1)[0].lstrip("# ").strip()

        # Extraction de l'identifiant de contrôle depuis le titre.
        # Ex. "CIS 5.2.2 — Conteneurs privilégiés" -> "CIS 5.2.2"
        m = re.search(r"((?:CIS|NSA|ADR)[-\s][\w.\-]+)", premiere_ligne)
        controle = m.group(1).strip() if m else premiere_ligne[:40]

        chunks.append({
            "texte": section,
            "source": source,
            "controle": controle,
            "titre": premiere_ligne,
        })

    return chunks


def main() -> None:
    if not DOSSIER_CONNAISSANCES.exists():
        raise SystemExit(f"Dossier introuvable : {DOSSIER_CONNAISSANCES}")

    # --- Reconstruction propre de l'index -----------------------------------
    # On repart de zéro à chaque ingestion : c'est idempotent, donc on évite
    # les doublons quand on relance après avoir modifié un document.
    if DOSSIER_CHROMA.exists():
        print(f"Suppression de l'index existant : {DOSSIER_CHROMA}")
        shutil.rmtree(DOSSIER_CHROMA)

    client = chromadb.PersistentClient(path=str(DOSSIER_CHROMA))
    collection = client.create_collection(
        name=NOM_COLLECTION,
        # cosine : la métrique adaptée aux embeddings de phrases
        metadata={"hnsw:space": "cosine"},
    )

    # --- Lecture et découpage ------------------------------------------------
    tous_les_chunks = []
    fichiers = sorted(DOSSIER_CONNAISSANCES.glob("*.md"))
    if not fichiers:
        raise SystemExit(f"Aucun fichier .md dans {DOSSIER_CONNAISSANCES}")

    for fichier in fichiers:
        contenu = fichier.read_text(encoding="utf-8")
        chunks = decouper_en_controles(contenu, source=fichier.stem)
        print(f"  {fichier.name:35s} -> {len(chunks):3d} chunks")
        tous_les_chunks.extend(chunks)

    if not tous_les_chunks:
        raise SystemExit("Aucun chunk produit — vérifie que tes documents "
                         "utilisent bien des titres '## '.")

    # --- Indexation ----------------------------------------------------------
    # Chroma calcule les embeddings automatiquement à l'insertion.
    # Le premier lancement télécharge le modèle ONNX (~80 Mo) : c'est normal
    # que ce soit plus lent la première fois.
    print(f"\nIndexation de {len(tous_les_chunks)} chunks "
          f"(le 1er lancement télécharge le modèle d'embedding)...")

    collection.add(
        ids=[f"chunk-{i}" for i in range(len(tous_les_chunks))],
        documents=[c["texte"] for c in tous_les_chunks],
        metadatas=[{
            "source": c["source"],
            "controle": c["controle"],
            "titre": c["titre"],
        } for c in tous_les_chunks],
    )

    print(f"OK — index construit dans {DOSSIER_CHROMA}")

    # --- Test de fumée -------------------------------------------------------
    # On vérifie tout de suite que le retrieval fonctionne. Si cette requête
    # ne remonte rien de pertinent, inutile d'aller plus loin.
    print("\nTest de recherche : 'conteneur privilégié'")
    res = collection.query(query_texts=["conteneur privilégié"], n_results=3)
    for doc, meta in zip(res["documents"][0], res["metadatas"][0]):
        print(f"  [{meta['controle']}] {meta['titre'][:60]}")


if __name__ == "__main__":
    main()
