FROM debian:stable-slim as builder

# Install tools and busybox static to copy into final image
RUN apt-get update && \
    apt-get install -y curl tar ca-certificates jq busybox-static && \
    rm -rf /var/lib/apt/lists/*

# Copy entrypoint early so we can normalize line endings and chmod it
COPY entrypoint.sh /entrypoint.sh
# Normalize CRLF -> LF and make executable
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

# Prepare a small artifact containing a /bin with busybox and /bin/sh symlink
RUN mkdir -p /artifact/bin && \
    cp /bin/busybox /artifact/bin/busybox && \
    ln -s busybox /artifact/bin/sh

# Download and extract Tailscale
RUN curl -Lo /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_latest_amd64.tgz" && \
    tar -C /tmp -xzf /tmp/tailscale.tgz

# Download and extract AdGuard Home (latest linux amd64)
RUN AGH_URL=$(curl -s https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | \
    grep browser_download_url | grep linux_amd64 | grep -v .sig | cut -d '"' -f 4) && \
    curl -Lo /tmp/AdGuardHome.tar.gz "$AGH_URL" && \
    tar -C /tmp -xzf /tmp/AdGuardHome.tar.gz

FROM gcr.io/distroless/base-debian12

ENV TS_STATE_DIR="/var/lib/tailscale" \
    TS_SOCKET="/var/run/tailscale/tailscaled.sock" \
    TS_KUBE_SECRET="tailscale" \
    TS_USERSPACE="true"

# Make /bin available for the copied busybox
COPY --from=builder /artifact/bin /bin

# Copy the normalized, executable entrypoint
COPY --from=builder /entrypoint.sh /entrypoint.sh

# Copy binaries
COPY --from=builder /tmp/tailscale*/tailscaled /usr/local/bin/tailscaled
COPY --from=builder /tmp/tailscale*/tailscale /usr/local/bin/tailscale
COPY --from=builder /tmp/AdGuardHome/AdGuardHome /usr/local/bin/AdGuardHome

# Volumes and ports
VOLUME ["/var/lib/tailscale", "/data"]

EXPOSE 53/udp 53/tcp 67/udp 80/tcp 443/tcp 3000/tcp

# Run as non-root
USER nonroot:nonroot
WORKDIR /home/nonroot

ENTRYPOINT ["/entrypoint.sh"]