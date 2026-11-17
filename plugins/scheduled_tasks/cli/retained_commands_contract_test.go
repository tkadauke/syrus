package scheduledtasks

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/cliplugin/cliplugintest"
)

func TestScheduleListFallsBackToAllSchedulesOutsideRepository(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireScheduleAuth(t, r)
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/scheduled_tasks" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"active_tasks":[{"id":2,"name":"Other","repository":{"slug":"acme/other"}}]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")
	cliplugintest.WithRepoSlug(t, "")

	command, output := NewScheduleCommand(), &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"list"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "Other") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestScheduleCreatePreservesRequestContract(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireScheduleAuth(t, r)
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/repositories" {
			w.Write([]byte(`{"active_repositories":[{"id":7,"slug":"acme/widgets"}]}`))
			return
		}
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/app/repositories/7/scheduled_tasks" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
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
		got := payload.ScheduledTask
		if got.Name != "Weekly tests" || got.Kind != "cron" || got.CronExpression != "0 9 * * 1" || got.PrPileupPolicy != "skip" || got.Prompt != "Write missing tests.\nThen tidy docs." {
			t.Fatalf("scheduled_task = %#v", got)
		}
		w.Write([]byte(`{"task":{"id":42}}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")
	cliplugintest.WithRepoSlug(t, "acme/widgets")

	command, output := NewScheduleCommand(), &bytes.Buffer{}
	command.SetIn(strings.NewReader("Weekly tests\n0 9 * * 1\nWrite missing tests.\nThen tidy docs.\n\n"))
	command.SetOut(output)
	command.SetArgs([]string{"create", "--yes"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
}

func TestScheduleDeletePreservesConfirmationAndRequestContract(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireScheduleAuth(t, r)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/scheduled_tasks/42":
			w.Write([]byte(`{"task":{"id":42,"name":"Weekly tests"}}`))
		case r.Method == http.MethodDelete && r.URL.Path == "/api/v1/app/scheduled_tasks/42":
			w.WriteHeader(http.StatusNoContent)
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command, output := NewScheduleCommand(), &bytes.Buffer{}
	command.SetIn(strings.NewReader("y\n"))
	command.SetOut(output)
	command.SetArgs([]string{"delete", "42"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !strings.Contains(output.String(), "Delete schedule 'Weekly tests'? [y/N]") {
		t.Fatalf("output = %q", output.String())
	}
}

func requireScheduleAuth(t *testing.T, r *http.Request) {
	t.Helper()
	if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
		t.Fatalf("Authorization = %q", got)
	}
}
