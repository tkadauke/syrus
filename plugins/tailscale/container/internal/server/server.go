// Package server is this container's HTTP surface: /healthz for the Docker
// healthcheck and the runtime manager's own probe, and /status, which
// proxies tailscaled's local API so the Rails plugin never has to read a
// Unix socket itself.
//
// Both routes are unauthenticated, matching every other container-backed
// plugin image in this codebase (git-mirror, the runtime manager itself):
// they are reachable only from the Compose project network, and neither
// route ever returns a secret -- not the auth key, not anything derived from
// it. /status carries only what the admin page already shows a logged-in
// operator: connectivity state, tailnet hostname, and tailnet IPs.
package server

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/tkadauke/syrus/plugins/tailscale/container/internal/tsd"
)

// Daemon is the part of tsd.Daemon this server reads.
type Daemon interface {
	Status(ctx context.Context) (running bool, status tsd.Status)
}

// statusResponse is the entire /status contract. daemon_running is false
// exactly when Daemon.Status reports the local API is unreachable -- not yet
// up, or gone -- which is a normal, expected state right after the container
// starts, not an error.
type statusResponse struct {
	DaemonRunning bool     `json:"daemon_running"`
	Connected     bool     `json:"connected"`
	BackendState  string   `json:"backend_state"`
	Hostname      *string  `json:"hostname"`
	TailscaleIPs  []string `json:"tailscale_ips"`
}

// New returns the HTTP handler.
func New(daemon Daemon) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) {
		running, status := daemon.Status(r.Context())
		resp := statusResponse{
			DaemonRunning: running,
			Connected:     running && status.Connected(),
			BackendState:  status.BackendState,
			TailscaleIPs:  status.TailscaleIPs,
		}
		if status.DNSName != "" {
			resp.Hostname = &status.DNSName
		}
		if resp.TailscaleIPs == nil {
			resp.TailscaleIPs = []string{}
		}
		writeJSON(w, http.StatusOK, resp)
	})
	return mux
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}
