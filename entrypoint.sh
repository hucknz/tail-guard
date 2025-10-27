#!/bin/sh
# POSIX entrypoint, intended for a distroless final image with /bin/sh provided
set -eu

# Defaults (can be overridden via env)
: "${TS_STATE_DIR:=/var/lib/tailscale}"
: "${TS_SOCKET:=/var/run/tailscale/tailscaled.sock}"
: "${TS_KUBE_SECRET:=tailscale}"
: "${TS_USERSPACE:=true}"
: "${TS_ACCEPT_DNS:=false}"

# Helper: try to create target dir, on failure return fallback path (but do not exit)
ensure_dir_or_fallback() {
  target="$1"        # full path to create, e.g. /var/lib/tailscale
  fallback_sub="$2"  # fallback subdir under HOME, e.g. .tailscale

  if mkdir -p "$target" 2>/dev/null; then
    printf '%s' "$target"
    return 0
  fi

  # fallback to $HOME/<sub> or /tmp/<sub> if HOME unset
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

# Ensure TS_STATE_DIR or fallback
TS_STATE_DIR_RESOLVED=$(ensure_dir_or_fallback "$TS_STATE_DIR" ".tailscale")
TS_STATE_DIR="$TS_STATE_DIR_RESOLVED"

# Ensure socket dir exists or fall back and move socket inside fallback dir
TS_SOCKET_DIR="$(dirname "$TS_SOCKET")"
if mkdir -p "$TS_SOCKET_DIR" 2>/dev/null; then
  :
else
  fb="$(ensure_dir_or_fallback "$TS_SOCKET_DIR" ".tailscale")" || true
  TS_SOCKET="$fb/tailscaled.sock"
  echo "Info: TS_SOCKET set to $TS_SOCKET" >&2
fi

# Ensure final state dir exists
mkdir -p "$TS_STATE_DIR" 2>/dev/null || true

# Ensure /data or fallback to home data dir
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

# Build flags for tailscale/tailscaled
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

TS_UP_FLAGS=""
if [ "${TS_ACCEPT_DNS}" = "true" ]; then
  TS_UP_FLAGS="$TS_UP_FLAGS --accept-dns"
fi

if [ "${TS_USERSPACE:-true}" = "true" ]; then
  TS_TAILSCALED_EXTRA_ARGS="${TS_TAILSCALED_EXTRA_ARGS:-} --tun=userspace-networking"
fi

# Start tailscaled in background (non-blocking)
# Ensure parent dir for state file exists
mkdir -p "$(dirname "${TS_STATE_DIR}/tailscaled.state")" 2>/dev/null || true

# Run tailscaled if binary exists
if [ -x /usr/local/bin/tailscaled ]; then
  /usr/local/bin/tailscaled \
    --state="${TS_STATE_DIR}/tailscaled.state" \
    --socket="${TS_SOCKET}" \
    ${TS_TAILSCALED_EXTRA_ARGS:-} &
  # give tailscaled a moment to initialize
  sleep 1
else
  echo "Warning: tailscaled binary not found at /usr/local/bin/tailscaled" >&2
fi

# Attempt to bring the node up; ignore failure to avoid container crash on misconfig
if [ -x /usr/local/bin/tailscale ]; then
  /usr/local/bin/tailscale --socket="${TS_SOCKET}" up ${TS_UP_FLAGS:-} ${TS_AUTH_FLAGS:-} ${TS_EXTRA:-} || true
else
  echo "Warning: tailscale binary not found at /usr/local/bin/tailscale" >&2
fi

# Exec AdGuard Home as PID 1
if [ -x /usr/local/bin/AdGuardHome ]; then
  exec /usr/local/bin/AdGuardHome --no-check-update --config "${DATA_DIR}/AdGuardHome.yaml" --work-dir "${DATA_DIR}"
else
  echo "Error: AdGuardHome binary not found at /usr/local/bin/AdGuardHome" >&2
  exit 1
fi