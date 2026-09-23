package server

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/tkadauke/syrus/plugins/git_mirror/container/internal/mirror"
)

const token = "0123456789abcdef0123456789abcdef"

type fakeStore struct {
	registered               map[string]mirror.Registration
	resolveErr               error
	readErr                  error
	repoDir                  string
	repoDirErr               error
	maxAge                   time.Duration
	withPatch                bool
	history                  mirror.History
	historyErr               error
	historyBase, historyHead string
}

func (f *fakeStore) Register(_ context.Context, id string, reg mirror.Registration) error {
	f.registered[id] = reg
	return nil
}
func (f *fakeStore) Remove(string) error   { return mirror.ErrUnknownRepository }
func (f *fakeStore) List() []mirror.Status { return []mirror.Status{{ID: "1", HasCredential: true}} }
func (f *fakeStore) Disk() mirror.Disk {
	return mirror.Disk{TotalBytes: 100, FreeBytes: 40, MirrorBytes: 10}
}
func (f *fakeStore) Resolve(_ context.Context, _, _ string, maxAge time.Duration) (string, time.Time, error) {
	f.maxAge = maxAge
	return "abc", time.Unix(0, 0), f.resolveErr
}
func (f *fakeStore) Tree(context.Context, string, string) ([]mirror.Entry, error) { return nil, nil }
func (f *fakeStore) Read(context.Context, string, string, string) (mirror.Blob, error) {
	return mirror.Blob{Bytes: []byte{0xff, 0x00}, ContentID: "oid"}, f.readErr
}
func (f *fakeStore) Changes(_ context.Context, _, _, _ string, withPatch bool) ([]mirror.Change, error) {
	f.withPatch = withPatch
	return nil, nil
}
func (f *fakeStore) Refs(_ context.Context, _, _ string, maxAge time.Duration) ([]mirror.Ref, error) {
	f.maxAge = maxAge
	return nil, nil
}
func (f *fakeStore) Relation(context.Context, string, string, string) (string, error) {
	return "ahead", nil
}
func (f *fakeStore) RepoDir(string) (string, error) {
	if f.repoDirErr != nil {
		return "", f.repoDirErr
	}
	if f.repoDir != "" {
		return f.repoDir, nil
	}
	return "", mirror.ErrUnknownRepository
}

func (f *fakeStore) History(_ context.Context, _, base, head string) (mirror.History, error) {
	f.historyBase, f.historyHead = base, head
	return f.history, f.historyErr
}

func do(h http.Handler, method, path, body string, authed bool) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if authed {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func errorCode(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error struct{ Code string } `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("not an error body: %s", rec.Body)
	}
	return body.Error.Code
}

func TestEveryRouteButHealthNeedsTheToken(t *testing.T) {
	h := New(&fakeStore{registered: map[string]mirror.Registration{}}, token)
	if rec := do(h, "GET", "/healthz", "", false); rec.Code != http.StatusOK {
		t.Fatalf("healthz: %d", rec.Code)
	}
	for _, path := range []string{"/v1/repositories", "/v1/repositories/1/resolve?ref=main", "/v1/repositories/1/blob?revision=a&path=b"} {
		if rec := do(h, "GET", path, "", false); rec.Code != http.StatusUnauthorized {
			t.Fatalf("%s without token: %d", path, rec.Code)
		}
	}
}

func TestRegisterAcceptsTheCredentialAndListNeverReturnsIt(t *testing.T) {
	store := &fakeStore{registered: map[string]mirror.Registration{}}
	h := New(store, token)

	rec := do(h, "PUT", "/v1/repositories/7", `{"vcs":"git","url":"https://github.com/a/b.git","username":"x-access-token","password":"ghs_secret"}`, true)
	if rec.Code != http.StatusOK || store.registered["7"].Password != "ghs_secret" {
		t.Fatalf("register: %d %s", rec.Code, rec.Body)
	}
	if list := do(h, "GET", "/v1/repositories", "", true); strings.Contains(list.Body.String(), "ghs_secret") {
		t.Fatalf("list leaked the credential: %s", list.Body)
	}
	if rec := do(h, "PUT", "/v1/repositories/7", `{"vcs":"git","url":"x","privileged":true}`, true); rec.Code != http.StatusBadRequest {
		t.Fatalf("unknown field: %d", rec.Code)
	}
}

func TestErrorsCarryCodesTheSyrusPluginMaps(t *testing.T) {
	cases := map[error]struct {
		status int
		code   string
	}{
		mirror.ErrUnknownRevision:   {http.StatusNotFound, "unknown_revision"},
		mirror.ErrNotFound:          {http.StatusNotFound, "not_found"},
		mirror.ErrUnknownRepository: {http.StatusNotFound, "unknown_repository"},
		mirror.ErrUnavailable:       {http.StatusServiceUnavailable, "unavailable"},
		mirror.ErrUnsupported:       {http.StatusNotImplemented, "unsupported"},
	}
	for err, want := range cases {
		h := New(&fakeStore{readErr: err}, token)
		rec := do(h, "GET", "/v1/repositories/1/blob?revision=a&path=b", "", true)
		if rec.Code != want.status || errorCode(t, rec) != want.code {
			t.Errorf("%v: got %d %s, want %d %s", err, rec.Code, rec.Body, want.status, want.code)
		}
	}
}

func TestBlobIsRawBytes(t *testing.T) {
	rec := do(New(&fakeStore{}, token), "GET", "/v1/repositories/1/blob?revision=a&path=b", "", true)
	if rec.Body.String() != "\xff\x00" || rec.Header().Get("X-Content-Id") != "oid" {
		t.Fatalf("got %q %v", rec.Body, rec.Header())
	}
}

func TestResolvePassesMaxAge(t *testing.T) {
	store := &fakeStore{}
	h := New(store, token)
	do(h, "GET", "/v1/repositories/1/resolve?ref=main&max_age=0", "", true)
	if store.maxAge != 0 {
		t.Fatalf("max_age 0 became %v", store.maxAge)
	}
	do(h, "GET", "/v1/repositories/1/resolve?ref=main", "", true)
	if store.maxAge != time.Minute {
		t.Fatalf("default max_age = %v", store.maxAge)
	}
	if rec := do(h, "GET", "/v1/repositories/1/resolve?ref=main&max_age=-1", "", true); rec.Code != http.StatusBadRequest {
		t.Fatalf("negative max_age: %d", rec.Code)
	}
}

func TestChangesPassesThePatchFlag(t *testing.T) {
	store := &fakeStore{}
	h := New(store, token)
	if rec := do(h, "GET", "/v1/repositories/1/changes?base=a&head=b&patch=1", "", true); rec.Code != http.StatusOK || !store.withPatch {
		t.Fatalf("patch=1: %d, withPatch=%v", rec.Code, store.withPatch)
	}
	do(h, "GET", "/v1/repositories/1/changes?base=a&head=b", "", true)
	if store.withPatch {
		t.Fatal("patches returned without being asked for")
	}
}

func TestHistoryPassesBaseAndHeadAndNormalizesNilCommits(t *testing.T) {
	store := &fakeStore{}
	h := New(store, token)
	rec := do(h, "GET", "/v1/repositories/1/history?base=a&head=b", "", true)
	if rec.Code != http.StatusOK {
		t.Fatalf("history: %d %s", rec.Code, rec.Body)
	}
	if store.historyBase != "a" || store.historyHead != "b" {
		t.Fatalf("history base/head = %q/%q", store.historyBase, store.historyHead)
	}
	var body struct {
		Commits     []mirror.Commit `json:"commits"`
		MergeBaseID string          `json:"merge_base_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v: %s", err, rec.Body)
	}
	if body.Commits == nil || len(body.Commits) != 0 {
		t.Fatalf("nil commits should serialize as [], got %v", rec.Body)
	}
}

func TestHistoryMapsUnsupportedTheSameWayChangesDoes(t *testing.T) {
	rec := do(New(&fakeStore{historyErr: mirror.ErrUnsupported}, token), "GET", "/v1/repositories/1/history?base=a&head=b", "", true)
	if rec.Code != http.StatusNotImplemented || errorCode(t, rec) != "unsupported" {
		t.Fatalf("history error: %d %s", rec.Code, rec.Body)
	}
}

func TestHistoryReturnsCommitsAndMergeBase(t *testing.T) {
	when, _ := time.Parse(time.RFC3339, "2026-09-22T12:00:00Z")
	store := &fakeStore{history: mirror.History{
		Commits:     []mirror.Commit{{SHA: strings.Repeat("c", 40), Message: "m", AuthoredAt: when}},
		MergeBaseID: "base-sha",
	}}
	rec := do(New(store, token), "GET", "/v1/repositories/1/history?base=a&head=b", "", true)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"merge_base_id":"base-sha"`) {
		t.Fatalf("history: %d %s", rec.Code, rec.Body)
	}
}

func TestRequestLogRecordsReadsButNotHealthChecksOrCredentials(t *testing.T) {
	var buf bytes.Buffer
	store := &fakeStore{registered: map[string]mirror.Registration{}}
	h := NewWithLogger(store, token, log.New(&buf, "", 0))

	do(h, "GET", "/healthz", "", false)
	do(h, "GET", "/v1/repositories/1/blob?revision=a&path=README", "", true)
	do(h, "GET", "/v1/repositories/1/resolve?ref=main", "", false)
	do(h, "PUT", "/v1/repositories/1", `{"vcs":"git","url":"https://github.com/a/b.git","password":"ghs_secret"}`, true)

	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("expected 3 lines, got %q", buf.String())
	}
	if !strings.HasPrefix(lines[0], "GET /v1/repositories/1/blob?revision=a&path=README 200 2B ") {
		t.Errorf("read line = %q", lines[0])
	}
	if !strings.HasPrefix(lines[1], "GET /v1/repositories/1/resolve?ref=main 401 ") {
		t.Errorf("unauthorized line = %q", lines[1])
	}
	if strings.Contains(buf.String(), "ghs_secret") || strings.Contains(buf.String(), "healthz") {
		t.Errorf("log leaked a credential or a health check:\n%s", buf.String())
	}
}

func TestListReportsDisk(t *testing.T) {
	rec := do(New(&fakeStore{}, token), "GET", "/v1/repositories", "", true)
	if !strings.Contains(rec.Body.String(), `"disk":{"total_bytes":100,"free_bytes":40,"mirror_bytes":10}`) {
		t.Fatalf("body = %s", rec.Body)
	}
}

func TestInfoRefsOnlyServesUploadPack(t *testing.T) {
	h := New(&fakeStore{repoDir: t.TempDir()}, token)
	if rec := do(h, "GET", "/v1/repositories/1/info/refs?service=git-receive-pack", "", true); rec.Code != http.StatusForbidden || errorCode(t, rec) != "unsupported" {
		t.Fatalf("git-receive-pack: %d %s", rec.Code, rec.Body)
	}
	if rec := do(h, "GET", "/v1/repositories/1/info/refs", "", true); rec.Code != http.StatusForbidden {
		t.Fatalf("missing service param: %d %s", rec.Code, rec.Body)
	}
}

func TestSmartHTTPRoutesNeedTheTokenAndAKnownRepository(t *testing.T) {
	h := New(&fakeStore{}, token)
	if rec := do(h, "GET", "/v1/repositories/1/info/refs?service=git-upload-pack", "", false); rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated info/refs: %d", rec.Code)
	}
	if rec := do(h, "GET", "/v1/repositories/1/info/refs?service=git-upload-pack", "", true); rec.Code != http.StatusNotFound || errorCode(t, rec) != "unknown_repository" {
		t.Fatalf("unknown repository: %d %s", rec.Code, rec.Body)
	}
}

// No route exists for git-receive-pack at all -- the strongest form of
// "never accept a push" is not wiring the handler up, not rejecting it once
// reached.
func TestNoRouteAcceptsGitReceivePack(t *testing.T) {
	h := New(&fakeStore{repoDir: t.TempDir()}, token)
	if rec := do(h, "POST", "/v1/repositories/1/git-receive-pack", "", true); rec.Code != http.StatusNotFound {
		t.Fatalf("git-receive-pack has no route but got %d: %s", rec.Code, rec.Body)
	}
}

func gitTestEnv() []string {
	return append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
}

func runGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = gitTestEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// runGitAuthed passes the bearer token the same way Syrus is expected to:
// as an http.extraHeader for this invocation only, never embedded in the
// URL or persisted into the repository's config.
func runGitAuthed(dir, bearer string, args ...string) (string, error) {
	full := append([]string{"-c", "http.extraHeader=Authorization: Bearer " + bearer}, args...)
	cmd := exec.Command("git", full...)
	cmd.Dir = dir
	cmd.Env = gitTestEnv()
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// End-to-end: a real git client clone/fetch against the smart-HTTP routes,
// wired to a real mirror.Store fetching from a real (file://) upstream --
// not the fakeStore the other tests use. Proves the CGI wiring in
// runGitHTTPBackend actually produces a working git transport, that auth
// gates it the same as the JSON routes, and that a push is refused outright.
func TestSmartHTTPServesRealClonesAndFetchesButRefusesAPush(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}

	upstream := t.TempDir()
	runGit(t, upstream, "init", "--quiet", "--initial-branch=main")
	runGit(t, upstream, "config", "user.email", "test@example.test")
	runGit(t, upstream, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(upstream, "README"), []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, upstream, "add", "-A")
	runGit(t, upstream, "commit", "--quiet", "-m", "first")

	store, err := mirror.Open(mirror.Config{DataDir: t.TempDir(), AllowFileURLs: true})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if err := store.Register(ctx, "9", mirror.Registration{VCS: "git", URL: "file://" + upstream}); err != nil {
		t.Fatal(err)
	}
	// Register's own first fetch runs in the background; Resolve fetches
	// synchronously when the mirror hasn't caught up yet, so this both
	// waits for it and proves the commit reached the mirror's disk.
	sha := runGit(t, upstream, "rev-parse", "HEAD")
	if got, _, err := store.Resolve(ctx, "9", "main", time.Minute); err != nil || got != sha {
		t.Fatalf("resolve main = %q, %v; want %q", got, err, sha)
	}

	srv := httptest.NewServer(New(store, token))
	defer srv.Close()
	cloneURL := srv.URL + "/v1/repositories/9"

	if out, err := runGitAuthed("", "wrong-token", "clone", "--quiet", cloneURL, filepath.Join(t.TempDir(), "unauth")); err == nil {
		t.Fatalf("clone with the wrong token should have failed:\n%s", out)
	}

	dest := filepath.Join(t.TempDir(), "clone")
	if out, err := runGitAuthed("", token, "clone", "--quiet", cloneURL, dest); err != nil {
		t.Fatalf("authenticated clone failed: %v\n%s", err, out)
	}
	if got, err := os.ReadFile(filepath.Join(dest, "README")); err != nil || string(got) != "hi" {
		t.Fatalf("README after clone = %q, %v", got, err)
	}

	// A second upstream commit, fetched into the mirror, must reach the
	// clone through an ordinary `git fetch` against the mirror -- proves
	// fetch, not just the initial clone, is served.
	if err := os.WriteFile(filepath.Join(upstream, "README"), []byte("bye"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, upstream, "commit", "--quiet", "-am", "second")
	newSHA := runGit(t, upstream, "rev-parse", "HEAD")
	if got, _, err := store.Resolve(ctx, "9", "main", time.Millisecond); err != nil || got != newSHA {
		t.Fatalf("resolve after second commit = %q, %v; want %q", got, err, newSHA)
	}
	if out, err := runGitAuthed(dest, token, "fetch", "--quiet", "origin", "main"); err != nil {
		t.Fatalf("authenticated fetch failed: %v\n%s", err, out)
	}
	if fetchedHead := runGit(t, dest, "rev-parse", "FETCH_HEAD"); fetchedHead != newSHA {
		t.Fatalf("fetched head = %q, want %q", fetchedHead, newSHA)
	}

	// No git-receive-pack route exists, so a push must fail outright.
	if out, err := runGitAuthed(dest, token, "push", cloneURL, "HEAD:refs/heads/pushed"); err == nil {
		t.Fatalf("push should have failed:\n%s", out)
	}
}
