#!/bin/sh
set -eu

# Default environment variables
: "${TS_STATE_DIR:=/var/lib/tailscale}"
: "${TS_SOCKET:=/var/run/tailscale/tailscaled.sock}"
: "${TS_KUBE_SECRET:=tailscale}"
: "${TS_USERSPACE:=true}"

mkdir -p "$TS_STATE_DIR"
mkdir -p "$(dirname "$TS_SOCKET")"

# Normalize optional flags
TS_AUTH_FLAGS=""
if [ "${TS_AUTH_ONCE:-false}" = "true" ]; then
  TS_AUTH_FLAGS="$TS_AUTH_FLAGS --auth-once"
fi
if [ -n "${TS_AUTHKEY:-}" ]; then
  TS_AUTH_FLAGS="$TS_AUTH_FLAGS --authkey=${TS_AUTHKEY}"
fi
if [ -n "${TS_HOSTNAME:-}" ]; then
  TS_AUTH_FLAGS="$TS_AUTH_FLAGS --hostname=${TS_HOSTNAME}"
fi

TS_EXTRA="${TS_EXTRA_ARGS:-}"
if [ -n "${TS_ROUTES:-}" ]; then
  TS_EXTRA="$TS_EXTRA --advertise-routes=${TS_ROUTES}"
fi
if [ -n "${TS_OUTBOUND_HTTP_PROXY_LISTEN:-}" ]; then
  TS_EXTRA="$TS_EXTRA --outbound-http-proxy-listen=${TS_OUTBOUND_HTTP_PROXY_LISTEN}"
fi
if [ -n "${TS_SOCKS5_SERVER:-}" ]; then
  TS_EXTRA="$TS_EXTRA --socks5-server=${TS_SOCKS5_SERVER}"
fi
if [ "${TS_ACCEPT_DNS:-false}" = "true" ]; then
  # note: accept-dns semantics may require --accept-dns to be true/false depending on CLI; adjust if needed
  TS_UP_FLAGS="$TS_UP_FLAGS --accept-dns"
fi

# Userspace networking
if [ "${TS_USERSPACE:-true}" = "true" ]; then
  TS_TAILSCALED_EXTRA_ARGS="${TS_TAILSCALED_EXTRA_ARGS:-} --tun=userspace-networking"
fi

# Start tailscaled in the background
/usr/local/bin/tailscaled \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket="${TS_SOCKET}" \
  ${TS_TAILSCALED_EXTRA_ARGS:-} &

# Give tailscaled a moment to start the socket
sleep 1

# Bring the node up (auth flags may be empty)
if [ -n "${TS_AUTH_FLAGS}${TS_UP_FLAGS}${TS_EXTRA}" ]; then
  /usr/local/bin/tailscale --socket="${TS_SOCKET}" up ${TS_UP_FLAGS:-} ${TS_AUTH_FLAGS:-} ${TS_EXTRA:-} || true
fi

# Start AdGuard Home (exec so it becomes PID 1)
exec /usr/local/bin/AdGuardHome --no-check-update --config /data/AdGuardHome.yaml --work-dir /data