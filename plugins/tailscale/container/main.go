// Command tailscale-service is the Tailscale plugin's privileged service
// container: it owns tailscaled, its persisted state, and the NET_ADMIN/
// NET_RAW/TUN-device grant the runtime manager's compiled
// internal/privileged.Definition gives it, so the worker never needs any of
// that itself. See docs/plans/tailscale-privileged-service-lane.md.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/tkadauke/syrus/plugins/tailscale/container/internal/server"
	"github.com/tkadauke/syrus/plugins/tailscale/container/internal/tsd"
)

const (
	defaultListen     = ":8080"
	defaultStatePath  = "/var/lib/tailscale/tailscaled.state"
	defaultSocketPath = "/var/run/tailscale/tailscaled.sock"
	defaultServeURL   = "http://web:80"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	if err := run(); err != nil {
		log.Fatalf("tailscale-service: %v", err)
	}
}

func run() error {
	// TS_AUTHKEY/TS_HOSTNAME/TS_EXIT_NODE are exactly the three keys the
	// runtime manager's privileged lane allows a request to set (see
	// internal/privileged.TailscaleAllowedEnvKeys on the plugin_runtime side).
	// TS_SERVE_TARGET is the one fixed value the manager merges in from its
	// own environment, never from a request. Nothing here is ever logged: the
	// auth key only ever reaches tailscaled as a `tailscale up` argument.
	authKey := os.Getenv("TS_AUTHKEY")
	if authKey == "" {
		return errors.New("TS_AUTHKEY must be set")
	}
	exitNode, err := strconv.ParseBool(envOr("TS_EXIT_NODE", "false"))
	if err != nil {
		return fmt.Errorf("TS_EXIT_NODE must be a boolean: %w", err)
	}

	cfg := tsd.Config{
		StatePath:   envOr("TS_STATE_PATH", defaultStatePath),
		SocketPath:  envOr("TS_SOCKET_PATH", defaultSocketPath),
		AuthKey:     authKey,
		Hostname:    os.Getenv("TS_HOSTNAME"),
		ExitNode:    exitNode,
		ServeTarget: envOr("TS_SERVE_TARGET", defaultServeURL),
	}
	daemon := tsd.New(tsd.ExecRunner{}, cfg)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := daemon.Start(ctx); err != nil {
		return fmt.Errorf("starting tailscaled: %w", err)
	}
	log.Printf("tailscale-service: tailscaled up, serving %s", cfg.ServeTarget)

	srv := &http.Server{Addr: envOr("TS_LISTEN", defaultListen), Handler: server.New(daemon), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()

	err = srv.ListenAndServe()
	// Stop tailscaled (best-effort logout, then terminate) regardless of how
	// the HTTP server exited, so a restart doesn't leave an orphaned process.
	stopCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if stopErr := daemon.Stop(stopCtx); stopErr != nil {
		log.Printf("tailscale-service: stopping tailscaled: %v", stopErr)
	}
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// healthcheck lets the image's HEALTHCHECK work without curl or wget.
func healthcheck() int {
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1" + envOr("TS_LISTEN", defaultListen) + "/healthz")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
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
