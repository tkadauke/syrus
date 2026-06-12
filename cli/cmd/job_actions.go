package cmd

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"runtime"
	"sort"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
)

var openBrowser = defaultOpenBrowser

func newJobCreateCommand() *cobra.Command {
	var repo string
	var yes bool
	cmd := &cobra.Command{
		Use:   "create",
		Short: "Create a direct Syrus job",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runJobCreate(cmd, repo, yes)
		},
	}
	cmd.Flags().StringVar(&repo, "repo", "", "repository slug, e.g. owner/name")
	cmd.Flags().BoolVar(&yes, "yes", false, "create without confirmation")
	return cmd
}

func newJobActionCommand(name string, action string, message string) *cobra.Command {
	return &cobra.Command{
		Use:   name + " JOB-ID",
		Short: message,
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			if err := client.RunJobAction(cmd.Context(), args[0], action); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Job #%s %s.\n", args[0], strings.TrimSuffix(strings.ToLower(message), "."))
			return nil
		},
	}
}

func newJobCheckoutCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "checkout JOB-ID",
		Short: "Check out a job branch locally",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runJobCheckout(cmd, args[0])
		},
	}
}

func newJobTestPlanCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "test-plan JOB-ID",
		Short: "Show a job test plan",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			job, err := client.GetAdminJob(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			plan, ok := latestTestPlan(job.Workflows)
			if !ok {
				fmt.Fprintln(cmd.OutOrStdout(), "No test plan yet — the job may still be implementing.")
				return nil
			}
			renderTestPlan(cmd.OutOrStdout(), plan)
			return nil
		},
	}
}

func newJobOpenCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "open JOB-ID",
		Short: "Open a job in the browser",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			_, creds, err := apiClient()
			if err != nil {
				return err
			}
			target := strings.TrimRight(creds.URL, "/") + "/jobs/" + args[0]
			if err := openBrowser(target); err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), target)
			return nil
		},
	}
}

func runJobCreate(cmd *cobra.Command, repo string, yes bool) error {
	repo = strings.TrimSpace(repo)
	if repo == "" {
		repo = currentRepoSlug()
	}
	if repo == "" {
		return errors.New("run from a GitHub checkout or pass --repo owner/name")
	}

	reader := bufio.NewReader(cmd.InOrStdin())
	title, description, err := promptJob(reader, cmd.OutOrStdout())
	if err != nil {
		return err
	}
	if title == "" {
		return errors.New("title cannot be blank")
	}
	if description == "" {
		return errors.New("description cannot be blank")
	}
	if !yes {
		ok, err := confirm(reader, cmd.OutOrStdout(), fmt.Sprintf("Create job in %s? [y/N] ", repo))
		if err != nil {
			return err
		}
		if !ok {
			fmt.Fprintln(cmd.OutOrStdout(), "Cancelled.")
			return nil
		}
	}

	client, _, err := apiClient()
	if err != nil {
		return err
	}
	repositoryID, err := repositoryIDForSlug(cmd, client, repo)
	if err != nil {
		return err
	}
	job, err := client.CreateDirectJob(cmd.Context(), api.CreateJobParams{
		RepositoryID: repositoryID,
		Title:        title,
		Prompt:       description,
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Job #%d created. Track with: syrus job watch %d\n", job.Job.ID, job.Job.ID)
	return nil
}

func promptJob(reader *bufio.Reader, out io.Writer) (string, string, error) {
	fmt.Fprint(out, "Title: ")
	title, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		return "", "", err
	}
	fmt.Fprintln(out, "Description (blank line to finish):")
	var lines []string
	for {
		line, readErr := reader.ReadString('\n')
		if readErr != nil && readErr != io.EOF {
			return "", "", readErr
		}
		trimmed := strings.TrimRight(line, "\r\n")
		if trimmed == "" {
			break
		}
		lines = append(lines, trimmed)
		if readErr == io.EOF {
			break
		}
	}
	return strings.TrimSpace(title), strings.TrimSpace(strings.Join(lines, "\n")), nil
}

func confirm(reader *bufio.Reader, out io.Writer, label string) (bool, error) {
	fmt.Fprint(out, label)
	answer, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		return false, err
	}
	answer = strings.TrimSpace(strings.ToLower(answer))
	return answer == "y" || answer == "yes", nil
}

func repositoryIDForSlug(cmd *cobra.Command, client *api.Client, slug string) (int64, error) {
	repos, err := client.ListRepositories(cmd.Context())
	if err != nil {
		return 0, err
	}
	for _, repo := range repos.Repositories {
		if repo.Slug == slug {
			return repo.ID, nil
		}
	}
	return 0, fmt.Errorf("repository %s is not configured for this Syrus account", slug)
}

func runJobCheckout(cmd *cobra.Command, id string) error {
	client, _, err := apiClient()
	if err != nil {
		return err
	}
	job, err := client.GetJobDetail(cmd.Context(), id)
	if err != nil {
		return err
	}
	branch := job.Job.BranchName
	if branch == "" {
		return fmt.Errorf("Job #%s has no branch yet", id)
	}
	repo := job.Repository.Slug
	if repo == "" {
		repo = job.Job.RepositorySlug
	}
	current := currentRepoSlug()
	if current == "" {
		return errors.New("run from the matching GitHub checkout")
	}
	if current != repo {
		return fmt.Errorf("current checkout is %s, but Job #%s belongs to %s", current, id, repo)
	}
	if err := runGit("fetch", "origin", branch+":"+branch); err != nil {
		return err
	}
	if err := runGit("checkout", branch); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Checked out %s. Run: syrus job test-plan %s\n", branch, id)
	return nil
}

func runGit(args ...string) error {
	command := exec.Command("git", args...)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("git %s failed: %s", strings.Join(args, " "), strings.TrimSpace(string(output)))
	}
	return nil
}

func latestTestPlan(workflows []api.AdminWorkflow) (any, bool) {
	sort.SliceStable(workflows, func(i, j int) bool {
		return workflows[i].ID > workflows[j].ID
	})
	for _, workflow := range workflows {
		if workflow.State != "succeeded" && workflow.FinishedAt == "" {
			continue
		}
		if plan, ok := workflow.Artifacts["test_plan"]; ok && plan != nil {
			return plan, true
		}
	}
	return nil, false
}

func renderTestPlan(out io.Writer, plan any) {
	steps := testPlanSteps(plan)
	if len(steps) == 0 {
		fmt.Fprintln(out, "No test plan yet — the job may still be implementing.")
		return
	}
	for i, step := range steps {
		fmt.Fprintf(out, "%d. %s\n", i+1, step.Title)
		if step.Notes != "" {
			fmt.Fprintf(out, "   %s\n", step.Notes)
		}
	}
}

type testPlanStep struct {
	Title string
	Notes string
}

func testPlanSteps(plan any) []testPlanStep {
	switch value := plan.(type) {
	case []any:
		return testPlanStepsFromArray(value)
	case map[string]any:
		for _, key := range []string{"steps", "items", "checks"} {
			if raw, ok := value[key].([]any); ok {
				return testPlanStepsFromArray(raw)
			}
		}
	}
	return nil
}

func testPlanStepsFromArray(items []any) []testPlanStep {
	steps := make([]testPlanStep, 0, len(items))
	for _, item := range items {
		switch value := item.(type) {
		case string:
			steps = append(steps, testPlanStep{Title: value})
		case map[string]any:
			title := firstString(value, "step", "title", "command", "description", "name")
			notes := firstString(value, "notes", "note", "details", "why")
			if title == "" {
				title = fmt.Sprint(value)
			}
			steps = append(steps, testPlanStep{Title: title, Notes: notes})
		default:
			steps = append(steps, testPlanStep{Title: fmt.Sprint(value)})
		}
	}
	return steps
}

func firstString(values map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := values[key]; ok {
			if text := strings.TrimSpace(fmt.Sprint(value)); text != "" {
				return text
			}
		}
	}
	return ""
}

func defaultOpenBrowser(target string) error {
	var command *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		command = exec.Command("open", target)
	case "windows":
		command = exec.Command("cmd", "/c", "start", "", target)
	default:
		command = exec.Command("xdg-open", target)
	}
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("open browser failed: %s", strings.TrimSpace(string(output)))
	}
	return nil
}
