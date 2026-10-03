package credentialstore

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/cliplugin/cliplugintest"
)

func requireAuth(t *testing.T, r *http.Request) {
	t.Helper()
	if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
		t.Fatalf("Authorization = %q", got)
	}
}

func withCredentials(t *testing.T, url string) {
	t.Helper()
	t.Setenv("SYRUS_CLI_URL", "")
	t.Setenv("SYRUS_CLI_INVOCATION_CONTEXT", "")
	t.Setenv("SYRUS_CLI_INTERNAL", "")
	cliplugintest.WithCredentials(t, url, "secret-token")
}

func TestCredentialStoreCredentialsListsSafeHandles(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/credential_store/credentials" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"credentials":[{"id":7,"name":"deploy-token","credential_type":"credential_store.url_token","scope_type":"repository","scope_id":3,"scope_label":"acme/widgets","safe_metadata":{"host":"api.example.com"},"active":true}],"options":{"credential_types":[]}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	command := NewCredentialStoreCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"credentials"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "deploy-token") || !strings.Contains(got, "api.example.com") {
		t.Fatalf("output = %q", got)
	}
	if strings.Contains(got, "super-secret") || strings.Contains(got, "payload") {
		t.Fatalf("output included secret-shaped data: %q", got)
	}
}

func TestCredentialStoreTypesSurfacesPluginDisabled(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte(`{"error":{"code":"plugin_disabled","message":"Plugin credential_store is disabled."}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	command := NewCredentialStoreCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"types"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "credential_store is disabled") {
		t.Fatalf("expected plugin_disabled error, got %v", err)
	}
}

func TestCredentialStoreLeasePostsScopedRequestAndRedactsOutput(t *testing.T) {
	var requestBody map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/app/credential_store/leases" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&requestBody); err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"lease":{"lease_id":"lease-123","credential_id":7,"credential_name":"deploy-token","credential_type":"credential_store.url_token","issued_at":"2026-10-03T00:00:00Z","expires_at":"2026-10-03T00:02:00Z","purpose":"deploy","tool_name":"deploy.push","safe_metadata":{"host":"api.example.com"}}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	command := NewCredentialStoreCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{
		"lease", "deploy-token",
		"--type", "credential_store.url_token",
		"--purpose", "deploy",
		"--tool", "deploy.push",
		"--target-json", `{"host":"api.example.com"}`,
		"--expires-in", "30",
	})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	lease := requestBody["lease"].(map[string]any)
	if lease["credential"] != "deploy-token" || lease["type"] != "credential_store.url_token" || lease["purpose"] != "deploy" {
		t.Fatalf("lease body = %#v", lease)
	}
	got := output.String()
	if !strings.Contains(got, "lease-123") || !strings.Contains(got, "deploy-token") {
		t.Fatalf("output = %q", got)
	}
	if strings.Contains(got, "super-secret") || strings.Contains(got, "payload") {
		t.Fatalf("output included secret-shaped data: %q", got)
	}
}

func TestCredentialStoreLeaseRequiresPolicyFlagsBeforeNetwork(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	command := NewCredentialStoreCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"lease", "deploy-token", "--purpose", "deploy"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "--type is required") {
		t.Fatalf("expected --type error, got %v", err)
	}
}

func TestCredentialStoreLeaseSurfacesAuthorizationFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		w.Write([]byte(`{"error":{"code":"forbidden","message":"credential access denied: tool not allowed"}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	command := NewCredentialStoreCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"lease", "deploy-token", "--type", "credential_store.url_token", "--purpose", "deploy", "--tool", "deploy.push"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "tool not allowed") {
		t.Fatalf("expected authorization failure, got %v", err)
	}
}
