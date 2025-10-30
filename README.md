# tail-guard
Tailscale® meets Adguard in a tiny Docker container. 

# Purpose
I wanted a simple and lightweight way to deploy Tailscale exit nodes & Adguard ad blocking to low powered (1 shared CPU, 265mb memory) VPS's around the world. I have these running on the fly.io legacy free tier but they should work anywhere containers are run. 

# Getting started
Tail-guard takes the same environment variables as the official Tailscale Docker container. 

*Note:* I haven't thoroughly tested all flags so you may find bugs. 

## Tail-guard specific flags:
`MODIFY_RESOLVCONF`: Some hosts need the resolv.conf to be modified to listen on 127.0.0.1/::1 or Adguard won't receive local queries. Defaults to false. 

## Tailscale flags:
`TS_ACCEPT_DNS`: Accept DNS configuration from the admin console. Not accepted by default.
`TS_AUTH_ONCE`: Attempt to log in only if not already logged in. False by default, to forcibly log in every time the container starts.
`TS_AUTHKEY`: A Tailscale auth key⁠ used to authenticate the container.
`TS_DEST_IP`: Proxy all incoming Tailscale traffic to the specified destination IP.
`TS_KUBE_SECRET`: If running in Kubernetes, the Kubernetes secret name where Tailscale state is stored. The default is tailscale.
`TS_HOSTNAME`: Use the specified hostname for the node.
`TS_OUTBOUND_HTTP_PROXY_LISTEN`: Set an address and port for the HTTP proxy⁠.
`TS_ROUTES`: Advertises subnet routes⁠. Equivalent to tailscale set --advertise-routes=. To accept advertised routes, use TS_EXTRA_ARGS to pass in --accept-routes.
`TS_SOCKET`: Unix socket path used by the Tailscale binary, where the tailscaled LocalAPI socket is created. The default is /var/run/tailscale/tailscaled.sock.
`TS_SOCKS5_SERVER`: Set an address and port for the SOCKS5 proxy⁠.
`TS_STATE_DIR`: Directory where the state of tailscaled is stored. This needs to persist across container restarts.
`TS_USERSPACE`: Enable userspace networking⁠, instead of kernel networking. Enabled by default.
`TS_EXTRA_ARGS`: any other CLI flags for tailscale set
`TS_TAILSCALED_EXTRA_ARGS`: any other flags for tailscaled

# Docker compose example
```
  tail-guard:
    image: ghcr.io/hucknz/tail-guard:latest
    container_name: tail-guard
    environment:
      - TS_AUTHKEY='tskey-auth-'
      - TS_HOSTNAME='tail-guard'
      - TS_EXTRA_ARGS= '--advertise-exit-node --accept-routes'
    restart: unless-stopped
    volumes:
      - /tailguard/tailscale:/data/tailscale
      - /tailguard/adguardhome/work:/data/adguard/work
      - /tailguard/adguardhome/conf:/data/adguard/conf
    ports:
      - '53:53/udp'
      - '53:53/tcp'
      - '3000:3000/tcp'
      - '8008:80/tcp'
```

# Known issues
* Most queries in Adguard show as coming from 127.0.0.1. It works, it just won't give you the source IP address. 

If you find any other problems feel free to raise an issue. 