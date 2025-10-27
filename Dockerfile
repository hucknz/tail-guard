# Multi-stage build: builder -> distroless final
FROM debian:stable-slim AS builder

# Install tools (jq for JSON parsing, busybox-static for final /bin/sh)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        tar \
        ca-certificates \
        jq \
        busybox-static && \
    rm -rf /var/lib/apt/lists/*

# Copy the entrypoint early so we can normalize line endings and set executable bit
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

# Prepare a small /artifact/bin with busybox and /bin/sh symlink for final image
RUN mkdir -p /artifact/bin && \
    cp /bin/busybox /artifact/bin/busybox && \
    ln -s busybox /artifact/bin/sh

# Download and extract the latest Tailscale binary (user-provided shortcut to latest)
RUN curl -fsSLo /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_latest_amd64.tgz" && \
    tar -C /tmp -xzf /tmp/tailscale.tgz

# Download and extract the latest AdGuard Home (linux_amd64)
RUN AGH_URL=$(curl -fsS https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | \
      jq -r '.assets[] | select(.name | test("linux_amd64")) | .browser_download_url' | grep -v '\.sig' | head -n1) && \
    curl -fsSLo /tmp/AdGuardHome.tar.gz "$AGH_URL" && \
    tar -C /tmp -xzf /tmp/AdGuardHome.tar.gz

# Ensure binaries are executable
RUN chmod +x /tmp/tailscale*/tailscaled /tmp/tailscale*/tailscale /tmp/AdGuardHome/AdGuardHome || true

# Final (distroless) image
FROM gcr.io/distroless/base-debian12

# Defaults (can be overridden by environment)
ENV TS_STATE_DIR="/var/lib/tailscale" \
    TS_SOCKET="/var/run/tailscale/tailscaled.sock" \
    TS_KUBE_SECRET="tailscale" \
    TS_USERSPACE="true"

# Provide a minimal /bin with busybox so our /entrypoint.sh's shebang works
COPY --from=builder /artifact/bin /bin

# Copy normalized executable entrypoint
COPY --from=builder /entrypoint.sh /entrypoint.sh

# Copy the binaries downloaded in builder
COPY --from=builder /tmp/tailscale*/tailscaled /usr/local/bin/tailscaled
COPY --from=builder /tmp/tailscale*/tailscale /usr/local/bin/tailscale
COPY --from=builder /tmp/AdGuardHome/AdGuardHome /usr/local/bin/AdGuardHome

# Ensure binaries are executable (mode preserved from builder copy)
# Expose common ports used by AdGuard Home and DNS
VOLUME ["/var/lib/tailscale", "/data"]
EXPOSE 53/udp 53/tcp 67/udp 80/tcp 443/tcp 3000/tcp

# Run as non-root user provided by distroless
USER nonroot:nonroot
WORKDIR /home/nonroot

ENTRYPOINT ["/entrypoint.sh"]