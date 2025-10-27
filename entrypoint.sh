#!/bin/sh
# POSIX entrypoint for a distroless image running as root
set -eu

log() { printf '%s %s\n' "$(date -u '+%Y/%m/%d %T')" "$*"; }

# Defaults (override via ENV)
: "${TS_STATE_DIR:=/var/lib/tailscale}"
: "${TS_SOCKET:=/var/run/tailscale/tailscaled.sock}"
: "${TS_KUBE_SECRET:=tailscale}"
: "${TS_USERSPACE:=true}"
: "${TS_ACCEPT_DNS:=false}"

# Resolve and create needed directories
mkdir -p "$(dirname "$TS_SOCKET")" 2>/dev/null || true
mkdir -p "$TS_STATE_DIR" 2>/dev/null || true
mkdir -p /data 2>/dev/null || true

log "Starting with:"
log "  TS_STATE_DIR=$TS_STATE_DIR"
log "  TS_SOCKET=$TS_SOCKET"
log "  DATA_DIR=/data"
log "  TS_USERSPACE=${TS_USERSPACE:-}"
log "  TS_ACCEPT_DNS=${TS_ACCEPT_DNS:-}"

# Build tailscaled extra args (tun mode)
TS_TAILSCALED_EXTRA_ARGS="${TS_TAILSCALED_EXTRA_ARGS:-}"
if [ "${TS_USERSPACE:-true}" = "true" ]; then
  # ensure userspace networking by default (safe for non-NET_ADMIN)
  case " $TS_TAILSCALED_EXTRA_ARGS " in
    *"--tun="*) ;; # user supplied --tun already
    *) TS_TAILSCALED_EXTRA_ARGS="$TS_TAILSCALED_EXTRA_ARGS --tun=userspace-networking" ;;
  esac
fi

# Build tailscale up flags from envs
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

# Start tailscaled (background)
if [ -x /usr/local/bin/tailscaled ]; then
  log "Launching tailscaled: --state=${TS_STATE_DIR}/tailscaled.state --socket=${TS_SOCKET} ${TS_TAILSCALED_EXTRA_ARGS:-}"
  /usr/local/bin/tailscaled \
    --state="${TS_STATE_DIR}/tailscaled.state" \
    --socket="${TS_SOCKET}" \
    ${TS_TAILSCALED_EXTRA_ARGS:-} &
  TAILSCALED_PID=$!
else
  log "Error: tailscaled not found at /usr/local/bin/tailscaled"
  TAILSCALED_PID=0
fi

# Wait for LocalAPI socket to show up (so tailscale up can talk to tailscaled)
wait_for_socket() {
  socket="$1"
  tries=0
  while [ "$tries" -lt 40 ]; do
    if [ -S "$socket" ]; then
      return 0
    fi
    sleep 0.25
    tries=$((tries + 1))
  done
  return 1
}

if [ "$TAILSCALED_PID" -ne 0 ]; then
  if wait_for_socket "$TS_SOCKET"; then
    log "tailscaled LocalAPI socket appeared at $TS_SOCKET"
  else
    log "Warning: tailscaled socket $TS_SOCKET did not appear in time"
  fi
fi

# Bring node up; allow failure without killing container so AdGuard can still start
if [ -x /usr/local/bin/tailscale ]; then
  log "Running: tailscale --socket=${TS_SOCKET} up ${TS_UP_FLAGS} ${TS_AUTH_FLAGS} ${TS_EXTRA}"
  /usr/local/bin/tailscale --socket="${TS_SOCKET}" up ${TS_UP_FLAGS:-} ${TS_AUTH_FLAGS:-} ${TS_EXTRA:-} || log "tailscale up returned non-zero"
else
  log "Warning: tailscale binary not found at /usr/local/bin/tailscale"
fi

# NOTE: TS_DEST_IP (proxy incoming Tailscale traffic to destination IP) requires iptables/nft and NET_ADMIN capabilities.
# If you set TS_DEST_IP you must run the container with NET_ADMIN and ensure iptables/nft commands are available (not included).
if [ -n "${TS_DEST_IP:-}" ]; then
  log "TS_DEST_IP is set to ${TS_DEST_IP}. To enable transparent proxying you must run the container with NET_ADMIN and set up NAT rules on the host or in-container (iptables/nft), which this image does not configure automatically."
fi

# Exec AdGuard Home as PID 1
if [ -x /usr/local/bin/AdGuardHome ]; then
  log "Execing AdGuardHome (work-dir /data)"
  exec /usr/local/bin/AdGuardHome --no-check-update --config /data/AdGuardHome.yaml --work-dir /data
else
  log "Error: AdGuardHome not found at /usr/local/bin/AdGuardHome"
  exit 1
fi