package cmd

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/internal/api"
)

func TestStatusCommandListsOpenJobs(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	var gotQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
			t.Fatalf("Authorization = %q", got)
		}
		if r.URL.Path != "/api/v1/admin/jobs" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{
			"count": 3,
			"jobs": [
				{"id":42,"repository":"tkadauke/myapp","issue_title":"Add avatar upload","state":"implemented","pr_number":98},
				{"id":43,"repository":"tkadauke/myapp","issue_title":"Fix password reset email","state":"running","pr_number":null},
				{"id":44,"repository":"tkadauke/other-repo","issue_title":"Upgrade Rails to 8.1","state":"queued","pr_number":null}
			]
		}`))
	}))
	defer server.Close()
	writeCredentials(t, home, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"status"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if gotQuery != "state=open" {
		t.Fatalf("query = %q", gotQuery)
	}

	got := output.String()
	for _, want := range []string{
		"ID       REPO                   TITLE",
		"JOB-42   tkadauke/myapp",
		"Add avatar upload",
		"implemented",
		"#98",
		"JOB-43   tkadauke/myapp",
		"Fix password reset email",
		"running",
		"JOB-44   tkadauke/other-repo",
		"Upgrade Rails to 8.1",
		"queued",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("output missing %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "\033[") {
		t.Fatalf("buffer output should not include color escapes:\n%q", got)
	}
}

func TestStatusCommandFiltersClosedJobsByRepo(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	var gotQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"count":0,"jobs":[]}`))
	}))
	defer server.Close()
	writeCredentials(t, home, server.URL)

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"status", "--closed", "--repo", "tkadauke/myapp"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if gotQuery != "repo=tkadauke%2Fmyapp&state=closed" {
		t.Fatalf("query = %q", gotQuery)
	}
}

func TestStatusCommandTruncatesLongTitlesForEightyColumns(t *testing.T) {
	pr := int64(1234)
	output := &bytes.Buffer{}
	renderStatus(output, []api.Job{{
		ID:         77,
		Repository: "tkadauke/myapp",
		IssueTitle: "This title is intentionally far too long for the fixed eighty column status view",
		State:      "running",
		PRNumber:   &pr,
	}}, 80, false)

	lines := strings.Split(strings.TrimRight(output.String(), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("lines = %d:\n%s", len(lines), output.String())
	}
	if len(lines[1]) > 80 {
		t.Fatalf("line length = %d, want <= 80:\n%s", len(lines[1]), lines[1])
	}
	if !strings.Contains(lines[1], "This title is intentionall.") {
		t.Fatalf("title was not truncated as expected:\n%s", lines[1])
	}
}

func writeCredentials(t *testing.T, home string, serverURL string) {
	t.Helper()
	path := filepath.Join(home, ".syrus", "credentials")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("url="+serverURL+"\ntoken=secret-token\n"), 0600); err != nil {
		t.Fatal(err)
	}
}
