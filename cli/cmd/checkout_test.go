package cmd

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/internal/api"
)

func TestCheckoutCommandFetchesAndChecksOutJobBranch(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/jobs/456" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
			t.Fatalf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"job":{"id":456,"state":"running","branch_name":"syrus/issue-42-456"},"repository":{"slug":"acme/widgets"}}`)
	})
	writeTestCredentials(t, server.URL)
	repoRoot := t.TempDir()

	var calls [][]string
	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		calls = append(calls, append([]string{}, args...))
		switch strings.Join(args, " ") {
		case "rev-parse --is-inside-work-tree":
			return "true\n", nil
		case "remote get-url origin":
			return "git@github.com:acme/widgets.git\n", nil
		case "fetch origin +refs/heads/syrus/issue-42-456:refs/remotes/origin/syrus/issue-42-456":
			return "", nil
		case "branch --show-current":
			return "main\n", nil
		case "show-ref --verify --quiet refs/heads/syrus/issue-42-456":
			return "", fmt.Errorf("exit status 1")
		case "checkout --track -b syrus/issue-42-456 refs/remotes/origin/syrus/issue-42-456":
			return "", nil
		case "rev-parse --show-toplevel":
			return repoRoot + "\n", nil
		default:
			return "", fmt.Errorf("unexpected git command: %v", args)
		}
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "JOB-456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	wantCalls := [][]string{
		{"rev-parse", "--is-inside-work-tree"},
		{"remote", "get-url", "origin"},
		{"fetch", "origin", "+refs/heads/syrus/issue-42-456:refs/remotes/origin/syrus/issue-42-456"},
		{"branch", "--show-current"},
		{"show-ref", "--verify", "--quiet", "refs/heads/syrus/issue-42-456"},
		{"checkout", "--track", "-b", "syrus/issue-42-456", "refs/remotes/origin/syrus/issue-42-456"},
		{"rev-parse", "--show-toplevel"},
	}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("git calls = %#v", calls)
	}
	wantOutput := "Checked out syrus/issue-42-456 — run 'syrus test-plan JOB-456' to see the test plan.\n"
	if output.String() != wantOutput {
		t.Fatalf("output = %q", output.String())
	}
}

func TestCheckoutCommandRunsPostCheckoutHooks(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"job":{"id":456,"state":"running","branch_name":"syrus/issue-42-456"},"repository":{"slug":"acme/widgets"}}`)
	})
	writeTestCredentials(t, server.URL)
	repoRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(repoRoot, ".syrus.yml"), []byte("hooks:\n  post_checkout:\n    - echo first\n    - bin/setup\n"), 0600); err != nil {
		t.Fatal(err)
	}

	var gitCalls [][]string
	branchRunner := checkoutGitStub(t, "syrus/issue-42-456", &gitCalls)

	var hookCalls []struct {
		dir     string
		command string
	}
	checkoutRunHookCommand = func(ctx context.Context, dir string, command string, stdout io.Writer, stderr io.Writer) error {
		hookCalls = append(hookCalls, struct {
			dir     string
			command string
		}{dir: dir, command: command})
		return nil
	}
	t.Cleanup(func() { checkoutRunHookCommand = runHookCommand })

	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		if strings.Join(args, " ") == "rev-parse --show-toplevel" {
			gitCalls = append(gitCalls, append([]string{}, args...))
			return repoRoot + "\n", nil
		}
		return branchRunner(ctx, dir, args...)
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "JOB-456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	wantHooks := []struct {
		dir     string
		command string
	}{
		{dir: repoRoot, command: "echo first"},
		{dir: repoRoot, command: "bin/setup"},
	}
	if !reflect.DeepEqual(hookCalls, wantHooks) {
		t.Fatalf("hook calls = %#v", hookCalls)
	}
}

func TestCheckoutCommandSkipsPostCheckoutHooksWithNoHooksFlag(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"job":{"id":456,"state":"running","branch_name":"syrus/issue-42-456"},"repository":{"slug":"acme/widgets"}}`)
	})
	writeTestCredentials(t, server.URL)

	var calls [][]string
	checkoutRunGit = checkoutGitStub(t, "syrus/issue-42-456", &calls)
	t.Cleanup(func() { checkoutRunGit = runGit })
	checkoutRunHookCommand = func(ctx context.Context, dir string, command string, stdout io.Writer, stderr io.Writer) error {
		t.Fatalf("hook command should not run")
		return nil
	}
	t.Cleanup(func() { checkoutRunHookCommand = runHookCommand })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "--no-hooks", "JOB-456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	wantCalls := checkoutGitBranchCalls("syrus/issue-42-456")
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("git calls = %#v", calls)
	}
}

func TestPostCheckoutHooksReportFailingCommandExitStatus(t *testing.T) {
	repoRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(repoRoot, ".syrus.yml"), []byte("hooks:\n  post_checkout:\n    - printf hook-output\n    - exit 7\n    - echo skipped\n"), 0600); err != nil {
		t.Fatal(err)
	}

	var gitCalls [][]string
	runner := func(ctx context.Context, dir string, args ...string) (string, error) {
		gitCalls = append(gitCalls, append([]string{}, args...))
		if strings.Join(args, " ") == "rev-parse --show-toplevel" {
			return repoRoot + "\n", nil
		}
		return "", fmt.Errorf("unexpected git command: %v", args)
	}

	stdout := &bytes.Buffer{}
	err := runPostCheckoutHooks(context.Background(), runner, runHookCommand, stdout, &bytes.Buffer{})
	if err == nil {
		t.Fatal("expected hook failure")
	}
	want := `post-checkout hook failed: "exit 7" exited with status 7`
	if err.Error() != want {
		t.Fatalf("error = %q", err.Error())
	}
	if stdout.String() != "hook-output" {
		t.Fatalf("stdout = %q", stdout.String())
	}
}

func TestCheckoutCommandHandlesAlreadyCheckedOutBranch(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"job":{"id":456,"state":"running","branch_name":"syrus/issue-42-456"},"repository":{"slug":"acme/widgets"}}`)
	})
	writeTestCredentials(t, server.URL)
	repoRoot := t.TempDir()

	var calls [][]string
	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		calls = append(calls, append([]string{}, args...))
		switch strings.Join(args, " ") {
		case "rev-parse --is-inside-work-tree":
			return "true\n", nil
		case "remote get-url origin":
			return "https://github.com/acme/widgets.git\n", nil
		case "fetch origin +refs/heads/syrus/issue-42-456:refs/remotes/origin/syrus/issue-42-456":
			return "", nil
		case "branch --show-current":
			return "syrus/issue-42-456\n", nil
		case "show-ref --verify --quiet refs/heads/syrus/issue-42-456":
			return "", nil
		case "status --porcelain":
			return "", nil
		case "rev-parse --verify refs/heads/syrus/issue-42-456", "rev-parse --verify refs/remotes/origin/syrus/issue-42-456":
			return "abc123\n", nil
		case "reset --hard refs/remotes/origin/syrus/issue-42-456":
			return "", nil
		case "rev-parse --show-toplevel":
			return repoRoot + "\n", nil
		default:
			return "", fmt.Errorf("unexpected git command: %v", args)
		}
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "JOB-456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	wantCalls := [][]string{
		{"rev-parse", "--is-inside-work-tree"},
		{"remote", "get-url", "origin"},
		{"fetch", "origin", "+refs/heads/syrus/issue-42-456:refs/remotes/origin/syrus/issue-42-456"},
		{"branch", "--show-current"},
		{"show-ref", "--verify", "--quiet", "refs/heads/syrus/issue-42-456"},
		{"status", "--porcelain"},
		{"rev-parse", "--verify", "refs/heads/syrus/issue-42-456"},
		{"rev-parse", "--verify", "refs/remotes/origin/syrus/issue-42-456"},
		{"reset", "--hard", "refs/remotes/origin/syrus/issue-42-456"},
		{"rev-parse", "--show-toplevel"},
	}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("git calls = %#v", calls)
	}
}

func TestCheckoutCommandUpdatesExistingBranchAfterForcePush(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"job":{"id":456,"state":"running","branch_name":"syrus/issue-42-456"},"repository":{"slug":"acme/widgets"}}`)
	})
	writeTestCredentials(t, server.URL)
	repoRoot := t.TempDir()

	originalTimestamp := checkoutBackupTimestamp
	checkoutBackupTimestamp = func() string { return "20260624T120000Z" }
	t.Cleanup(func() { checkoutBackupTimestamp = originalTimestamp })

	var calls [][]string
	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		calls = append(calls, append([]string{}, args...))
		switch strings.Join(args, " ") {
		case "rev-parse --is-inside-work-tree":
			return "true\n", nil
		case "remote get-url origin":
			return "https://github.com/acme/widgets.git\n", nil
		case "fetch origin +refs/heads/syrus/issue-42-456:refs/remotes/origin/syrus/issue-42-456":
			return "", nil
		case "branch --show-current":
			return "main\n", nil
		case "show-ref --verify --quiet refs/heads/syrus/issue-42-456":
			return "", nil
		case "rev-parse --verify refs/heads/syrus/issue-42-456":
			return "old-sha\n", nil
		case "rev-parse --verify refs/remotes/origin/syrus/issue-42-456":
			return "new-sha\n", nil
		case "merge-base --is-ancestor refs/heads/syrus/issue-42-456 refs/remotes/origin/syrus/issue-42-456":
			return "", fmt.Errorf("exit status 1")
		case "branch syrus/backup/syrus-issue-42-456-20260624T120000Z refs/heads/syrus/issue-42-456":
			return "", nil
		case "branch -f syrus/issue-42-456 refs/remotes/origin/syrus/issue-42-456":
			return "", nil
		case "checkout syrus/issue-42-456":
			return "", nil
		case "rev-parse --show-toplevel":
			return repoRoot + "\n", nil
		default:
			return "", fmt.Errorf("unexpected git command: %v", args)
		}
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "JOB-456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	wantCalls := [][]string{
		{"rev-parse", "--is-inside-work-tree"},
		{"remote", "get-url", "origin"},
		{"fetch", "origin", "+refs/heads/syrus/issue-42-456:refs/remotes/origin/syrus/issue-42-456"},
		{"branch", "--show-current"},
		{"show-ref", "--verify", "--quiet", "refs/heads/syrus/issue-42-456"},
		{"rev-parse", "--verify", "refs/heads/syrus/issue-42-456"},
		{"rev-parse", "--verify", "refs/remotes/origin/syrus/issue-42-456"},
		{"merge-base", "--is-ancestor", "refs/heads/syrus/issue-42-456", "refs/remotes/origin/syrus/issue-42-456"},
		{"branch", "syrus/backup/syrus-issue-42-456-20260624T120000Z", "refs/heads/syrus/issue-42-456"},
		{"branch", "-f", "syrus/issue-42-456", "refs/remotes/origin/syrus/issue-42-456"},
		{"checkout", "syrus/issue-42-456"},
		{"rev-parse", "--show-toplevel"},
	}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("git calls = %#v", calls)
	}
}

func TestCheckoutCommandRejectsDirtyCheckedOutBranch(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"job":{"id":456,"state":"running","branch_name":"syrus/issue-42-456"},"repository":{"slug":"acme/widgets"}}`)
	})
	writeTestCredentials(t, server.URL)

	var calls [][]string
	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		calls = append(calls, append([]string{}, args...))
		switch strings.Join(args, " ") {
		case "rev-parse --is-inside-work-tree":
			return "true\n", nil
		case "remote get-url origin":
			return "https://github.com/acme/widgets.git\n", nil
		case "fetch origin +refs/heads/syrus/issue-42-456:refs/remotes/origin/syrus/issue-42-456":
			return "", nil
		case "branch --show-current":
			return "syrus/issue-42-456\n", nil
		case "show-ref --verify --quiet refs/heads/syrus/issue-42-456":
			return "", nil
		case "status --porcelain":
			return " M app/models/job.rb\n", nil
		default:
			return "", fmt.Errorf("unexpected git command: %v", args)
		}
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "JOB-456"})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected error")
	}
	want := "cannot update syrus/issue-42-456 because it is currently checked out with local changes; commit or stash them first"
	if err.Error() != want {
		t.Fatalf("error = %q", err.Error())
	}

	wantCalls := [][]string{
		{"rev-parse", "--is-inside-work-tree"},
		{"remote", "get-url", "origin"},
		{"fetch", "origin", "+refs/heads/syrus/issue-42-456:refs/remotes/origin/syrus/issue-42-456"},
		{"branch", "--show-current"},
		{"show-ref", "--verify", "--quiet", "refs/heads/syrus/issue-42-456"},
		{"status", "--porcelain"},
	}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("git calls = %#v", calls)
	}
}

func TestCheckoutCommandReportsMissingBranch(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"job":{"id":456,"state":"queued","branch_name":""},"repository":{"slug":"acme/widgets"}}`)
	})
	writeTestCredentials(t, server.URL)

	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		t.Fatalf("git should not be called")
		return "", nil
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "JOB-456"})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected error")
	}
	if err.Error() != "Job JOB-456 does not have a branch yet (state: queued)" {
		t.Fatalf("error = %q", err.Error())
	}
}

func TestCheckoutCommandRejectsWrongRepository(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"job":{"id":456,"state":"running","branch_name":"syrus/issue-42-456"},"repository":{"slug":"acme/widgets"}}`)
	})
	writeTestCredentials(t, server.URL)

	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		switch strings.Join(args, " ") {
		case "rev-parse --is-inside-work-tree":
			return "true\n", nil
		case "remote get-url origin":
			return "https://github.com/other/repo.git\n", nil
		default:
			t.Fatalf("unexpected git command after repo mismatch: %v", args)
			return "", nil
		}
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "JOB-456"})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected error")
	}
	want := "Current git remote origin (https://github.com/other/repo.git) does not match job repository acme/widgets."
	if err.Error() != want {
		t.Fatalf("error = %q", err.Error())
	}
}

func TestCheckoutCommandChecksOutSingleSinkEpicJob(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/epics/42" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"epic":{"id":42,"number":42,"title":"Add auth system","repository_slug":"acme/widgets"},"jobs":[{"id":40,"state":"closed","title":"Add user model","branch_name":"syrus/issue-40","depends_on_job_ids":[]},{"id":45,"state":"open","title":"Add OAuth login endpoint","branch_name":"syrus/issue-45","depends_on_job_ids":[40]}]}`)
	})
	writeTestCredentials(t, server.URL)

	var pickerCalled bool
	originalPicker := epicPickerFunc
	epicPickerFunc = func(epicRef string, candidates []epicCandidate) (*api.JobItem, error) {
		pickerCalled = true
		return nil, nil
	}
	t.Cleanup(func() { epicPickerFunc = originalPicker })

	var calls [][]string
	checkoutRunGit = checkoutGitStub(t, "syrus/issue-45", &calls)
	t.Cleanup(func() { checkoutRunGit = runGit })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "EPIC-42"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if pickerCalled {
		t.Fatal("picker should not be called for a single sink")
	}
	wantOutput := "Checked out syrus/issue-45 — run 'syrus test-plan JOB-45' to see the test plan.\n"
	if output.String() != wantOutput {
		t.Fatalf("output = %q", output.String())
	}
	wantCalls := checkoutGitCalls("syrus/issue-45")
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("git calls = %#v", calls)
	}
}

func TestCheckoutCommandChecksOutSelectedEpicJob(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"epic":{"id":42,"number":42,"title":"Add auth system","repository_slug":"acme/widgets"},"jobs":[{"id":42,"state":"closed","title":"Add user model","branch_name":"syrus/issue-42","depends_on_job_ids":[]},{"id":45,"state":"open","title":"Add OAuth login endpoint","branch_name":"syrus/issue-45","depends_on_job_ids":[42]},{"id":47,"state":"implemented","title":"Add role-based access control","branch_name":"syrus/issue-47","depends_on_job_ids":[42]}]}`)
	})
	writeTestCredentials(t, server.URL)

	originalPicker := epicPickerFunc
	epicPickerFunc = func(epicRef string, candidates []epicCandidate) (*api.JobItem, error) {
		if epicRef != "EPIC-42 · Add auth system (3 jobs)" {
			t.Fatalf("epicRef = %q", epicRef)
		}
		if len(candidates) != 2 {
			t.Fatalf("candidates = %#v", candidates)
		}
		if len(candidates[0].ancestors) != 1 || candidates[0].ancestors[0].ID != 42 {
			t.Fatalf("ancestors = %#v", candidates[0].ancestors)
		}
		return &candidates[0].job, nil
	}
	t.Cleanup(func() { epicPickerFunc = originalPicker })

	var calls [][]string
	checkoutRunGit = checkoutGitStub(t, "syrus/issue-45", &calls)
	t.Cleanup(func() { checkoutRunGit = runGit })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "EPIC-42"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	wantOutput := "Checked out syrus/issue-45 — run 'syrus test-plan JOB-45' to see the test plan.\n"
	if output.String() != wantOutput {
		t.Fatalf("output = %q", output.String())
	}
	wantCalls := checkoutGitCalls("syrus/issue-45")
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("git calls = %#v", calls)
	}
}

func TestCheckoutCommandCancelsEpicPicker(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"epic":{"id":42,"number":42,"title":"Add auth system","repository_slug":"acme/widgets"},"jobs":[{"id":45,"state":"open","title":"Add OAuth login endpoint","branch_name":"syrus/issue-45","depends_on_job_ids":[]},{"id":47,"state":"implemented","title":"Add role-based access control","branch_name":"syrus/issue-47","depends_on_job_ids":[]}]}`)
	})
	writeTestCredentials(t, server.URL)

	originalPicker := epicPickerFunc
	epicPickerFunc = func(epicRef string, candidates []epicCandidate) (*api.JobItem, error) {
		return nil, nil
	}
	t.Cleanup(func() { epicPickerFunc = originalPicker })

	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		t.Fatalf("git should not be called")
		return "", nil
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "EPIC-42"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if output.String() != "Cancelled.\n" {
		t.Fatalf("output = %q", output.String())
	}
}

func TestCheckoutCommandRejectsEpicWithNoJobs(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"epic":{"id":42,"number":42,"title":"Add auth system","repository_slug":"acme/widgets"},"jobs":[]}`)
	})
	writeTestCredentials(t, server.URL)

	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		t.Fatalf("git should not be called")
		return "", nil
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "EPIC-42"})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected error")
	}
	if err.Error() != "Epic EPIC-42 has no jobs" {
		t.Fatalf("error = %q", err.Error())
	}
}

func TestCheckoutCommandRejectsEpicWithNoSinkBranches(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"epic":{"id":42,"number":42,"title":"Add auth system","repository_slug":"acme/widgets"},"jobs":[{"id":40,"state":"closed","title":"Add user model","branch_name":"syrus/issue-40","depends_on_job_ids":[]},{"id":45,"state":"queued","title":"Add OAuth login endpoint","branch_name":"","depends_on_job_ids":[40]}]}`)
	})
	writeTestCredentials(t, server.URL)

	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		t.Fatalf("git should not be called")
		return "", nil
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "EPIC-42"})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected error")
	}
	if err.Error() != "Epic EPIC-42 has no jobs with a branch yet" {
		t.Fatalf("error = %q", err.Error())
	}
}

func TestCheckoutCommandRoutesJobRefsToJobCheckout(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/jobs/42" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"job":{"id":42,"state":"running","branch_name":"syrus/issue-42"},"repository":{"slug":"acme/widgets"}}`)
	})
	writeTestCredentials(t, server.URL)

	var calls [][]string
	checkoutRunGit = checkoutGitStub(t, "syrus/issue-42", &calls)
	t.Cleanup(func() { checkoutRunGit = runGit })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"checkout", "JOB-42"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
}

func checkoutServer(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return server
}

func writeTestCredentials(t *testing.T, url string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, ".syrus", "credentials")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	contents := fmt.Sprintf("url=%s\ntoken=secret-token\n", url)
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
}

func checkoutGitStub(t *testing.T, branch string, calls *[][]string) gitRunner {
	t.Helper()
	repoRoot := t.TempDir()
	return func(ctx context.Context, dir string, args ...string) (string, error) {
		*calls = append(*calls, append([]string{}, args...))
		switch strings.Join(args, " ") {
		case "rev-parse --is-inside-work-tree":
			return "true\n", nil
		case "remote get-url origin":
			return "git@github.com:acme/widgets.git\n", nil
		case "fetch origin +refs/heads/" + branch + ":refs/remotes/origin/" + branch:
			return "", nil
		case "branch --show-current":
			return "main\n", nil
		case "show-ref --verify --quiet refs/heads/" + branch:
			return "", fmt.Errorf("exit status 1")
		case "checkout --track -b " + branch + " refs/remotes/origin/" + branch:
			return "", nil
		case "rev-parse --show-toplevel":
			return repoRoot + "\n", nil
		default:
			return "", fmt.Errorf("unexpected git command: %v", args)
		}
	}
}

func checkoutGitBranchCalls(branch string) [][]string {
	return [][]string{
		{"rev-parse", "--is-inside-work-tree"},
		{"remote", "get-url", "origin"},
		{"fetch", "origin", "+refs/heads/" + branch + ":refs/remotes/origin/" + branch},
		{"branch", "--show-current"},
		{"show-ref", "--verify", "--quiet", "refs/heads/" + branch},
		{"checkout", "--track", "-b", branch, "refs/remotes/origin/" + branch},
	}
}

func checkoutGitCalls(branch string) [][]string {
	return append(checkoutGitBranchCalls(branch), []string{"rev-parse", "--show-toplevel"})
}
