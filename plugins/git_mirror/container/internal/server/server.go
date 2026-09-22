// Package server is the mirror's HTTP API. Every route but /healthz needs the
// bearer token Syrus and the mirror share.
//
//	GET    /healthz
//	GET    /v1/repositories
//	PUT    /v1/repositories/{id}                     register, refresh credential
//	DELETE /v1/repositories/{id}
//	GET    /v1/repositories/{id}/resolve?ref=&max_age=
//	GET    /v1/repositories/{id}/tree?revision=
//	GET    /v1/repositories/{id}/blob?revision=&path=   raw bytes
//	GET    /v1/repositories/{id}/changes?base=&head=&patch=1
//
// Errors are {"error":{"code","message"}} with codes the Syrus plugin maps
// onto the content contract: unknown_repository, unknown_revision, not_found,
// unavailable, unsupported, bad_request, unauthorized, and unregistered (a
// repository on disk that Syrus has not registered since the mirror started;
// Syrus registers it and retries).
package server

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/tkadauke/syrus/plugins/git_mirror/container/internal/mirror"
)

// Store is the part of mirror.Store the API uses.
type Store interface {
	Register(ctx context.Context, id string, reg mirror.Registration) error
	Remove(id string) error
	List() []mirror.Status
	Resolve(ctx context.Context, id, ref string, maxAge time.Duration) (string, time.Time, error)
	Tree(ctx context.Context, id, revision string) ([]mirror.Entry, error)
	Read(ctx context.Context, id, revision, path string) (mirror.Blob, error)
	Changes(ctx context.Context, id, base, head string, withPatch bool) ([]mirror.Change, error)
}

const maxRegistrationBytes = 64 << 10

// New returns the API handler, logging every request but health checks.
func New(store Store, token string) http.Handler {
	return NewWithLogger(store, token, log.Default())
}

// NewWithLogger is New with the request log sent to logger (nil disables it).
func NewWithLogger(store Store, token string, logger *log.Logger) http.Handler {
	s := &server{store: store, token: []byte(token)}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.Handle("GET /v1/repositories", s.auth(s.list))
	mux.Handle("PUT /v1/repositories/{id}", s.auth(s.register))
	mux.Handle("DELETE /v1/repositories/{id}", s.auth(s.remove))
	mux.Handle("GET /v1/repositories/{id}/resolve", s.auth(s.resolve))
	mux.Handle("GET /v1/repositories/{id}/tree", s.auth(s.tree))
	mux.Handle("GET /v1/repositories/{id}/blob", s.auth(s.blob))
	mux.Handle("GET /v1/repositories/{id}/changes", s.auth(s.changes))
	if logger == nil {
		return mux
	}
	return requestLog(mux, logger)
}

// requestLog writes one line per request: method, path and query, status,
// response size, and duration. Health checks are skipped -- Docker and the
// runtime manager probe every few seconds. Request bodies are never logged:
// a registration carries the fetch credential. Query strings carry only
// refs, revisions, and paths.
func requestLog(next http.Handler, logger *log.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}
		started := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		target := r.URL.Path
		if r.URL.RawQuery != "" {
			target += "?" + r.URL.RawQuery
		}
		logger.Printf("%s %s %d %dB %s", r.Method, target, rec.status, rec.bytes, time.Since(started).Round(time.Millisecond))
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	n, err := r.ResponseWriter.Write(b)
	r.bytes += n
	return n, err
}

type server struct {
	store Store
	token []byte
}

func (s *server) auth(next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		given, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || subtle.ConstantTimeCompare([]byte(given), s.token) != 1 {
			writeError(w, http.StatusUnauthorized, "unauthorized", "missing or invalid token")
			return
		}
		next(w, r)
	})
}

func (s *server) list(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"repositories": s.store.List()})
}

func (s *server) register(w http.ResponseWriter, r *http.Request) {
	var reg mirror.Registration
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxRegistrationBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&reg); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid registration: "+err.Error())
		return
	}
	if err := s.store.Register(r.Context(), r.PathValue("id"), reg); err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "registered"})
}

func (s *server) remove(w http.ResponseWriter, r *http.Request) {
	if err := s.store.Remove(r.PathValue("id")); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) resolve(w http.ResponseWriter, r *http.Request) {
	maxAge := 60 * time.Second
	if raw := r.URL.Query().Get("max_age"); raw != "" {
		seconds, err := strconv.Atoi(raw)
		if err != nil || seconds < 0 {
			writeError(w, http.StatusBadRequest, "bad_request", "max_age must be a non-negative integer")
			return
		}
		maxAge = time.Duration(seconds) * time.Second
	}
	sha, observedAt, err := s.store.Resolve(r.Context(), r.PathValue("id"), r.URL.Query().Get("ref"), maxAge)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": sha, "observed_at": observedAt.UTC().Format(time.RFC3339Nano)})
}

func (s *server) tree(w http.ResponseWriter, r *http.Request) {
	entries, err := s.store.Tree(r.Context(), r.PathValue("id"), r.URL.Query().Get("revision"))
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if entries == nil {
		entries = []mirror.Entry{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries})
}

func (s *server) blob(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	blob, err := s.store.Read(r.Context(), r.PathValue("id"), query.Get("revision"), query.Get("path"))
	if err != nil {
		writeStoreError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Content-Id", blob.ContentID)
	w.Header().Set("Content-Length", strconv.Itoa(len(blob.Bytes)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(blob.Bytes)
}

func (s *server) changes(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	withPatch := query.Get("patch") == "1" || query.Get("patch") == "true"
	changes, err := s.store.Changes(r.Context(), r.PathValue("id"), query.Get("base"), query.Get("head"), withPatch)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if changes == nil {
		changes = []mirror.Change{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"changes": changes})
}

func writeStoreError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, mirror.ErrUnknownRepository):
		writeError(w, http.StatusNotFound, "unknown_repository", err.Error())
	case errors.Is(err, mirror.ErrUnknownRevision):
		writeError(w, http.StatusNotFound, "unknown_revision", err.Error())
	case errors.Is(err, mirror.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, mirror.ErrUnregistered):
		writeError(w, http.StatusServiceUnavailable, "unregistered", err.Error())
	case errors.Is(err, mirror.ErrBadRequest):
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
	case errors.Is(err, mirror.ErrUnsupported):
		writeError(w, http.StatusNotImplemented, "unsupported", err.Error())
	default:
		writeError(w, http.StatusServiceUnavailable, "unavailable", err.Error())
	}
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
