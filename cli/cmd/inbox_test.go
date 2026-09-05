package cmd

import (
	"context"
	"errors"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/tkadauke/syrus/cli/pkg/api"
)

type fakeInboxClient struct {
	lists          map[string][]api.JobItem
	details        map[string]api.JobDetail
	listFilters    []url.Values
	detailRequests []string
	approved       []string
	retried        []string
}

func (f *fakeInboxClient) ListJobs(_ context.Context, filters url.Values) (api.JobList, error) {
	f.listFilters = append(f.listFilters, filters)
	state := filters.Get("state")
	return api.JobList{Count: len(f.lists[state]), Jobs: f.lists[state]}, nil
}

func (f *fakeInboxClient) GetJobDetail(_ context.Context, id string) (api.JobDetail, error) {
	f.detailRequests = append(f.detailRequests, id)
	return f.details[id], nil
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

func TestInboxApproveMarksRowHandledAfterConfirmation(t *testing.T) {
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

	updated, refreshCmd := model.Update(msg)
	model = updated.(inboxModel)
	if refreshCmd == nil {
		t.Fatalf("expected refresh after handled action")
	}
	if len(model.jobs) != 1 {
		t.Fatalf("jobs after approve = %v", model.jobs)
	}
	if model.handled[456] != "approve" {
		t.Fatalf("handled marker = %q", model.handled[456])
	}
	if !model.isRead(456) {
		t.Fatalf("approved row was not marked read")
	}
	if !strings.Contains(model.View(), "done: approved") {
		t.Fatalf("view does not show handled marker:\n%s", model.View())
	}
}

func TestInboxRefreshPreservesExistingOrderAndHandledRows(t *testing.T) {
	model := newInboxModel(&fakeInboxClient{}, inboxOptions{})
	model.jobs = []api.JobItem{
		{ID: 1, State: "implemented", Title: "First"},
		{ID: 2, State: "failed", Title: "Second"},
	}
	model.handled[1] = "approve"
	model.read[1] = "approve"

	updated, _ := model.Update(inboxRefreshMsg{jobs: []api.JobItem{
		{ID: 3, State: "implemented", Title: "Third", UpdatedAt: "2026-06-12T12:00:00Z"},
		{ID: 4, State: "implemented", Title: "Fourth", UpdatedAt: "2026-06-12T11:00:00Z"},
		{ID: 2, State: "failed", Title: "Second refreshed"},
	}})
	model = updated.(inboxModel)

	var ids []int64
	for _, job := range model.jobs {
		ids = append(ids, job.ID)
	}
	if want := []int64{1, 2, 4, 3}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("ids after refresh = %v, want %v", ids, want)
	}
	if model.jobs[1].Title != "Second refreshed" {
		t.Fatalf("existing row did not refresh: %q", model.jobs[1].Title)
	}
	if model.handled[1] != "approve" {
		t.Fatalf("handled row lost marker")
	}
	if !model.isRead(1) {
		t.Fatalf("read row lost marker")
	}
	if model.isRead(3) || model.isRead(4) {
		t.Fatalf("new rows should start unread")
	}
}

func TestInboxOpenPRMarksRowRead(t *testing.T) {
	model := newInboxModel(&fakeInboxClient{}, inboxOptions{})
	model.jobs = []api.JobItem{{ID: 5, State: "implemented", PRURL: "https://example.com/pr"}}

	updated, cmd := model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("o")})
	model = updated.(inboxModel)

	if cmd == nil {
		t.Fatalf("expected open URL command")
	}
	if !model.isRead(5) {
		t.Fatalf("opened PR row was not marked read")
	}
}

func TestInboxOpenSyrusMarksRowRead(t *testing.T) {
	model := newInboxModel(&fakeInboxClient{}, inboxOptions{appURL: "https://syrus.example.com"})
	model.jobs = []api.JobItem{{ID: 5, State: "implemented"}}

	updated, cmd := model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("s")})
	model = updated.(inboxModel)

	if cmd == nil {
		t.Fatalf("expected open Syrus command")
	}
	if !model.isRead(5) {
		t.Fatalf("opened Syrus row was not marked read")
	}
	if !strings.Contains(model.status, "Opened Syrus page for JOB-5") {
		t.Fatalf("status = %q", model.status)
	}
}

func TestInboxSuccessfulReadActionsMarkRowsRead(t *testing.T) {
	model := newInboxModel(&fakeInboxClient{}, inboxOptions{})
	model.jobs = []api.JobItem{{ID: 9, State: "implemented"}, {ID: 10, State: "implemented"}}

	updated, _ := model.Update(inboxActionMsg{jobID: 9, kind: "checkout", read: true})
	model = updated.(inboxModel)
	updated, _ = model.Update(inboxActionMsg{jobID: 10, kind: "diff", read: true})
	model = updated.(inboxModel)

	if !model.isRead(9) {
		t.Fatalf("checkout row was not marked read")
	}
	if !model.isRead(10) {
		t.Fatalf("diff row was not marked read")
	}
}

func TestInboxUsesAvailableTerminalWidth(t *testing.T) {
	model := newInboxModel(&fakeInboxClient{}, inboxOptions{})
	model.jobs = []api.JobItem{{
		ID:    12,
		State: "implemented",
		Title: "This title keeps going beyond the old fixed inbox title width",
	}}

	updated, _ := model.Update(tea.WindowSizeMsg{Width: 118, Height: 40})
	model = updated.(inboxModel)
	view := model.View()

	if !strings.Contains(view, strings.Repeat("─", 118)) {
		t.Fatalf("view does not use full terminal width:\n%s", view)
	}
	if !strings.Contains(view, "beyond the old fixed inbox title width") {
		t.Fatalf("job title was still truncated to the old fixed width:\n%s", view)
	}
}

func TestInboxOpenDetailShowsLoadingBeforeFetchCompletes(t *testing.T) {
	model := newInboxModel(&fakeInboxClient{}, inboxOptions{})
	model.jobs = []api.JobItem{{ID: 12, State: "implemented", Title: "Summarize me"}}

	updated, cmd := model.Update(tea.KeyMsg{Type: tea.KeyEnter})
	model = updated.(inboxModel)

	if cmd == nil {
		t.Fatalf("expected detail fetch command")
	}
	if !strings.Contains(model.View(), "Loading details...") {
		t.Fatalf("view does not show loading detail state:\n%s", model.View())
	}
	if strings.Contains(model.View(), "No summary captured yet.") {
		t.Fatalf("view shows empty summary before detail fetch completes:\n%s", model.View())
	}
}

func TestInboxFetchesDetailWhenSelectionChangesWithPanelOpen(t *testing.T) {
	client := &fakeInboxClient{details: map[string]api.JobDetail{
		"2": {Summary: &api.JobSummary{Text: "Second job summary"}},
	}}
	model := newInboxModel(client, inboxOptions{})
	model.jobs = []api.JobItem{
		{ID: 1, State: "implemented", Title: "First"},
		{ID: 2, State: "implemented", Title: "Second"},
	}
	model.detailOpen = true
	model.details[1] = "First job summary"
	model.detailDone[1] = true

	updated, cmd := model.Update(tea.KeyMsg{Type: tea.KeyDown})
	model = updated.(inboxModel)

	if model.cursor != 1 {
		t.Fatalf("cursor = %d, want 1", model.cursor)
	}
	if cmd == nil {
		t.Fatalf("expected detail fetch command")
	}
	msg := cmd().(inboxDetailMsg)
	if msg.err != nil {
		t.Fatal(msg.err)
	}
	updated, _ = model.Update(msg)
	model = updated.(inboxModel)

	if !reflect.DeepEqual(client.detailRequests, []string{"2"}) {
		t.Fatalf("detail requests = %v", client.detailRequests)
	}
	if !strings.Contains(model.View(), "Second job summary") {
		t.Fatalf("view does not show fetched detail:\n%s", model.View())
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
	updated, _ = model.Update(msg)
	model = updated.(inboxModel)
	if !model.isRead(8) {
		t.Fatalf("retried row was not marked read")
	}
}

func TestInboxActionErrorKeepsRow(t *testing.T) {
	model := newInboxModel(&fakeInboxClient{}, inboxOptions{})
	model.jobs = []api.JobItem{{ID: 9, State: "implemented"}}

	updated, _ := model.Update(inboxActionMsg{jobID: 9, kind: "approve", handled: true, err: errors.New("nope")})
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

func TestPagerCommandLine(t *testing.T) {
	tests := []struct {
		name      string
		goos      string
		pagerEnv  string
		wantName  string
		wantArgs  []string
		wantPager bool
	}{
		{name: "unset PAGER defaults to less on linux", goos: "linux", pagerEnv: "", wantName: "less", wantArgs: []string{}, wantPager: true},
		{name: "unset PAGER defaults to less on darwin", goos: "darwin", pagerEnv: "", wantName: "less", wantArgs: []string{}, wantPager: true},
		{name: "unset PAGER prints directly on windows", goos: "windows", pagerEnv: "", wantPager: false},
		{name: "blank PAGER prints directly on windows", goos: "windows", pagerEnv: "   ", wantPager: false},
		{name: "set PAGER honored on windows", goos: "windows", pagerEnv: "more.com", wantName: "more.com", wantArgs: []string{}, wantPager: true},
		{name: "PAGER with args split into fields", goos: "linux", pagerEnv: "less -RFX", wantName: "less", wantArgs: []string{"-RFX"}, wantPager: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			name, args, usePager := pagerCommandLine(tt.goos, tt.pagerEnv)
			if usePager != tt.wantPager {
				t.Fatalf("usePager = %v, want %v", usePager, tt.wantPager)
			}
			if !usePager {
				return
			}
			if name != tt.wantName {
				t.Errorf("name = %q, want %q", name, tt.wantName)
			}
			if !reflect.DeepEqual(args, tt.wantArgs) {
				t.Errorf("args = %v, want %v", args, tt.wantArgs)
			}
		})
	}
}
