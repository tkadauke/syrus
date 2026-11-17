package scheduledtasks

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/cliplugin/cliplugintest"
)

func TestScheduleListScopesToCurrentRepositoryWhenPresent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"active_tasks":[{"id":1,"name":"Mine","cron_expression":"0 9 * * 1","repository":{"slug":"acme/widgets"}},{"id":2,"name":"Other","repository":{"slug":"acme/other"}}]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")
	cliplugintest.WithRepoSlug(t, "acme/widgets")

	command := NewScheduleCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"list"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "Mine") || strings.Contains(output.String(), "Other") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestScheduleCreatePostsToCurrentRepository(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/repositories":
			w.Write([]byte(`{"active_repositories":[{"id":7,"slug":"acme/widgets"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/app/repositories/7/scheduled_tasks":
			w.Write([]byte(`{"task":{"id":42}}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")
	cliplugintest.WithRepoSlug(t, "acme/widgets")

	command := NewScheduleCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetIn(strings.NewReader("Weekly tests\n0 9 * * 1\nWrite missing tests.\n\n"))
	command.SetArgs([]string{"create", "--yes"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "Created schedule #42") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestScheduleDeleteRequiresConfirmation(t *testing.T) {
	deleted := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet {
			w.Write([]byte(`{"task":{"id":42,"name":"Weekly tests"}}`))
			return
		}
		deleted = true
		w.Write([]byte(`{}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewScheduleCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetIn(strings.NewReader("y\n"))
	command.SetArgs([]string{"delete", "42"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !deleted || !strings.Contains(output.String(), "Deleted schedule #42") {
		t.Fatalf("deleted=%v output=%q", deleted, output.String())
	}
}
