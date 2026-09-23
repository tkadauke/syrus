// Package bridge fronts @playwright/mcp with the health check the Browser
// Plugin Runtime service contract needs.
//
// playwright-mcp's own streamable-HTTP transport answers every plain GET
// with a 4xx (it only understands a POST that starts an MCP session, or a
// GET carrying an already-established mcp-session-id header), so nothing at
// its own port can double as a health check the way Git Mirror's /healthz
// does. This package owns the service's exposed port instead: it answers
// GET /healthz itself, from a live TCP dial to the playwright-mcp child
// process rather than a cached flag, and reverse-proxies everything else
// (the real MCP traffic) to that child, which listens on a loopback-only
// address nothing outside the container can reach directly.
package bridge

import (
	"net/http"
	"net/http/httputil"
	"net/url"
)

// HealthPath is the path the Browser Plugin Runtime service contract
// declares as its healthcheck (see SyrusBrowser::RuntimeService).
const HealthPath = "/healthz"

// New returns the handler the service's exposed port serves. alive is
// called on every health check -- typically a short-timeout TCP dial to the
// playwright-mcp child -- so /healthz reflects whether the child is
// actually reachable right now, not merely whether it was at startup.
func New(childURL string, alive func() error) (http.Handler, error) {
	target, err := url.Parse(childURL)
	if err != nil {
		return nil, err
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	// -1 flushes every write immediately instead of buffering, which
	// streamable HTTP MCP's SSE-shaped responses need to arrive as they are
	// produced rather than only once the child closes the connection.
	proxy.FlushInterval = -1

	mux := http.NewServeMux()
	mux.HandleFunc(HealthPath, func(w http.ResponseWriter, r *http.Request) {
		if err := alive(); err != nil {
			http.Error(w, `{"status":"unavailable","error":"`+err.Error()+`"}`, http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.Handle("/", proxy)
	return mux, nil
}
