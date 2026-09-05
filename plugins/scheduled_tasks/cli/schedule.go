package scheduledtasks

import (
	"bufio"
	"errors"
	"fmt"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

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
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			list, err := ListScheduledTasks(cmd.Context(), client)
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
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			payload, err := GetScheduledTask(cmd.Context(), client, args[0])
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
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			payload, err := GetScheduledTask(cmd.Context(), client, args[0])
			if err != nil {
				return err
			}
			reader := bufio.NewReader(cmd.InOrStdin())
			answer, err := cliplugin.Prompt(reader, cmd.OutOrStdout(), fmt.Sprintf("Delete schedule '%s'? [y/N] ", payload.Task.Name))
			if err != nil {
				return err
			}
			if !cliplugin.Confirmed(answer) {
				fmt.Fprintln(cmd.OutOrStdout(), "Cancelled.")
				return nil
			}
			if err := DeleteScheduledTask(cmd.Context(), client, args[0]); err != nil {
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
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			payload, err := FireScheduledTask(cmd.Context(), client, args[0])
			if err != nil {
				return err
			}
			if payload.FireResult.JobID == 0 {
				if payload.Message != "" {
					return errors.New(payload.Message)
				}
				return errors.New("schedule run did not create a job")
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Created %s\n", cliplugin.JobSlug(payload.FireResult.JobID))
			return nil
		},
	}
}

func runScheduleCreate(cmd *cobra.Command, yes bool) error {
	repo := cliplugin.DetectCurrentRepoSlug()
	if repo == "" {
		return errors.New("syrus schedule create requires a GitHub repository checkout")
	}
	client, err := cliplugin.Client()
	if err != nil {
		return err
	}
	repositories, err := client.ListRepositories(cmd.Context())
	if err != nil {
		return err
	}
	repositoryID, ok := cliplugin.RepositoryIDForSlug(repositories.AvailableRepositories(), repo)
	if !ok {
		return fmt.Errorf("repository %s is not configured in Syrus", repo)
	}

	reader := bufio.NewReader(cmd.InOrStdin())
	name, err := cliplugin.Prompt(reader, cmd.OutOrStdout(), "Label: ")
	if err != nil {
		return err
	}
	cron, err := cliplugin.Prompt(reader, cmd.OutOrStdout(), `Cron expression (e.g. 0 9 * * 1 = every Monday at 9am UTC): `)
	if err != nil {
		return err
	}
	fmt.Fprintln(cmd.OutOrStdout(), "Prompt (blank line to finish):")
	body, err := cliplugin.ReadMultiline(reader)
	if err != nil {
		return err
	}
	params := CreateScheduleParams{
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
		answer, err := cliplugin.Prompt(reader, cmd.OutOrStdout(), fmt.Sprintf("Create schedule '%s' for %s? [y/N] ", params.Name, repo))
		if err != nil {
			return err
		}
		if !cliplugin.Confirmed(answer) {
			fmt.Fprintln(cmd.OutOrStdout(), "Cancelled.")
			return nil
		}
	}

	created, err := CreateScheduledTask(cmd.Context(), client, repositoryID, params)
	if err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Created schedule #%d\n", created.Task.ID)
	return nil
}

func tasksForCurrentRepo(tasks []ScheduledTask) []ScheduledTask {
	repo := cliplugin.DetectCurrentRepoSlug()
	if repo == "" {
		return tasks
	}
	var scoped []ScheduledTask
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

func valueOrDash(value string) string {
	if strings.TrimSpace(value) == "" {
		return "-"
	}
	return value
}
