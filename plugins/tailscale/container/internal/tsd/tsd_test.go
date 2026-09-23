package tsd

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeHandle stands in for a running tailscaled process.
type fakeHandle struct {
	signals []os.Signal
	waitErr error
}

func (h *fakeHandle) Signal(sig os.Signal) error {
	h.signals = append(h.signals, sig)
	return nil
}
func (h *fakeHandle) Wait() error { return h.waitErr }

// fakeRunner records every command it was asked to run, so tests can assert
// on exact arguments -- in particular, that the auth key only ever appears
// as a `tailscale up` argument and nowhere else.
type fakeRunner struct {
	mu       sync.Mutex
	started  [][]string
	ran      [][]string
	startErr error
	runErr   error
	handle   *fakeHandle
}

func (r *fakeRunner) Start(_ context.Context, name string, args ...string) (Handle, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.started = append(r.started, append([]string{name}, args...))
	if r.startErr != nil {
		return nil, r.startErr
	}
	if r.handle == nil {
		r.handle = &fakeHandle{}
	}
	return r.handle, nil
}

func (r *fakeRunner) Run(_ context.Context, name string, args ...string) ([]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ran = append(r.ran, append([]string{name}, args...))
	return nil, r.runErr
}

func (r *fakeRunner) commands() [][]string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([][]string(nil), r.ran...)
}

func newTestDaemon(runner *fakeRunner, cfg Config, statusBody []byte, statusErr error) *Daemon {
	d := New(runner, cfg)
	d.fetchStatus = func(context.Context) ([]byte, error) { return statusBody, statusErr }
	return d
}

const readyStatus = `{"BackendState":"Running","Self":{"DNSName":"box.tail.ts.net.","Online":true,"TailscaleIPs":["100.64.0.1"]}}`

func TestStartSpawnsTailscaledThenUpThenServe(t *testing.T) {
	runner := &fakeRunner{}
	cfg := Config{StatePath: "/var/lib/tailscale/tailscaled.state", SocketPath: "/var/run/tailscale/tailscaled.sock", AuthKey: "tskey-abc123", ServeTarget: "http://web:80"}
	d := newTestDaemon(runner, cfg, []byte(readyStatus), nil)

	if err := d.Start(context.Background()); err != nil {
		t.Fatal(err)
	}

	if len(runner.started) != 1 {
		t.Fatalf("started %d processes, want 1", len(runner.started))
	}
	spawn := runner.started[0]
	if spawn[0] != "tailscaled" || spawn[1] != "--state=/var/lib/tailscale/tailscaled.state" || spawn[2] != "--socket=/var/run/tailscale/tailscaled.sock" {
		t.Errorf("tailscaled args = %v", spawn)
	}

	commands := runner.commands()
	if len(commands) != 2 {
		t.Fatalf("ran %d commands, want up and serve, got %v", len(commands), commands)
	}
	up := commands[0]
	if up[0] != "tailscale" || !contains(up, "up") || !contains(up, "--authkey=tskey-abc123") {
		t.Errorf("up command = %v", up)
	}
	serve := commands[1]
	if serve[0] != "tailscale" || !contains(serve, "serve") || !contains(serve, "http://web:80") {
		t.Errorf("serve command = %v", serve)
	}
}

func TestUpIncludesHostnameAndExitNodeOnlyWhenConfigured(t *testing.T) {
	runner := &fakeRunner{}
	cfg := Config{AuthKey: "tskey-abc123", Hostname: "syrus-home", ExitNode: true}
	d := newTestDaemon(runner, cfg, []byte(readyStatus), nil)

	if err := d.Start(context.Background()); err != nil {
		t.Fatal(err)
	}

	up := runner.commands()[0]
	if !contains(up, "--hostname=syrus-home") {
		t.Errorf("up = %v, want --hostname=syrus-home", up)
	}
	if !contains(up, "--advertise-exit-node") {
		t.Errorf("up = %v, want --advertise-exit-node", up)
	}
}

func TestUpOmitsHostnameAndExitNodeByDefault(t *testing.T) {
	runner := &fakeRunner{}
	d := newTestDaemon(runner, Config{AuthKey: "tskey-abc123"}, []byte(readyStatus), nil)

	if err := d.Start(context.Background()); err != nil {
		t.Fatal(err)
	}

	up := runner.commands()[0]
	for _, forbidden := range []string{"--hostname=", "--advertise-exit-node"} {
		for _, arg := range up {
			if strings.Contains(arg, forbidden) {
				t.Errorf("up = %v, did not expect %s", up, forbidden)
			}
		}
	}
}

func TestServeDefaultsToTheInternalWebURLWhenUnset(t *testing.T) {
	runner := &fakeRunner{}
	d := newTestDaemon(runner, Config{AuthKey: "tskey-abc123", ServeTarget: ""}, []byte(readyStatus), nil)

	if err := d.Start(context.Background()); err != nil {
		t.Fatal(err)
	}

	serve := runner.commands()[1]
	if !contains(serve, "http://web:80") {
		t.Errorf("serve = %v, want the default internal web URL", serve)
	}
}

func TestStartFailsIfTailscaledNeverBecomesReady(t *testing.T) {
	runner := &fakeRunner{}
	d := newTestDaemon(runner, Config{AuthKey: "tskey-abc123"}, nil, errors.New("connection refused"))
	// Speed the test up: waitUntilReady polls on a real clock.
	d.fetchStatus = func(context.Context) ([]byte, error) { return nil, errors.New("connection refused") }

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	err := d.Start(ctx)
	if err == nil {
		t.Fatal("expected an error when tailscaled never becomes ready")
	}
	if len(runner.commands()) != 0 {
		t.Error("must not run `tailscale up` before the daemon is ready")
	}
}

func TestStopLogsOutThenSignalsAndWaits(t *testing.T) {
	runner := &fakeRunner{}
	d := newTestDaemon(runner, Config{AuthKey: "tskey-abc123"}, []byte(readyStatus), nil)
	if err := d.Start(context.Background()); err != nil {
		t.Fatal(err)
	}

	if err := d.Stop(context.Background()); err != nil {
		t.Fatal(err)
	}

	commands := runner.commands()
	logout := commands[len(commands)-1]
	if !contains(logout, "logout") {
		t.Errorf("expected a logout command, got %v", commands)
	}
	if len(runner.handle.signals) != 1 {
		t.Errorf("expected exactly one signal sent to the process, got %v", runner.handle.signals)
	}
}

func TestStatusReportsNotRunningWhenTheLocalAPIIsUnreachable(t *testing.T) {
	runner := &fakeRunner{}
	d := newTestDaemon(runner, Config{}, nil, errors.New("no such file or directory"))

	running, status := d.Status(context.Background())

	if running {
		t.Error("expected running = false when the local API cannot be reached")
	}
	if status.Connected() {
		t.Error("expected not connected")
	}
}

func TestStatusParsesTheLocalAPIResponse(t *testing.T) {
	runner := &fakeRunner{}
	d := newTestDaemon(runner, Config{}, []byte(readyStatus), nil)

	running, status := d.Status(context.Background())

	if !running {
		t.Fatal("expected running = true")
	}
	if !status.Connected() {
		t.Error("expected connected = true")
	}
	if status.DNSName != "box.tail.ts.net" {
		t.Errorf("dns name = %q, want the trailing dot stripped", status.DNSName)
	}
	if len(status.TailscaleIPs) != 1 || status.TailscaleIPs[0] != "100.64.0.1" {
		t.Errorf("ips = %v", status.TailscaleIPs)
	}
}

func TestStatusIsNotConnectedWhileBackendIsStillStarting(t *testing.T) {
	runner := &fakeRunner{}
	body := `{"BackendState":"Starting","Self":{"DNSName":"box.tail.ts.net.","Online":false}}`
	d := newTestDaemon(runner, Config{}, []byte(body), nil)

	running, status := d.Status(context.Background())

	if !running {
		t.Fatal("expected running = true: the local API answered")
	}
	if status.Connected() {
		t.Error("expected not connected while the backend is still starting")
	}
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if strings.Contains(s, needle) {
			return true
		}
	}
	return false
}
