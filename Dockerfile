# Distroless image running Tailscale + AdGuardHome
# - Latest Tailscale via official apt repo (builder)
# - Latest AdGuardHome via GitHub "latest/download" (builder, multi-arch)
# - Minimal Go entrypoint orchestrating both processes
# - Supports envs: TS_ACCEPT_DNS, TS_AUTH_ONCE, TS_AUTHKEY, TS_DEST_IP (warn),
#   TS_KUBE_SECRET (warn), TS_HOSTNAME, TS_OUTBOUND_HTTP_PROXY_LISTEN, TS_ROUTES,
#   TS_SOCKET, TS_SOCKS5_SERVER, TS_STATE_DIR, TS_USERSPACE (default true),
#   TS_EXTRA_ARGS, TS_TAILSCALED_EXTRA_ARGS

############################
# 1) Build tiny entrypoint #
############################
FROM golang:1.23-bookworm AS entrypoint-builder
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
WORKDIR /src
RUN mkdir -p /out
# Write the entrypoint source
RUN cat > main.go <<'GO'
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func strBoolEnv(k string, def bool) bool {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	switch strings.ToLower(v) {
	case "1", "t", "true", "y", "yes", "on":
		return true
	default:
		return false
	}
}

func splitArgs(s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	return strings.Fields(s)
}

func waitFor(cmdName string, args []string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		cmd := exec.CommandContext(ctx, cmdName, args...)
		_ = cmd.Run()
		cancel()
		if cmd.ProcessState != nil && cmd.ProcessState.ExitCode() == 0 {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s %v not ready after %s", cmdName, args, timeout)
		}
		time.Sleep(300 * time.Millisecond)
	}
}

func pipeOutput(prefix string, r io.Reader) {
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := r.Read(buf)
			if n > 0 {
				lines := strings.Split(string(buf[:n]), "\n")
				for _, ln := range lines {
					if strings.TrimSpace(ln) == "" {
						continue
					}
					log.Printf("%s%s", prefix, ln)
				}
			}
			if err != nil {
				return
			}
		}
	}()
}

func startProc(name string, args ...string) (*exec.Cmd, error) {
	cmd := exec.Command(name, args...)
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	pipeOutput(fmt.Sprintf("[%s] ", filepath.Base(name)), stdout)
	pipeOutput(fmt.Sprintf("[%s] ", filepath.Base(name)), stderr)
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return cmd, nil
}

func main() {
	log.SetFlags(0)

	// Env with defaults
	tsStateDir := getenv("TS_STATE_DIR", "/var/lib/tailscale")
	tsSocket := getenv("TS_SOCKET", "/var/run/tailscale/tailscaled.sock")
	tsUserspace := strBoolEnv("TS_USERSPACE", true)
	tsAuthOnce := strBoolEnv("TS_AUTH_ONCE", false)
	tsAcceptDNS := strBoolEnv("TS_ACCEPT_DNS", false)
	tsAuthKey := os.Getenv("TS_AUTHKEY")
	tsRoutes := os.Getenv("TS_ROUTES")
	tsHost := os.Getenv("TS_HOSTNAME")
	tsSocks5 := os.Getenv("TS_SOCKS5_SERVER")
	tsHTTPProxy := os.Getenv("TS_OUTBOUND_HTTP_PROXY_LISTEN")
	tsExtraArgs := splitArgs(os.Getenv("TS_EXTRA_ARGS")) // to tailscale set
	tsTailscaledExtra := splitArgs(os.Getenv("TS_TAILSCALED_EXTRA_ARGS"))
	tsDestIP := os.Getenv("TS_DEST_IP")
	tsKubeSecret := os.Getenv("TS_KUBE_SECRET") // not implemented; warn only

	// Prepare dirs
	_ = os.MkdirAll(tsStateDir, 0700)
	_ = os.MkdirAll("/var/run/tailscale", 0755)
	_ = os.MkdirAll("/opt/adguardhome/work", 0755)
	_ = os.MkdirAll("/opt/adguardhome/conf", 0755)

	if tsDestIP != "" {
		log.Printf("[warn] TS_DEST_IP is not supported in this minimal distroless image (no iptables). Ignoring value: %q", tsDestIP)
	}
	if tsKubeSecret != "" {
		log.Printf("[warn] TS_KUBE_SECRET is not implemented in this image. Mount a Kubernetes Secret to TS_STATE_DIR instead. Ignoring value: %q", tsKubeSecret)
	}

	// 1) Start tailscaled
	tsdArgs := []string{
		"--state=" + filepath.Join(tsStateDir, "tailscaled.state"),
		"--socket=" + tsSocket,
	}
	if tsUserspace {
		tsdArgs = append(tsdArgs, "--tun=userspace-networking")
	}
	tsdArgs = append(tsdArgs, tsTailscaledExtra...)

	tsd, err := startProc("/usr/bin/tailscaled", tsdArgs...)
	if err != nil {
		log.Fatalf("failed to start tailscaled: %v", err)
	}

	// Ensure the LocalAPI is reachable (daemon ready), even if not logged in yet.
	// Use "version" (always zero exit when daemon reachable) instead of "status" (non-zero when NeedsLogin).
	if err := waitFor("/usr/bin/tailscale", []string{"--socket=" + tsSocket, "version"}, 30*time.Second); err != nil {
		log.Fatalf("tailscaled not ready: %v", err)
	}

	// 2) tailscale up (unless already logged in and TS_AUTH_ONCE)
	alreadyUp := func() bool {
		// "status" still useful to detect a fully running node; ignore output.
		cmd := exec.Command("/usr/bin/tailscale", "--socket="+tsSocket, "status", "--peers=false")
		return cmd.Run() == nil
	}()

	shouldUp := true
	if tsAuthOnce && alreadyUp {
		log.Printf("TS_AUTH_ONCE=true and Tailscale already up; skipping 'tailscale up'")
		shouldUp = false
	}

	if shouldUp {
		upArgs := []string{"--socket=" + tsSocket, "up"}
		upArgs = append(upArgs, fmt.Sprintf("--accept-dns=%v", tsAcceptDNS))
		if tsUserspace {
			upArgs = append(upArgs, "--tun=userspace-networking")
		}
		if tsAuthKey != "" {
			upArgs = append(upArgs, "--authkey="+tsAuthKey)
		}
		if tsHost != "" {
			upArgs = append(upArgs, "--hostname="+tsHost)
		}
		if tsRoutes != "" {
			upArgs = append(upArgs, "--advertise-routes="+tsRoutes)
		}
		if tsSocks5 != "" {
			upArgs = append(upArgs, "--socks5-server="+tsSocks5)
		}
		if tsHTTPProxy != "" {
			upArgs = append(upArgs, "--outbound-http-proxy-listen="+tsHTTPProxy)
		}
		cmd := exec.Command("/usr/bin/tailscale", upArgs...)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		log.Printf("Running: tailscale %s", strings.Join(upArgs, " "))
		if err := cmd.Run(); err != nil {
			log.Printf("[error] tailscale up failed: %v", err)
			// If no authkey was provided, this may require interactive login; container keeps running.
		}
	}

	// 3) Apply extra 'tailscale set' arguments, if provided
	if len(tsExtraArgs) > 0 {
		args := append([]string{"--socket=" + tsSocket, "set"}, tsExtraArgs...)
		cmd := exec.Command("/usr/bin/tailscale", args...)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		log.Printf("Running: tailscale %s", strings.Join(args, " "))
		if err := cmd.Run(); err != nil {
			log.Printf("[warn] tailscale set failed: %v", err)
		}
	}

	// 4) Start AdGuardHome
	aghArgs := []string{
		"--no-check-update",
		"--work-dir", "/opt/adguardhome/work",
		"--config", "/opt/adguardhome/conf/AdGuardHome.yaml",
	}
	agh, err := startProc("/usr/local/bin/AdGuardHome", aghArgs...)
	if err != nil {
		log.Fatalf("failed to start AdGuardHome: %v", err)
	}

	// 5) Signal handling and wait
	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	var exitErr error

waitLoop:
	for {
		select {
		case sig := <-sigCh:
			log.Printf("received signal: %s, forwarding to children", sig)
			_ = tsd.Process.Signal(sig)
			_ = agh.Process.Signal(sig)
		default:
			if tsd.ProcessState != nil && tsd.ProcessState.Exited() {
				exitErr = errors.New("tailscaled exited")
				break waitLoop
			}
			if agh.ProcessState != nil && agh.ProcessState.Exited() {
				exitErr = errors.New("AdGuardHome exited")
				break waitLoop
			}
			time.Sleep(300 * time.Millisecond)
		}
	}

	_, _ = tsd.Process.Wait()
	_, _ = agh.Process.Wait()

	if exitErr != nil {
		log.Fatalf("exiting: %v", exitErr)
	}
}
GO
# Build the entrypoint without requiring a go.mod
RUN CGO_ENABLED=0 GOFLAGS="-trimpath" go build -ldflags="-s -w" -o /out/entrypoint ./main.go

#############################
# 2) Get latest Tailscale   #
#############################
FROM debian:bookworm-slim AS tailscale-builder
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends curl gnupg ca-certificates && rm -rf /var/lib/apt/lists/*
# Add Tailscale apt repo and install latest stable
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
 && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null \
 && apt-get update \
 && apt-get install -y --no-install-recommends tailscale \
 && rm -rf /var/lib/apt/lists/*

#############################
# 3) Get latest AdGuardHome #
#############################
FROM debian:bookworm-slim AS adgh-builder
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
ARG TARGETARCH
ARG TARGETVARIANT
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl tar && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /out
# Use buildx-provided TARGETARCH/TARGETVARIANT to choose the correct asset
RUN case "$TARGETARCH" in \
      amd64) agh_arch=amd64 ;; \
      arm64) agh_arch=arm64 ;; \
      arm) \
        case "$TARGETVARIANT" in \
          v7) agh_arch=armv7 ;; \
          v6) agh_arch=armv6 ;; \
          *) echo "Unsupported ARM variant: TARGETVARIANT=$TARGETVARIANT" >&2; exit 1 ;; \
        esac ;; \
      *) echo "Unsupported architecture: TARGETARCH=$TARGETARCH TARGETVARIANT=$TARGETVARIANT" >&2; exit 1 ;; \
    esac; \
    curl -fL --retry 5 --retry-delay 2 "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${agh_arch}.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 0755 /tmp/AdGuardHome/AdGuardHome /out/AdGuardHome

#############################
# 4) Final distroless image #
#############################
FROM gcr.io/distroless/base-debian12
# Copy binaries
# tailscaled is installed at /usr/sbin/tailscaled in Debian; copy it into /usr/bin in the final image.
COPY --from=tailscale-builder   /usr/sbin/tailscaled    /usr/bin/tailscaled
COPY --from=tailscale-builder   /usr/bin/tailscale     /usr/bin/tailscale
COPY --from=adgh-builder        /out/AdGuardHome       /usr/local/bin/AdGuardHome
COPY --from=entrypoint-builder  /out/entrypoint        /entrypoint

WORKDIR /
ENV PATH=/usr/bin:/usr/local/bin
ENV TS_STATE_DIR=/var/lib/tailscale \
    TS_SOCKET=/var/run/tailscale/tailscaled.sock \
    TS_USERSPACE=true \
    TS_ACCEPT_DNS=false \
    TS_AUTH_ONCE=false

VOLUME ["/var/lib/tailscale", "/opt/adguardhome/work", "/opt/adguardhome/conf"]

# DNS and AdGuardHome UI (default first-run UI port 3000)
EXPOSE 53/tcp 53/udp 3000/tcp

ENTRYPOINT ["/entrypoint"]