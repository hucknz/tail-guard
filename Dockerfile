FROM debian:stable-slim as builder

RUN apt-get update && \
    apt-get install -y curl tar ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Download and extract Tailscale
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list \
    sudo apt-get update \
    sudo apt-get install tailscale

# Download and extract AdGuard Home
RUN AGH_URL=$(curl -s https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | \
    grep browser_download_url | grep linux_amd64 | grep -v .sig | cut -d '"' -f 4) && \
    curl -Lo /tmp/AdGuardHome.tar.gz "$AGH_URL" && \
    tar -C /tmp -xzf /tmp/AdGuardHome.tar.gz

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

FROM gcr.io/distroless/base-debian12

ENV TS_STATE_DIR="/var/lib/tailscale" \
    TS_SOCKET="/var/run/tailscale/tailscaled.sock" \
    TS_KUBE_SECRET="tailscale" \
    TS_USERSPACE="true"

USER nonroot:nonroot
WORKDIR /home/nonroot

COPY --from=builder /tmp/tailscale*/tailscaled /usr/local/bin/
COPY --from=builder /tmp/tailscale*/tailscale /usr/local/bin/
COPY --from=builder /tmp/AdGuardHome/AdGuardHome /usr/local/bin/AdGuardHome
COPY --from=builder /entrypoint.sh /entrypoint.sh

VOLUME ["/var/lib/tailscale", "/data"]

EXPOSE 53/udp 53/tcp 67/udp 80/tcp 443/tcp 3000/tcp

ENTRYPOINT ["/entrypoint.sh"]