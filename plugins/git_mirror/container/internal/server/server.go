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
//	GET    /v1/repositories/{id}/refs?pattern=&max_age=
//	GET    /v1/repositories/{id}/relation?base=&head=
//	GET    /v1/repositories/{id}/history?base=&head=
//	GET    /v1/repositories/{id}/info/refs?service=git-upload-pack   smart-HTTP clone/fetch
//	POST   /v1/repositories/{id}/git-upload-pack
//
// The last two are git's own smart-HTTP transport, not JSON: a plain `git
// clone`/`git fetch` pointed at `<endpoint>/v1/repositories/{id}` speaks it
// directly. There is no git-receive-pack route, on info/refs or otherwise, so
// this server can never accept a push regardless of what a client tries --
// the mirror is a read-only replica.
//
// Errors are {"error":{"code","message"}} with codes the Syrus plugin maps
// onto the content contract: unknown_repository, unknown_revision, not_found,
// unavailable, unsupported, bad_request, unauthorized, and unregistered (a
// repository on disk that Syrus has not registered since the mirror started;
// Syrus registers it and retries).
package server

import (
	"bufio"
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/textproto"
	"os/exec"
	"path/filepath"
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
	Disk() mirror.Disk
	Resolve(ctx context.Context, id, ref string, maxAge time.Duration) (string, time.Time, error)
	Tree(ctx context.Context, id, revision string) ([]mirror.Entry, error)
	Read(ctx context.Context, id, revision, path string) (mirror.Blob, error)
	Changes(ctx context.Context, id, base, head string, withPatch bool) ([]mirror.Change, error)
	Refs(ctx context.Context, id, pattern string, maxAge time.Duration) ([]mirror.Ref, error)
	Relation(ctx context.Context, id, base, head string) (string, error)
	History(ctx context.Context, id, base, head string) (mirror.History, error)
	RepoDir(id string) (string, error)
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
	mux.Handle("GET /v1/repositories/{id}/refs", s.auth(s.refs))
	mux.Handle("GET /v1/repositories/{id}/relation", s.auth(s.relation))
	mux.Handle("GET /v1/repositories/{id}/history", s.auth(s.history))
	mux.Handle("GET /v1/repositories/{id}/info/refs", s.auth(s.infoRefs))
	mux.Handle("POST /v1/repositories/{id}/git-upload-pack", s.auth(s.uploadPack))
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
	writeJSON(w, http.StatusOK, map[string]any{"repositories": s.store.List(), "disk": s.store.Disk()})
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

func (s *server) refs(w http.ResponseWriter, r *http.Request) {
	maxAge, ok := maxAgeFrom(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "bad_request", "max_age must be a non-negative integer")
		return
	}
	refs, err := s.store.Refs(r.Context(), r.PathValue("id"), r.URL.Query().Get("pattern"), maxAge)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if refs == nil {
		refs = []mirror.Ref{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"refs": refs})
}

func (s *server) relation(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	relation, err := s.store.Relation(r.Context(), r.PathValue("id"), query.Get("base"), query.Get("head"))
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"relation": relation})
}

func (s *server) history(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	history, err := s.store.History(r.Context(), r.PathValue("id"), query.Get("base"), query.Get("head"))
	if err != nil {
		writeStoreError(w, err)
		return
	}
	if history.Commits == nil {
		history.Commits = []mirror.Commit{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"commits": history.Commits, "merge_base_id": history.MergeBaseID})
}

// gitHTTPBackend is the command that serves smart-HTTP git, as CGI. A
// package var so a test can point it at a stub instead of assuming a real
// git binary.
var gitHTTPBackend = []string{"git", "http-backend"}

// gitHTTPMaxRequestBuffer bounds how much of a request body git-http-backend
// buffers in memory before it starts streaming; set explicitly rather than
// left to git's own default so a change to that default doesn't change this
// server's memory behavior silently.
const gitHTTPMaxRequestBuffer = "10485760" // 10MiB

func (s *server) infoRefs(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("service") != "git-upload-pack" {
		writeError(w, http.StatusForbidden, "unsupported", "this mirror is read-only and serves only git-upload-pack")
		return
	}
	s.runGitHTTPBackend(w, r, "/info/refs")
}

func (s *server) uploadPack(w http.ResponseWriter, r *http.Request) {
	s.runGitHTTPBackend(w, r, "/git-upload-pack")
}

// runGitHTTPBackend serves one smart-HTTP request by running `git
// http-backend` as a CGI script against the repository the id resolves to,
// streaming its response straight through without buffering the packfile in
// memory. GIT_PROJECT_ROOT is the repositories directory and PATH_INFO names
// the one repository this request is for; both are computed here from the id
// the store already resolved, never from anything on the wire, so there is
// no path traversal through PATH_INFO into another mirrored repository.
func (s *server) runGitHTTPBackend(w http.ResponseWriter, r *http.Request, suffix string) {
	dir, err := s.store.RepoDir(r.PathValue("id"))
	if err != nil {
		writeStoreError(w, err)
		return
	}

	cmd := exec.CommandContext(r.Context(), gitHTTPBackend[0], gitHTTPBackend[1:]...)
	cmd.Env = []string{
		"PATH=/usr/local/bin:/usr/bin:/bin",
		"HOME=/tmp",
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_PROJECT_ROOT=" + filepath.Dir(dir),
		"GIT_HTTP_EXPORT_ALL=1",
		"GIT_HTTP_MAX_REQUEST_BUFFER=" + gitHTTPMaxRequestBuffer,
		"PATH_INFO=/" + filepath.Base(dir) + suffix,
		"REQUEST_METHOD=" + r.Method,
		"QUERY_STRING=" + r.URL.RawQuery,
		"CONTENT_TYPE=" + r.Header.Get("Content-Type"),
		"CONTENT_LENGTH=" + r.Header.Get("Content-Length"),
		"REMOTE_ADDR=" + r.RemoteAddr,
		"SERVER_PROTOCOL=" + r.Proto,
	}
	if encoding := r.Header.Get("Content-Encoding"); encoding != "" {
		cmd.Env = append(cmd.Env, "CONTENT_ENCODING="+encoding)
	}
	cmd.Stdin = r.Body

	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "unavailable", "git http-backend: "+err.Error())
		return
	}
	if err := cmd.Start(); err != nil {
		writeError(w, http.StatusServiceUnavailable, "unavailable", "git http-backend: "+err.Error())
		return
	}

	reader := bufio.NewReader(stdout)
	header, status, err := readCGIResponse(reader)
	if err != nil {
		_ = cmd.Wait()
		writeError(w, http.StatusServiceUnavailable, "unavailable", "git http-backend: "+strings.TrimSpace(stderr.String()))
		return
	}
	for key, values := range header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(status)
	_, _ = io.Copy(w, reader)
	if err := cmd.Wait(); err != nil {
		log.Printf("git-mirror: git http-backend %s: %v: %s", suffix, err, strings.TrimSpace(stderr.String()))
	}
}

// readCGIResponse parses the CGI header block git-http-backend writes ahead
// of the body: MIME headers terminated by a blank line, with an optional
// "Status: <code> <text>" line naming the HTTP status (git omits it for a
// plain 200).
func readCGIResponse(r *bufio.Reader) (http.Header, int, error) {
	header, err := textproto.NewReader(r).ReadMIMEHeader()
	if err != nil {
		return nil, 0, err
	}
	status := http.StatusOK
	if raw := header.Get("Status"); raw != "" {
		header.Del("Status")
		if fields := strings.Fields(raw); len(fields) > 0 {
			if parsed, convErr := strconv.Atoi(fields[0]); convErr == nil {
				status = parsed
			}
		}
	}
	return http.Header(header), status, nil
}

func maxAgeFrom(r *http.Request) (time.Duration, bool) {
	raw := r.URL.Query().Get("max_age")
	if raw == "" {
		return 60 * time.Second, true
	}
	seconds, err := strconv.Atoi(raw)
	return time.Duration(seconds) * time.Second, err == nil && seconds >= 0
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
