# Multi-stage build for rootless, distroless AdGuard Home with Tailscale
FROM alpine:latest AS version-fetcher

# Install dependencies for API calls
RUN apk add --no-cache curl jq

# Fetch latest versions from GitHub APIs and create download scripts
RUN curl -s https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | \
    jq -r '.tag_name' > /tmp/adguard_version && \
    curl -s https://api.github.com/repos/tailscale/tailscale/releases/latest | \
    jq -r '.tag_name' | sed 's/^v//' > /tmp/tailscale_version && \
    echo "AdGuard version: $(cat /tmp/adguard_version)" && \
    echo "Tailscale version: $(cat /tmp/tailscale_version)"

# AdGuard Home builder stage
FROM golang:1.21-alpine AS adguard-builder

# Copy version info
COPY --from=version-fetcher /tmp/adguard_version /tmp/adguard_version

# Install build dependencies
RUN apk add --no-cache git make npm

# Set working directory
WORKDIR /src

# Clone AdGuard Home source using latest version
RUN ADGUARD_VERSION=$(cat /tmp/adguard_version) && \
    echo "Building AdGuard Home version: $ADGUARD_VERSION" && \
    git clone --branch "$ADGUARD_VERSION" --depth 1 https://github.com/AdguardTeam/AdGuardHome.git .

# Build AdGuard Home
RUN make build-release

# Tailscale stage
FROM alpine:latest AS tailscale-builder

# Copy version info
COPY --from=version-fetcher /tmp/tailscale_version /tmp/tailscale_version

ARG TARGETARCH=amd64

# Install dependencies
RUN apk add --no-cache curl ca-certificates

# Download Tailscale using a script to handle variables properly
RUN TAILSCALE_VERSION=$(cat /tmp/tailscale_version) && \
    echo "Downloading Tailscale version: $TAILSCALE_VERSION for architecture: $TARGETARCH" && \
    DOWNLOAD_URL="https://github.com/tailscale/tailscale/releases/download/v$TAILSCALE_VERSION/tailscale_${TAILSCALE_VERSION}_linux_$TARGETARCH.tgz" && \
    echo "Download URL: $DOWNLOAD_URL" && \
    curl -fsSL "$DOWNLOAD_URL" -o tailscale.tgz && \
    tar xzf tailscale.tgz --strip-components=1 && \
    chmod +x tailscale tailscaled && \
    ls -la tailscale tailscaled && \
    rm tailscale.tgz && \
    echo "Tailscale $TAILSCALE_VERSION downloaded successfully"

# Final distroless stage  
FROM gcr.io/distroless/static-debian12:nonroot

# Copy version files for reference
COPY --from=version-fetcher /tmp/adguard_version /tmp/tailscale_version /opt/versions/

# Copy AdGuard Home binary
COPY --from=adguard-builder /src/dist/AdGuardHome/AdGuardHome /usr/local/bin/AdGuardHome

# Copy Tailscale binaries
COPY --from=tailscale-builder /tailscale /usr/local/bin/tailscale
COPY --from=tailscale-builder /tailscaled /usr/local/bin/tailscaled

# Switch to root to create directories, then back to nonroot
USER 0
RUN mkdir -p /opt/adguardhome/work /opt/adguardhome/conf /var/lib/tailscale /var/run/tailscale /opt/versions && \
    chown -R 65532:65532 /opt/adguardhome /var/lib/tailscale /var/run/tailscale /opt/versions
USER 65532:65532

# Set working directory
WORKDIR /opt/adguardhome/work

# Create enhanced startup script with version info and all Tailscale parameters
COPY --chown=65532:65532 <<'EOF' /usr/local/bin/start.sh
#!/bin/sh
set -e

# Display version information
echo "=== Container Version Information ==="
if [ -f /opt/versions/adguard_version ]; then
    echo "AdGuard Home version: $(cat /opt/versions/adguard_version)"
fi
if [ -f /opt/versions/tailscale_version ]; then
    echo "Tailscale version: $(cat /opt/versions/tailscale_version)"
fi
echo "Build date: 2025-10-24"
echo "====================================="

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

echo "Starting Tailscale with userspace networking..."

# Build tailscaled arguments
TAILSCALED_ARGS="--state=${TS_STATE_DIR}/tailscaled.state --socket=${TS_SOCKET}"

# Add userspace networking if enabled (default for rootless containers)
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
TAILSCALED_PID=$!

# Wait for Tailscale to be ready
echo "Waiting for tailscaled to start..."
sleep 5

# Function to check if tailscale is responsive
check_tailscale() {
    /usr/local/bin/tailscale --socket="$TS_SOCKET" version >/dev/null 2>&1
}

# Wait up to 30 seconds for tailscale to be responsive
TIMEOUT=30
while [ $TIMEOUT -gt 0 ]; do
    if check_tailscale; then
        echo "Tailscale daemon is ready"
        break
    fi
    echo "Waiting for tailscale daemon... ($TIMEOUT seconds remaining)"
    sleep 1
    TIMEOUT=$((TIMEOUT - 1))
done

if [ $TIMEOUT -eq 0 ]; then
    echo "Tailscale daemon failed to start properly"
    exit 1
fi

# Check if we should authenticate
SHOULD_AUTH=false

if [ -n "$TS_AUTHKEY" ]; then
    if [ "$TS_AUTH_ONCE" = "true" ]; then
        # Check if already logged in
        if ! /usr/local/bin/tailscale --socket="$TS_SOCKET" status --json >/dev/null 2>&1; then
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
    
    if [ $? -eq 0 ]; then
        echo "Tailscale authentication successful"
    else
        echo "Tailscale authentication failed"
        exit 1
    fi
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
    echo "Note: TS_DEST_IP forwarding to $TS_DEST_IP requires additional network configuration"
fi

echo "Tailscale setup complete. Starting AdGuard Home..."

# Function to handle shutdown gracefully
cleanup() {
    echo "Shutting down..."
    if [ -n "$TAILSCALED_PID" ]; then
        kill $TAILSCALED_PID 2>/dev/null || true
    fi
    exit 0
}

# Set up signal handlers
trap cleanup TERM INT

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

# Add labels with version info
LABEL org.opencontainers.image.title="AdGuard Home with Tailscale" \
      org.opencontainers.image.description="Rootless, distroless AdGuard Home with Tailscale integration" \
      org.opencontainers.image.authors="hucknz" \
      org.opencontainers.image.created="2025-10-24T04:11:50Z" \
      org.opencontainers.image.source="https://github.com/hucknz/adguard-tailscale"

# Expose ports
EXPOSE 53/tcp 53/udp 67/udp 68/udp 80/tcp 443/tcp 443/udp 3000/tcp 853/tcp

# Enhanced health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/tailscale", "--socket=/var/run/tailscale/tailscaled.sock", "status"]

# Set volumes
VOLUME ["/opt/adguardhome/work", "/opt/adguardhome/conf", "/var/lib/tailscale"]

# Start the combined service
ENTRYPOINT ["/usr/local/bin/start.sh"]