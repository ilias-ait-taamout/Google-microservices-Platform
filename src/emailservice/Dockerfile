ARG BUILDPLATFORM=linux/amd64

FROM --platform=$BUILDPLATFORM python:3.14.8-alpine@sha256:f6a589d43c42b9e7f7dc67a12d37132491f362859a5d750607710cc56da3bc72 AS base

FROM base AS builder

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

RUN apk update \
    && apk add --no-cache g++ linux-headers \
    && rm -rf /var/cache/apk/*

COPY requirements.txt .
RUN pip install -r requirements.txt \
    && pip install --upgrade "setuptools>=78.1.1"

FROM base

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

ENV ENABLE_PROFILER=1

RUN apk update \
    && apk add --no-cache libstdc++ \
    && rm -rf /var/cache/apk/*

WORKDIR /email_server

COPY --from=builder /usr/local/lib/python3.14/ /usr/local/lib/python3.14/

COPY . .


# Une image d'execution n'a aucune raison d'embarquer un installateur de
# paquets. pip vendorise ses propres copies de certifi, urllib3, msgpack et
# setuptools dans pip/_vendor/vendor.txt, et Trivy les compte comme des
# paquets installes : ce sont les quatre constats restants, strictement
# identiques sur les trois services Python et absents de leurs requirements.
# Monter pip ne sert a rien : sa derniere version vendorise encore
# msgpack 1.1.2 et urllib3 2.7.0 (verifie sur ses quatre dernieres versions).
#
# APRES tous les COPY, et c'est le point delicat : un COPY fusionne, donc une
# suppression faite plus haut serait annulee par la copie venue du builder.
RUN python -m pip uninstall -y pip

EXPOSE 8080
ENTRYPOINT [ "python", "email_server.py" ]
