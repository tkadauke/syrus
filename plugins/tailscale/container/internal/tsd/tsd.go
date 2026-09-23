// Package tsd owns tailscaled's lifecycle inside the Tailscale plugin's
// privileged service container: spawning it, bringing it up with the
// configured auth key/hostname/exit-node setting, serving Syrus over it the
// way the admin UI already promises, and reading its local API for status.
//
// This is the one process boundary in the whole Syrus stack that is meant to
// hold NET_ADMIN/NET_RAW and the /dev/net/tun device -- see
// docs/plans/tailscale-privileged-service-lane.md. Nothing here reads a
// caller-supplied "extra flags" value: Config is built by main from exactly
// the three env keys the runtime manager's privileged lane allows through
// (TS_AUTHKEY, TS_HOSTNAME, TS_EXIT_NODE) plus the fixed serve target, and
// that is the entire configuration surface.
package tsd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Config is everything one tailscaled instance needs. AuthKey is never
// logged by this package -- see Daemon.Start and Daemon.up.
type Config struct {
	StatePath   string // persisted on the container's named volume
	SocketPath  string // ephemeral: only this process and `tailscale` need it
	AuthKey     string
	Hostname    string
	ExitNode    bool
	ServeTarget string // e.g. "http://web:80"
}

// Handle is a running process this package started.
type Handle interface {
	Wait() error
	Signal(sig os.Signal) error
}

// Runner is the process boundary tsd depends on, so tests can run against a
// fake instead of a real tailscaled/tailscale binary.
type Runner interface {
	// Start launches a long-running process and returns a handle to it. Used
	// only for tailscaled itself.
	Start(ctx context.Context, name string, args ...string) (Handle, error)
	// Run runs a short-lived command to completion and returns its combined
	// output. Used for `tailscale up`/`serve`/`logout`.
	Run(ctx context.Context, name string, args ...string) ([]byte, error)
}

// Status is tailscaled's local API status, trimmed to what this plugin
// needs. Never carries the auth key -- tailscaled's own status endpoint
// doesn't return one.
type Status struct {
	BackendState string   `json:"BackendState"`
	DNSName      string   `json:"dns_name"`
	Online       bool     `json:"online"`
	TailscaleIPs []string `json:"tailscale_ips"`
}

// Connected reports whether the tailnet identity is actually up, the same
// rule the Syrus admin page has always used.
func (s Status) Connected() bool {
	return s.BackendState == "Running" || s.Online
}

const (
	readyTimeout      = 30 * time.Second
	readyPollInterval = 500 * time.Millisecond
)

// Daemon supervises one tailscaled instance.
type Daemon struct {
	runner Runner
	cfg    Config
	handle Handle

	// fetchStatus is a test seam; New sets it to a real unix-socket HTTP GET
	// against cfg.SocketPath.
	fetchStatus func(ctx context.Context) ([]byte, error)
}

// New returns a Daemon that will run tailscaled through runner.
func New(runner Runner, cfg Config) *Daemon {
	return &Daemon{runner: runner, cfg: cfg, fetchStatus: defaultFetchStatus(cfg.SocketPath)}
}

// Start spawns tailscaled, waits for its local API to answer, then runs
// `tailscale up` with the configured auth key/hostname/exit-node setting and
// `tailscale serve` for Syrus's internal URL -- current behavior, just
// sourced from this container instead of the worker.
func (d *Daemon) Start(ctx context.Context) error {
	handle, err := d.runner.Start(ctx, "tailscaled", "--state="+d.cfg.StatePath, "--socket="+d.cfg.SocketPath)
	if err != nil {
		return fmt.Errorf("spawning tailscaled: %w", err)
	}
	d.handle = handle

	if err := d.waitUntilReady(ctx); err != nil {
		return err
	}
	if err := d.up(ctx); err != nil {
		return fmt.Errorf("tailscale up: %w", err)
	}
	if err := d.serve(ctx); err != nil {
		return fmt.Errorf("tailscale serve: %w", err)
	}
	return nil
}

// Stop logs the node out (best-effort) and terminates tailscaled.
func (d *Daemon) Stop(ctx context.Context) error {
	_, _ = d.runner.Run(ctx, "tailscale", "--socket="+d.cfg.SocketPath, "logout")
	if d.handle == nil {
		return nil
	}
	_ = d.handle.Signal(os.Interrupt)
	return d.handle.Wait()
}

// Status reads tailscaled's local API. A failure (not up yet, socket gone)
// is reported as daemon_running: false rather than an error -- the whole
// point of this method is to answer "what state is the daemon in", and "not
// running" is itself a valid answer.
func (d *Daemon) Status(ctx context.Context) (running bool, status Status) {
	body, err := d.fetchStatus(ctx)
	if err != nil {
		return false, Status{}
	}
	var raw struct {
		BackendState string `json:"BackendState"`
		Self         struct {
			DNSName      string   `json:"DNSName"`
			Online       bool     `json:"Online"`
			TailscaleIPs []string `json:"TailscaleIPs"`
		} `json:"Self"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return true, Status{}
	}
	return true, Status{
		BackendState: raw.BackendState,
		DNSName:      strings.TrimSuffix(raw.Self.DNSName, "."),
		Online:       raw.Self.Online,
		TailscaleIPs: raw.Self.TailscaleIPs,
	}
}

func (d *Daemon) waitUntilReady(ctx context.Context) error {
	deadline := time.Now().Add(readyTimeout)
	for {
		if running, _ := d.Status(ctx); running {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("tailscaled did not become ready within %s", readyTimeout)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(readyPollInterval):
		}
	}
}

// up runs `tailscale up`. The auth key reaches the child process only as a
// command argument, never through an env var this process would log, and
// this function itself never formats cfg.AuthKey into a log line.
func (d *Daemon) up(ctx context.Context) error {
	args := []string{"--socket=" + d.cfg.SocketPath, "up", "--authkey=" + d.cfg.AuthKey}
	if d.cfg.Hostname != "" {
		args = append(args, "--hostname="+d.cfg.Hostname)
	}
	if d.cfg.ExitNode {
		args = append(args, "--advertise-exit-node")
	}
	_, err := d.runner.Run(ctx, "tailscale", args...)
	return err
}

func (d *Daemon) serve(ctx context.Context) error {
	target := d.cfg.ServeTarget
	if target == "" {
		target = "http://web:80"
	}
	_, err := d.runner.Run(ctx, "tailscale", "--socket="+d.cfg.SocketPath, "serve", "--bg", "--https=443", target)
	return err
}

// defaultFetchStatus reads tailscaled's local API over its Unix socket, the
// same endpoint the old in-worker code read directly.
func defaultFetchStatus(socketPath string) func(ctx context.Context) ([]byte, error) {
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", socketPath)
			},
		},
		Timeout: 5 * time.Second,
	}
	return func(ctx context.Context) ([]byte, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://local-tailscaled.sock/localapi/v0/status", nil)
		if err != nil {
			return nil, err
		}
		// Recent tailscaled versions refuse local API requests without this
		// header (a CSRF-style guard, unrelated to auth); older versions ignore
		// it. Setting it unconditionally keeps this working across versions.
		req.Header.Set("Sec-Tailscale", "unsafe")
		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("tailscaled local API returned %d", resp.StatusCode)
		}
		buf := new(bytes.Buffer)
		if _, err := buf.ReadFrom(resp.Body); err != nil {
			return nil, err
		}
		return buf.Bytes(), nil
	}
}

// ExecRunner runs real tailscaled/tailscale binaries. It is the only place
// in this package that touches os/exec.
type ExecRunner struct{}

func (ExecRunner) Start(ctx context.Context, name string, args ...string) (Handle, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return execHandle{cmd}, nil
}

// Run's output is only ever surfaced by main to its own stderr for
// diagnostics -- it is tailscale CLI chatter (state transitions, warnings),
// never a value main formats a request body or client-facing response from.
func (ExecRunner) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	return cmd.CombinedOutput()
}

type execHandle struct{ cmd *exec.Cmd }

func (h execHandle) Wait() error                { return h.cmd.Wait() }
func (h execHandle) Signal(sig os.Signal) error { return h.cmd.Process.Signal(sig) }
