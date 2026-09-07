package spendinginsights

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/cliplugin/cliplugintest"
)

func requireAuth(t *testing.T, r *http.Request) {
	t.Helper()
	if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
		t.Fatalf("Authorization = %q", got)
	}
}

const samplePayload = `{
	"scope": {"admin": false, "user_id": 1, "label": "mine@example.com"},
	"filters": {"start_date": "2026-06-01", "end_date": "2026-06-05", "default_window_days": 90, "agent_providers": []},
	"totals": {"week_usd": 1.5, "month_usd": 4.5, "lifetime_usd": 10.25, "workflow_lifetime_usd": 9.0, "chat_lifetime_usd": 1.25, "average_job_30d_usd": 2.0, "average_merged_pr_30d_usd": 3.0},
	"breakdowns": {
		"epics": [{"id": 1, "label": "Cost Senate", "path": "/epics/1", "jobs_count": 2, "total_usd": 5.0, "average_job_usd": 2.5, "display_number": "EPIC-1"}],
		"users": [{"id": 1, "label": "mine@example.com", "path": "/profiles/1", "jobs_count": 3, "total_usd": 9.0, "average_job_usd": 3.0, "last_30_days_usd": 4.0}],
		"repositories": [{"id": 7, "label": "acme/widgets", "path": "/repositories/7", "jobs_count": 4, "total_usd": 10.25, "average_job_usd": 2.5625}],
		"trigger_kinds": [{"trigger_kind": "initial", "jobs_count": 3, "runs_count": 5, "total_usd": 8.0, "average_usd": 1.6}]
	},
	"top_runs": [],
	"trend": []
}`

func TestSpendingDefaultRendersRepositoryBreakdown(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/insights/spending" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(samplePayload))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSpendingCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "Scope: mine@example.com") || strings.Contains(got, "instance-wide") {
		t.Fatalf("expected non-admin scope without instance-wide marker, got %q", got)
	}
	if !strings.Contains(got, "Window: 2026-06-01 to 2026-06-05") {
		t.Fatalf("output = %q", got)
	}
	if !strings.Contains(got, "Lifetime:                   $10.25 (workflows: $9.00, chats: $1.25)") {
		t.Fatalf("output = %q", got)
	}
	if !strings.Contains(got, "By repository") || !strings.Contains(got, "acme/widgets") || !strings.Contains(got, "$10.25") {
		t.Fatalf("expected repository breakdown, got %q", got)
	}
	if strings.Contains(got, "Cost Senate") {
		t.Fatalf("did not expect epic breakdown in default output, got %q", got)
	}
}

func TestSpendingGroupByUserRendersUserBreakdown(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(samplePayload))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSpendingCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"--group-by", "user"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "By user") || !strings.Contains(got, "mine@example.com") || !strings.Contains(got, "$9.00") {
		t.Fatalf("expected user breakdown, got %q", got)
	}
	if strings.Contains(got, "By repository") {
		t.Fatalf("did not expect repository breakdown, got %q", got)
	}
}

func TestSpendingGroupByTriggerKindRendersTriggerKindBreakdown(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(samplePayload))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSpendingCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"--group-by", "trigger_kind"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "By trigger kind") || !strings.Contains(got, "initial") || !strings.Contains(got, "$8.00") {
		t.Fatalf("expected trigger kind breakdown, got %q", got)
	}
}

func TestSpendingRejectsUnknownGroupBy(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSpendingCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"--group-by", "agent_provider"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "unknown --group-by") {
		t.Fatalf("expected unknown --group-by error, got %v", err)
	}
}

func TestSpendingRejectsInvalidSinceDate(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSpendingCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"--since", "not-a-date"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "--since") {
		t.Fatalf("expected --since date error, got %v", err)
	}
}

func TestSpendingPassesSinceUntilThrough(t *testing.T) {
	var gotStart, gotEnd string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotStart = r.URL.Query().Get("start_date")
		gotEnd = r.URL.Query().Get("end_date")
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(samplePayload))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSpendingCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"--since", "2026-06-01", "--until", "2026-06-05"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if gotStart != "2026-06-01" || gotEnd != "2026-06-05" {
		t.Fatalf("start_date = %q, end_date = %q", gotStart, gotEnd)
	}
}

func TestSpendingRendersInstanceWideScopeForAdmins(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"scope": {"admin": true, "user_id": 1, "label": "All users"}, "filters": {"start_date": "2026-06-01", "end_date": "2026-06-05"}, "totals": {}, "breakdowns": {"epics": [], "users": [], "repositories": [], "trigger_kinds": []}}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSpendingCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "Scope: All users (instance-wide)") {
		t.Fatalf("expected instance-wide scope marker, got %q", got)
	}
	if !strings.Contains(got, "No spend in this window.") {
		t.Fatalf("expected empty-breakdown message, got %q", got)
	}
}

func TestSpendingJSONPrintsRawPayload(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(samplePayload))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSpendingCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"--json"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, `"total_usd":10.25`) {
		t.Fatalf("output = %q", got)
	}
}

func TestSpendingSurfacesUnauthorizedError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		w.Write([]byte(`{"error":{"code":"unauthorized","message":"Sign in to use the app API."}}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewSpendingCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "Sign in to use the app API.") {
		t.Fatalf("expected unauthorized message, got %v", err)
	}
}
