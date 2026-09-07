package globalsearch

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

func TestSearchRendersResultsGroupedByType(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/search" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		if got := r.URL.Query().Get("q"); got != "deploy" {
			t.Fatalf("q = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"results":[
			{"type":"job","id":123,"slug":"JOB-123","title":"Fix deploy script","snippet":"<mark>deploy</mark> script","rank":0,"path":"/jobs/123","state":"open","repository_slug":"acme/widgets"},
			{"type":"chat","id":9,"title":"General","snippet":"we should <mark>deploy</mark> soon","rank":1,"path":"/chats/1?message_id=9"}
		]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSearchCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"deploy"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "JOB (1)") || !strings.Contains(got, "JOB-123") || !strings.Contains(got, "Fix deploy script") {
		t.Fatalf("output = %q", got)
	}
	if !strings.Contains(got, "CHAT (1)") || !strings.Contains(got, "#9") {
		t.Fatalf("output = %q", got)
	}
	if strings.Contains(got, "<mark>") {
		t.Fatalf("expected mark tags stripped, got %q", got)
	}
}

func TestSearchPassesTypeFilterThrough(t *testing.T) {
	var gotTypes []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotTypes = r.URL.Query()["types[]"]
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"results":[]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSearchCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"deploy", "--type", "job,chat"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if len(gotTypes) != 2 || gotTypes[0] != "job" || gotTypes[1] != "chat" {
		t.Fatalf("types[] = %v", gotTypes)
	}
	if !strings.Contains(output.String(), "No results.") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestSearchRejectsUnknownType(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSearchCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"deploy", "--type", "bogus"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "unknown --type") {
		t.Fatalf("expected unknown --type error, got %v", err)
	}
}

func TestSearchSurfacesQueryTooShortError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":{"code":"bad_request","message":"query must be at least 2 characters."}}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSearchCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"a"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "query must be at least 2 characters.") {
		t.Fatalf("expected bad_request message, got %v", err)
	}
}

func TestSearchLimitFlagIsPassedThrough(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("limit"); got != "5" {
			t.Fatalf("limit = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"results":[]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSearchCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"deploy", "--limit", "5"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
}

func TestSearchJSONPrintsRawPayload(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"results":[{"type":"job","id":123,"slug":"JOB-123","title":"Fix deploy script","snippet":"deploy","rank":0,"path":"/jobs/123","state":"open","repository_slug":"acme/widgets"}]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSearchCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"deploy", "--json"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, `"slug":"JOB-123"`) {
		t.Fatalf("output = %q", got)
	}
}
