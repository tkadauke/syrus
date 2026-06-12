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

func TestScheduleListScopesToCurrentRepositoryWhenPresent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/scheduled_tasks" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"active_tasks":[{"id":1,"name":"Local","cron_expression":"0 9 * * 1","next_fire_at":"2026-06-15T09:00:00Z","repository":{"slug":"acme/widgets"}},{"id":2,"name":"Other","cron_expression":"0 8 * * 1","repository":{"slug":"acme/other"}}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	command := NewScheduleCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"list"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); !strings.Contains(got, "ID") || !strings.Contains(got, "LABEL") || !strings.Contains(got, "Local") {
		t.Fatalf("output = %q", got)
	}
	if strings.Contains(output.String(), "Other") {
		t.Fatalf("expected current repo scope, got %q", output.String())
	}
}

func TestScheduleListFallsBackToAllSchedules(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"active_tasks":[{"id":2,"name":"Other","cron_expression":"0 8 * * 1","repository":{"slug":"acme/other"}}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	command := NewScheduleCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"list"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "Other") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestScheduleCreatePostsToCurrentRepository(t *testing.T) {
	var postSeen bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/repositories":
			w.Write([]byte(`{"active_repositories":[{"id":7,"slug":"acme/widgets"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/app/repositories/7/scheduled_tasks":
			postSeen = true
			var payload struct {
				ScheduledTask struct {
					Name           string `json:"name"`
					Kind           string `json:"kind"`
					CronExpression string `json:"cron_expression"`
					PrPileupPolicy string `json:"pr_pileup_policy"`
					Prompt         string `json:"prompt"`
				} `json:"scheduled_task"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			if payload.ScheduledTask.Name != "Weekly tests" {
				t.Fatalf("name = %q", payload.ScheduledTask.Name)
			}
			if payload.ScheduledTask.Kind != "cron" || payload.ScheduledTask.PrPileupPolicy != "skip" {
				t.Fatalf("payload = %#v", payload.ScheduledTask)
			}
			if payload.ScheduledTask.Prompt != "Write missing tests.\nThen tidy docs." {
				t.Fatalf("prompt = %q", payload.ScheduledTask.Prompt)
			}
			w.Write([]byte(`{"task":{"id":42}}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")
	withRepoSlug(t, "acme/widgets")

	command := NewScheduleCommand()
	output := &bytes.Buffer{}
	command.SetIn(strings.NewReader("Weekly tests\n0 9 * * 1\nWrite missing tests.\nThen tidy docs.\n"))
	command.SetOut(output)
	command.SetArgs([]string{"create", "--yes"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !postSeen {
		t.Fatal("expected POST /api/v1/app/repositories/7/scheduled_tasks")
	}
	if !strings.Contains(output.String(), "Created schedule #42") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestScheduleShowPrintsLastFiveJobs(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/scheduled_tasks/42" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"task":{"id":42,"name":"Weekly tests","state":"scheduled","repository":{"slug":"acme/widgets"},"cron_expression":"0 9 * * 1","next_fire_at":"2026-06-15T09:00:00Z","pr_pileup_policy":"skip","auto_approve_mode":"never","prompt":"Write missing tests."},"recent_jobs":[{"id":1,"state":"closed"},{"id":2,"state":"closed"},{"id":3,"state":"closed"},{"id":4,"state":"closed"},{"id":5,"state":"closed"},{"id":6,"state":"closed"}]}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	command := NewScheduleCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"show", "42"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "Schedule #42: Weekly tests") || !strings.Contains(got, "#5 closed") {
		t.Fatalf("output = %q", got)
	}
	if strings.Contains(got, "#6 closed") {
		t.Fatalf("expected only five jobs, got %q", got)
	}
}

func TestScheduleDeleteRequiresConfirmation(t *testing.T) {
	var deleted bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/scheduled_tasks/42":
			w.Write([]byte(`{"task":{"id":42,"name":"Weekly tests"}}`))
		case r.Method == http.MethodDelete && r.URL.Path == "/api/v1/app/scheduled_tasks/42":
			deleted = true
			w.WriteHeader(http.StatusNoContent)
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	command := NewScheduleCommand()
	output := &bytes.Buffer{}
	command.SetIn(strings.NewReader("y\n"))
	command.SetOut(output)
	command.SetArgs([]string{"delete", "42"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !deleted {
		t.Fatal("expected DELETE /api/v1/app/scheduled_tasks/42")
	}
	if !strings.Contains(output.String(), "Delete schedule 'Weekly tests'? [y/N]") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestScheduleRunPrintsCreatedJob(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/app/scheduled_tasks/42/fire_now" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"message":"Fired (job #99).","fire_result":{"fired":true,"job_id":99}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL, "secret-token")

	command := NewScheduleCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"run", "42"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if output.String() != "Created job #99\n" {
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

func requireAuth(t *testing.T, r *http.Request) {
	t.Helper()
	if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
		t.Fatalf("Authorization = %q", got)
	}
}
