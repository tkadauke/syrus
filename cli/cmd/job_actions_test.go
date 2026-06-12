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
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			w.Write([]byte(`{"job":{"id":456,"title":"Tune the aqueduct"},"repository":{"slug":"acme/widgets"}}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writeTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetIn(strings.NewReader("Tune the aqueduct\nMake the CLI flow work.\nKeep the stones numbered.\n\n"))
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "create", "--repo", "acme/widgets", "--yes"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "Job #456 created. Track with: syrus job watch 456") {
		t.Fatalf("output = %q", output.String())
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
	writeTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "approve", "456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := strings.TrimSpace(output.String()); got != "Job #456 approved." {
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
	writeTestCredentials(t, server.URL)

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
	writeTestCredentials(t, server.URL)

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"job", "checkout", "456"})

	err := command.Execute()
	if err == nil || err.Error() != "Job #456 has no branch yet" {
		t.Fatalf("error = %v", err)
	}
}

func TestJobOpenUsesConfiguredInstanceURL(t *testing.T) {
	writeTestCredentials(t, "https://syrus.example.test/")
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

func writeTestCredentials(t *testing.T, url string) {
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
