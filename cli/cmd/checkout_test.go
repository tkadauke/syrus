package cmd

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestCheckoutCommandFetchesAndChecksOutJobBranch(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/admin/jobs/456" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
			t.Fatalf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":456,"state":"running","branch_name":"syrus/issue-42-456","repository":{"slug":"acme/widgets"}}`)
	})
	writeTestCredentials(t, server.URL)

	var calls [][]string
	checkoutRunGit = func(ctx context.Context, dir string, args ...string) (string, error) {
		calls = append(calls, append([]string{}, args...))
		switch strings.Join(args, " ") {
		case "rev-parse --is-inside-work-tree":
			return "true\n", nil
		case "remote get-url origin":
			return "git@github.com:acme/widgets.git\n", nil
		case "branch --show-current":
			return "main\n", nil
		case "fetch origin syrus/issue-42-456:syrus/issue-42-456", "checkout syrus/issue-42-456":
			return "", nil
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
		{"branch", "--show-current"},
		{"fetch", "origin", "syrus/issue-42-456:syrus/issue-42-456"},
		{"checkout", "syrus/issue-42-456"},
	}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("git calls = %#v", calls)
	}
	wantOutput := "Checked out syrus/issue-42-456 — run 'syrus test-plan JOB-456' to see the test plan.\n"
	if output.String() != wantOutput {
		t.Fatalf("output = %q", output.String())
	}
}

func TestCheckoutCommandHandlesAlreadyCheckedOutBranch(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":456,"state":"running","branch_name":"syrus/issue-42-456","repository":{"slug":"acme/widgets"}}`)
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
		case "branch --show-current":
			return "syrus/issue-42-456\n", nil
		case "fetch origin syrus/issue-42-456", "checkout syrus/issue-42-456":
			return "", nil
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
		{"branch", "--show-current"},
		{"fetch", "origin", "syrus/issue-42-456"},
		{"checkout", "syrus/issue-42-456"},
	}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("git calls = %#v", calls)
	}
}

func TestCheckoutCommandReportsMissingBranch(t *testing.T) {
	server := checkoutServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":456,"state":"queued","branch_name":"","repository":{"slug":"acme/widgets"}}`)
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
		fmt.Fprint(w, `{"id":456,"state":"running","branch_name":"syrus/issue-42-456","repository":{"slug":"acme/widgets"}}`)
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
