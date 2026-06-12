package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
	"github.com/tkadauke/syrus/cli/internal/config"
)

func NewJobCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "job", Short: "Inspect Syrus jobs"}
	cmd.AddCommand(
		newJobListCommand(false),
		newJobSearchCommand(),
		newJobShowCommand(),
		newJobLogCommand(),
		newJobWatchCommand(),
		newJobDiffCommand(),
		newJobCreateCommand(),
		newJobActionCommand("approve", "approve", "Approved"),
		newJobActionCommand("cancel", "cancel", "Cancellation requested"),
		newJobActionCommand("retry", "run_again", "Retry enqueued"),
		newJobActionCommand("rebase", "rebase", "Rebase enqueued"),
		newJobCheckoutCommand(),
		newJobTestPlanCommand(),
		newJobOpenCommand(),
	)
	return cmd
}

func newJobListCommand(search bool) *cobra.Command {
	var state string
	var limit int
	cmd := &cobra.Command{
		Use:   "list",
		Short: "List jobs",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runJobList(cmd, state, limit, "")
		},
	}
	if search {
		cmd.Use = "search QUERY"
		cmd.Short = "Search jobs by title"
		cmd.Args = cobra.ExactArgs(1)
		cmd.RunE = func(cmd *cobra.Command, args []string) error {
			return runJobList(cmd, state, limit, args[0])
		}
	}
	cmd.Flags().StringVar(&state, "state", "open", "open, closed, or all")
	cmd.Flags().IntVar(&limit, "limit", 20, "maximum rows to show")
	return cmd
}

func newJobSearchCommand() *cobra.Command { return newJobListCommand(true) }

func newJobShowCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "show JOB-ID",
		Short: "Show a job",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			job, err := client.GetJobDetail(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			transcript, _ := client.GetJobTranscript(cmd.Context(), args[0])
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "JOB-%d · %s\n", job.Job.ID, job.Job.Title)
			fmt.Fprintf(out, "State: %s\nRepo: %s\n", job.Job.State, job.Repository.Slug)
			if job.Job.PRURL != "" {
				fmt.Fprintf(out, "PR: %s\n", job.Job.PRURL)
			}
			fmt.Fprintf(out, "Created: %s\nUpdated: %s\n", job.Job.CreatedAt, job.Job.UpdatedAt)
			if job.Job.CurrentStep != "" {
				fmt.Fprintf(out, "Current step: %s\n", job.Job.CurrentStep)
			}
			if len(transcript.Lines) > 0 {
				fmt.Fprintln(out, "\nLast log lines:")
				start := max(0, len(transcript.Lines)-10)
				for _, line := range transcript.Lines[start:] {
					fmt.Fprintln(out, line)
				}
			}
			return nil
		},
	}
}

func newJobLogCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "log JOB-ID",
		Short: "Show or stream a job transcript",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			seen := 0
			for {
				transcript, err := client.GetJobTranscript(cmd.Context(), args[0])
				if err != nil {
					return err
				}
				if transcript.Complete {
					return page(cmd, strings.Join(transcript.Lines, "\n"))
				}
				for _, line := range transcript.Lines[seen:] {
					fmt.Fprintln(cmd.OutOrStdout(), line)
				}
				seen = len(transcript.Lines)
				if transcript.Complete {
					return nil
				}
				select {
				case <-cmd.Context().Done():
					return nil
				case <-time.After(2 * time.Second):
				}
			}
		},
	}
}

func newJobWatchCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "watch JOB-ID",
		Short: "Watch a job",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			first := true
			for {
				job, err := client.GetJobDetail(cmd.Context(), args[0])
				if err != nil {
					return err
				}
				if !first {
					fmt.Fprint(cmd.OutOrStdout(), "\033[H\033[2J")
				}
				first = false
				renderJobWatch(cmd.OutOrStdout(), job)
				if job.Job.State == "closed" {
					return nil
				}
				select {
				case <-cmd.Context().Done():
					return nil
				case <-time.After(3 * time.Second):
				}
			}
		},
	}
}

func newJobDiffCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "diff JOB-ID",
		Short: "Show a job pull request diff",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			diff, err := client.GetJobDiff(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			if diff.NoGithubToken || diff.Diff == "" {
				fmt.Fprintln(cmd.OutOrStdout(), diff.PRURL)
				return nil
			}
			return page(cmd, diff.Diff)
		},
	}
}

func NewEpicCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "epic", Short: "Inspect Syrus epics"}
	cmd.AddCommand(newEpicListCommand(false), newEpicListCommand(true), newEpicShowCommand())
	return cmd
}

func newEpicListCommand(search bool) *cobra.Command {
	var limit int
	cmd := &cobra.Command{
		Use:   "list",
		Short: "List epics",
		RunE: func(cmd *cobra.Command, args []string) error {
			query := ""
			if search {
				query = args[0]
			}
			return runEpicList(cmd, limit, query)
		},
	}
	if search {
		cmd.Use = "search QUERY"
		cmd.Short = "Search epics by title"
		cmd.Args = cobra.ExactArgs(1)
	}
	cmd.Flags().IntVar(&limit, "limit", 20, "maximum rows to show")
	return cmd
}

func newEpicShowCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "show EPIC-ID",
		Short: "Show an epic",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			epic, err := client.GetEpic(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "EPIC-%d · %s\nState: %s\nRepo: %s\n\n", epic.Epic.ID, epic.Epic.Title, epic.Epic.State, epic.Epic.RepositorySlug)
			tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "ID\tSTATE\tREPO\tTITLE\tPR")
			for _, job := range epic.Jobs {
				fmt.Fprintf(tw, "%d\t%s\t%s\t%s\t%s\n", job.ID, job.State, job.RepositorySlug, job.Title, prText(job))
			}
			return tw.Flush()
		},
	}
}

func NewRepoCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "repo", Short: "Inspect Syrus repositories"}
	cmd.AddCommand(&cobra.Command{
		Use:   "list",
		Short: "List repositories",
		RunE: func(cmd *cobra.Command, args []string) error {
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			repos, err := client.ListRepositories(cmd.Context())
			if err != nil {
				return err
			}
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "REPO\tACTIVE JOBS\tLAST JOB")
			for _, repo := range repos.Repositories {
				last := ""
				if repo.LastJob != nil {
					last = fmt.Sprintf("JOB-%d %s", repo.LastJob.ID, repo.LastJob.Title)
				}
				fmt.Fprintf(tw, "%s\t%d\t%s\n", repo.Slug, repo.ActiveJobsCount, last)
			}
			return tw.Flush()
		},
	})
	return cmd
}

func NewWhoamiCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "whoami",
		Short: "Show current Syrus identity",
		RunE: func(cmd *cobra.Command, args []string) error {
			client, creds, err := apiClient()
			if err != nil {
				return err
			}
			who, err := client.Whoami(cmd.Context())
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Email: %s\nInstance: %s\nToken: …%s\n", who.Whoami.Email, creds.URL, last4(creds.Token))
			return nil
		},
	}
}

func runJobList(cmd *cobra.Command, state string, limit int, query string) error {
	client, _, err := apiClient()
	if err != nil {
		return err
	}
	filters := url.Values{}
	filters.Set("state", state)
	filters.Set("limit", strconv.Itoa(limit))
	if repo := currentRepoSlug(); repo != "" {
		filters.Set("repo", repo)
	}
	list, err := client.ListJobs(cmd.Context(), filters)
	if err != nil {
		return err
	}
	tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tSTATE\tREPO\tTITLE\tPR")
	for _, job := range list.Jobs {
		if query != "" && !strings.Contains(strings.ToLower(job.Title), strings.ToLower(query)) {
			continue
		}
		fmt.Fprintf(tw, "%d\t%s\t%s\t%s\t%s\n", job.ID, inspectColorState(job.State), job.RepositorySlug, truncate(job.Title, 80), prText(job))
	}
	return tw.Flush()
}

func runEpicList(cmd *cobra.Command, limit int, query string) error {
	client, _, err := apiClient()
	if err != nil {
		return err
	}
	filters := url.Values{}
	filters.Set("limit", strconv.Itoa(limit))
	if repo := currentRepoSlug(); repo != "" {
		filters.Set("repo", repo)
	}
	list, err := client.ListEpics(cmd.Context(), filters)
	if err != nil {
		return err
	}
	tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tSTATE\tTITLE\tJOBS")
	for _, epic := range list.Epics {
		if query != "" && !strings.Contains(strings.ToLower(epic.Title), strings.ToLower(query)) {
			continue
		}
		fmt.Fprintf(tw, "%d\t%s\t%s\t%d/%d done\n", epic.ID, inspectColorState(epic.State), truncate(epic.Title, 80), epic.DoneJobsCount, epic.TotalJobsCount)
	}
	return tw.Flush()
}

func apiClient() (*api.Client, config.Credentials, error) {
	creds, err := config.LoadDefaultCredentials()
	if err != nil {
		if errors.Is(err, config.ErrMissingCredentials) || errors.Is(err, config.ErrIncompleteCredentials) {
			return nil, config.Credentials{}, errors.New(loginMessage)
		}
		return nil, config.Credentials{}, err
	}
	client, err := api.NewClient(creds.URL, creds.Token)
	return client, creds, err
}

func currentRepoSlug() string {
	out, err := exec.CommandContext(context.Background(), "git", "config", "--get", "remote.origin.url").Output()
	if err != nil {
		return ""
	}
	return parseGitHubSlug(strings.TrimSpace(string(out)))
}

func parseGitHubSlug(remote string) string {
	patterns := []*regexp.Regexp{
		regexp.MustCompile(`github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$`),
	}
	for _, pattern := range patterns {
		match := pattern.FindStringSubmatch(remote)
		if len(match) == 3 {
			return match[1] + "/" + match[2]
		}
	}
	return ""
}

func renderJobWatch(out io.Writer, job api.JobDetail) {
	fmt.Fprintf(out, "JOB-%d · %s     %s\n", job.Job.ID, job.Job.Title, job.Repository.Slug)
	fmt.Fprintln(out, "──────────────────────────────────────────")
	workflows := job.Workflows
	if len(workflows) == 0 && job.Job.Workflow != nil {
		workflows = []api.WorkflowBrief{*job.Job.Workflow}
	}
	if len(workflows) == 0 {
		fmt.Fprintln(out, "No workflow steps yet.")
		return
	}
	for _, step := range workflows[0].Steps {
		mark := " "
		status := step.State
		if step.State == "succeeded" {
			mark = "✓"
		} else if step.State == "running" || step.RunState == "running" {
			mark = "●"
			status = "running"
		}
		fmt.Fprintf(out, "%s %-18s %s\n", mark, step.DisplayName, status)
	}
}

func page(cmd *cobra.Command, text string) error {
	pager := strings.TrimSpace(os.Getenv("PAGER"))
	if pager == "" {
		fmt.Fprint(cmd.OutOrStdout(), text)
		if !strings.HasSuffix(text, "\n") {
			fmt.Fprintln(cmd.OutOrStdout())
		}
		return nil
	}
	parts := strings.Fields(pager)
	process := exec.Command(parts[0], parts[1:]...)
	process.Stdin = strings.NewReader(text)
	process.Stdout = cmd.OutOrStdout()
	process.Stderr = cmd.ErrOrStderr()
	return process.Run()
}

func prText(job api.JobItem) string {
	if job.PRNumber == 0 {
		return ""
	}
	return fmt.Sprintf("#%d", job.PRNumber)
}

func inspectColorState(state string) string {
	switch state {
	case "running", "open", "in_progress":
		return "\033[34m" + state + "\033[0m"
	case "failed", "cancelled":
		return "\033[31m" + state + "\033[0m"
	case "succeeded", "closed", "done":
		return "\033[32m" + state + "\033[0m"
	default:
		return state
	}
}

func truncate(value string, width int) string {
	if len(value) <= width {
		return value
	}
	if width <= 1 {
		return value[:width]
	}
	return value[:width-1] + "…"
}

func last4(value string) string {
	if len(value) <= 4 {
		return value
	}
	return value[len(value)-4:]
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
