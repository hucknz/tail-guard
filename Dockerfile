############################
# 1) Build tiny entrypoint #
############################
FROM golang:1.23-bookworm AS entrypoint-builder
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY entrypoint/ ./entrypoint/
RUN mkdir -p /out \
    && CGO_ENABLED=0 GOFLAGS="-trimpath" \
       go build -ldflags="-s -w" -o /out/entrypoint ./entrypoint

#############################
# 2) Get latest Tailscale   #
#############################
FROM debian:bookworm-slim AS tailscale-builder
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends curl gnupg ca-certificates && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
 && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null \
 && apt-get update \
 && apt-get install -y --no-install-recommends tailscale \
 && rm -rf /var/lib/apt/lists/*

#############################
# 3) Get latest AdGuardHome #
#############################
FROM debian:bookworm-slim AS adgh-builder
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
ARG TARGETARCH
ARG TARGETVARIANT
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl tar && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /out
RUN case "$TARGETARCH" in \
      amd64) agh_arch=amd64 ;; \
      arm64) agh_arch=arm64 ;; \
      arm) \
        case "$TARGETVARIANT" in \
          v7) agh_arch=armv7 ;; \
          v6) agh_arch=armv6 ;; \
          *) echo "Unsupported ARM variant: TARGETVARIANT=$TARGETVARIANT" >&2; exit 1 ;; \
        esac ;; \
      *) echo "Unsupported architecture: TARGETARCH=$TARGETARCH TARGETVARIANT=$TARGETVARIANT" >&2; exit 1 ;; \
    esac; \
    curl -fL --retry 5 --retry-delay 2 "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${agh_arch}.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 0755 /tmp/AdGuardHome/AdGuardHome /out/AdGuardHome

#############################
# 4) Final distroless image #
#############################
FROM gcr.io/distroless/base-debian12
COPY --from=tailscale-builder   /usr/sbin/tailscaled    /usr/bin/tailscaled
COPY --from=tailscale-builder   /usr/bin/tailscale      /usr/bin/tailscale
COPY --from=adgh-builder        /out/AdGuardHome        /usr/local/bin/AdGuardHome
COPY --from=entrypoint-builder  /out/entrypoint         /entrypoint

WORKDIR /
ENV PATH=/usr/bin:/usr/local/bin
# Single base data dir (override with DATA_DIR if needed)
ENV DATA_DIR=/data
# Defaults (can be overridden). If TS_STATE_DIR is unset, entrypoint will use $DATA_DIR/tailscale.
ENV TS_SOCKET=/var/run/tailscale/tailscaled.sock \
    TS_USERSPACE=true \
    TS_ACCEPT_DNS=false \
    TS_AUTH_ONCE=false

# Single volume
VOLUME ["/data"]

# DNS and AdGuardHome UI (default first-run UI port 3000)
EXPOSE 53/tcp 53/udp 3000/tcp

ENTRYPOINT ["/entrypoint"]