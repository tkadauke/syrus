package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

func TestJobCreatePostsDirectJob(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/repositories":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"active_repositories":[{"id":12,"slug":"acme/widgets"}]}`))
		case "/api/v1/app/jobs":
			if r.Method != http.MethodPost {
				t.Fatalf("method = %s", r.Method)
			}
			var payload map[string]any
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload["repository_id"].(float64) != 12 {
				t.Fatalf("repository_id = %#v", payload["repository_id"])
			}
			if payload["title"] != "Tune the aqueduct" {
				t.Fatalf("title = %#v", payload["title"])
			}
			if payload["prompt"] != "Make the CLI flow work.\nKeep the stones numbered." {
				t.Fatalf("prompt = %#v", payload["prompt"])
			}
			for _, omitted := range []string{"priority", "agent_provider", "epic_id", "owner_user_id"} {
				if _, present := payload[omitted]; present {
					t.Fatalf("expected %q to be omitted when not passed, got %#v", omitted, payload[omitted])
				}
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			w.Write([]byte(`{"job":{"id":456,"title":"Tune the aqueduct"},"repository":{"slug":"acme/widgets"}}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetIn(strings.NewReader("Tune the aqueduct\nMake the CLI flow work.\nKeep the stones numbered.\n\n"))
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "create", "--repo", "acme/widgets", "--yes"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "JOB-456 created. Track with: syrus job watch 456") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestJobCreateWithPriorityAgentAndOwnerFlags(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/repositories":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"active_repositories":[{"id":12,"slug":"acme/widgets"}]}`))
		case "/api/v1/app/jobs":
			var payload map[string]any
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload["priority"] != "high" {
				t.Fatalf("priority = %#v", payload["priority"])
			}
			if payload["agent_provider"] != "codex" {
				t.Fatalf("agent_provider = %#v", payload["agent_provider"])
			}
			if payload["owner_user_id"].(float64) != 7 {
				t.Fatalf("owner_user_id = %#v", payload["owner_user_id"])
			}
			if _, present := payload["epic_id"]; present {
				t.Fatalf("expected epic_id to be omitted when --epic is not passed, got %#v", payload["epic_id"])
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			w.Write([]byte(`{"job":{"id":457,"title":"Tune the aqueduct"},"repository":{"slug":"acme/widgets"}}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetIn(strings.NewReader("Tune the aqueduct\nMake the CLI flow work.\n\n"))
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{
		"job", "create", "--repo", "acme/widgets", "--yes",
		"--priority", "high", "--agent", "codex", "--owner", "7",
	})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "JOB-457 created. Track with: syrus job watch 457") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestJobCreateWithEpicFlagResolvesEpicID(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/repositories":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"active_repositories":[{"id":12,"slug":"acme/widgets"}]}`))
		case "/api/v1/app/epics/42":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"epic":{"id":99,"title":"Aqueduct overhaul"}}`))
		case "/api/v1/app/jobs":
			var payload map[string]any
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload["epic_id"].(float64) != 99 {
				t.Fatalf("epic_id = %#v", payload["epic_id"])
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			w.Write([]byte(`{"job":{"id":458,"title":"Tune the aqueduct"},"repository":{"slug":"acme/widgets"}}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetIn(strings.NewReader("Tune the aqueduct\nMake the CLI flow work.\n\n"))
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "create", "--repo", "acme/widgets", "--yes", "--epic", "EPIC-42"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "JOB-458 created. Track with: syrus job watch 458") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestJobCreateRejectsInvalidPriority(t *testing.T) {
	writeJobActionTestCredentials(t, "http://example.invalid")

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetIn(strings.NewReader("Tune the aqueduct\nMake the CLI flow work.\n\n"))
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "create", "--repo", "acme/widgets", "--yes", "--priority", "urgentish"})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected an error for an invalid --priority value")
	}
	if !strings.Contains(err.Error(), "invalid --priority") {
		t.Fatalf("error = %v", err)
	}
}

func TestJobCreateRejectsNonNumericOwner(t *testing.T) {
	writeJobActionTestCredentials(t, "http://example.invalid")

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetIn(strings.NewReader("Tune the aqueduct\nMake the CLI flow work.\n\n"))
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "create", "--repo", "acme/widgets", "--yes", "--owner", "not-a-user-id"})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected an error for a non-numeric --owner value")
	}
	if !strings.Contains(err.Error(), "invalid --owner") {
		t.Fatalf("error = %v", err)
	}
}

func TestJobCreateFailsFastOnInvalidRepoWithoutPrompting(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/repositories":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"active_repositories":[{"id":12,"slug":"acme/widgets"}]}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetIn(strings.NewReader(""))
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "create", "--repo", "acme/bogus", "--yes"})

	err := command.Execute()
	if err == nil || err.Error() != "repository acme/bogus is not configured for this Syrus account" {
		t.Fatalf("error = %v", err)
	}
	if strings.Contains(output.String(), "Title:") {
		t.Fatalf("expected no prompt output, got %q", output.String())
	}
}

func TestJobActionPostsEndpoint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/app/jobs/456/approve" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "approve", "456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := strings.TrimSpace(output.String()); got != "JOB-456 approved." {
		t.Fatalf("output = %q", got)
	}
}

func TestJobTestPlanRendersLatestCompletedPlan(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/admin/jobs/456" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{
			"id":456,
			"workflows":[
				{"id":1,"state":"succeeded","artifacts":{"test_plan":{"steps":["bin/old"]}}},
				{"id":2,"state":"succeeded","artifacts":{"test_plan":{"steps":[{"step":"bin/rspec","notes":"Run the regression specs."}]}}}
			]
		}`))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "test-plan", "456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); !strings.Contains(got, "1. bin/rspec\n   Run the regression specs.") {
		t.Fatalf("output = %q", got)
	}
}

func TestJobCheckoutFailsWhenBranchMissing(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/jobs/456" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"job":{"id":456},"repository":{"slug":"acme/widgets"}}`))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "checkout", "456"})

	err := command.Execute()
	if err == nil || err.Error() != "JOB-456 has no branch yet" {
		t.Fatalf("error = %v", err)
	}
}

func TestJobCheckoutRunsProjectHooksAgainstEffectiveBaseBranch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/jobs/456" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{
			"job":{"id":456,"branch_name":"syrus/issue-42","effective_base_branch":"release/4.2"},
			"repository":{"slug":"acme/widgets","default_branch":"main"}
		}`)
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	previousDetectCurrentRepoSlug := cliplugin.DetectCurrentRepoSlug
	cliplugin.DetectCurrentRepoSlug = func() string { return "acme/widgets" }
	t.Cleanup(func() { cliplugin.DetectCurrentRepoSlug = previousDetectCurrentRepoSlug })

	repoRoot := t.TempDir()
	writeCheckoutConfig(t, repoRoot, "", "hooks:\n  post_checkout:\n    - bin/root-hook\n")
	writeCheckoutConfig(t, repoRoot, "apps/api", "hooks:\n  post_checkout:\n    - bin/api-hook\n")
	writeCheckoutConfig(t, repoRoot, "apps/web", "hooks:\n  post_checkout:\n    - bin/web-hook\n")

	var gitCalls [][]string
	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		gitCalls = append(gitCalls, append([]string{}, args...))
		switch strings.Join(args, " ") {
		case "rev-parse --is-inside-work-tree":
			return "true\n", nil
		case "remote get-url origin":
			return "git@github.com:acme/widgets.git\n", nil
		case "fetch origin +refs/heads/syrus/issue-42:refs/remotes/origin/syrus/issue-42":
			return "", nil
		case "branch --show-current":
			return "main\n", nil
		case "show-ref --verify --quiet refs/heads/syrus/issue-42":
			return "", fmt.Errorf("exit status 1")
		case "checkout --track -b syrus/issue-42 refs/remotes/origin/syrus/issue-42":
			return "", nil
		case "rev-parse --show-toplevel":
			return repoRoot + "\n", nil
		case "fetch origin +refs/heads/release/4.2:refs/remotes/origin/release/4.2":
			return "", nil
		case "diff --name-only refs/remotes/origin/release/4.2...HEAD":
			return "apps/api/main.go\n", nil
		default:
			return "", fmt.Errorf("unexpected git command: %v", args)
		}
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	var hookCommands []string
	checkoutRunHookCommand = func(ctx context.Context, dir string, command string, stdout io.Writer, stderr io.Writer) error {
		hookCommands = append(hookCommands, command)
		return nil
	}
	t.Cleanup(func() { checkoutRunHookCommand = runHookCommand })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "checkout", "456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	wantHooks := []string{"bin/root-hook", "bin/api-hook"}
	if !reflect.DeepEqual(hookCommands, wantHooks) {
		t.Fatalf("hook commands = %#v", hookCommands)
	}
	foundEffectiveBaseDiff := false
	for _, call := range gitCalls {
		if reflect.DeepEqual(call, []string{"diff", "--name-only", "refs/remotes/origin/release/4.2...HEAD"}) {
			foundEffectiveBaseDiff = true
		}
	}
	if !foundEffectiveBaseDiff {
		t.Fatalf("git calls did not diff against effective base: %#v", gitCalls)
	}
}

func TestJobOpenUsesConfiguredInstanceURL(t *testing.T) {
	writeJobActionTestCredentials(t, "https://syrus.example.test/")
	var opened string
	previous := openBrowser
	openBrowser = func(target string) error {
		opened = target
		return nil
	}
	t.Cleanup(func() { openBrowser = previous })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "open", "456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if opened != "https://syrus.example.test/jobs/456" {
		t.Fatalf("opened = %q", opened)
	}
}

func writeJobActionTestCredentials(t *testing.T, url string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, ".syrus")
	if err := os.MkdirAll(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "credentials"), []byte("url="+url+"\ntoken=test-token\n"), 0600); err != nil {
		t.Fatal(err)
	}
}
