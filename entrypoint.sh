#!/bin/sh
# POSIX entrypoint for AdGuard Home + Tailscale (Option A)
set -eu

# Defaults (can be overridden via env)
: "${TS_STATE_DIR:=/var/lib/tailscale}"
: "${TS_SOCKET:=/var/run/tailscale/tailscaled.sock}"
: "${TS_KUBE_SECRET:=tailscale}"
: "${TS_USERSPACE:=true}"
: "${TS_ACCEPT_DNS:=false}"

# Helper: try to create target dir, on failure return fallback path
ensure_dir_or_fallback() {
  target="$1"
  fallback_sub="$2"

  if mkdir -p "$target" 2>/dev/null; then
    printf '%s' "$target"
    return 0
  fi

  if [ -n "${HOME:-}" ]; then
    fb="$HOME/$fallback_sub"
  else
    fb="/tmp/$fallback_sub"
  fi

  mkdir -p "$fb" 2>/dev/null || true
  echo "Warning: cannot create $target, falling back to $fb" >&2
  printf '%s' "$fb"
  return 1
}

# Resolve state dir and socket parent BEFORE starting tailscaled
TS_STATE_DIR="$(ensure_dir_or_fallback "$TS_STATE_DIR" ".tailscale")"
TS_SOCKET_DIR="$(dirname "$TS_SOCKET")"
if mkdir -p "$TS_SOCKET_DIR" 2>/dev/null; then
  :
else
  fb="$(ensure_dir_or_fallback "$TS_SOCKET_DIR" ".tailscale")" || true
  TS_SOCKET="${fb}/tailscaled.sock"
  echo "Info: TS_SOCKET set to $TS_SOCKET" >&2
fi

# Ensure final dirs exist
mkdir -p "$TS_STATE_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$TS_SOCKET")" 2>/dev/null || true

# Data dir (AdGuard)
if mkdir -p /data 2>/dev/null; then
  DATA_DIR="/data"
else
  if [ -n "${HOME:-}" ]; then
    DATA_DIR="$HOME/data"
  else
    DATA_DIR="/tmp/data"
  fi
  mkdir -p "$DATA_DIR" 2>/dev/null || true
  echo "Info: using data dir $DATA_DIR" >&2
fi

# Build Tailscale flags
TS_AUTH_FLAGS=""
[ "${TS_AUTH_ONCE:-false}" = "true" ] && TS_AUTH_FLAGS="$TS_AUTH_FLAGS --auth-once"
[ -n "${TS_AUTHKEY:-}" ] && TS_AUTH_FLAGS="$TS_AUTH_FLAGS --authkey=${TS_AUTHKEY}"
[ -n "${TS_HOSTNAME:-}" ] && TS_AUTH_FLAGS="$TS_AUTH_FLAGS --hostname=${TS_HOSTNAME}"

TS_EXTRA="${TS_EXTRA_ARGS:-}"
[ -n "${TS_ROUTES:-}" ] && TS_EXTRA="$TS_EXTRA --advertise-routes=${TS_ROUTES}"
[ -n "${TS_OUTBOUND_HTTP_PROXY_LISTEN:-}" ] && TS_EXTRA="$TS_EXTRA --outbound-http-proxy-listen=${TS_OUTBOUND_HTTP_PROXY_LISTEN}"
[ -n "${TS_SOCKS5_SERVER:-}" ] && TS_EXTRA="$TS_EXTRA --socks5-server=${TS_SOCKS5_SERVER}"

TS_UP_FLAGS=""
[ "${TS_ACCEPT_DNS:-false}" = "true" ] && TS_UP_FLAGS="$TS_UP_FLAGS --accept-dns"

if [ "${TS_USERSPACE:-true}" = "true" ]; then
  TS_TAILSCALED_EXTRA_ARGS="${TS_TAILSCALED_EXTRA_ARGS:-} --tun=userspace-networking"
fi

# Start tailscaled with the resolved state/socket
if [ -x /usr/local/bin/tailscaled ]; then
  /usr/local/bin/tailscaled \
    --state="${TS_STATE_DIR}/tailscaled.state" \
    --socket="${TS_SOCKET}" \
    ${TS_TAILSCALED_EXTRA_ARGS:-} &
else
  echo "Warning: tailscaled binary not found at /usr/local/bin/tailscaled" >&2
fi

# Wait for tailscaled LocalAPI socket to appear (up to ~10s)
wait_for_socket() {
  socket="$1"
  tries=0
  while [ "$tries" -lt 20 ]; do
    if [ -S "$socket" ]; then
      return 0
    fi
    sleep 0.25
    tries=$((tries + 1))
  done
  return 1
}

if ! wait_for_socket "$TS_SOCKET"; then
  echo "Warning: tailscaled socket $TS_SOCKET did not appear in time" >&2
fi

# Attempt to bring the node up; ignore failure to avoid container crash
if [ -x /usr/local/bin/tailscale ]; then
  /usr/local/bin/tailscale --socket="${TS_SOCKET}" up ${TS_UP_FLAGS:-} ${TS_AUTH_FLAGS:-} ${TS_EXTRA:-} || true
else
  echo "Warning: tailscale binary not found at /usr/local/bin/tailscale" >&2
fi

# Finally start AdGuard Home as PID 1
if [ -x /usr/local/bin/AdGuardHome ]; then
  exec /usr/local/bin/AdGuardHome --no-check-update --config "${DATA_DIR}/AdGuardHome.yaml" --work-dir "${DATA_DIR}"
else
  echo "Error: AdGuardHome binary not found at /usr/local/bin/AdGuardHome" >&2
  exit 1
fi