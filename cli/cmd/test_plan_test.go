package cmd

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPlanFetchesAppJobAndPrintsPlan(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	var stdout bytes.Buffer
	var requestedURL string
	var requestedToken string
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

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		requestedURL = request.URL.String()
		requestedToken = request.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(payload))
	}))
	defer server.Close()
	writeCredentials(t, home, server.URL, "secret-token")

	command := NewTestPlanCommand()
	command.SetOut(&stdout)
	command.SetArgs([]string{"JOB-456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if requestedURL != "/api/v1/app/jobs/456" {
		t.Fatalf("unexpected request URL: %s", requestedURL)
	}
	if requestedToken != "Bearer secret-token" {
		t.Fatalf("unexpected authorization header: %s", requestedToken)
	}

	expected := `Test plan for JOB-456: Add user avatar upload

1. Navigate to /settings/profile
2. Click "Upload avatar" and select a PNG under 2 MB
3. Verify the avatar appears in the nav bar immediately

Notes: Avatar storage uses ActiveStorage.
`
	if stdout.String() != expected {
		t.Fatalf("unexpected output:\n%s", stdout.String())
	}
}

func TestPlanPrintsPendingMessageWhenNoTestPlanAvailable(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	var stdout bytes.Buffer
	payload := `{
		"job": {
			"id": 456,
			"issue_title": "Add user avatar upload"
		},
		"test_plan": null
	}`

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(payload))
	}))
	defer server.Close()
	writeCredentials(t, home, server.URL, "secret-token")

	command := NewTestPlanCommand()
	command.SetOut(&stdout)
	command.SetArgs([]string{"JOB-456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	expected := "No test plan available for JOB-456 yet — the job may still be implementing.\n"
	if stdout.String() != expected {
		t.Fatalf("unexpected output: %q", stdout.String())
	}
}

func TestPlanDefaultsToCurrentSyrusJobBranch(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	var stdout bytes.Buffer
	var requestedURL string
	payload := `{
		"job": {
			"id": 456,
			"issue_title": "Add user avatar upload"
		},
		"test_plan": {
			"steps": ["Run the default branch smoke test"],
			"notes": ""
		}
	}`

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		requestedURL = request.URL.String()
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(payload))
	}))
	defer server.Close()
	writeCredentials(t, home, server.URL, "secret-token")

	originalRunner := checkoutRunGit
	checkoutRunGit = func(_ context.Context, _ string, args ...string) (string, error) {
		switch strings.Join(args, " ") {
		case "rev-parse --is-inside-work-tree":
			return "true\n", nil
		case "branch --show-current":
			return "syrus/issue-720-456\n", nil
		default:
			t.Fatalf("unexpected git command: %s", strings.Join(args, " "))
			return "", nil
		}
	}
	t.Cleanup(func() { checkoutRunGit = originalRunner })

	command := NewTestPlanCommand()
	command.SetOut(&stdout)
	command.SetArgs([]string{})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if requestedURL != "/api/v1/app/jobs/456" {
		t.Fatalf("unexpected request URL: %s", requestedURL)
	}
	if !strings.Contains(stdout.String(), "Test plan for JOB-456") {
		t.Fatalf("unexpected output:\n%s", stdout.String())
	}
}

func TestPlanWithoutArgumentRequiresSyrusJobBranch(t *testing.T) {
	originalRunner := checkoutRunGit
	checkoutRunGit = func(_ context.Context, _ string, args ...string) (string, error) {
		switch strings.Join(args, " ") {
		case "rev-parse --is-inside-work-tree":
			return "true\n", nil
		case "branch --show-current":
			return "main\n", nil
		default:
			t.Fatalf("unexpected git command: %s", strings.Join(args, " "))
			return "", nil
		}
	}
	t.Cleanup(func() { checkoutRunGit = originalRunner })

	command := NewTestPlanCommand()
	command.SetArgs([]string{})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "current branch is a Syrus job branch") {
		t.Fatalf("unexpected error: %s", err)
	}
}

func TestJobIDFromBranchParsesKnownSyrusBranches(t *testing.T) {
	for branch, want := range map[string]string{
		"syrus/issue-720-456":  "456",
		"syrus/direct-732":     "732",
		"syrus/scheduled-4-99": "99",
		"syrus/local-8":        "8",
	} {
		got, ok := jobIDFromBranch(branch)
		if !ok || got != want {
			t.Fatalf("jobIDFromBranch(%q) = %q, %v; want %q, true", branch, got, ok, want)
		}
	}

	if _, ok := jobIDFromBranch("syrus/issue-720"); ok {
		t.Fatalf("ambiguous issue branch should not infer a Job id")
	}
}

func TestPlanAcceptsHumanSlug(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	var requestedURL string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestedURL = r.URL.String()
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"job":{"id":42,"issue_title":"My feature"},"test_plan":{"steps":["Open the app"],"notes":""}}`))
	}))
	defer server.Close()
	writeCredentials(t, home, server.URL, "token")

	command := NewTestPlanCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"my-feature-slug"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if requestedURL != "/api/v1/app/jobs/my-feature-slug" {
		t.Fatalf("unexpected request URL: %s", requestedURL)
	}
}

func TestPlanAcceptsNumericIDWithoutPrefix(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	var requestedURL string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestedURL = r.URL.String()
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"job":{"id":456,"issue_title":"Add feature"},"test_plan":{"steps":["Step 1"],"notes":""}}`))
	}))
	defer server.Close()
	writeCredentials(t, home, server.URL, "token")

	command := NewTestPlanCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if requestedURL != "/api/v1/app/jobs/456" {
		t.Fatalf("unexpected request URL: %s", requestedURL)
	}
}

func TestParseJobIDAcceptsSlug(t *testing.T) {
	cases := []struct {
		input string
		want  string
	}{
		{"JOB-123", "123"},
		{"job-456", "456"},
		{"789", "789"},
		{"my-feature-slug", "my-feature-slug"},
		{"add-user-avatar-upload", "add-user-avatar-upload"},
	}
	for _, tc := range cases {
		got, err := parseJobID(tc.input)
		if err != nil {
			t.Errorf("parseJobID(%q) error: %v", tc.input, err)
			continue
		}
		if got != tc.want {
			t.Errorf("parseJobID(%q) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

func TestParseJobIDRejectsEmpty(t *testing.T) {
	_, err := parseJobID("")
	if err == nil {
		t.Fatal("expected error for empty input")
	}
	if !strings.Contains(err.Error(), "required") {
		t.Fatalf("unexpected error: %s", err)
	}
}
