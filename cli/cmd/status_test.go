package cmd

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestStatusCommandReportsNotInGitRepository(t *testing.T) {
	statusRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		if strings.Join(args, " ") != "rev-parse --is-inside-work-tree" {
			t.Fatalf("unexpected git command: %v", args)
		}
		return "", fmt.Errorf("exit status 128")
	}
	t.Cleanup(func() { statusRunGit = runGit })

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"status"})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected error")
	}
	if err.Error() != "Current directory is not a git repository." {
		t.Fatalf("error = %q", err.Error())
	}
}

func TestStatusCommandReportsNotOnSyrusBranch(t *testing.T) {
	var calls [][]string
	statusRunGit = statusGitStub(t, "main", "0", &calls)
	t.Cleanup(func() { statusRunGit = runGit })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"status"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); got != "Not on a Syrus job branch.\n" {
		t.Fatalf("output = %q", got)
	}
	wantCalls := [][]string{
		{"rev-parse", "--is-inside-work-tree"},
		{"branch", "--show-current"},
	}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("git calls = %#v", calls)
	}
}

func TestStatusCommandReportsUpToDateSyrusBranch(t *testing.T) {
	var calls [][]string
	statusRunGit = statusGitStub(t, "syrus/direct-1291", "0", &calls)
	t.Cleanup(func() { statusRunGit = runGit })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"status"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); got != "JOB-1291 (syrus/direct-1291) — up to date\n" {
		t.Fatalf("output = %q", got)
	}
	wantCalls := [][]string{
		{"rev-parse", "--is-inside-work-tree"},
		{"branch", "--show-current"},
		{"fetch", "origin", "+refs/heads/syrus/direct-1291:refs/remotes/origin/syrus/direct-1291"},
		{"rev-list", "--count", "HEAD..refs/remotes/origin/syrus/direct-1291"},
	}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("git calls = %#v", calls)
	}
}

func TestStatusCommandReportsBehindSyrusBranch(t *testing.T) {
	var calls [][]string
	statusRunGit = statusGitStub(t, "syrus/issue-720-1291", "2", &calls)
	t.Cleanup(func() { statusRunGit = runGit })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"status"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); got != "JOB-1291 (syrus/issue-720-1291) — ⚠ 2 commit(s) behind remote\n" {
		t.Fatalf("output = %q", got)
	}
}

func TestStatusCommandPrintsJSONForSyrusBranch(t *testing.T) {
	var calls [][]string
	statusRunGit = statusGitStub(t, "syrus/scheduled-4-99", "3", &calls)
	t.Cleanup(func() { statusRunGit = runGit })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"status", "--json"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); got != "{\"job_id\":99,\"branch\":\"syrus/scheduled-4-99\",\"behind\":3}\n" {
		t.Fatalf("output = %q", got)
	}
}

func TestStatusCommandPrintsJSONForUpToDateSyrusBranch(t *testing.T) {
	var calls [][]string
	statusRunGit = statusGitStub(t, "syrus/direct-1291", "0", &calls)
	t.Cleanup(func() { statusRunGit = runGit })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"status", "--json"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); got != "{\"job_id\":1291,\"branch\":\"syrus/direct-1291\",\"behind\":0}\n" {
		t.Fatalf("output = %q", got)
	}
}

func TestStatusCommandPrintsJSONWhenNotOnSyrusBranch(t *testing.T) {
	var calls [][]string
	statusRunGit = statusGitStub(t, "", "0", &calls)
	t.Cleanup(func() { statusRunGit = runGit })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"status", "--json"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); got != "{\"job_id\":0,\"branch\":\"\",\"behind\":0}\n" {
		t.Fatalf("output = %q", got)
	}
}

func TestStatusJobIDFromBranchRecognizesGeneratedBranchNames(t *testing.T) {
	cases := map[string]int{
		"syrus/direct-732":     732,
		"syrus/local-8":        8,
		"syrus/issue-720-456":  456,
		"syrus/scheduled-4-99": 99,
		"syrus/issue-42":       42,
		"syrus/scheduled-12":   12,
		"syrus/cron-77":        77,
	}

	for branch, want := range cases {
		got, ok := statusJobIDFromBranch(branch)
		if !ok {
			t.Fatalf("statusJobIDFromBranch(%q) did not match", branch)
		}
		if got != want {
			t.Fatalf("statusJobIDFromBranch(%q) = %d, want %d", branch, got, want)
		}
	}
	if _, ok := statusJobIDFromBranch("main"); ok {
		t.Fatal("main branch should not match")
	}
}

func statusGitStub(t *testing.T, branch string, behind string, calls *[][]string) gitRunner {
	t.Helper()
	return func(ctx context.Context, dir string, args ...string) (string, error) {
		if dir == "" {
			t.Fatalf("git command should run from explicit working directory: %v", args)
		}
		if _, err := os.Stat(dir); err != nil {
			t.Fatalf("git command dir = %q: %v", dir, err)
		}
		*calls = append(*calls, append([]string{}, args...))
		switch strings.Join(args, " ") {
		case "rev-parse --is-inside-work-tree":
			return "true\n", nil
		case "branch --show-current":
			return branch + "\n", nil
		case "fetch origin +refs/heads/" + branch + ":refs/remotes/origin/" + branch:
			return "", nil
		case "rev-list --count HEAD..refs/remotes/origin/" + branch:
			return behind + "\n", nil
		default:
			return "", fmt.Errorf("unexpected git command: %v", args)
		}
	}
}
