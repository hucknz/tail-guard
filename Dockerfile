############################
# 1) Build tiny entrypoint #
############################
FROM golang:1.23-bookworm AS entrypoint-builder
WORKDIR /src
RUN mkdir -p /out
COPY entrypoint/main.go ./main.go
RUN CGO_ENABLED=0 GOFLAGS="-trimpath" go build -ldflags="-s -w" -o /out/entrypoint ./main.go

#############################
# 2) Get latest Tailscale   #
#############################
FROM debian:bookworm-slim AS tailscale-builder
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends curl gnupg ca-certificates
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
 && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null \
 && apt-get update \
 && apt-get install -y --no-install-recommends tailscale

#############################
# 3) Get latest AdGuardHome #
#############################
FROM debian:bookworm-slim AS adgh-builder
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
ARG TARGETARCH
ARG TARGETVARIANT
# Pin a specific release (e.g. v0.107.55) for reproducible, cache-friendly builds.
# Defaults to "latest" to preserve existing behavior.
ARG ADGUARDHOME_VERSION=latest
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends ca-certificates curl tar
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
    if [ "$ADGUARDHOME_VERSION" = "latest" ]; then \
      agh_url="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${agh_arch}.tar.gz"; \
    else \
      agh_url="https://github.com/AdguardTeam/AdGuardHome/releases/download/${ADGUARDHOME_VERSION}/AdGuardHome_linux_${agh_arch}.tar.gz"; \
    fi; \
    curl -fL --retry 5 --retry-delay 2 "$agh_url" | tar -xz -C /tmp; \
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

# Tune the Go runtime (tailscaled, AdGuardHome, and entrypoint are all Go binaries)
# for small, single-core hosts (~1 vCPU / 256MB):
#  - GOMAXPROCS avoids spinning up scheduler threads for cores that aren't available.
#  - GOMEMLIMIT gives the GC a soft ceiling so it paces itself instead of growing the
#    heap until the container's hard memory limit triggers an OOM kill.
#  - GODEBUG=madvdontneed=1 makes freed memory return to the OS immediately instead
#    of lingering resident (and counted against the cgroup limit) under MADV_FREE.
# Override any of these at runtime if you have more headroom.
ENV GOMAXPROCS=1 \
    GOMEMLIMIT=150MiB \
    GODEBUG=madvdontneed=1

# Single volume
VOLUME ["/data"]

# DNS and AdGuardHome UI (default first-run UI port 3000)
EXPOSE 53/tcp 53/udp 3000/tcp

ENTRYPOINT ["/entrypoint"]