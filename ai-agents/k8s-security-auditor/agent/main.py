#!/usr/bin/env python3
"""
=============================================================================
 AGENT — Boucle de tool-calling Claude + client MCP
=============================================================================

C'EST LE CHEF D'ORCHESTRE. Il tient DEUX connexions séparées qui ne se
voient jamais l'une l'autre :

   1. Vers l'API Anthropic (HTTPS)  -> pour faire raisonner Claude
   2. Vers le serveur MCP (stdio)   -> pour interroger le cluster

Claude n'a AUCUN accès au serveur MCP. Il émet une intention d'appel sous
forme de texte structuré ; c'est CE FICHIER qui décide de l'exécuter.
Le point de contrôle est donc dans notre code, pas dans le modèle.

DÉROULÉ D'UN AUDIT
    t=0.0s  lancement de mcp_server/server.py en sous-processus
    t=0.5s  handshake MCP + récupération de la liste des outils
    t=0.6s  APPEL CLAUDE #1  -> "je veux list_pods(default)"
    t=3.6s  exécution via MCP (Claude n'intervient pas)
    t=3.8s  APPEL CLAUDE #2  -> "je veux get_rbac_bindings(default)"
    ...
    t=12s   stop_reason="end_turn" -> rapport JSON final

UTILISATION
    export ANTHROPIC_API_KEY="sk-ant-..."
    python agent/main.py "Audite le namespace default"
=============================================================================
"""

import asyncio
import json
import os
import sys
from datetime import datetime
from pathlib import Path

# --- SDK Anthropic ----------------------------------------------------------
from anthropic import Anthropic, APIError

# --- SDK MCP côté CLIENT ----------------------------------------------------
# stdio_client lance le serveur en sous-processus et ouvre les deux tuyaux.
# ClientSession parle le JSON-RPC par-dessus ces tuyaux.
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# Permet de lancer `python agent/main.py` depuis la racine du projet
sys.path.insert(0, str(Path(__file__).resolve().parent))
from prompts import SYSTEM_PROMPT  # noqa: E402


# =============================================================================
# CONFIGURATION
# =============================================================================
# ⚠️ Vérifie l'identifiant exact du modèle dans la doc Anthropic avant usage :
#    https://docs.claude.com/en/docs/about-claude/models
MODELE = "claude-sonnet-4-6"

MAX_TOKENS = 8000      # plafond de la RÉPONSE (pas de l'entrée)
MAX_TOURS = 10         # borne dure de la boucle : sans elle, un agent peut
                       # rappeler le même outil indéfiniment (vécu au 1er run)
TIMEOUT_API = 90.0     # secondes ; le défaut du SDK (~10 min) est trop long


def log(msg: str) -> None:
    """Trace de diagnostic sur stderr, pour laisser stdout au rapport final."""
    print(msg, file=sys.stderr, flush=True)


# =============================================================================
# LA BOUCLE D'AGENT
# =============================================================================
async def auditer(question: str) -> str:
    """Exécute un audit complet et renvoie le rapport JSON produit par Claude."""

    # --- 1. Vérification de la clé AVANT tout le reste -----------------------
    # Le SDK lit ANTHROPIC_API_KEY tout seul, mais on veut un message clair
    # plutôt qu'une AuthenticationError cryptique après 30 secondes.
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise SystemExit(
            "ERREUR : la variable ANTHROPIC_API_KEY n'est pas définie.\n"
            "  export ANTHROPIC_API_KEY='sk-ant-...'\n"
            "  (ou copie .env.example vers .env et remplis-le)"
        )

    # timeout + max_retries : le SDK réessaie déjà tout seul sur 429/5xx
    # avec un backoff exponentiel. Pas besoin d'écrire notre propre retry.
    claude = Anthropic(timeout=TIMEOUT_API, max_retries=3)

    # --- 2. Lancement du serveur MCP en sous-processus -----------------------
    # sys.executable = le python courant (celui du venv), pas "python" au
    # hasard dans le PATH : évite les erreurs de dépendances manquantes.
    chemin_serveur = Path(__file__).resolve().parent.parent / "mcp_server" / "server.py"
    params = StdioServerParameters(
        command=sys.executable,
        args=[str(chemin_serveur)],
        env=None,  # hérite de l'environnement courant (donc du KUBECONFIG)
    )

    log("=" * 70)
    log(f"AUDIT : {question}")
    log("=" * 70)

    # Le `async with` garantit que le sous-processus est bien tué à la sortie,
    # même en cas d'exception. Sans ça, on laisse des processus zombies.
    async with stdio_client(params) as (lecture, ecriture):
        async with ClientSession(lecture, ecriture) as session:

            # --- 3. Handshake JSON-RPC ---------------------------------------
            await session.initialize()
            log("[mcp] handshake OK")

            # --- 4. Découverte des outils ------------------------------------
            # On ne code EN DUR aucune définition d'outil ici : le serveur
            # s'auto-décrit. Ajouter un outil = modifier le serveur seulement.
            outils_mcp = await session.list_tools()

            # Traduction MCP -> format Anthropic. Elle est directe parce que
            # les deux utilisent du JSON Schema : inputSchema -> input_schema.
            outils = [{
                "name": t.name,
                "description": t.description,
                "input_schema": t.inputSchema,
            } for t in outils_mcp.tools]

            log(f"[mcp] {len(outils)} outils découverts : "
                f"{', '.join(o['name'] for o in outils)}")

            # --- 5. L'historique de conversation -----------------------------
            # POINT CLÉ : l'API Anthropic est SANS MÉMOIRE. Chaque appel repart
            # de zéro. C'est cette liste `messages` qui EST la mémoire : on la
            # renvoie intégralement à chaque tour.
            messages = [{"role": "user", "content": question}]
            total_in = total_out = 0

            # --- 6. LA BOUCLE ------------------------------------------------
            for tour in range(MAX_TOURS):

                # ---- 6a. Appel à Claude -------------------------------------
                try:
                    reponse = claude.messages.create(
                        model=MODELE,
                        max_tokens=MAX_TOKENS,
                        system=SYSTEM_PROMPT,   # paramètre séparé, PAS un message
                        tools=outils,           # à renvoyer à CHAQUE appel
                        messages=messages,      # tout l'historique, à chaque fois
                    )
                except APIError as exc:
                    log(f"[erreur] appel Claude échoué : {exc}")
                    return json.dumps({
                        "erreur": "appel LLM indisponible",
                        "detail": str(exc),
                    }, ensure_ascii=False, indent=2)

                total_in += reponse.usage.input_tokens
                total_out += reponse.usage.output_tokens
                log(f"\n[tour {tour}] stop_reason={reponse.stop_reason} "
                    f"| tokens in={reponse.usage.input_tokens} "
                    f"out={reponse.usage.output_tokens}")

                # ---- 6b. On rejoue la réponse de Claude dans l'historique ----
                # TELLE QUELLE : elle contient les blocs tool_use avec leurs
                # identifiants, dont l'API a besoin au tour suivant.
                messages.append({"role": "assistant", "content": reponse.content})

                # ---- 6c. A-t-il fini ? --------------------------------------
                # stop_reason pilote toute la boucle :
                #   "tool_use"   -> il veut un outil, on continue
                #   "end_turn"   -> il a terminé, c'est le rapport final
                #   "max_tokens" -> réponse tronquée, augmenter MAX_TOKENS
                if reponse.stop_reason != "tool_use":
                    log(f"\n{'=' * 70}")
                    log(f"TERMINÉ en {tour + 1} tours | "
                        f"tokens totaux : {total_in} in / {total_out} out")
                    log("=" * 70)
                    # content est une LISTE de blocs hétérogènes : on ne peut
                    # pas faire content[0].text, il faut filtrer les blocs texte.
                    return "".join(
                        b.text for b in reponse.content if b.type == "text"
                    )

                # ---- 6d. Exécution des outils demandés ----------------------
                # Claude peut en demander PLUSIEURS dans une seule réponse.
                # Règle de l'API : chaque tool_use doit recevoir son
                # tool_result, tous dans le MÊME message utilisateur.
                resultats = []
                for bloc in reponse.content:
                    if bloc.type != "tool_use":
                        continue  # on saute les blocs de texte de raisonnement

                    log(f"  -> {bloc.name}({json.dumps(bloc.input, ensure_ascii=False)})")

                    # C'EST ICI le point de contrôle : on pourrait refuser,
                    # filtrer via une allowlist, journaliser pour l'audit...
                    try:
                        sortie = await session.call_tool(bloc.name, bloc.input)
                        contenu = sortie.content[0].text
                        est_erreur = False
                    except Exception as exc:
                        # On ne fait pas planter l'agent : on remonte l'erreur
                        # à Claude qui s'adaptera ("ce namespace n'existe pas,
                        # j'essaie default"). C'est ce qui rend l'agent robuste.
                        contenu = f"Erreur d'exécution de l'outil : {exc}"
                        est_erreur = True
                        log(f"     [!] {contenu}")

                    resultats.append({
                        "type": "tool_result",
                        "tool_use_id": bloc.id,   # DOIT correspondre au caractère près
                        "content": contenu,       # une CHAÎNE, pas un dict
                        "is_error": est_erreur,
                    })

                # ---- 6e. Les résultats repartent en rôle "user" -------------
                # Contre-intuitif : ce n'est pas l'utilisateur qui parle. Mais
                # dans le protocole, tout ce qui n'est pas produit par le modèle
                # est de rôle "user". Le type de bloc fait la distinction.
                messages.append({"role": "user", "content": resultats})

            # --- 7. Garde-fou ------------------------------------------------
            log(f"[!] limite de {MAX_TOURS} tours atteinte")
            return json.dumps({"erreur": f"limite de {MAX_TOURS} tours atteinte"},
                              ensure_ascii=False)


# =============================================================================
# POINT D'ENTRÉE
# =============================================================================
def main() -> None:
    question = (
        " ".join(sys.argv[1:]) if len(sys.argv) > 1
        else "Audite le namespace default et identifie les chemins d'attaque."
    )

    rapport = asyncio.run(auditer(question))

    # Le rapport part sur STDOUT -> on peut le rediriger vers un fichier,
    # tandis que la trace de diagnostic reste lisible sur stderr.
    print(rapport)

    # Sauvegarde horodatée : utile pour une capture d'écran de démonstration.
    dossier = Path(__file__).resolve().parent.parent / "rapports"
    dossier.mkdir(exist_ok=True)
    fichier = dossier / f"audit-{datetime.now():%Y%m%d-%H%M%S}.json"
    fichier.write_text(rapport, encoding="utf-8")
    log(f"\nRapport enregistré : {fichier}")


if __name__ == "__main__":
    main()
