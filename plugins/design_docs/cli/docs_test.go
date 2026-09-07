package designdocs

import (
	"bytes"
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

func TestDocsListShowsAllDocsWithNoRepoDetected(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/design_docs" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"design_docs":[{"id":10,"display_id":"DOC-10","title":"Job Backlog","state":"draft","visibility":"public","owner":{"id":1,"name":"Ada"},"repositories":[{"id":1,"slug":"acme/widgets"}],"updated_at":"2026-09-01T00:00:00Z"}]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")
	cliplugintest.WithRepoSlug(t, "")

	command := NewDocsCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"list"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "DOC-10") || !strings.Contains(got, "Job Backlog") || !strings.Contains(got, "Ada") {
		t.Fatalf("output = %q", got)
	}
}

func TestDocsListScopesToAutoDetectedRepository(t *testing.T) {
	var repoIndexSeen bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/repositories":
			w.Write([]byte(`{"active_repositories":[{"id":7,"slug":"acme/widgets"}]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/repositories/7/design_docs":
			repoIndexSeen = true
			w.Write([]byte(`{"design_docs":[{"id":21,"display_id":"DOC-21","title":"K8s Viewer","state":"draft","visibility":"public","repositories":[{"id":7,"slug":"acme/widgets"}]}]}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")
	cliplugintest.WithRepoSlug(t, "acme/widgets")

	command := NewDocsCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"list"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !repoIndexSeen {
		t.Fatal("expected GET .../repositories/7/design_docs")
	}
	if !strings.Contains(output.String(), "DOC-21") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestDocsListRejectsUnknownExplicitRepo(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"active_repositories":[{"id":7,"slug":"acme/widgets"}]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewDocsCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"list", "--repo", "acme/unknown"})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected an error for an unconfigured --repo")
	}
	if !strings.Contains(err.Error(), "acme/unknown") {
		t.Fatalf("error = %q", err.Error())
	}
}

func TestDocsListFallsBackToAllDocsWhenAutoDetectedRepoUnknown(t *testing.T) {
	var docsIndexSeen bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/repositories":
			w.Write([]byte(`{"active_repositories":[{"id":7,"slug":"acme/other"}]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/design_docs":
			docsIndexSeen = true
			w.Write([]byte(`{"design_docs":[{"id":10,"display_id":"DOC-10","title":"Job Backlog"}]}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")
	cliplugintest.WithRepoSlug(t, "acme/widgets")

	command := NewDocsCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"list"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !docsIndexSeen {
		t.Fatal("expected fallback GET .../design_docs")
	}
	if !strings.Contains(output.String(), "DOC-10") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestDocsShowPrintsRenderedBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/design_docs/10" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"design_doc":{"id":10,"display_id":"DOC-10","title":"Job Backlog","state":"draft","visibility":"public","owner":{"name":"Ada"},"repositories":[{"id":1,"slug":"acme/widgets"}],"updated_at":"2026-09-01T00:00:00Z","rendered_markdown":"# Job Backlog\n\nSome content."}}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewDocsCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"show", "DOC-10"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "DOC-10 · Job Backlog") || !strings.Contains(got, "Some content.") || !strings.Contains(got, "Owner: Ada") {
		t.Fatalf("output = %q", got)
	}
}

func TestDocsShowAcceptsBareNumericID(t *testing.T) {
	var pathSeen string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		pathSeen = r.URL.Path
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"design_doc":{"id":10,"display_id":"DOC-10","title":"Job Backlog","rendered_markdown":"body"}}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewDocsCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"show", "10"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if pathSeen != "/api/v1/app/design_docs/10" {
		t.Fatalf("path = %q", pathSeen)
	}
}

func TestDocsShowNotFound(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte(`{"error":{"code":"not_found","message":"Couldn't find DesignDoc with 'id'=999"}}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewDocsCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"show", "DOC-999"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "DesignDoc") {
		t.Fatalf("expected not-found error, got %v", err)
	}
}

func TestDocsShowSurfacesDisabledPluginError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte(`{"error":{"code":"plugin_disabled","message":"The design_docs plugin is disabled."}}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewDocsCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"show", "DOC-1"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "design_docs plugin is disabled") {
		t.Fatalf("expected plugin_disabled error, got %v", err)
	}
}

func TestDocsShowRequiresID(t *testing.T) {
	command := NewDocsCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"show", ""})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "design doc id is required") {
		t.Fatalf("expected id-required error, got %v", err)
	}
}
