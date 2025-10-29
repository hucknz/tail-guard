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

// unquote removes a single pair of matching leading/trailing quotes (' or ")
// without attempting full shell parsing.
func unquote(s string) string {
	if len(s) >= 2 {
		if (s[0] == '\'' && s[len(s)-1] == '\'') || (s[0] == '"' && s[len(s)-1] == '"') {
			return s[1 : len(s)-1]
		}
	}
	return s
}

// splitArgs splits on whitespace and then strips wrapping quotes from each token.
func splitArgs(s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	toks := strings.Fields(s)
	for i := range toks {
		toks[i] = unquote(toks[i])
	}
	return toks
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

func ensureDir(path string, mode os.FileMode) {
	_ = os.MkdirAll(path, mode)
	_ = os.Chmod(path, mode) // enforce mode even if pre-existing (e.g., mounted)
}

// Add after ensuring directories but before starting tailscaled
func setupLocalDNS() error {
    resolv := `nameserver 127.0.0.1
nameserver fdaa::3
`
    return os.WriteFile("/etc/resolv.conf", []byte(resolv), 0644)
}

// wait up to timeout for a Tailscale 100.x IP to be present
func waitForTailscaleIP(socket string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		out, _ := exec.Command("/usr/bin/tailscale", "--socket="+socket, "ip").CombinedOutput()
		s := strings.TrimSpace(string(out))
		// tailscale ip may return multiple addresses; look for the 100.x/100:* family
		if s != "" && (strings.Contains(s, "100.") || strings.Contains(s, "100:")) {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("no tailscale IP after %s: output=%q", timeout, s)
		}
		time.Sleep(300 * time.Millisecond)
	}
}

func main() {
	log.SetFlags(0)

	// Base data dir for everything (single volume)
	dataDir := getenv("DATA_DIR", "/data")

	// Env with defaults
	// If TS_STATE_DIR is unset, store Tailscale state under dataDir/tailscale
	tsStateDir := getenv("TS_STATE_DIR", filepath.Join(dataDir, "tailscale"))
	tsSocket := getenv("TS_SOCKET", "/var/run/tailscale/tailscaled.sock")
	tsUserspace := strBoolEnv("TS_USERSPACE", true)
	tsAuthOnce := strBoolEnv("TS_AUTH_ONCE", false)
	tsAcceptDNS := strBoolEnv("TS_ACCEPT_DNS", false)

	// Unquote single-value envs to be forgiving if users wrap values in '...'/ "..."
	tsAuthKey := unquote(os.Getenv("TS_AUTHKEY"))
	tsRoutes := unquote(os.Getenv("TS_ROUTES"))
	tsHost := unquote(os.Getenv("TS_HOSTNAME"))
	tsSocks5 := unquote(os.Getenv("TS_SOCKS5_SERVER"))
	tsHTTPProxy := unquote(os.Getenv("TS_OUTBOUND_HTTP_PROXY_LISTEN"))
	tsDestIP := unquote(os.Getenv("TS_DEST_IP"))
	tsKubeSecret := unquote(os.Getenv("TS_KUBE_SECRET")) // not implemented; warn only

	// Derive AdGuardHome paths under data dir (can be overridden)
	aghWork := getenv("ADGUARDHOME_WORK_DIR", filepath.Join(dataDir, "adguard", "work"))
	aghConf := getenv("ADGUARDHOME_CONF_DIR", filepath.Join(dataDir, "adguard", "conf"))

	// Args-style envs: split and unquote each token
	tsExtraArgs := splitArgs(os.Getenv("TS_EXTRA_ARGS"))                  // for "tailscale set"
	tsTailscaledExtra := splitArgs(os.Getenv("TS_TAILSCALED_EXTRA_ARGS")) // for "tailscaled"

	// Prepare dirs (AdGuardHome prefers 0700 on work/conf)
	ensureDir(tsStateDir, 0700)
	ensureDir("/var/run/tailscale", 0755)
	ensureDir(aghWork, 0700)
	ensureDir(aghConf, 0700)

	if err := setupLocalDNS(); err != nil {
		log.Printf("[warn] failed to setup local DNS: %v", err)
	}

	if tsDestIP != "" {
		log.Printf("[warn] TS_DEST_IP is not supported in this minimal distroless image (no iptables). Ignoring value: %q", tsDestIP)
	}
	if tsKubeSecret != "" {
		log.Printf("[warn] TS_KUBE_SECRET is not implemented in this image. Mount a Kubernetes Secret to TS_STATE_DIR instead. Ignoring value: %q", tsKubeSecret)
	}

	// 1) Start tailscaled (userspace networking handled here)
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
	if err := waitFor("/usr/bin/tailscale", []string{"--socket=" + tsSocket, "version"}, 30*time.Second); err != nil {
		log.Fatalf("tailscaled not ready: %v", err)
	}

	// 2) tailscale up (unless already logged in and TS_AUTH_ONCE)
	alreadyUp := func() bool {
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
		// Do not pass --tun to "tailscale up"; it's for tailscaled only.
		if tsAuthKey != "" {
			upArgs = append(upArgs, "--auth-key="+tsAuthKey)
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
			// If no auth key is provided, interactive login might be required; container keeps running.
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

	// after tailscale up and any set commands:
	if err := waitForTailscaleIP(tsSocket, 10*time.Second); err != nil {
		log.Printf("[warn] tailscale IP not found: %v — continuing, but DNS routing may fail", err)
	} else {
		log.Printf("[info] tailscale IP detected; starting AdGuard")
	}

	// 4) Start AdGuardHome
	aghArgs := []string{
		"--no-check-update",
		"--work-dir", aghWork,
		"--config", aghConf + "/AdGuardHome.yaml",
	}
	agh, err := startProc("/usr/local/bin/AdGuardHome", aghArgs...)
	if err != nil {
		log.Fatalf("failed to start AdGuardHome: %v", err)
	}

	// 5) Signal handling and wait
	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)

	// Add: graceful logout on first termination signal
	loggedOut := make(chan struct{}, 1)
	go func() {
		sig := <-sigCh
		log.Printf("received signal: %s, initiating graceful logout", sig)

		// Try a quick forced logout so the node is removed immediately
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "/usr/bin/tailscale", "--socket="+tsSocket, "logout", "--force")
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		_ = cmd.Run() // best-effort; continue regardless

		// Forward the signal to children to stop them
		_ = tsd.Process.Signal(sig)
		_ = agh.Process.Signal(sig)

		close(loggedOut)
	}()

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