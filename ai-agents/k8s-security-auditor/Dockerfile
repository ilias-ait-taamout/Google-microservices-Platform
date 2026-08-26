# =============================================================================
#  Image de l'agent — build multi-stage, exécution non-root
#  On applique à notre propre agent le niveau d'exigence qu'on audite ailleurs
#  (ADR-004) : sinon l'agent serait lui-même un finding de son propre rapport.
# =============================================================================

# --- Étape 1 : build des dépendances -----------------------------------------
FROM python:3.12-slim AS builder

WORKDIR /build
COPY requirements.txt .

# --user installe dans /root/.local, qu'on copiera dans l'image finale.
# Résultat : les outils de compilation ne se retrouvent pas dans l'image
# livrée -> surface d'attaque et taille réduites.
RUN pip install --no-cache-dir --user -r requirements.txt


# --- Étape 2 : image d'exécution ---------------------------------------------
FROM python:3.12-slim

# Utilisateur non privilégié, UID > 10000 conformément à l'ADR-004.
RUN groupadd --gid 10001 auditor \
 && useradd --uid 10001 --gid 10001 --create-home --shell /usr/sbin/nologin auditor

WORKDIR /app

COPY --from=builder /root/.local /home/auditor/.local
ENV PATH=/home/auditor/.local/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY --chown=auditor:auditor mcp_server/ ./mcp_server/
COPY --chown=auditor:auditor agent/      ./agent/
COPY --chown=auditor:auditor rag/        ./rag/

USER auditor

# ⚠️ La clé API n'est PAS dans l'image. Elle est injectée à l'exécution via
# un secretKeyRef alimenté par External Secrets depuis AWS Secrets Manager.
# Une clé dans une image Docker est une clé publiée.

ENTRYPOINT ["python", "agent/main.py"]
CMD ["Audite tous les namespaces applicatifs et identifie les chemins d'attaque."]
