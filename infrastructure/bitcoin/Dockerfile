FROM debian:bookworm-slim AS downloader

ARG BITCOIN_VERSION=32.1
ARG TARGETARCH
ARG BITCOIN_SHA_AMD64=61545c17c3120fb7412f896d248b11993af04ec8817aad3649c55b2afb044963
ARG BITCOIN_SHA_ARM64=7ed37c7373eb6aa3e3f72842596a1afeba1b223717033cade9842b25773e1922

RUN apt-get update \
 && apt-get install --no-install-recommends --yes ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) archive_arch="x86_64-linux-gnu"; expected="$BITCOIN_SHA_AMD64" ;; \
      arm64) archive_arch="aarch64-linux-gnu"; expected="$BITCOIN_SHA_ARM64" ;; \
      *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    archive="bitcoin-${BITCOIN_VERSION}-${archive_arch}.tar.gz"; \
    curl --fail --location --proto '=https' --tlsv1.2 \
      "https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/${archive}" \
      --output "/tmp/${archive}"; \
    echo "${expected}  /tmp/${archive}" | sha256sum --check --strict; \
    tar --extract --gzip --file "/tmp/${archive}" --strip-components=2 \
      --directory /usr/local/bin \
      "bitcoin-${BITCOIN_VERSION}/bin/bitcoind" \
      "bitcoin-${BITCOIN_VERSION}/bin/bitcoin-cli"

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install --no-install-recommends --yes ca-certificates gosu \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 bitcoin \
 && useradd --uid 10001 --gid bitcoin --home-dir /data --no-create-home bitcoin

COPY --from=downloader /usr/local/bin/bitcoind /usr/local/bin/bitcoind
COPY --from=downloader /usr/local/bin/bitcoin-cli /usr/local/bin/bitcoin-cli
COPY infrastructure/bitcoin/entrypoint.sh /usr/local/bin/nodi-bitcoin-entrypoint
RUN chmod 0755 /usr/local/bin/nodi-bitcoin-entrypoint

VOLUME ["/data"]
EXPOSE 8332 8333
ENTRYPOINT ["nodi-bitcoin-entrypoint"]
