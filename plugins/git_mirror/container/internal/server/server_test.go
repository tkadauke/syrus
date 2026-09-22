package server

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/tkadauke/syrus/plugins/git_mirror/container/internal/mirror"
)

const token = "0123456789abcdef0123456789abcdef"

type fakeStore struct {
	registered map[string]mirror.Registration
	resolveErr error
	readErr    error
	maxAge     time.Duration
	withPatch  bool
}

func (f *fakeStore) Register(_ context.Context, id string, reg mirror.Registration) error {
	f.registered[id] = reg
	return nil
}
func (f *fakeStore) Remove(string) error   { return mirror.ErrUnknownRepository }
func (f *fakeStore) List() []mirror.Status { return []mirror.Status{{ID: "1", HasCredential: true}} }
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
