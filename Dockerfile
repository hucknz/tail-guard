# Multi-stage build for rootless, distroless AdGuard Home with Tailscale
FROM golang:1.21-alpine AS adguard-builder

# Install build dependencies
RUN apk add --no-cache git make npm

# Set working directory
WORKDIR /src

# Clone AdGuard Home source
ARG ADGUARD_VERSION=v0.107.43
RUN git clone --branch ${ADGUARD_VERSION} --depth 1 https://github.com/AdguardTeam/AdGuardHome.git .

# Build AdGuard Home
RUN make build-release

# Tailscale stage
FROM alpine:latest AS tailscale-builder

ARG TAILSCALE_VERSION=1.54.0
RUN apk add --no-cache curl
RUN curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_linux_amd64.tgz" | tar xzv --strip-components=1
RUN chmod +x tailscale tailscaled

# Final distroless stage
FROM gcr.io/distroless/static-debian12:nonroot

# Copy AdGuard Home binary
COPY --from=adguard-builder /src/dist/AdGuardHome/AdGuardHome /usr/local/bin/AdGuardHome

# Copy Tailscale binaries
COPY --from=tailscale-builder /tailscale /usr/local/bin/tailscale
COPY --from=tailscale-builder /tailscaled /usr/local/bin/tailscaled

# Create necessary directories with proper permissions
USER 0
RUN mkdir -p /opt/adguardhome/work /opt/adguardhome/conf /var/lib/tailscale /var/run/tailscale && \
    chown -R 65532:65532 /opt/adguardhome /var/lib/tailscale /var/run/tailscale
USER 65532:65532

# Set working directory
WORKDIR /opt/adguardhome/work

# Create enhanced startup script with all Tailscale parameters
COPY --chown=65532:65532 <<'EOF' /usr/local/bin/start.sh
#!/bin/sh
set -e

# Set defaults for Tailscale parameters
TS_ACCEPT_DNS=${TS_ACCEPT_DNS:-false}
TS_AUTH_ONCE=${TS_AUTH_ONCE:-false}
TS_DEST_IP=${TS_DEST_IP:-}
TS_KUBE_SECRET=${TS_KUBE_SECRET:-tailscale}
TS_HOSTNAME=${TS_HOSTNAME:-}
TS_OUTBOUND_HTTP_PROXY_LISTEN=${TS_OUTBOUND_HTTP_PROXY_LISTEN:-}
TS_ROUTES=${TS_ROUTES:-}
TS_SOCKET=${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}
TS_SOCKS5_SERVER=${TS_SOCKS5_SERVER:-}
TS_STATE_DIR=${TS_STATE_DIR:-/var/lib/tailscale}
TS_USERSPACE=${TS_USERSPACE:-true}
TS_EXTRA_ARGS=${TS_EXTRA_ARGS:-}
TS_TAILSCALED_EXTRA_ARGS=${TS_TAILSCALED_EXTRA_ARGS:-}

# Build tailscaled arguments
TAILSCALED_ARGS="--state=${TS_STATE_DIR}/tailscaled.state --socket=${TS_SOCKET}"

# Add userspace networking if enabled
if [ "$TS_USERSPACE" = "true" ]; then
    TAILSCALED_ARGS="$TAILSCALED_ARGS --tun=userspace-networking"
fi

# Add any extra tailscaled arguments
if [ -n "$TS_TAILSCALED_EXTRA_ARGS" ]; then
    TAILSCALED_ARGS="$TAILSCALED_ARGS $TS_TAILSCALED_EXTRA_ARGS"
fi

# Start Tailscale daemon in background
echo "Starting tailscaled with args: $TAILSCALED_ARGS"
/usr/local/bin/tailscaled $TAILSCALED_ARGS &

# Wait for Tailscale to be ready
sleep 3

# Check if we should authenticate (either no auth key provided, or auth_once is false, or not already logged in)
SHOULD_AUTH=false

if [ -n "$TS_AUTHKEY" ]; then
    if [ "$TS_AUTH_ONCE" = "true" ]; then
        # Check if already logged in
        if ! /usr/local/bin/tailscale --socket="$TS_SOCKET" status >/dev/null 2>&1; then
            SHOULD_AUTH=true
        else
            echo "Already authenticated and TS_AUTH_ONCE=true, skipping authentication"
        fi
    else
        SHOULD_AUTH=true
    fi
fi

# Authenticate with Tailscale if needed
if [ "$SHOULD_AUTH" = "true" ]; then
    echo "Authenticating with Tailscale..."
    
    # Build tailscale up arguments
    UP_ARGS="--authkey=$TS_AUTHKEY"
    
    # Add hostname if specified
    if [ -n "$TS_HOSTNAME" ]; then
        UP_ARGS="$UP_ARGS --hostname=$TS_HOSTNAME"
    fi
    
    # Add accept DNS if enabled
    if [ "$TS_ACCEPT_DNS" = "true" ]; then
        UP_ARGS="$UP_ARGS --accept-dns"
    fi
    
    # Add advertised routes if specified
    if [ -n "$TS_ROUTES" ]; then
        UP_ARGS="$UP_ARGS --advertise-routes=$TS_ROUTES"
    fi
    
    # Add any extra arguments
    if [ -n "$TS_EXTRA_ARGS" ]; then
        UP_ARGS="$UP_ARGS $TS_EXTRA_ARGS"
    fi
    
    echo "Running: tailscale --socket=$TS_SOCKET up $UP_ARGS"
    /usr/local/bin/tailscale --socket="$TS_SOCKET" up $UP_ARGS
fi

# Set up proxies if specified
if [ -n "$TS_SOCKS5_SERVER" ]; then
    echo "Starting SOCKS5 proxy on $TS_SOCKS5_SERVER"
    /usr/local/bin/tailscale --socket="$TS_SOCKET" serve --bg --socks5="$TS_SOCKS5_SERVER" &
fi

if [ -n "$TS_OUTBOUND_HTTP_PROXY_LISTEN" ]; then
    echo "Starting HTTP proxy on $TS_OUTBOUND_HTTP_PROXY_LISTEN"
    /usr/local/bin/tailscale --socket="$TS_SOCKET" serve --bg --http="$TS_OUTBOUND_HTTP_PROXY_LISTEN" &
fi

# Set up destination IP forwarding if specified
if [ -n "$TS_DEST_IP" ]; then
    echo "Setting up traffic forwarding to $TS_DEST_IP"
    # Note: This would typically require additional network configuration
    # and may need custom iptables rules or other networking setup
    echo "Warning: TS_DEST_IP forwarding may require additional network configuration"
fi

echo "Tailscale setup complete. Starting AdGuard Home..."

# Start AdGuard Home
exec /usr/local/bin/AdGuardHome --config /opt/adguardhome/conf/AdGuardHome.yaml --work-dir /opt/adguardhome/work
EOF

RUN chmod +x /usr/local/bin/start.sh

# Set default environment variables
ENV TS_USERSPACE=true \
    TS_AUTH_ONCE=false \
    TS_ACCEPT_DNS=false \
    TS_SOCKET=/var/run/tailscale/tailscaled.sock \
    TS_STATE_DIR=/var/lib/tailscale \
    TS_KUBE_SECRET=tailscale

# Expose ports
EXPOSE 53/tcp 53/udp 67/udp 68/udp 80/tcp 443/tcp 443/udp 3000/tcp 853/tcp

# Enhanced health check that verifies both Tailscale and AdGuard Home
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/bin/sh", "-c", "/usr/local/bin/tailscale --socket=${TS_SOCKET:-/var/run/tailscale/tailscaled.sock} status && curl -f http://localhost:3000/ || exit 1"]

# Set volumes
VOLUME ["/opt/adguardhome/work", "/opt/adguardhome/conf", "/var/lib/tailscale"]

# Start the combined service
ENTRYPOINT ["/usr/local/bin/start.sh"]