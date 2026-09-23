// Command browser-bridge runs @playwright/mcp as the Browser Plugin Runtime
// service: streamable HTTP MCP, exactly as SyrusBrowser::Session's
// stdio path already speaks it, just reached over the network instead of a
// per-owner subprocess. See plugins/browser/docs/syrus_docs/browser.md for
// the full service boundary this implements.
//
// It holds no secrets and keeps no state: every browser session lives only
// as long as the owning Run or chat keeps its MCP session open
// (--isolated), and nothing here persists across restarts.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"

	"github.com/tkadauke/syrus/plugins/browser/container/internal/bridge"
)

const (
	defaultListen         = ":8080"
	defaultChildHost      = "127.0.0.1"
	defaultChildPort      = "8931"
	defaultCommand        = "playwright-mcp"
	defaultExecutablePath = "/opt/syrus-browser/chromium"
	dialTimeout           = 2 * time.Second
	shutdownTimeout       = 10 * time.Second
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	if err := run(); err != nil {
		log.Fatalf("browser: %v", err)
	}
}

func run() error {
	listen := envOr("BROWSER_LISTEN", defaultListen)
	childAddr := net.JoinHostPort(envOr("BROWSER_MCP_HOST", defaultChildHost), envOr("BROWSER_MCP_PORT", defaultChildPort))

	cmd := childCommand(childAddr)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("starting %s: %w", cmd.Path, err)
	}
	childDone := make(chan error, 1)
	go func() { childDone <- cmd.Wait() }()

	handler, err := bridge.New("http://"+childAddr, func() error { return dial(childAddr) })
	if err != nil {
		return fmt.Errorf("building bridge handler: %w", err)
	}
	srv := &http.Server{Addr: listen, Handler: handler, ReadHeaderTimeout: 10 * time.Second}
	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.ListenAndServe() }()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	var runErr error
	select {
	case <-ctx.Done():
	case err := <-childDone:
		runErr = fmt.Errorf("%s exited: %w", cmd.Path, err)
	case err := <-serveErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			runErr = err
		}
	}

	shutdown, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	_ = srv.Shutdown(shutdown)
	stopChild(cmd, childDone)

	return runErr
}

// childCommand builds the same @playwright/mcp invocation
// SyrusBrowser::Session.spawn_stdio uses, bound to a loopback-only address
// instead of --host 0.0.0.0: nothing outside this process should reach the
// child directly, only through the bridge's exposed port. --no-sandbox
// mirrors playwright-mcp's own documented container recipe -- Chromium's
// setuid sandbox helper needs privileges this service intentionally does
// not have. --allowed-hosts '*' turns off playwright-mcp's own Host-header
// check, which otherwise rejects requests unless their Host header matches
// the address it bound to; the bridge is the actual network boundary here.
func childCommand(childAddr string) *exec.Cmd {
	host, port, _ := net.SplitHostPort(childAddr)
	cmd := exec.Command(envOr("BROWSER_MCP_COMMAND", defaultCommand),
		"--headless", "--isolated", "--block-service-workers", "--no-sandbox",
		"--allowed-hosts", "*",
		"--host", host,
		"--port", port,
	)
	cmd.Env = append(os.Environ(),
		"PLAYWRIGHT_MCP_EXECUTABLE_PATH="+envOr("SYRUS_BROWSER_EXECUTABLE_PATH", defaultExecutablePath),
	)
	return cmd
}

func stopChild(cmd *exec.Cmd, done <-chan error) {
	if cmd.Process == nil {
		return
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
	}
}

func dial(addr string) error {
	conn, err := net.DialTimeout("tcp", addr, dialTimeout)
	if err != nil {
		return err
	}
	return conn.Close()
}

// healthcheck lets the image's Docker HEALTHCHECK work without curl or wget.
func healthcheck() int {
	_, port, err := net.SplitHostPort(envOr("BROWSER_LISTEN", defaultListen))
	if err != nil {
		return 1
	}
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + port + bridge.HealthPath)
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
