package cmd

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
)

const inboxRefreshInterval = 30 * time.Second

type inboxAPI interface {
	ListJobs(context.Context, url.Values) (api.JobList, error)
	GetJobDetail(context.Context, string) (api.JobDetail, error)
	GetJobTranscript(context.Context, string) (api.JobTranscript, error)
	GetJobDiff(context.Context, string) (api.JobDiff, error)
	ApproveJob(context.Context, string) error
	RetryJob(context.Context, string) error
}

type inboxOptions struct {
	watch bool
	repo  string
}

type inboxRefreshMsg struct {
	jobs []api.JobItem
	err  error
}

type inboxDetailMsg struct {
	jobID   int64
	summary string
	err     error
}

type inboxActionMsg struct {
	jobID  int64
	kind   string
	remove bool
	err    error
}

type inboxPageMsg struct {
	jobID int64
	kind  string
	text  string
	err   error
}

type inboxTickMsg struct{}

type inboxModel struct {
	client  inboxAPI
	options inboxOptions

	jobs       []api.JobItem
	cursor     int
	detailOpen bool
	details    map[int64]string
	help       bool
	loading    bool
	quitting   bool
	err        string
	status     string
	confirm    string
	pendingID  int64
	pending    map[int64]string
}

func NewInboxCommand() *cobra.Command {
	var watch bool
	var repo string
	cmd := &cobra.Command{
		Use:   "inbox",
		Short: "Review implemented and failed Syrus jobs",
		RunE: func(cmd *cobra.Command, args []string) error {
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			if repo == "" {
				repo = currentRepoSlug()
			}
			options := inboxOptions{watch: watch, repo: repo}
			jobs, err := fetchInboxJobs(cmd.Context(), client, repo)
			if err != nil {
				return err
			}
			if len(jobs) == 0 && !watch {
				fmt.Fprintln(cmd.OutOrStdout(), "Nothing in your inbox. Syrus is on it.")
				return nil
			}

			model := newInboxModel(client, options)
			model.jobs = jobs
			_, err = tea.NewProgram(model).Run()
			return err
		},
	}
	cmd.Flags().BoolVar(&watch, "watch", false, "stay open and poll every 30 seconds when the inbox is empty")
	cmd.Flags().StringVar(&repo, "repo", "", "repository slug to scope to, owner/name")
	return cmd
}

func newInboxModel(client inboxAPI, options inboxOptions) inboxModel {
	return inboxModel{
		client:  client,
		options: options,
		details: map[int64]string{},
		pending: map[int64]string{},
	}
}

func (m inboxModel) Init() tea.Cmd {
	return inboxTick()
}

func (m inboxModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		return m.updateKey(msg)
	case inboxRefreshMsg:
		m.loading = false
		if msg.err != nil {
			m.err = msg.err.Error()
			return m, inboxTick()
		}
		m.err = ""
		m.jobs = msg.jobs
		if m.cursor >= len(m.jobs) {
			m.cursor = max(0, len(m.jobs)-1)
		}
		return m, inboxTick()
	case inboxDetailMsg:
		delete(m.pending, msg.jobID)
		if msg.err != nil {
			m.err = msg.err.Error()
		} else {
			m.details[msg.jobID] = msg.summary
			m.err = ""
		}
		return m, nil
	case inboxActionMsg:
		delete(m.pending, msg.jobID)
		m.confirm = ""
		m.pendingID = 0
		if msg.err != nil {
			m.err = msg.err.Error()
			return m, nil
		}
		m.err = ""
		m.status = fmt.Sprintf("%s succeeded for JOB-%d", msg.kind, msg.jobID)
		if msg.remove {
			m.jobs = slices.DeleteFunc(m.jobs, func(job api.JobItem) bool { return job.ID == msg.jobID })
			if m.cursor >= len(m.jobs) {
				m.cursor = max(0, len(m.jobs)-1)
			}
			return m, refreshInboxCmd(m.client, m.options.repo)
		}
		return m, nil
	case inboxPageMsg:
		if msg.err != nil {
			m.err = msg.err.Error()
			return m, nil
		}
		return m, tea.ExecProcess(pagerCommand(msg.text), func(err error) tea.Msg {
			return inboxActionMsg{jobID: msg.jobID, kind: msg.kind, err: err}
		})
	case inboxTickMsg:
		if m.quitting {
			return m, nil
		}
		m.loading = true
		return m, refreshInboxCmd(m.client, m.options.repo)
	}
	return m, nil
}

func (m inboxModel) updateKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.confirm != "" {
		switch msg.String() {
		case "y", "Y":
			return m.confirmAction()
		case "n", "N", "esc":
			m.confirm = ""
			m.pendingID = 0
			return m, nil
		}
	}

	switch msg.String() {
	case "ctrl+c", "q":
		m.quitting = true
		return m, tea.Quit
	case "up", "k":
		if m.cursor > 0 {
			m.cursor--
		}
	case "down", "j":
		if m.cursor < len(m.jobs)-1 {
			m.cursor++
		}
	case "enter":
		job, ok := m.selectedJob()
		if !ok {
			return m, nil
		}
		m.detailOpen = !m.detailOpen
		if m.detailOpen {
			m.pending[job.ID] = "detail"
			return m, fetchInboxDetailCmd(m.client, job.ID)
		}
	case "?":
		m.help = !m.help
	case "R":
		m.loading = true
		return m, refreshInboxCmd(m.client, m.options.repo)
	case "a":
		if job, ok := m.selectedJob(); ok && job.State == "implemented" {
			m.confirm = "approve"
			m.pendingID = job.ID
		}
	case "r":
		if job, ok := m.selectedJob(); ok && job.State == "failed" {
			m.confirm = "retry"
			m.pendingID = job.ID
		}
	case "o":
		if job, ok := m.selectedJob(); ok && job.PRURL != "" {
			return m, tea.ExecProcess(openURLCommand(job.PRURL), nil)
		}
	case "c":
		if job, ok := m.selectedJob(); ok {
			return m, checkoutJobCmd(m.client, job.ID)
		}
	case "d":
		if job, ok := m.selectedJob(); ok {
			return m, pageJobDiffCmd(m.client, job.ID)
		}
	case "l":
		if job, ok := m.selectedJob(); ok {
			return m, pageJobLogCmd(m.client, job.ID)
		}
	}
	return m, nil
}

func (m inboxModel) confirmAction() (tea.Model, tea.Cmd) {
	jobID := m.pendingID
	kind := m.confirm
	m.pending[jobID] = kind
	m.status = fmt.Sprintf("%s JOB-%d...", strings.Title(kind), jobID)
	return m, func() tea.Msg {
		var err error
		id := strconv.FormatInt(jobID, 10)
		if kind == "approve" {
			err = m.client.ApproveJob(context.Background(), id)
		} else {
			err = m.client.RetryJob(context.Background(), id)
		}
		return inboxActionMsg{jobID: jobID, kind: kind, remove: true, err: err}
	}
}

func (m inboxModel) selectedJob() (api.JobItem, bool) {
	if len(m.jobs) == 0 || m.cursor < 0 || m.cursor >= len(m.jobs) {
		return api.JobItem{}, false
	}
	return m.jobs[m.cursor], true
}

func (m inboxModel) View() string {
	if len(m.jobs) == 0 {
		return "Nothing in your inbox. Syrus is on it.\n"
	}

	header := headerStyle.Render("SYRUS INBOX")
	scope := "all repos"
	if m.options.repo != "" {
		scope = m.options.repo
	}
	lines := []string{fmt.Sprintf("%s  %d jobs · %s", header, len(m.jobs), scope), ruleStyle.Render(strings.Repeat("─", 66))}

	for i, job := range m.jobs {
		pointer := " "
		if i == m.cursor {
			pointer = "▶"
		}
		pr := prText(job)
		pending := m.pending[job.ID]
		if pending != "" {
			pending = "  " + spinnerStyle.Render(pending+"...")
		}
		lines = append(lines, fmt.Sprintf("%s JOB-%-5d %-34s %-13s %s%s", pointer, job.ID, truncate(job.Title, 34), stateStyle(job.State).Render(job.State), pr, pending))
	}

	if m.detailOpen {
		if job, ok := m.selectedJob(); ok {
			lines = append(lines, renderInboxDetail(job, m.details[job.ID]))
		}
	}

	lines = append(lines, ruleStyle.Render(strings.Repeat("─", 66)))
	if m.confirm != "" {
		lines = append(lines, fmt.Sprintf("Confirm %s JOB-%d? y/N", m.confirm, m.pendingID))
	} else if m.help {
		lines = append(lines, "↑/↓ j/k navigate · enter details · a approve · o open PR · c checkout · d diff · l log · r retry · R refresh · ? help · q quit")
	} else {
		lines = append(lines, "a approve  o open PR  c checkout  d diff  l log  r retry  R refresh  ? help  q quit")
	}
	if m.loading {
		lines = append(lines, subtleStyle.Render("Refreshing..."))
	}
	if m.status != "" {
		lines = append(lines, successStyle.Render(m.status))
	}
	if m.err != "" {
		lines = append(lines, errorStyle.Render(m.err))
	}
	return strings.Join(lines, "\n") + "\n"
}

func fetchInboxJobs(ctx context.Context, client inboxAPI, repo string) ([]api.JobItem, error) {
	var jobs []api.JobItem
	for _, state := range []string{"implemented", "failed"} {
		filters := url.Values{}
		filters.Set("state", state)
		filters.Set("limit", "100")
		if repo != "" {
			filters.Set("repo", repo)
		}
		list, err := client.ListJobs(ctx, filters)
		if err != nil {
			return nil, err
		}
		jobs = append(jobs, list.Jobs...)
	}
	slices.SortFunc(jobs, func(a, b api.JobItem) int {
		return strings.Compare(b.UpdatedAt, a.UpdatedAt)
	})
	return jobs, nil
}

func refreshInboxCmd(client inboxAPI, repo string) tea.Cmd {
	return func() tea.Msg {
		jobs, err := fetchInboxJobs(context.Background(), client, repo)
		return inboxRefreshMsg{jobs: jobs, err: err}
	}
}

func inboxTick() tea.Cmd {
	return tea.Tick(inboxRefreshInterval, func(time.Time) tea.Msg { return inboxTickMsg{} })
}

func fetchInboxDetailCmd(client inboxAPI, jobID int64) tea.Cmd {
	return func() tea.Msg {
		detail, err := client.GetJobDetail(context.Background(), strconv.FormatInt(jobID, 10))
		if err != nil {
			return inboxDetailMsg{jobID: jobID, err: err}
		}
		summary := detailPanelText(detail)
		return inboxDetailMsg{jobID: jobID, summary: summary}
	}
}

func detailPanelText(detail api.JobDetail) string {
	if testPlan := extractTestPlan(detail); testPlan != "" {
		return "Test plan:\n" + testPlan
	}
	if detail.Summary != nil {
		return detail.Summary.Text
	}
	return ""
}

func extractTestPlan(detail api.JobDetail) string {
	for _, workflow := range detail.Workflows {
		body, ok := workflow.Artifacts["pr_body"].(string)
		if !ok {
			continue
		}
		if testPlan := extractMarkdownSection(body, "test plan"); testPlan != "" {
			return testPlan
		}
	}
	return ""
}

func extractMarkdownSection(markdown string, heading string) string {
	lines := strings.Split(markdown, "\n")
	var out []string
	capturing := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			title := strings.TrimSpace(strings.TrimLeft(trimmed, "#"))
			if strings.EqualFold(title, heading) {
				capturing = true
				continue
			}
			if capturing {
				break
			}
		}
		if capturing {
			out = append(out, line)
		}
	}
	return strings.TrimSpace(strings.Join(out, "\n"))
}

func formatJobDetailStatus(job api.JobItem) string {
	parts := []string{strings.Title(job.State)}
	if job.PRNumber > 0 {
		parts = append(parts, prText(job))
	}
	return strings.Join(parts, " · ")
}

func renderInboxDetail(job api.JobItem, summary string) string {
	if strings.TrimSpace(summary) == "" {
		summary = "No summary captured yet."
	}
	width := 64
	title := fmt.Sprintf(" JOB-%d · %s ", job.ID, truncate(job.Title, 42))
	var out []string
	out = append(out, "┌─"+title+strings.Repeat("─", max(0, width-len(title)))+"┐")
	out = append(out, fmt.Sprintf("│ %-62s │", truncate(formatJobDetailStatus(job), 62)))
	for _, line := range strings.Split(summary, "\n") {
		out = append(out, fmt.Sprintf("│ %-62s │", truncate(line, 62)))
	}
	out = append(out, "└"+strings.Repeat("─", width+2)+"┘")
	return strings.Join(out, "\n")
}

func stateStyle(state string) lipgloss.Style {
	switch state {
	case "implemented":
		return lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
	case "failed":
		return lipgloss.NewStyle().Foreground(lipgloss.Color("196"))
	default:
		return lipgloss.NewStyle()
	}
}

var (
	headerStyle  = lipgloss.NewStyle().Bold(true)
	ruleStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	subtleStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	errorStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("196"))
	successStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
	spinnerStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("39"))
)

func openURLCommand(target string) *exec.Cmd {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", target)
	case "windows":
		return exec.Command("cmd", "/c", "start", target)
	default:
		return exec.Command("xdg-open", target)
	}
}

func checkoutJobCmd(client inboxAPI, jobID int64) tea.Cmd {
	return func() tea.Msg {
		detail, err := client.GetJobDetail(context.Background(), strconv.FormatInt(jobID, 10))
		if err != nil {
			return inboxActionMsg{jobID: jobID, kind: "checkout", err: err}
		}
		branch := strings.TrimSpace(detail.Job.BranchName)
		if branch == "" {
			return inboxActionMsg{jobID: jobID, kind: "checkout", err: fmt.Errorf("JOB-%d has no branch", jobID)}
		}
		repo := currentRepoSlug()
		if repo == "" || repo != detail.Repository.Slug {
			return inboxActionMsg{jobID: jobID, kind: "checkout", err: fmt.Errorf("checkout requires $PWD to be %s", detail.Repository.Slug)}
		}
		cmd := exec.Command("git", "checkout", branch)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		err = cmd.Run()
		return inboxActionMsg{jobID: jobID, kind: "checkout", err: err}
	}
}

func pageJobDiffCmd(client inboxAPI, jobID int64) tea.Cmd {
	return func() tea.Msg {
		diff, err := client.GetJobDiff(context.Background(), strconv.FormatInt(jobID, 10))
		if err != nil {
			return inboxPageMsg{jobID: jobID, kind: "diff", err: err}
		}
		text := diff.Diff
		if text == "" {
			text = diff.PRURL
		}
		return inboxPageMsg{jobID: jobID, kind: "diff", text: text}
	}
}

func pageJobLogCmd(client inboxAPI, jobID int64) tea.Cmd {
	return func() tea.Msg {
		transcript, err := client.GetJobTranscript(context.Background(), strconv.FormatInt(jobID, 10))
		if err != nil {
			return inboxPageMsg{jobID: jobID, kind: "log", err: err}
		}
		return inboxPageMsg{jobID: jobID, kind: "log", text: strings.Join(transcript.Lines, "\n")}
	}
}

func pagerCommand(text string) *exec.Cmd {
	pager := strings.TrimSpace(os.Getenv("PAGER"))
	if pager == "" {
		pager = "less"
	}
	parts := strings.Fields(pager)
	cmd := exec.Command(parts[0], parts[1:]...)
	cmd.Stdin = strings.NewReader(text)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd
}
