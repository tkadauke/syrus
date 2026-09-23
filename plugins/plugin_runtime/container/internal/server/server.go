// Package server exposes the manager over HTTP to Syrus.
package server

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"

	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/manager"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/policy"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/privileged"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/spec"
)

const maxBodyBytes = 64 << 10

// Manager is what the server drives.
type Manager interface {
	Ensure(ctx context.Context, name string, s spec.Service) (manager.Status, error)
	EnsurePrivileged(ctx context.Context, name string, env map[string]string) (manager.Status, error)
	Status(ctx context.Context, name string) (manager.Status, error)
	Remove(ctx context.Context, name string, purge bool) error
	List(ctx context.Context) ([]manager.Status, error)
	Stop(ctx context.Context, name string) (manager.Status, error)
	Start(ctx context.Context, name string) (manager.Status, error)
	Restart(ctx context.Context, name string) (manager.Status, error)
	Logs(ctx context.Context, name string, tail int) (string, error)
	Volumes(ctx context.Context) ([]manager.VolumeStatus, error)
	RemoveVolume(ctx context.Context, name string) error
	PurgePlugin(ctx context.Context, plugin string) ([]string, error)
}

const (
	defaultLogTail = 200
	maxLogTail     = 5000
)

// Info is reported by /healthz so an operator can see which project and
// network the manager attached itself to.
type Info struct {
	Project         string   `json:"project"`
	Network         string   `json:"network"`
	AllowedPrefixes []string `json:"allowed_image_prefixes"`
}

// New returns the HTTP handler. Every /v1 route requires the bearer token.
func New(m Manager, token string, info Info) http.Handler {
	mux := http.NewServeMux()
	s := &handlers{manager: m, info: info}

	// Unauthenticated so the container healthcheck and an operator's curl
	// can reach it. It reveals no secrets and changes nothing.
	mux.HandleFunc("GET /healthz", s.healthz)

	mux.Handle("GET /v1/services", auth(token, http.HandlerFunc(s.list)))
	mux.Handle("GET /v1/services/{name}", auth(token, http.HandlerFunc(s.status)))
	mux.Handle("PUT /v1/services/{name}", auth(token, http.HandlerFunc(s.ensure)))
	mux.Handle("DELETE /v1/services/{name}", auth(token, http.HandlerFunc(s.remove)))
	// The privileged lane: a small, separately named verb that can only ever
	// configure one of a compiled table of first-party services (see
	// internal/privileged). Every other operation above and below acts on
	// whatever container the label lookup finds, privileged or not, and needs
	// no privileged counterpart because none of them accepts a payload that
	// shapes a container.
	mux.Handle("PUT /v1/privileged/{name}", auth(token, http.HandlerFunc(s.ensurePrivileged)))
	// Operator actions from Syrus's admin page.
	mux.Handle("POST /v1/services/{name}/stop", auth(token, s.action(s.manager.Stop)))
	mux.Handle("POST /v1/services/{name}/start", auth(token, s.action(s.manager.Start)))
	mux.Handle("POST /v1/services/{name}/restart", auth(token, s.action(s.manager.Restart)))
	mux.Handle("GET /v1/services/{name}/logs", auth(token, http.HandlerFunc(s.logs)))
	// Stored data: plugin services' volumes.
	mux.Handle("GET /v1/volumes", auth(token, http.HandlerFunc(s.volumes)))
	mux.Handle("DELETE /v1/volumes/{name}", auth(token, http.HandlerFunc(s.removeVolume)))
	mux.Handle("DELETE /v1/plugins/{plugin}", auth(token, http.HandlerFunc(s.purgePlugin)))
	return mux
}

func auth(token string, next http.Handler) http.Handler {
	expected := []byte("Bearer " + token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := []byte(r.Header.Get("Authorization"))
		if subtle.ConstantTimeCompare(got, expected) != 1 {
			writeError(w, http.StatusUnauthorized, "missing or invalid bearer token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

type handlers struct {
	manager Manager
	info    Info
}

func (h *handlers) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "info": h.info})
}

func (h *handlers) list(w http.ResponseWriter, r *http.Request) {
	statuses, err := h.manager.List(r.Context())
	if err != nil {
		h.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"services": statuses})
}

func (h *handlers) status(w http.ResponseWriter, r *http.Request) {
	st, err := h.manager.Status(r.Context(), r.PathValue("name"))
	if err != nil {
		h.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (h *handlers) ensure(w http.ResponseWriter, r *http.Request) {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	// A field the manager does not model -- "privileged", "devices", "binds" --
	// is refused rather than silently dropped. Dropping would be safe, but a
	// caller asking for something it cannot have should find out.
	decoder.DisallowUnknownFields()
	var s spec.Service
	if err := decoder.Decode(&s); err != nil {
		writeError(w, http.StatusBadRequest, "invalid service spec: "+err.Error())
		return
	}

	st, err := h.manager.Ensure(r.Context(), r.PathValue("name"), s)
	if err != nil {
		h.fail(w, err)
		return
	}
	code := http.StatusOK
	if st.State == manager.StatePulling {
		code = http.StatusAccepted
	}
	writeJSON(w, code, st)
}

// privilegedRequest is the entire wire shape of a privileged request: env
// only. There is no image, internal_port, volumes, devices, or cap_add key
// for a caller to populate -- DisallowUnknownFields refuses one that tries.
type privilegedRequest struct {
	Env map[string]string `json:"env"`
}

func (h *handlers) ensurePrivileged(w http.ResponseWriter, r *http.Request) {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	decoder.DisallowUnknownFields()
	var req privilegedRequest
	if err := decoder.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid privileged request: "+err.Error())
		return
	}

	st, err := h.manager.EnsurePrivileged(r.Context(), r.PathValue("name"), req.Env)
	if err != nil {
		h.fail(w, err)
		return
	}
	code := http.StatusOK
	if st.State == manager.StatePulling {
		code = http.StatusAccepted
	}
	writeJSON(w, code, st)
}

func (h *handlers) remove(w http.ResponseWriter, r *http.Request) {
	purge := r.URL.Query().Get("purge") == "true"
	if err := h.manager.Remove(r.Context(), r.PathValue("name"), purge); err != nil {
		h.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handlers) action(do func(context.Context, string) (manager.Status, error)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		st, err := do(r.Context(), r.PathValue("name"))
		if err != nil {
			h.fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, st)
	})
}

// logs answers text/plain: the last `tail` lines (default 200, at most 5000)
// of the container's stdout and stderr, timestamped.
func (h *handlers) logs(w http.ResponseWriter, r *http.Request) {
	tail := defaultLogTail
	if raw := r.URL.Query().Get("tail"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 {
			writeError(w, http.StatusBadRequest, "tail must be a positive integer")
			return
		}
		tail = min(n, maxLogTail)
	}
	text, err := h.manager.Logs(r.Context(), r.PathValue("name"), tail)
	if err != nil {
		h.fail(w, err)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, text)
}

func (h *handlers) volumes(w http.ResponseWriter, r *http.Request) {
	volumes, err := h.manager.Volumes(r.Context())
	if err != nil {
		h.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"volumes": volumes})
}

func (h *handlers) removeVolume(w http.ResponseWriter, r *http.Request) {
	if err := h.manager.RemoveVolume(r.Context(), r.PathValue("name")); err != nil {
		h.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handlers) purgePlugin(w http.ResponseWriter, r *http.Request) {
	removed, err := h.manager.PurgePlugin(r.Context(), r.PathValue("plugin"))
	if err != nil {
		h.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"removed_volumes": removed})
}

func (h *handlers) fail(w http.ResponseWriter, err error) {
	if errors.Is(err, manager.ErrNotFound) {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	if errors.Is(err, manager.ErrVolumeInUse) {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	var refused *policy.Error
	if errors.As(err, &refused) {
		writeError(w, http.StatusUnprocessableEntity, err.Error())
		return
	}
	var privilegedRefused *privileged.Error
	if errors.As(err, &privilegedRefused) {
		writeError(w, http.StatusUnprocessableEntity, err.Error())
		return
	}
	log.Printf("runtime-manager: %v", err)
	// The daemon's message can name paths and images; that is fine for the
	// caller, which is Syrus, and useful when something goes wrong.
	writeError(w, http.StatusBadGateway, strings.TrimSpace(err.Error()))
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, code int, message string) {
	writeJSON(w, code, map[string]string{"error": message})
}
