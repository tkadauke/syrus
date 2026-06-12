package cmd

import (
	"context"
	"errors"
	"net/url"
	"strconv"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/tkadauke/syrus/cli/internal/api"
)

type fakeInboxClient struct {
	lists       map[string][]api.JobItem
	listFilters []url.Values
	approved    []string
	retried     []string
}

func (f *fakeInboxClient) ListJobs(_ context.Context, filters url.Values) (api.JobList, error) {
	f.listFilters = append(f.listFilters, filters)
	state := filters.Get("state")
	return api.JobList{Count: len(f.lists[state]), Jobs: f.lists[state]}, nil
}

func (f *fakeInboxClient) GetJobDetail(context.Context, string) (api.JobDetail, error) {
	return api.JobDetail{}, nil
}

func (f *fakeInboxClient) GetJobTranscript(context.Context, string) (api.JobTranscript, error) {
	return api.JobTranscript{}, nil
}

func (f *fakeInboxClient) GetJobDiff(context.Context, string) (api.JobDiff, error) {
	return api.JobDiff{}, nil
}

func (f *fakeInboxClient) ApproveJob(_ context.Context, id string) error {
	f.approved = append(f.approved, id)
	return nil
}

func (f *fakeInboxClient) RetryJob(_ context.Context, id string) error {
	f.retried = append(f.retried, id)
	return nil
}

func TestFetchInboxJobsScopesToRepoAndAttentionStates(t *testing.T) {
	client := &fakeInboxClient{lists: map[string][]api.JobItem{
		"implemented": {{ID: 1, State: "implemented", UpdatedAt: "2026-06-12T10:00:00Z"}},
		"failed":      {{ID: 2, State: "failed", UpdatedAt: "2026-06-12T11:00:00Z"}},
	}}

	jobs, err := fetchInboxJobs(context.Background(), client, "tkadauke/myapp")
	if err != nil {
		t.Fatal(err)
	}
	if got := []int64{jobs[0].ID, jobs[1].ID}; got[0] != 2 || got[1] != 1 {
		t.Fatalf("jobs sorted by updated_at desc = %v", got)
	}
	if len(client.listFilters) != 2 {
		t.Fatalf("ListJobs called %d times, want 2", len(client.listFilters))
	}
	for _, filters := range client.listFilters {
		if filters.Get("repo") != "tkadauke/myapp" {
			t.Fatalf("repo filter = %q", filters.Get("repo"))
		}
		if filters.Get("state") != "implemented" && filters.Get("state") != "failed" {
			t.Fatalf("unexpected state filter %q", filters.Get("state"))
		}
	}
}

func TestInboxApproveRemovesRowAfterConfirmation(t *testing.T) {
	client := &fakeInboxClient{lists: map[string][]api.JobItem{}}
	model := newInboxModel(client, inboxOptions{})
	model.jobs = []api.JobItem{{ID: 456, State: "implemented", Title: "Add dark mode"}}

	updated, cmd := model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("a")})
	model = updated.(inboxModel)
	if model.confirm != "approve" || model.pendingID != 456 {
		t.Fatalf("confirm = %q pendingID = %d", model.confirm, model.pendingID)
	}

	updated, cmd = model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("y")})
	model = updated.(inboxModel)
	msg := cmd().(inboxActionMsg)
	if msg.err != nil {
		t.Fatal(msg.err)
	}
	if got := client.approved; len(got) != 1 || got[0] != "456" {
		t.Fatalf("approved = %v", got)
	}

	updated, _ = model.Update(msg)
	model = updated.(inboxModel)
	if len(model.jobs) != 0 {
		t.Fatalf("jobs after approve = %v", model.jobs)
	}
}

func TestInboxRetryOnlyAppliesToFailedJobs(t *testing.T) {
	client := &fakeInboxClient{}
	model := newInboxModel(client, inboxOptions{})
	model.jobs = []api.JobItem{{ID: 7, State: "implemented"}, {ID: 8, State: "failed"}}

	updated, _ := model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("r")})
	model = updated.(inboxModel)
	if model.confirm != "" {
		t.Fatalf("unexpected retry confirmation for implemented job")
	}

	model.cursor = 1
	updated, cmd := model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("r")})
	model = updated.(inboxModel)
	if model.confirm != "retry" || model.pendingID != 8 {
		t.Fatalf("confirm = %q pendingID = %d", model.confirm, model.pendingID)
	}
	updated, cmd = model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("y")})
	model = updated.(inboxModel)
	msg := cmd().(inboxActionMsg)
	if msg.err != nil {
		t.Fatal(msg.err)
	}
	if got := client.retried; len(got) != 1 || got[0] != strconv.Itoa(8) {
		t.Fatalf("retried = %v", got)
	}
}

func TestInboxActionErrorKeepsRow(t *testing.T) {
	model := newInboxModel(&fakeInboxClient{}, inboxOptions{})
	model.jobs = []api.JobItem{{ID: 9, State: "implemented"}}

	updated, _ := model.Update(inboxActionMsg{jobID: 9, kind: "approve", remove: true, err: errors.New("nope")})
	model = updated.(inboxModel)

	if len(model.jobs) != 1 {
		t.Fatalf("jobs removed on error")
	}
	if model.err != "nope" {
		t.Fatalf("err = %q", model.err)
	}
}

func TestDetailPanelTextPrefersTestPlanArtifact(t *testing.T) {
	detail := api.JobDetail{
		Summary: &api.JobSummary{Text: "Implemented the switch."},
		Workflows: []api.WorkflowBrief{{
			Artifacts: map[string]any{
				"pr_body": "Adds a switch.\n\n## Test plan\n1. Open settings\n2. Toggle it\n\n## Notes\nNone",
			},
		}},
	}

	got := detailPanelText(detail)
	want := "Test plan:\n1. Open settings\n2. Toggle it"
	if got != want {
		t.Fatalf("detailPanelText = %q, want %q", got, want)
	}
}
