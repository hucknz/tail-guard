#!/bin/sh
set -eu

# Tailscale state directory
export TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
export TS_SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"
export TS_KUBE_SECRET="${TS_KUBE_SECRET:-tailscale}"
export TS_USERSPACE="${TS_USERSPACE:-true}"

mkdir -p "$TS_STATE_DIR"
mkdir -p "$(dirname "$TS_SOCKET")"

TS_AUTH_FLAGS=""
[ "${TS_AUTH_ONCE:-false}" = "true" ] && TS_AUTH_FLAGS="$TS_AUTH_FLAGS --auth-once"
[ -n "${TS_AUTHKEY:-}" ] && TS_AUTH_FLAGS="$TS_AUTH_FLAGS --authkey=${TS_AUTHKEY}"
[ -n "${TS_HOSTNAME:-}" ] && TS_AUTH_FLAGS="$TS_AUTH_FLAGS --hostname=${TS_HOSTNAME}"

[ -n "${TS_ROUTES:-}" ] && TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-} --advertise-routes=${TS_ROUTES}"
[ -n "${TS_OUTBOUND_HTTP_PROXY_LISTEN:-}" ] && TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-} --outbound-http-proxy-listen=${TS_OUTBOUND_HTTP_PROXY_LISTEN}"
[ -n "${TS_SOCKS5_SERVER:-}" ] && TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-} --socks5-server=${TS_SOCKS5_SERVER}"

# Accept DNS config if requested
TS_UP_FLAGS=""
[ "${TS_ACCEPT_DNS:-false}" = "true" ] && TS_UP_FLAGS="$TS_UP_FLAGS --accept-dns=false"

# Userspace networking
[ "${TS_USERSPACE:-true}" = "true" ] && TS_TAILSCALED_EXTRA_ARGS="${TS_TAILSCALED_EXTRA_ARGS:-} --tun=userspace-networking"

# Start tailscaled in background
/usr/local/bin/tailscaled \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket="${TS_SOCKET}" \
  ${TS_TAILSCALED_EXTRA_ARGS:-} &

sleep 2

# Authenticate and bring up Tailscale
/usr/local/bin/tailscale --socket="${TS_SOCKET}" up \
  $TS_UP_FLAGS $TS_AUTH_FLAGS ${TS_EXTRA_ARGS:-}

# If TS_DEST_IP is set, proxy all Tailscale traffic to it (iptables or similar - not possible in distroless, so this part needs to be handled externally or with a custom proxy binary)

# Start AdGuard Home
exec /usr/local/bin/AdGuardHome --no-check-update --config /data/AdGuardHome.yaml --work-dir /data