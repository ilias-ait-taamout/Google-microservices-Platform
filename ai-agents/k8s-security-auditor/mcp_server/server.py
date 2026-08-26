#!/usr/bin/env python3
"""
=============================================================================
 SERVEUR MCP — Auditeur de sécurité Kubernetes (LECTURE SEULE)
=============================================================================

RÔLE DE CE FICHIER
------------------
Ce fichier expose des "outils" (tools) que le modèle Claude pourra demander
à utiliser. Il ne parle JAMAIS à Claude directement : il parle uniquement à
l'API Kubernetes, et communique avec l'agent via le protocole MCP (JSON-RPC).

CHAÎNE COMPLÈTE :
    agent/main.py  ──lance en sous-processus──>  CE FICHIER
                   <──JSON-RPC sur stdin/stdout──>
    agent/main.py  ──HTTPS──> API Anthropic (Claude)

Claude n'a AUCUN accès réseau vers ce serveur. Il émet une intention
("je veux appeler list_pods"), et c'est l'agent qui décide de l'exécuter.

PRINCIPE DE SÉCURITÉ
--------------------
Tous les outils sont en lecture seule. Aucun verbe d'écriture n'est exposé.
En déploiement cluster, cette garantie est doublée par le RBAC du
ServiceAccount (voir deploy/rbac.yaml) : même si le code voulait écrire,
l'API Kubernetes renverrait 403.

LANCEMENT
---------
Ce fichier n'est normalement PAS lancé à la main : agent/main.py le démarre
tout seul en sous-processus. Pour un test isolé :
    python mcp_server/server.py     (il attendra sur stdin, c'est normal)
=============================================================================
"""

import json
import sys
from pathlib import Path

# --- SDK MCP officiel -------------------------------------------------------
# FastMCP transforme automatiquement une fonction Python décorée en outil MCP :
#   - le nom de la fonction        -> le nom de l'outil
#   - la docstring                 -> la "description" lue par Claude
#   - les annotations de type      -> l'inputSchema (JSON Schema)
# C'est pour cela que les docstrings ci-dessous sont écrites AVEC SOIN :
# elles sont le seul élément sur lequel Claude s'appuie pour décider
# quand appeler tel ou tel outil. Une docstring floue = un agent qui se trompe.
from mcp.server.fastmcp import FastMCP

# --- Client Kubernetes officiel --------------------------------------------
from kubernetes import client, config
from kubernetes.client.rest import ApiException
from kubernetes.config import ConfigException


# =============================================================================
# 1. LOGGING — TOUJOURS SUR STDERR, JAMAIS SUR STDOUT
# =============================================================================
# ATTENTION, PIÈGE CLASSIQUE DU TRANSPORT STDIO :
# stdout est réservé au protocole JSON-RPC. Un simple print() casse le flux
# et fait planter la connexion MCP avec une erreur illisible.
# => tout log part sur stderr.
def log(message: str) -> None:
    """Écrit un message de diagnostic sur stderr (jamais stdout)."""
    print(f"[mcp-server] {message}", file=sys.stderr, flush=True)


# =============================================================================
# 2. CONNEXION À L'API KUBERNETES
# =============================================================================
# Deux modes d'authentification, testés dans cet ordre :
#
#   a) IN-CLUSTER : le code tourne dans un pod. Le kubelet a monté :
#         /var/run/secrets/kubernetes.io/serviceaccount/token      (JWT)
#         /var/run/secrets/kubernetes.io/serviceaccount/ca.crt     (CA TLS)
#      + les variables KUBERNETES_SERVICE_HOST / _PORT.
#      Aucun secret à gérer, le token est renouvelé automatiquement.
#
#   b) KUBECONFIG : le code tourne sur ton poste. Il lit ~/.kube/config
#      (URL de l'apiserver + certificat client + CA).
#
# Le même binaire fonctionne dans les deux cas, sans variable de config :
# c'est ce qu'on attend d'une image conteneurisée.
try:
    config.load_incluster_config()
    K8S_MODE = "in-cluster (ServiceAccount)"
except ConfigException:
    try:
        config.load_kube_config()
        K8S_MODE = "kubeconfig local"
    except ConfigException as exc:
        log(f"FATAL : aucune configuration Kubernetes trouvée -> {exc}")
        log("Vérifie que ton cluster kind tourne : kubectl cluster-info")
        raise SystemExit(1)

log(f"connexion Kubernetes établie en mode : {K8S_MODE}")

# Trois clients, un par groupe d'API. C'est le découpage de l'API Kubernetes :
core_v1 = client.CoreV1Api()               # pods, namespaces, serviceaccounts
net_v1 = client.NetworkingV1Api()          # networkpolicies
rbac_v1 = client.RbacAuthorizationV1Api()  # roles, rolebindings, clusterroles


# =============================================================================
# 3. INSTANCIATION DU SERVEUR MCP
# =============================================================================
# Le nom sert d'identifiant du serveur lors du handshake `initialize`.
mcp = FastMCP("k8s-security-auditor")


# =============================================================================
# 4. LES OUTILS EXPOSÉS À CLAUDE
# =============================================================================
# RÈGLE DE CONCEPTION IMPORTANTE :
# on ne renvoie JAMAIS l'objet Kubernetes brut. Un pod complet en JSON pèse
# ~3 000 tokens de métadonnées (managedFields, annotations, status...).
# Sur 40 pods et 4 tours de boucle, le contexte explose et le coût aussi.
# => chaque outil PROJETTE une quinzaine de champs utiles à l'audit.
#    Mesure réelle : ~120 000 tokens/audit sans projection, ~15 000 avec.
# =============================================================================


@mcp.tool()
def list_namespaces() -> list[str]:
    """Liste tous les namespaces du cluster.

    À utiliser en premier si l'utilisateur ne précise pas quel namespace
    auditer, afin de découvrir la structure du cluster.
    """
    try:
        return [ns.metadata.name for ns in core_v1.list_namespace().items]
    except ApiException as exc:
        # On renvoie l'erreur au lieu de lever : Claude la lira et s'adaptera.
        return [f"ERREUR API Kubernetes {exc.status} : {exc.reason}"]


@mcp.tool()
def list_pods(namespace: str) -> list[dict]:
    """Liste les pods d'un namespace avec leur posture de sécurité complète.

    Retourne pour chaque pod : le ServiceAccount utilisé, l'usage du réseau
    ou du PID de l'hôte, les volumes hostPath montés, et pour chaque
    conteneur : image, privileged, allowPrivilegeEscalation, runAsNonRoot,
    readOnlyRootFilesystem et capabilities ajoutées.

    C'est l'outil à utiliser EN PREMIER pour cartographier un namespace.

    Args:
        namespace: le namespace à inspecter, par exemple 'default' ou 'prod'.
    """
    try:
        pods = core_v1.list_namespaced_pod(namespace)
    except ApiException as exc:
        return [{"erreur": f"API Kubernetes {exc.status} : {exc.reason}"}]

    resultat = []
    for pod in pods.items:
        # securityContext au niveau du POD (peut être None)
        pod_sc = pod.spec.security_context

        conteneurs = []
        for c in pod.spec.containers:
            # securityContext au niveau du CONTENEUR (peut aussi être None).
            # Important : le niveau conteneur écrase le niveau pod.
            c_sc = c.security_context
            conteneurs.append({
                "nom": c.name,
                "image": c.image,
                # bool(None) == False : un champ absent vaut "non défini",
                # ce qui, en sécurité, équivaut au défaut permissif de K8s.
                "privileged": bool(c_sc and c_sc.privileged),
                "allow_privilege_escalation": (
                    c_sc.allow_privilege_escalation if c_sc else None
                ),
                "run_as_non_root": c_sc.run_as_non_root if c_sc else None,
                "read_only_root_filesystem": (
                    c_sc.read_only_root_filesystem if c_sc else None
                ),
                "capabilities_ajoutees": (
                    list(c_sc.capabilities.add)
                    if c_sc and c_sc.capabilities and c_sc.capabilities.add
                    else []
                ),
            })

        resultat.append({
            "nom": pod.metadata.name,
            "namespace": pod.metadata.namespace,
            # Le SA détermine les droits API du pod -> critique pour l'audit.
            "service_account": pod.spec.service_account_name or "default",
            "host_network": bool(pod.spec.host_network),
            "host_pid": bool(pod.spec.host_pid),
            "host_ipc": bool(pod.spec.host_ipc),
            "run_as_user": pod_sc.run_as_user if pod_sc else None,
            "run_as_non_root_pod": pod_sc.run_as_non_root if pod_sc else None,
            # Un hostPath monté = accès au système de fichiers du nœud.
            # C'est un vecteur d'évasion de conteneur classique.
            "volumes_hostpath": [
                {"nom": v.name, "chemin_hote": v.host_path.path}
                for v in (pod.spec.volumes or [])
                if v.host_path is not None
            ],
            "labels": pod.metadata.labels or {},
            "conteneurs": conteneurs,
        })

    log(f"list_pods({namespace}) -> {len(resultat)} pods")
    return resultat


@mcp.tool()
def list_network_policies(namespace: str) -> dict:
    """Liste les NetworkPolicies d'un namespace et indique si le namespace
    est en deny-by-default.

    Un namespace SANS aucune NetworkPolicy laisse toutes les communications
    ouvertes entre tous les pods : c'est une absence de segmentation réseau.
    Croise ce résultat avec list_pods pour évaluer le rayon d'impact d'un
    pod compromis.

    Args:
        namespace: le namespace à inspecter.
    """
    try:
        policies = net_v1.list_namespaced_network_policy(namespace)
    except ApiException as exc:
        return {"erreur": f"API Kubernetes {exc.status} : {exc.reason}"}

    details = []
    for p in policies.items:
        selector = p.spec.pod_selector
        # Un podSelector vide {} cible TOUS les pods du namespace :
        # c'est le motif utilisé pour un deny-all.
        cible_tous = not (selector.match_labels or selector.match_expressions)
        details.append({
            "nom": p.metadata.name,
            "cible_tous_les_pods": cible_tous,
            "selecteur": selector.match_labels or {},
            "types": list(p.policy_types or []),
            "nb_regles_ingress": len(p.spec.ingress or []),
            "nb_regles_egress": len(p.spec.egress or []),
        })

    return {
        "namespace": namespace,
        "nombre_de_policies": len(details),
        # Le signal le plus important pour l'agent :
        "aucune_segmentation_reseau": len(details) == 0,
        "policies": details,
    }


@mcp.tool()
def get_service_accounts(namespace: str) -> list[dict]:
    """Liste les ServiceAccounts d'un namespace.

    Indique notamment si le montage automatique du token API est activé
    (automountServiceAccountToken). Un token monté dans un pod qui n'appelle
    jamais l'API Kubernetes est une surface d'attaque inutile.

    Args:
        namespace: le namespace à inspecter.
    """
    try:
        sas = core_v1.list_namespaced_service_account(namespace)
    except ApiException as exc:
        return [{"erreur": f"API Kubernetes {exc.status} : {exc.reason}"}]

    return [{
        "nom": sa.metadata.name,
        # None = valeur par défaut de Kubernetes, c'est-à-dire True (monté).
        "automount_token": (
            sa.automount_service_account_token
            if sa.automount_service_account_token is not None
            else "non défini (défaut Kubernetes = monté)"
        ),
        "nb_secrets_lies": len(sa.secrets or []),
    } for sa in sas.items]


@mcp.tool()
def get_rbac_bindings(namespace: str) -> dict:
    """Analyse les permissions RBAC accordées aux ServiceAccounts d'un
    namespace, via les RoleBindings locaux et les ClusterRoleBindings.

    Signale en particulier les liaisons vers 'cluster-admin' ou vers des
    ClusterRoles à privilèges élevés : un pod dont le ServiceAccount est
    cluster-admin permet une compromission totale du cluster s'il est piraté.

    Args:
        namespace: le namespace dont on veut analyser les ServiceAccounts.
    """
    resultat = {"namespace": namespace, "rolebindings": [],
                "clusterrolebindings": [], "alertes": []}

    # --- a) RoleBindings locaux au namespace --------------------------------
    try:
        for rb in rbac_v1.list_namespaced_role_binding(namespace).items:
            sujets = [
                {"kind": s.kind, "nom": s.name, "namespace": s.namespace}
                for s in (rb.subjects or [])
            ]
            resultat["rolebindings"].append({
                "nom": rb.metadata.name,
                "role_ref": f"{rb.role_ref.kind}/{rb.role_ref.name}",
                "sujets": sujets,
            })
            if rb.role_ref.name in ("cluster-admin", "admin", "edit"):
                resultat["alertes"].append(
                    f"RoleBinding '{rb.metadata.name}' accorde le rôle "
                    f"privilégié '{rb.role_ref.name}'"
                )
    except ApiException as exc:
        resultat["rolebindings"] = [{"erreur": f"{exc.status} {exc.reason}"}]

    # --- b) ClusterRoleBindings : portée cluster, plus dangereux ------------
    # On filtre pour ne garder que ceux qui concernent un SA de CE namespace,
    # sinon on remonterait des dizaines de bindings système sans intérêt.
    try:
        for crb in rbac_v1.list_cluster_role_binding().items:
            concernes = [
                s for s in (crb.subjects or [])
                if s.kind == "ServiceAccount" and s.namespace == namespace
            ]
            if not concernes:
                continue
            resultat["clusterrolebindings"].append({
                "nom": crb.metadata.name,
                "cluster_role": crb.role_ref.name,
                "service_accounts": [s.name for s in concernes],
            })
            if crb.role_ref.name == "cluster-admin":
                for s in concernes:
                    resultat["alertes"].append(
                        f"CRITIQUE : le ServiceAccount '{s.name}' du namespace "
                        f"'{namespace}' est lié à cluster-admin "
                        f"(via '{crb.metadata.name}')"
                    )
    except ApiException as exc:
        resultat["clusterrolebindings"] = [{"erreur": f"{exc.status} {exc.reason}"}]

    return resultat


# =============================================================================
# 5. OUTIL RAG — LA BASE DE CONNAISSANCES
# =============================================================================
# Pourquoi un RAG plutôt que la connaissance interne du modèle ?
#   1) Le modèle connaît vaguement les benchmarks CIS et invente parfois des
#      numéros de contrôle plausibles mais faux.
#   2) On veut que les recommandations citent NOS ADR et NOS runbooks,
#      que le modèle n'a jamais vus.
# => chaque recommandation devient traçable et auditable.
#
# Choix technique : ChromaDB en mode persistant (un simple dossier sur disque),
# avec sa fonction d'embedding par défaut (ONNX MiniLM-L6-v2, ~80 Mo, local).
# Zéro serveur à déployer, zéro appel API pour l'indexation.
# L'import est fait À L'INTÉRIEUR de la fonction pour que le serveur démarre
# même si le RAG n'est pas encore construit (dégradation gracieuse).
# =============================================================================

CHEMIN_CHROMA = Path(__file__).resolve().parent.parent / "rag" / "chroma_db"
_collection_cache = None  # on ne recharge pas l'index à chaque appel


@mcp.tool()
def search_security_knowledge(query: str, nb_resultats: int = 3) -> list[dict]:
    """Recherche dans la base de connaissances sécurité : contrôles CIS
    Kubernetes Benchmark, guide de durcissement NSA/CISA, et les ADR internes
    de la plateforme.

    À utiliser SYSTÉMATIQUEMENT avant de formuler une recommandation, afin de
    citer le contrôle de référence exact plutôt que de le deviner.

    Args:
        query: la question ou le sujet, ex. 'conteneur privilégié' ou
               'absence de NetworkPolicy'.
        nb_resultats: nombre d'extraits à retourner (3 par défaut).
    """
    global _collection_cache
    try:
        if _collection_cache is None:
            import chromadb  # import tardif : dépendance optionnelle
            client_chroma = chromadb.PersistentClient(path=str(CHEMIN_CHROMA))
            _collection_cache = client_chroma.get_collection("security_knowledge")

        res = _collection_cache.query(query_texts=[query], n_results=nb_resultats)

        # Chroma renvoie des listes de listes (une par requête) -> on aplatit.
        return [
            {
                "source": meta.get("source", "inconnue"),
                "controle": meta.get("controle", "n/a"),
                "extrait": doc,
            }
            for doc, meta in zip(res["documents"][0], res["metadatas"][0])
        ]
    except Exception as exc:
        # On ne fait JAMAIS planter l'agent parce que le RAG est indisponible.
        # On renvoie une explication : Claude en tiendra compte et signalera
        # que ses recommandations ne sont pas sourcées.
        return [{
            "erreur": f"base de connaissances indisponible ({exc})",
            "action": "Lance d'abord : python rag/ingest.py",
        }]


# =============================================================================
# 6. POINT D'ENTRÉE
# =============================================================================
if __name__ == "__main__":
    # transport="stdio" : le serveur lit le JSON-RPC sur stdin et répond sur
    # stdout. C'est le mode utilisé en développement et par Claude Desktop.
    # Pour un déploiement en cluster, on passerait à un transport HTTP/SSE.
    log("démarrage du serveur MCP (transport stdio), en attente...")
    mcp.run(transport="stdio")
