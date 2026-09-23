package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/plugins/tailscale/container/internal/tsd"
)

type fakeDaemon struct {
	running bool
	status  tsd.Status
}

func (f fakeDaemon) Status(context.Context) (bool, tsd.Status) { return f.running, f.status }

func get(h http.Handler, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestHealthzIsOpenAndAlwaysOk(t *testing.T) {
	rec := get(New(fakeDaemon{}), "/healthz")
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d", rec.Code)
	}
}

func TestStatusReportsNotRunningWithoutError(t *testing.T) {
	rec := get(New(fakeDaemon{running: false}), "/status")
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d", rec.Code)
	}
	var body statusResponse
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.DaemonRunning || body.Connected {
		t.Errorf("body = %+v, want daemon_running/connected both false", body)
	}
	if body.Hostname != nil {
		t.Errorf("hostname = %v, want nil", body.Hostname)
	}
}

func TestStatusReportsConnectedAndHostnameWhenUp(t *testing.T) {
	daemon := fakeDaemon{running: true, status: tsd.Status{BackendState: "Running", DNSName: "box.tail.ts.net", Online: true, TailscaleIPs: []string{"100.64.0.1"}}}
	rec := get(New(daemon), "/status")

	var body statusResponse
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if !body.DaemonRunning || !body.Connected {
		t.Errorf("body = %+v, want both true", body)
	}
	if body.Hostname == nil || *body.Hostname != "box.tail.ts.net" {
		t.Errorf("hostname = %v", body.Hostname)
	}
	if len(body.TailscaleIPs) != 1 || body.TailscaleIPs[0] != "100.64.0.1" {
		t.Errorf("ips = %v", body.TailscaleIPs)
	}
}

// The auth key must never appear anywhere in a response this container
// serves -- it isn't part of tsd.Status at all, but this pins the contract
// at the HTTP boundary too.
func TestStatusResponseNeverContainsAnAuthKeyShapedValue(t *testing.T) {
	daemon := fakeDaemon{running: true, status: tsd.Status{BackendState: "Running", DNSName: "box.tail.ts.net"}}
	rec := get(New(daemon), "/status")

	if strings.Contains(strings.ToLower(rec.Body.String()), "authkey") || strings.Contains(rec.Body.String(), "tskey-") {
		t.Errorf("response leaked something auth-key-shaped: %s", rec.Body.String())
	}
}
