package cmd

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestRootCommandReportsMissingCredentials(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected missing credentials error")
	}
	if err.Error() != loginMessage {
		t.Fatalf("error = %q", err.Error())
	}
}

func TestLoginCommandWritesCredentials(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	input := strings.NewReader("https://syrus.example.com\nsecret-token\n")
	output := &bytes.Buffer{}
	command := NewLoginCommand()
	command.SetIn(input)
	command.SetOut(output)

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	contents, err := os.ReadFile(filepath.Join(home, ".syrus", "credentials"))
	if err != nil {
		t.Fatal(err)
	}
	if got := string(contents); got != "url=https://syrus.example.com\ntoken=secret-token\n" {
		t.Fatalf("credentials file = %q", got)
	}
}

func TestRootCommandSelectsExistingSessionAndRunsREPL(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeTestCredentials(t, home, "")

	var streamedBody string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/chats":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"chats":[{"id":42,"title":"Planning open source release","repository":{"id":7,"slug":"tkadauke/syrus"},"updated_at":"2026-06-11T12:00:00Z"}],"repositories":[{"id":7,"slug":"tkadauke/syrus"}]}`))
		case "/api/v1/app/chats/42/message":
			body := new(bytes.Buffer)
			body.ReadFrom(r.Body)
			streamedBody = body.String()
			w.Header().Set("Content-Type", "text/event-stream")
			w.Write([]byte("event: text_chunk\ndata: {\"content\":\"Ave\"}\n\n"))
			w.Write([]byte("event: turn_complete\ndata: {}\n\n"))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writeTestCredentials(t, home, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetIn(strings.NewReader("1\nhello\n"))
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if streamedBody != `{"content":"hello"}` {
		t.Fatalf("streamed body = %q", streamedBody)
	}
	if got := output.String(); !strings.Contains(got, "Recent sessions:") || !strings.Contains(got, "You: ") || !strings.Contains(got, "Ave") {
		t.Fatalf("output = %q", got)
	}
}

func TestRootCommandCreatesRepoAttachedSession(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	repoDir := initGitRepo(t, "git@github.com:tkadauke/syrus.git")
	oldwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(repoDir); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(oldwd)

	var createPayload struct {
		RepositoryID int64 `json:"repository_id"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/chats":
			if r.Method == http.MethodGet {
				w.Header().Set("Content-Type", "application/json")
				w.Write([]byte(`{"chats":[],"repositories":[{"id":7,"slug":"tkadauke/syrus"}]}`))
				return
			}
			if err := json.NewDecoder(r.Body).Decode(&createPayload); err != nil {
				t.Fatal(err)
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			w.Write([]byte(`{"chat":{"id":99,"title":"syrus","repository":{"id":7,"slug":"tkadauke/syrus"}}}`))
		case "/api/v1/app/chats/99/message":
			w.Header().Set("Content-Type", "text/event-stream")
			w.Write([]byte("event: text_chunk\ndata: {\"content\":\"Done\"}\n\n"))
			w.Write([]byte("event: turn_complete\ndata: {}\n\n"))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writeTestCredentials(t, home, server.URL)

	command := NewRootCommand()
	command.SetIn(strings.NewReader("1\nstart\n"))
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if createPayload.RepositoryID != 7 {
		t.Fatalf("repository_id = %d", createPayload.RepositoryID)
	}
}

func TestRootCommandHandlesMultipleChatProposalsSequentially(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeTestCredentials(t, home, "")

	var actions []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/chats":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"chats":[{"id":42,"title":"Planning","repository":{"id":7,"slug":"tkadauke/syrus"},"updated_at":"2026-06-11T12:00:00Z"}],"repositories":[{"id":7,"slug":"tkadauke/syrus"}]}`))
		case "/api/v1/app/chats/42/message":
			w.Header().Set("Content-Type", "text/event-stream")
			w.Write([]byte("event: text_chunk\ndata: {\"content\":\"Proposal proposed.\",\"message\":{\"proposal\":{\"id\":5,\"title\":\"Add dark mode\"}}}\n\n"))
			w.Write([]byte("event: proposal\ndata: {\"proposal\":{\"id\":5,\"title\":\"Add dark mode\",\"scoped_repository_slug\":\"tkadauke/myapp\",\"app_confirm_path\":\"/api/v1/app/chats/42/proposals/5/confirm\",\"app_reject_path\":\"/api/v1/app/chats/42/proposals/5/reject\"}}\n\n"))
			w.Write([]byte("event: proposal\ndata: {\"proposal\":{\"id\":6,\"title\":\"Settings dignity\",\"epic_bundle\":true,\"active_children_count\":2,\"app_confirm_path\":\"/api/v1/app/chats/42/proposals/6/confirm\",\"app_reject_path\":\"/api/v1/app/chats/42/proposals/6/reject\"}}\n\n"))
			w.Write([]byte("event: turn_complete\ndata: {}\n\n"))
		case "/api/v1/app/chats/42/proposals/5/confirm":
			actions = append(actions, "confirm-5")
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"message":"Proposal confirmed."}`))
		case "/api/v1/app/chats/42/proposals/6/reject":
			actions = append(actions, "reject-6")
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"message":"Proposal rejected."}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writeTestCredentials(t, home, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetIn(strings.NewReader("1\nhello\nc\nx\n"))
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := strings.Join(actions, ","); got != "confirm-5,reject-6" {
		t.Fatalf("actions = %q", got)
	}
	text := output.String()
	for _, want := range []string{"Proposed Job", "Add dark mode", "Repository: tkadauke/myapp", "Filed.", "Proposed Epic", "2 child Jobs", "Choose c to confirm or s to skip. Skipping.", "Skipped."} {
		if !strings.Contains(text, want) {
			t.Fatalf("output missing %q: %q", want, text)
		}
	}
	if strings.Contains(text, "Proposal proposed.") {
		t.Fatalf("placeholder proposal text was rendered: %q", text)
	}
}

func writeTestCredentials(t *testing.T, home string, serverURL string) {
	t.Helper()
	if serverURL == "" {
		serverURL = "https://syrus.example.com"
	}
	if err := os.MkdirAll(filepath.Join(home, ".syrus"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".syrus", "credentials"), []byte("url="+serverURL+"\ntoken=secret-token\n"), 0600); err != nil {
		t.Fatal(err)
	}
}

func initGitRepo(t *testing.T, remote string) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{
		{"init"},
		{"remote", "add", "origin", remote},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, output)
		}
	}
	return dir
}
