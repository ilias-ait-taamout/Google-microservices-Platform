ARG BUILDPLATFORM=linux/amd64

FROM --platform=$BUILDPLATFORM python:3.14.3-slim@sha256:fb83750094b46fd6b8adaa80f66e2302ecbe45d513f6cece637a841e1025b4ca AS base

FROM base AS builder

RUN apt-get -qq update \
    && apt-get install -y --no-install-recommends g++ \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install -r requirements.txt

FROM base
ENV PYTHONUNBUFFERED=1

WORKDIR /shoppingassistantservice

COPY --from=builder /usr/local/lib/python3.14/ /usr/local/lib/python3.14/

COPY . .

ENV PORT "8080"
EXPOSE 8080

ENTRYPOINT ["python", "shoppingassistantservice.py"]
