package cmd

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseGitHubSlug(t *testing.T) {
	tests := map[string]string{
		"https://github.com/tkadauke/syrus.git": "tkadauke/syrus",
		"git@github.com:tkadauke/syrus.git":    "tkadauke/syrus",
		"https://github.com/acme/my.repo":       "acme/my.repo",
		"https://example.com/acme/my.repo":      "",
	}

	for remote, want := range tests {
		if got := parseGitHubSlug(remote); got != want {
			t.Fatalf("parseGitHubSlug(%q) = %q, want %q", remote, got, want)
		}
	}
}

func TestLast4(t *testing.T) {
	if got := last4("secret-token"); got != "oken" {
		t.Fatalf("last4 returned %q", got)
	}
	if got := last4("abc"); got != "abc" {
		t.Fatalf("last4 short token returned %q", got)
	}
}

func TestEpicCreatePostsToCurrentRepository(t *testing.T) {
	var postSeen bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
			t.Fatalf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/epics/new":
			w.Write([]byte(`{"repositories":[{"id":3,"slug":"acme/widgets"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/app/epics":
			postSeen = true
			var payload struct {
				Epic struct {
					RepositoryID int64  `json:"repository_id"`
					Title        string `json:"title"`
					Description  string `json:"description"`
				} `json:"epic"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload.Epic.RepositoryID != 3 {
				t.Fatalf("repository_id = %d", payload.Epic.RepositoryID)
			}
			if payload.Epic.Title != "Raise the forum" {
				t.Fatalf("title = %q", payload.Epic.Title)
			}
			if payload.Epic.Description != "Install tasteful columns.\nThen hold court." {
				t.Fatalf("description = %q", payload.Epic.Description)
			}
			w.Write([]byte(`{"redirect_to":"/epics/12","epic":{"id":12,"title":"Raise the forum"}}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	command := NewEpicCommand()
	input := strings.NewReader("Raise the forum\nInstall tasteful columns.\nThen hold court.\n\ny\n")
	output := &bytes.Buffer{}
	command.SetIn(input)
	command.SetOut(output)
	command.SetArgs([]string{"create"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !postSeen {
		t.Fatal("expected POST /api/v1/app/epics")
	}
	if got := output.String(); !strings.Contains(got, "Create epic in acme/widgets? [y/N] ") {
		t.Fatalf("output missing confirmation prompt: %q", got)
	}
	if got := output.String(); !strings.Contains(got, "Epic #12\n"+server.URL+"/epics/12") {
		t.Fatalf("output = %q", got)
	}
}

func TestEpicCreateYesSkipsConfirmation(t *testing.T) {
	var postSeen bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/epics/new":
			w.Write([]byte(`{"repositories":[{"id":3,"slug":"acme/widgets"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/app/epics":
			postSeen = true
			w.Write([]byte(`{"redirect_to":"/epics/13","epic":{"id":13}}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	command := NewEpicCommand()
	output := &bytes.Buffer{}
	command.SetIn(strings.NewReader("Raise the forum\nInstall tasteful columns.\n\n"))
	command.SetOut(output)
	command.SetArgs([]string{"create", "--yes"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !postSeen {
		t.Fatal("expected POST /api/v1/app/epics")
	}
	if strings.Contains(output.String(), "Create epic in acme/widgets?") {
		t.Fatalf("confirmation prompt was printed: %q", output.String())
	}
}

func TestEpicCreateStopsWhenConfirmationIsDeclined(t *testing.T) {
	var postSeen bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/epics/new":
			w.Write([]byte(`{"repositories":[{"id":3,"slug":"acme/widgets"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/app/epics":
			postSeen = true
			w.Write([]byte(`{"epic":{"id":14}}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	command := NewEpicCommand()
	output := &bytes.Buffer{}
	command.SetIn(strings.NewReader("Raise the forum\nInstall tasteful columns.\n\nn\n"))
	command.SetOut(output)
	command.SetArgs([]string{"create"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if postSeen {
		t.Fatal("did not expect POST /api/v1/app/epics")
	}
	if !strings.Contains(output.String(), "Cancelled.") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestEpicCreateRequiresCurrentRepository(t *testing.T) {
	withCredentials(t, "https://syrus.example.com", "secret-token")
	withRepoSlug(t, "")

	command := NewEpicCommand()
	command.SetIn(strings.NewReader("Raise the forum\n\n"))
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"create", "--yes"})

	err := command.Execute()
	if err == nil || err.Error() != "syrus epic create requires a GitHub repository remote" {
		t.Fatalf("error = %v", err)
	}
}

func TestEpicCreateRequiresAvailableRepository(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"repositories":[{"id":4,"slug":"other/private"}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	command := NewEpicCommand()
	command.SetIn(strings.NewReader("Raise the forum\n\n"))
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"create", "--yes"})

	err := command.Execute()
	if err == nil || err.Error() != "repository acme/widgets is not available to this Syrus user" {
		t.Fatalf("error = %v", err)
	}
}

func TestEpicOpenUsesConfiguredInstanceURL(t *testing.T) {
	withCredentials(t, "https://syrus.example.com/", "secret-token")
	var opened []string
	oldOpenURL := openURL
	openURL = func(target string) error {
		opened = append(opened, target)
		return nil
	}
	t.Cleanup(func() { openURL = oldOpenURL })

	command := NewEpicCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"open", "12"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if len(opened) != 1 || opened[0] != "https://syrus.example.com/epics/12" {
		t.Fatalf("opened = %#v", opened)
	}
	if output.String() != "https://syrus.example.com/epics/12\n" {
		t.Fatalf("output = %q", output.String())
	}
}

func withCredentials(t *testing.T, url string, token string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, ".syrus", "credentials")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("url="+url+"\ntoken="+token+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
}

func withRepoSlug(t *testing.T, slug string) {
	t.Helper()
	oldDetect := detectCurrentRepoSlug
	detectCurrentRepoSlug = func() string { return slug }
	t.Cleanup(func() { detectCurrentRepoSlug = oldDetect })
}
