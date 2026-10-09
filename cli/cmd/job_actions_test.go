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
			w.Write([]byte(`{"repositories":[{"id":12,"slug":"acme/widgets"}]}`))
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
	if !strings.HasSuffix(output.String(), "JOB-456\n") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestJobCreateWithPriorityAgentAndOwnerFlags(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/repositories":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"repositories":[{"id":12,"slug":"acme/widgets"}]}`))
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
	if !strings.HasSuffix(output.String(), "JOB-457\n") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestJobCreateWithEpicFlagResolvesEpicID(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/repositories":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"repositories":[{"id":12,"slug":"acme/widgets"}]}`))
		case "/api/v1/app/epics/EPIC-42":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"epic":{"id":99,"number":42,"title":"Aqueduct overhaul"}}`))
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
	if !strings.HasSuffix(output.String(), "JOB-458\n") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestJobCreateWithNonInteractiveTitleBodyAndDependsOn(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/repositories":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"repositories":[{"id":12,"slug":"acme/widgets"}]}`))
		case "/api/v1/app/jobs":
			var payload map[string]any
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload["title"] != "Tune the aqueduct" {
				t.Fatalf("title = %#v", payload["title"])
			}
			if payload["prompt"] != "Make the CLI flow work." {
				t.Fatalf("prompt = %#v", payload["prompt"])
			}
			dependsOnJobIDs := payload["depends_on_job_ids"].([]any)
			if len(dependsOnJobIDs) != 1 || dependsOnJobIDs[0].(float64) != 123 {
				t.Fatalf("depends_on_job_ids = %#v", payload["depends_on_job_ids"])
			}
			dependsOn := payload["depends_on"].([]any)
			if len(dependsOn) != 1 || dependsOn[0] != "prep-foundation" {
				t.Fatalf("depends_on = %#v", payload["depends_on"])
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			w.Write([]byte(`{"job":{"id":459,"title":"Tune the aqueduct"},"repository":{"slug":"acme/widgets"}}`))
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
	command.SetArgs([]string{
		"job", "create", "--repo", "acme/widgets", "--yes",
		"--title", "Tune the aqueduct",
		"--body", "Make the CLI flow work.",
		"--depends-on", "JOB-123",
		"--depends-on", "prep-foundation",
	})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if strings.Contains(output.String(), "Title:") {
		t.Fatalf("expected no interactive prompt, got %q", output.String())
	}
}

func TestJobCreateBodyFilePreservesBlankLines(t *testing.T) {
	bodyPath := filepath.Join(t.TempDir(), "body.md")
	body := "First paragraph.\n\nSecond paragraph.\n"
	if err := os.WriteFile(bodyPath, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/repositories":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"repositories":[{"id":12,"slug":"acme/widgets"}]}`))
		case "/api/v1/app/jobs":
			var payload map[string]any
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload["prompt"] != "First paragraph.\n\nSecond paragraph." {
				t.Fatalf("prompt = %#v", payload["prompt"])
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			w.Write([]byte(`{"job":{"id":460,"title":"Tune the aqueduct"},"repository":{"slug":"acme/widgets"}}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	command := NewRootCommand()
	command.SetIn(strings.NewReader(""))
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{
		"job", "create", "--repo", "acme/widgets", "--yes",
		"--title", "Tune the aqueduct",
		"--body-file", bodyPath,
	})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
}

func TestJobCreateFileDashReadsBodyFromStdin(t *testing.T) {
	body := "First paragraph.\n\nSecond paragraph.\n"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/repositories":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"repositories":[{"id":12,"slug":"acme/widgets"}]}`))
		case "/api/v1/app/jobs":
			var payload map[string]any
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload["prompt"] != "First paragraph.\n\nSecond paragraph." {
				t.Fatalf("prompt = %#v", payload["prompt"])
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			w.Write([]byte(`{"job":{"id":461,"title":"Tune the aqueduct"},"repository":{"slug":"acme/widgets"}}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	command := NewRootCommand()
	command.SetIn(strings.NewReader(body))
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{
		"job", "create", "--repo", "acme/widgets", "--yes",
		"--title", "Tune the aqueduct",
		"--file", "-",
	})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
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
			w.Write([]byte(`{"repositories":[{"id":12,"slug":"acme/widgets"}]}`))
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

func TestJobCreateFailsFastOnInvalidEpicWithoutPrompting(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/repositories":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"repositories":[{"id":12,"slug":"acme/widgets"}]}`))
		case "/api/v1/app/epics/EPIC-404":
			http.Error(w, `{"error":{"message":"not found"}}`, http.StatusNotFound)
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
	command.SetArgs([]string{"job", "create", "--repo", "acme/widgets", "--yes", "--epic", "EPIC-404"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "could not resolve epic EPIC-404") {
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

func TestJobActionCommandsPostExpectedEndpoints(t *testing.T) {
	cases := []struct {
		args []string
		path string
		body string
	}{
		{[]string{"job", "start", "456"}, "/api/v1/app/jobs/456/start", ""},
		{[]string{"job", "pause", "456"}, "/api/v1/app/jobs/456/pause", ""},
		{[]string{"job", "unpause", "456"}, "/api/v1/app/jobs/456/unpause", ""},
		{[]string{"job", "unapprove", "456"}, "/api/v1/app/jobs/456/unapprove", ""},
		{[]string{"job", "stop-landing", "456"}, "/api/v1/app/jobs/456/stop_landing", ""},
		{[]string{"job", "move-to-backlog", "456"}, "/api/v1/app/jobs/456/move_to_backlog", ""},
		{[]string{"job", "release-from-backlog", "456"}, "/api/v1/app/jobs/456/release_from_backlog", ""},
		{[]string{"job", "accept-triage", "456"}, "/api/v1/app/jobs/456/accept_triage", ""},
		{[]string{"job", "reject-triage", "456"}, "/api/v1/app/jobs/456/reject_triage", ""},
		{[]string{"job", "reopen", "456"}, "/api/v1/app/jobs/456/reopen", ""},
		{[]string{"job", "close-investigation", "456"}, "/api/v1/app/jobs/456/close_investigation", ""},
		{[]string{"job", "check-mergeability", "456"}, "/api/v1/app/jobs/456/check_mergeability", ""},
		{[]string{"job", "recheck-pr-checks", "456"}, "/api/v1/app/jobs/456/recheck_pr_checks", ""},
		{[]string{"job", "resume", "456", "--source-run", "9"}, "/api/v1/app/jobs/456/resume", `"source_run_id":"9"`},
		{[]string{"job", "retry-step", "456", "--workflow", "12"}, "/api/v1/app/jobs/456/workflows/12/retry_step", ""},
		{[]string{"job", "push-commits", "456", "--workflow", "12"}, "/api/v1/app/jobs/456/workflows/12/push_commits", ""},
		{[]string{"job", "stop-run", "456", "--run", "34"}, "/api/v1/app/jobs/456/runs/34/stop", ""},
		{[]string{"job", "diagnose", "456", "--run", "34"}, "/api/v1/app/jobs/456/runs/34/diagnose", ""},
	}

	for _, tc := range cases {
		t.Run(strings.Join(tc.args[1:], "_"), func(t *testing.T) {
			var body string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodPost || r.URL.Path != tc.path {
					t.Fatalf("unexpected request %s %s, want POST %s", r.Method, r.URL.Path, tc.path)
				}
				raw, err := io.ReadAll(r.Body)
				if err != nil {
					t.Fatal(err)
				}
				body = string(raw)
				w.WriteHeader(http.StatusOK)
			}))
			defer server.Close()
			writeJobActionTestCredentials(t, server.URL)

			output := &bytes.Buffer{}
			command := NewRootCommand()
			command.SetOut(output)
			command.SetErr(&bytes.Buffer{})
			command.SetArgs(tc.args)

			if err := command.Execute(); err != nil {
				t.Fatalf("Execute returned error: %v", err)
			}
			if tc.body != "" && !strings.Contains(body, tc.body) {
				t.Fatalf("body = %q, want to contain %q", body, tc.body)
			}
		})
	}
}

func TestGeneratedJobActionHelpTextIsNotResultMessage(t *testing.T) {
	command := NewJobCommand()
	resultMessages := map[string]string{
		"approve": "Approved",
		"cancel":  "Cancellation requested",
		"retry":   "Retry enqueued",
		"rebase":  "Rebase enqueued",
		"pause":   "Paused",
		"unpause": "Unpaused",
	}
	for name, resultMessage := range resultMessages {
		child, _, err := command.Find([]string{name})
		if err != nil {
			t.Fatalf("Find(%s) returned error: %v", name, err)
		}
		if child == nil {
			t.Fatalf("command %s not found", name)
		}
		if child.Short == resultMessage {
			t.Fatalf("%s Short reuses result message %q", name, child.Short)
		}
	}
}

func TestJobTestPlanUsesAppPayloadLikeTopLevelCommand(t *testing.T) {
	payload := `{
		"job": {
			"id": 456,
			"issue_title": "Add user avatar upload"
		},
		"test_plan": {
			"steps": [
				"Navigate to /settings/profile",
				"Click \"Upload avatar\" and select a PNG under 2 MB",
				"Verify the avatar appears in the nav bar immediately"
			],
			"notes": "Avatar storage uses ActiveStorage."
		}
	}`
	var requestedPaths []string

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/jobs/456" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		requestedPaths = append(requestedPaths, r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(payload))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	jobOutput := executeJobActionCommand(t, []string{"job", "test-plan", "456"})
	topLevelOutput := executeJobActionCommand(t, []string{"test-plan", "456"})

	if jobOutput != topLevelOutput {
		t.Fatalf("outputs differ:\njob test-plan:\n%s\ntest-plan:\n%s", jobOutput, topLevelOutput)
	}

	expected := `Test plan for JOB-456: Add user avatar upload

1. Navigate to /settings/profile
2. Click "Upload avatar" and select a PNG under 2 MB
3. Verify the avatar appears in the nav bar immediately

Notes: Avatar storage uses ActiveStorage.
`
	if jobOutput != expected {
		t.Fatalf("output = %q", jobOutput)
	}
	if !reflect.DeepEqual(requestedPaths, []string{"/api/v1/app/jobs/456", "/api/v1/app/jobs/456"}) {
		t.Fatalf("requested paths = %#v", requestedPaths)
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
	t.Setenv("SYRUS_CLI_URL", "")
	t.Setenv("SYRUS_CLI_INVOCATION_CONTEXT", "")
	t.Setenv("SYRUS_CLI_INTERNAL", "")
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("SYRUS_CLI_INTERNAL", "")
	t.Setenv("SYRUS_CLI_URL", "")
	t.Setenv("SYRUS_CLI_INVOCATION_CONTEXT", "")
	t.Setenv("SYRUS_PROFILE", "")
	path := filepath.Join(home, ".syrus")
	if err := os.MkdirAll(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "credentials"), []byte("url="+url+"\ntoken=test-token\n"), 0600); err != nil {
		t.Fatal(err)
	}
}

func executeJobActionCommand(t *testing.T, args []string) string {
	t.Helper()

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs(args)

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute(%v) returned error: %v", args, err)
	}

	return output.String()
}
