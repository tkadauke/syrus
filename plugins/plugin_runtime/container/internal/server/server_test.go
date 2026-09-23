package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/manager"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/policy"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/privileged"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/spec"
)

const token = "0123456789abcdef0123456789abcdef"

type stubManager struct {
	ensured           bool
	ensuredPrivileged bool
	privilegedEnv     map[string]string
	purged            *bool
	state             string
	err               error
	acted             []string
	tail              int
}

func (s *stubManager) Ensure(_ context.Context, name string, _ spec.Service) (manager.Status, error) {
	s.ensured = true
	return manager.Status{Service: name, State: s.state}, s.err
}
func (s *stubManager) EnsurePrivileged(_ context.Context, name string, env map[string]string) (manager.Status, error) {
	s.ensuredPrivileged = true
	s.privilegedEnv = env
	return manager.Status{Service: name, State: s.state, Privileged: true}, s.err
}
func (s *stubManager) Status(_ context.Context, name string) (manager.Status, error) {
	return manager.Status{Service: name, State: manager.StateRunning}, nil
}
func (s *stubManager) Remove(_ context.Context, _ string, purge bool) error {
	s.purged = &purge
	return nil
}
func (s *stubManager) List(context.Context) ([]manager.Status, error) { return nil, nil }
func (s *stubManager) Stop(_ context.Context, name string) (manager.Status, error) {
	s.acted = append(s.acted, "stop "+name)
	return manager.Status{Service: name, State: manager.StateStopped}, s.err
}
func (s *stubManager) Start(_ context.Context, name string) (manager.Status, error) {
	s.acted = append(s.acted, "start "+name)
	return manager.Status{Service: name, State: manager.StateRunning}, s.err
}
func (s *stubManager) Restart(_ context.Context, name string) (manager.Status, error) {
	s.acted = append(s.acted, "restart "+name)
	return manager.Status{Service: name, State: manager.StateRunning}, s.err
}
func (s *stubManager) Volumes(context.Context) ([]manager.VolumeStatus, error) {
	return []manager.VolumeStatus{{Name: "syrus_plugin_git-mirror_data", Service: "git-mirror", Plugin: "git_mirror"}}, s.err
}
func (s *stubManager) RemoveVolume(_ context.Context, name string) error {
	s.acted = append(s.acted, "remove-volume "+name)
	return s.err
}
func (s *stubManager) PurgePlugin(_ context.Context, plugin string) ([]string, error) {
	s.acted = append(s.acted, "purge "+plugin)
	return []string{"syrus_plugin_git-mirror_data"}, s.err
}
func (s *stubManager) Logs(_ context.Context, name string, tail int) (string, error) {
	s.tail = tail
	return "2026-09-22T01:00:00Z GET /v1/repositories 200\n", s.err
}

const body = `{"plugin":"git_mirror","image":"ghcr.io/tkadauke/x:1","internal_port":8080}`

func do(h http.Handler, method, path, auth, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// Anything on the project network can reach the manager, including agents
// running in the worker. Every route that can change or reveal state needs
// the token.
func TestEveryV1RouteRequiresTheToken(t *testing.T) {
	m := &stubManager{state: manager.StateRunning}
	h := New(m, token, Info{})
	routes := []struct{ method, path string }{
		{"GET", "/v1/services"},
		{"GET", "/v1/services/git-mirror"},
		{"PUT", "/v1/services/git-mirror"},
		{"DELETE", "/v1/services/git-mirror"},
		{"PUT", "/v1/privileged/tailscale"},
		{"POST", "/v1/services/git-mirror/stop"},
		{"POST", "/v1/services/git-mirror/start"},
		{"POST", "/v1/services/git-mirror/restart"},
		{"GET", "/v1/services/git-mirror/logs"},
		{"GET", "/v1/volumes"},
		{"DELETE", "/v1/volumes/syrus_plugin_git-mirror_data"},
		{"DELETE", "/v1/plugins/git_mirror"},
	}
	for _, r := range routes {
		for _, auth := range []string{"", "Bearer wrong", token, "Basic " + token} {
			if rec := do(h, r.method, r.path, auth, body); rec.Code != http.StatusUnauthorized {
				t.Errorf("%s %s with %q: code %d, want 401", r.method, r.path, auth, rec.Code)
			}
		}
	}
	if m.ensured || m.purged != nil || len(m.acted) > 0 || m.tail != 0 {
		t.Fatal("an unauthenticated request reached the manager")
	}
}

func TestHealthzIsOpenAndReportsWhereTheManagerAttached(t *testing.T) {
	rec := do(New(&stubManager{}, token, Info{Project: "syrus", Network: "syrus_default"}), "GET", "/healthz", "", "")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "syrus_default") {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body.String())
	}
}

// Asking for something the manager does not model must fail loudly, not be
// silently dropped -- the caller should learn it cannot have it.
func TestUnknownFieldsAreRefused(t *testing.T) {
	m := &stubManager{state: manager.StateRunning}
	h := New(m, token, Info{})
	for _, extra := range []string{`"privileged":true`, `"devices":["/dev/sda"]`, `"binds":["/:/host"]`, `"network_mode":"host"`} {
		payload := strings.Replace(body, "{", "{"+extra+",", 1)
		if rec := do(h, "PUT", "/v1/services/git-mirror", "Bearer "+token, payload); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: code %d, want 400", extra, rec.Code)
		}
	}
	if m.ensured {
		t.Fatal("a request with a forbidden field reached the manager")
	}
}

func TestPolicyRefusalIs422AndDaemonFailureIs502(t *testing.T) {
	refusing := New(&stubManager{err: policyError()}, token, Info{})
	if rec := do(refusing, "PUT", "/v1/services/git-mirror", "Bearer "+token, body); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("policy refusal: code %d, want 422", rec.Code)
	}
	failing := New(&stubManager{err: context.DeadlineExceeded}, token, Info{})
	if rec := do(failing, "PUT", "/v1/services/git-mirror", "Bearer "+token, body); rec.Code != http.StatusBadGateway {
		t.Errorf("daemon failure: code %d, want 502", rec.Code)
	}
}

// The privileged route's request body carries only env: no image,
// internal_port, volumes, devices, or cap_add key exists for a caller to
// populate, and DisallowUnknownFields refuses one that tries -- the same
// refusal the generic route gives a "privileged" field.
func TestPrivilegedRouteAcceptsOnlyEnv(t *testing.T) {
	m := &stubManager{state: manager.StateRunning}
	h := New(m, token, Info{})

	rec := do(h, "PUT", "/v1/privileged/tailscale", "Bearer "+token, `{"env":{"TS_AUTHKEY":"tskey-abc"}}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("code %d, want 200: %s", rec.Code, rec.Body.String())
	}
	if !m.ensuredPrivileged {
		t.Fatal("expected EnsurePrivileged to be called")
	}
	if m.privilegedEnv["TS_AUTHKEY"] != "tskey-abc" {
		t.Errorf("env = %v", m.privilegedEnv)
	}
	if !strings.Contains(rec.Body.String(), `"privileged":true`) {
		t.Errorf("expected the response to report privileged: true, got %s", rec.Body.String())
	}

	for _, extra := range []string{`"image":"evil/x:1"`, `"internal_port":9`, `"devices":["/dev/sda"]`, `"cap_add":["SYS_ADMIN"]`} {
		m.ensuredPrivileged = false
		payload := strings.Replace(`{"env":{}}`, "{", "{"+extra+",", 1)
		if rec := do(h, "PUT", "/v1/privileged/tailscale", "Bearer "+token, payload); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: code %d, want 400", extra, rec.Code)
		}
		if m.ensuredPrivileged {
			t.Errorf("%s: reached the manager despite the unknown field", extra)
		}
	}
}

// A refusal from the privileged registry (unknown name, disallowed env key)
// must be as loud and as typed as a generic policy refusal.
func TestPrivilegedRefusalIs422(t *testing.T) {
	def, _ := privileged.NewRegistry("img:1", "http://web:80").Lookup("tailscale")
	refused := privileged.ValidateEnv(def, map[string]string{"TS_EXTRA_ARGS": "--accept-routes"})

	h := New(&stubManager{err: refused}, token, Info{})
	if rec := do(h, "PUT", "/v1/privileged/tailscale", "Bearer "+token, `{"env":{}}`); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("code %d, want 422: %s", rec.Code, rec.Body.String())
	}
}

func TestEnsureReturns202WhilePulling(t *testing.T) {
	h := New(&stubManager{state: manager.StatePulling}, token, Info{})
	if rec := do(h, "PUT", "/v1/services/git-mirror", "Bearer "+token, body); rec.Code != http.StatusAccepted {
		t.Fatalf("code %d, want 202", rec.Code)
	}
}

func TestDeletePurgesOnlyWhenAsked(t *testing.T) {
	m := &stubManager{}
	h := New(m, token, Info{})
	do(h, "DELETE", "/v1/services/git-mirror", "Bearer "+token, "")
	if m.purged == nil || *m.purged {
		t.Fatal("a plain DELETE must keep volumes")
	}
	do(h, "DELETE", "/v1/services/git-mirror?purge=true", "Bearer "+token, "")
	if !*m.purged {
		t.Fatal("purge=true must remove volumes")
	}
}

func policyError() error {
	return policy.New(nil).Validate("svc", spec.Service{Plugin: "p", Image: "ghcr.io/x/y:1", InternalPort: 1})
}

func TestOperatorActionsReachTheManager(t *testing.T) {
	m := &stubManager{}
	h := New(m, token, Info{})
	for _, action := range []string{"stop", "start", "restart"} {
		if rec := do(h, "POST", "/v1/services/git-mirror/"+action, "Bearer "+token, ""); rec.Code != http.StatusOK {
			t.Fatalf("%s: code %d: %s", action, rec.Code, rec.Body)
		}
	}
	if strings.Join(m.acted, ",") != "stop git-mirror,start git-mirror,restart git-mirror" {
		t.Fatalf("acted = %v", m.acted)
	}
}

func TestActionsOnAServiceWithoutAContainerAre404(t *testing.T) {
	h := New(&stubManager{err: manager.ErrNotFound}, token, Info{})
	if rec := do(h, "POST", "/v1/services/git-mirror/stop", "Bearer "+token, ""); rec.Code != http.StatusNotFound {
		t.Fatalf("code %d, want 404", rec.Code)
	}
}

func TestLogsArePlainTextWithABoundedTail(t *testing.T) {
	m := &stubManager{}
	h := New(m, token, Info{})

	rec := do(h, "GET", "/v1/services/git-mirror/logs", "Bearer "+token, "")
	if rec.Code != http.StatusOK || !strings.HasPrefix(rec.Header().Get("Content-Type"), "text/plain") || !strings.Contains(rec.Body.String(), "GET /v1/repositories") {
		t.Fatalf("got %d %q %q", rec.Code, rec.Header().Get("Content-Type"), rec.Body)
	}
	if m.tail != 200 {
		t.Fatalf("default tail = %d, want 200", m.tail)
	}
	do(h, "GET", "/v1/services/git-mirror/logs?tail=999999", "Bearer "+token, "")
	if m.tail != 5000 {
		t.Fatalf("tail was not capped: %d", m.tail)
	}
	if rec := do(h, "GET", "/v1/services/git-mirror/logs?tail=zero", "Bearer "+token, ""); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad tail: %d", rec.Code)
	}
}

func TestVolumeRoutes(t *testing.T) {
	m := &stubManager{}
	h := New(m, token, Info{})
	if rec := do(h, "GET", "/v1/volumes", "Bearer "+token, ""); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "git-mirror") {
		t.Fatalf("list: %d %s", rec.Code, rec.Body)
	}
	if rec := do(h, "DELETE", "/v1/volumes/syrus_plugin_git-mirror_data", "Bearer "+token, ""); rec.Code != http.StatusNoContent {
		t.Fatalf("remove: %d", rec.Code)
	}
	if rec := do(h, "DELETE", "/v1/plugins/git_mirror", "Bearer "+token, ""); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "removed_volumes") {
		t.Fatalf("purge: %d %s", rec.Code, rec.Body)
	}
	if strings.Join(m.acted, ",") != "remove-volume syrus_plugin_git-mirror_data,purge git_mirror" {
		t.Fatalf("acted = %v", m.acted)
	}
	if rec := do(New(&stubManager{err: manager.ErrVolumeInUse}, token, Info{}), "DELETE", "/v1/volumes/x", "Bearer "+token, ""); rec.Code != http.StatusConflict {
		t.Fatalf("in use: %d, want 409", rec.Code)
	}
}
