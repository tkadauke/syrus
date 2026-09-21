// Package server exposes the manager over HTTP to Syrus.
package server

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"

	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/manager"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/policy"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/spec"
)

const maxBodyBytes = 64 << 10

// Manager is what the server drives.
type Manager interface {
	Ensure(ctx context.Context, name string, s spec.Service) (manager.Status, error)
	Status(ctx context.Context, name string) (manager.Status, error)
	Remove(ctx context.Context, name string, purge bool) error
	List(ctx context.Context) ([]manager.Status, error)
}

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

func (h *handlers) remove(w http.ResponseWriter, r *http.Request) {
	purge := r.URL.Query().Get("purge") == "true"
	if err := h.manager.Remove(r.Context(), r.PathValue("name"), purge); err != nil {
		h.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handlers) fail(w http.ResponseWriter, err error) {
	var refused *policy.Error
	if errors.As(err, &refused) {
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
