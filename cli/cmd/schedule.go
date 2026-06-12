package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
	"github.com/tkadauke/syrus/cli/internal/config"
)

var detectCurrentRepoSlug = currentRepoSlug

func NewScheduleCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "schedule", Short: "Manage Syrus schedules"}
	cmd.AddCommand(newScheduleListCommand(), newScheduleCreateCommand(), newScheduleShowCommand(), newScheduleDeleteCommand(), newScheduleRunCommand())
	return cmd
}

func newScheduleListCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List schedules",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := apiClient()
			if err != nil {
				return err
			}
			list, err := client.ListScheduledTasks(cmd.Context())
			if err != nil {
				return err
			}
			tasks := tasksForCurrentRepo(list.ActiveTasks)
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "ID\tLABEL\tCRON\tNEXT RUN\tREPO")
			for _, task := range tasks {
				fmt.Fprintf(tw, "%d\t%s\t%s\t%s\t%s\n", task.ID, task.Name, valueOrDash(task.CronExpression), valueOrDash(task.NextFireAt), task.Repository.Slug)
			}
			return tw.Flush()
		},
	}
}

func newScheduleCreateCommand() *cobra.Command {
	var yes bool
	cmd := &cobra.Command{
		Use:   "create",
		Short: "Create a schedule in the current repository",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runScheduleCreate(cmd, yes)
		},
	}
	cmd.Flags().BoolVar(&yes, "yes", false, "create without prompting for confirmation")
	return cmd
}

func newScheduleShowCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "show ID",
		Short: "Show a schedule",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := apiClient()
			if err != nil {
				return err
			}
			payload, err := client.GetScheduledTask(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			task := payload.Task
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "Schedule #%d: %s\n", task.ID, task.Name)
			fmt.Fprintf(out, "State: %s\nRepository: %s\n", task.State, task.Repository.Slug)
			fmt.Fprintf(out, "Cron: %s\nNext run: %s\n", valueOrDash(task.CronExpression), valueOrDash(task.NextFireAt))
			fmt.Fprintf(out, "Pileup policy: %s\nAuto approve: %s\n\n", valueOrDash(task.PrPileupPolicy), valueOrDash(task.AutoApproveMode))
			fmt.Fprintln(out, "Prompt:")
			for _, line := range strings.Split(task.Prompt, "\n") {
				fmt.Fprintf(out, "  %s\n", line)
			}
			fmt.Fprintln(out, "\nRecent jobs:")
			if len(payload.RecentJobs) == 0 {
				fmt.Fprintln(out, "  none")
				return nil
			}
			for i, job := range payload.RecentJobs {
				if i >= 5 {
					break
				}
				fmt.Fprintf(out, "  #%d %s\n", job.ID, job.State)
			}
			return nil
		},
	}
}

func newScheduleDeleteCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "delete ID",
		Short: "Delete a schedule",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := apiClient()
			if err != nil {
				return err
			}
			payload, err := client.GetScheduledTask(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			reader := bufio.NewReader(cmd.InOrStdin())
			answer, err := prompt(reader, cmd.OutOrStdout(), fmt.Sprintf("Delete schedule '%s'? [y/N] ", payload.Task.Name))
			if err != nil {
				return err
			}
			if !confirmed(answer) {
				fmt.Fprintln(cmd.OutOrStdout(), "Cancelled.")
				return nil
			}
			if err := client.DeleteScheduledTask(cmd.Context(), args[0]); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Deleted schedule #%s\n", args[0])
			return nil
		},
	}
}

func newScheduleRunCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "run ID",
		Short: "Run a schedule now",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := apiClient()
			if err != nil {
				return err
			}
			payload, err := client.FireScheduledTask(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			if payload.FireResult.JobID == 0 {
				if payload.Message != "" {
					return errors.New(payload.Message)
				}
				return errors.New("schedule run did not create a job")
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Created job #%d\n", payload.FireResult.JobID)
			return nil
		},
	}
}

func runScheduleCreate(cmd *cobra.Command, yes bool) error {
	repo := detectCurrentRepoSlug()
	if repo == "" {
		return errors.New("syrus schedule create requires a GitHub repository checkout")
	}
	client, err := apiClient()
	if err != nil {
		return err
	}
	repositories, err := client.ListRepositories(cmd.Context())
	if err != nil {
		return err
	}
	repositoryID, ok := repositoryIDForSlug(repositories.AvailableRepositories(), repo)
	if !ok {
		return fmt.Errorf("repository %s is not configured in Syrus", repo)
	}

	reader := bufio.NewReader(cmd.InOrStdin())
	name, err := prompt(reader, cmd.OutOrStdout(), "Label: ")
	if err != nil {
		return err
	}
	cron, err := prompt(reader, cmd.OutOrStdout(), `Cron expression (e.g. 0 9 * * 1 = every Monday at 9am UTC): `)
	if err != nil {
		return err
	}
	fmt.Fprintln(cmd.OutOrStdout(), "Prompt (blank line to finish):")
	body, err := readMultiline(reader)
	if err != nil {
		return err
	}
	params := api.CreateScheduleParams{
		Name:           strings.TrimSpace(name),
		Kind:           "cron",
		CronExpression: strings.TrimSpace(cron),
		PrPileupPolicy: "skip",
		Prompt:         body,
	}
	if params.Name == "" {
		return errors.New("label is required")
	}
	if params.CronExpression == "" {
		return errors.New("cron expression is required")
	}
	if strings.TrimSpace(params.Prompt) == "" {
		return errors.New("prompt is required")
	}
	if !yes {
		answer, err := prompt(reader, cmd.OutOrStdout(), fmt.Sprintf("Create schedule '%s' for %s? [y/N] ", params.Name, repo))
		if err != nil {
			return err
		}
		if !confirmed(answer) {
			fmt.Fprintln(cmd.OutOrStdout(), "Cancelled.")
			return nil
		}
	}

	created, err := client.CreateScheduledTask(cmd.Context(), repositoryID, params)
	if err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Created schedule #%d\n", created.Task.ID)
	return nil
}

func apiClient() (*api.Client, error) {
	creds, err := loadCredentials()
	if err != nil {
		return nil, err
	}
	return api.NewClient(creds.URL, creds.Token)
}

func loadCredentials() (config.Credentials, error) {
	creds, err := config.LoadDefaultCredentials()
	if err != nil {
		if errors.Is(err, config.ErrMissingCredentials) || errors.Is(err, config.ErrIncompleteCredentials) {
			return config.Credentials{}, errors.New(loginMessage)
		}
		return config.Credentials{}, err
	}
	return creds, nil
}

func tasksForCurrentRepo(tasks []api.ScheduledTask) []api.ScheduledTask {
	repo := detectCurrentRepoSlug()
	if repo == "" {
		return tasks
	}
	var scoped []api.ScheduledTask
	for _, task := range tasks {
		if task.Repository.Slug == repo {
			scoped = append(scoped, task)
		}
	}
	if len(scoped) == 0 {
		return tasks
	}
	return scoped
}

func repositoryIDForSlug(repositories []api.Repository, slug string) (int64, bool) {
	for _, repository := range repositories {
		if repository.Slug == slug {
			return repository.ID, true
		}
	}
	return 0, false
}

func readMultiline(reader *bufio.Reader) (string, error) {
	var lines []string
	for {
		line, err := reader.ReadString('\n')
		if err != nil && err != io.EOF {
			return "", err
		}
		line = strings.TrimSuffix(line, "\n")
		line = strings.TrimSuffix(line, "\r")
		if line == "" {
			return strings.Join(lines, "\n"), nil
		}
		lines = append(lines, line)
		if err == io.EOF {
			return strings.Join(lines, "\n"), nil
		}
	}
}

func confirmed(answer string) bool {
	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y", "yes":
		return true
	default:
		return false
	}
}

func valueOrDash(value string) string {
	if strings.TrimSpace(value) == "" {
		return "-"
	}
	return value
}

func currentRepoSlug() string {
	out, err := exec.CommandContext(context.Background(), "git", "config", "--get", "remote.origin.url").Output()
	if err != nil {
		return ""
	}
	return parseGitHubSlug(strings.TrimSpace(string(out)))
}

func parseGitHubSlug(remote string) string {
	pattern := regexp.MustCompile(`github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$`)
	match := pattern.FindStringSubmatch(remote)
	if len(match) == 3 {
		return match[1] + "/" + match[2]
	}
	return ""
}
