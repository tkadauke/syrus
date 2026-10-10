package cmd

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/api"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

var openBrowser = defaultOpenBrowser

// jobCreatePriorities mirrors Job::PRIORITIES in app/models/job.rb.
var jobCreatePriorities = []string{"urgent", "high", "medium", "low"}

func newJobCreateCommand() *cobra.Command {
	var repo string
	var yes bool
	var priority string
	var agent string
	var epic string
	var owner string
	var title string
	var body string
	var bodyFile string
	var dependsOn []string
	cmd := &cobra.Command{
		Use:   "create",
		Short: "Create a direct Syrus job",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runJobCreate(cmd, jobCreateOptions{
				repo:      repo,
				yes:       yes,
				priority:  priority,
				agent:     agent,
				epic:      epic,
				owner:     owner,
				title:     title,
				body:      body,
				bodyFile:  bodyFile,
				dependsOn: dependsOn,
			})
		},
	}
	cmd.Flags().StringVar(&repo, "repo", "", "repository slug, e.g. owner/name")
	cmd.Flags().BoolVar(&yes, "yes", false, "create without confirmation")
	cmd.Flags().StringVar(&priority, "priority", "", "priority: urgent, high, medium, or low (default: medium)")
	cmd.Flags().StringVar(&agent, "agent", "", "agent provider slug, e.g. claude or codex")
	cmd.Flags().StringVar(&epic, "epic", "", "attach to an epic, e.g. EPIC-42 or a slug")
	cmd.Flags().StringVar(&owner, "owner", "", "assign a repository member as owner, by user ID")
	cmd.Flags().StringVar(&title, "title", "", "job title")
	cmd.Flags().StringVar(&body, "body", "", "job description")
	cmd.Flags().StringVar(&body, "prompt", "", "job description")
	cmd.Flags().StringVar(&bodyFile, "body-file", "", "read the job description from a file")
	cmd.Flags().StringVar(&bodyFile, "file", "", "read the job description from a file, or '-' for stdin")
	cmd.Flags().StringArrayVar(&dependsOn, "depends-on", nil, "existing dependency, repeatable; accepts JOB-123 or a proposal slug")
	return cmd
}

type jobCreateOptions struct {
	repo      string
	yes       bool
	priority  string
	agent     string
	epic      string
	owner     string
	title     string
	body      string
	bodyFile  string
	dependsOn []string
}

type jobActionSpec struct {
	name    string
	action  string
	short   string
	message string
}

func newJobActionCommand(spec jobActionSpec) *cobra.Command {
	return &cobra.Command{
		Use:   spec.name + " JOB-ID",
		Short: spec.short,
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			if err := client.RunJobAction(cmd.Context(), args[0], spec.action); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s %s.\n", jobSlug(args[0]), strings.TrimSuffix(strings.ToLower(spec.message), "."))
			return nil
		},
	}
}

func newJobResumeCommand() *cobra.Command {
	var sourceRunID string
	cmd := &cobra.Command{
		Use:   "resume JOB-ID --source-run RUN-ID",
		Short: "Resume a job from a source run",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sourceRunID = strings.TrimSpace(sourceRunID)
			if sourceRunID == "" {
				return errors.New("--source-run is required")
			}
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			if err := client.RunJobActionWithPayload(cmd.Context(), args[0], "resume", map[string]string{"source_run_id": sourceRunID}); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s resume enqueued.\n", jobSlug(args[0]))
			return nil
		},
	}
	cmd.Flags().StringVar(&sourceRunID, "source-run", "", "source run ID to resume from")
	return cmd
}

func newJobWorkflowActionCommand(name string, action string, short string, message string) *cobra.Command {
	var workflowID string
	cmd := &cobra.Command{
		Use:   name + " JOB-ID --workflow WORKFLOW-ID",
		Short: short,
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			workflowID = strings.TrimSpace(workflowID)
			if workflowID == "" {
				return errors.New("--workflow is required")
			}
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			if err := client.RunJobWorkflowAction(cmd.Context(), args[0], workflowID, action); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s %s.\n", jobSlug(args[0]), strings.TrimSuffix(strings.ToLower(message), "."))
			return nil
		},
	}
	cmd.Flags().StringVar(&workflowID, "workflow", "", "workflow ID")
	return cmd
}

func newJobRunActionCommand(name string, action string, short string, message string) *cobra.Command {
	var runID string
	cmd := &cobra.Command{
		Use:   name + " JOB-ID --run RUN-ID",
		Short: short,
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			runID = strings.TrimSpace(runID)
			if runID == "" {
				return errors.New("--run is required")
			}
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			if err := client.RunJobRunAction(cmd.Context(), args[0], runID, action); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s %s.\n", jobSlug(args[0]), strings.TrimSuffix(strings.ToLower(message), "."))
			return nil
		},
	}
	cmd.Flags().StringVar(&runID, "run", "", "run ID")
	return cmd
}

func newJobCheckoutCommand() *cobra.Command {
	var noHooks bool
	cmd := &cobra.Command{
		Use:   "checkout JOB-ID",
		Short: "Check out a job branch locally",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runJobCheckout(cmd, args[0], noHooks)
		},
	}
	cmd.Flags().BoolVar(&noHooks, "no-hooks", false, "skip .syrus.yml hooks.post_checkout commands")
	return cmd
}

func newJobTestPlanCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "test-plan JOB-ID",
		Short: "Show a job test plan",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runTestPlan(cmd.Context(), args[0], cmd.OutOrStdout())
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

func runJobCreate(cmd *cobra.Command, opts jobCreateOptions) error {
	repo := strings.TrimSpace(opts.repo)
	if repo == "" {
		repo = cliplugin.DetectCurrentRepoSlug()
	}
	if repo == "" {
		return errors.New("run from a GitHub checkout or pass --repo owner/name")
	}

	priority := strings.TrimSpace(opts.priority)
	if priority != "" && !slices.Contains(jobCreatePriorities, priority) {
		return fmt.Errorf("invalid --priority %q: must be one of %s", priority, strings.Join(jobCreatePriorities, ", "))
	}

	var ownerUserID int64
	owner := strings.TrimSpace(opts.owner)
	if owner != "" {
		parsed, err := strconv.ParseInt(owner, 10, 64)
		if err != nil {
			return fmt.Errorf("invalid --owner %q: must be a numeric user ID", owner)
		}
		ownerUserID = parsed
	}

	client, _, err := apiClient()
	if err != nil {
		return err
	}
	repositories, err := client.ListRepositories(cmd.Context())
	if err != nil {
		return err
	}
	repositoryID, ok := repositoryIDForSlug(repositories.AvailableRepositories(), repo)
	if !ok {
		return fmt.Errorf("repository %s is not configured for this Syrus account", repo)
	}

	var epicID int64
	epic := strings.TrimSpace(opts.epic)
	if epic != "" {
		_, ref, err := parseEpicRef(epic)
		if err != nil {
			return err
		}
		resolved, err := client.GetEpic(cmd.Context(), ref)
		if err != nil {
			return fmt.Errorf("could not resolve epic %s: %w", epic, err)
		}
		epicID = resolved.Epic.ID
	}

	reader := bufio.NewReader(cmd.InOrStdin())
	title, description, err := jobCreateText(reader, cmd.OutOrStdout(), opts.title, opts.body, opts.bodyFile)
	if err != nil {
		return err
	}
	if title == "" {
		return errors.New("title cannot be blank")
	}
	if description == "" {
		return errors.New("description cannot be blank")
	}
	if !opts.yes {
		ok, err := confirm(reader, cmd.OutOrStdout(), fmt.Sprintf("Create job in %s? [y/N] ", repo))
		if err != nil {
			return err
		}
		if !ok {
			fmt.Fprintln(cmd.OutOrStdout(), "Cancelled.")
			return nil
		}
	}

	dependsOnJobIDs, dependsOnSlugs, err := parseJobCreateDependencies(opts.dependsOn)
	if err != nil {
		return err
	}

	job, err := client.CreateDirectJob(cmd.Context(), api.CreateJobParams{
		RepositoryID:    repositoryID,
		Title:           title,
		Prompt:          description,
		Priority:        priority,
		AgentProvider:   strings.TrimSpace(opts.agent),
		EpicID:          epicID,
		OwnerUserID:     ownerUserID,
		DependsOn:       dependsOnSlugs,
		DependsOnJobIDs: dependsOnJobIDs,
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "%s\n", jobSlug(job.Job.ID))
	return nil
}

func jobCreateText(reader *bufio.Reader, out io.Writer, titleFlag string, bodyFlag string, bodyFile string) (string, string, error) {
	title := strings.TrimSpace(titleFlag)
	body := bodyFlag
	bodyFile = strings.TrimSpace(bodyFile)
	if body != "" && bodyFile != "" {
		return "", "", errors.New("--body and --body-file cannot be used together")
	}
	if bodyFile != "" {
		content, err := readBodyFile(reader, bodyFile)
		if err != nil {
			return "", "", err
		}
		body = string(content)
	}
	if title != "" && body != "" {
		return title, strings.TrimSpace(body), nil
	}
	promptedTitle, promptedBody, err := promptJob(reader, out)
	if err != nil {
		return "", "", err
	}
	if title == "" {
		title = promptedTitle
	}
	if body == "" {
		body = promptedBody
	}
	return strings.TrimSpace(title), strings.TrimSpace(body), nil
}

func readBodyFile(reader *bufio.Reader, path string) ([]byte, error) {
	if path == "-" {
		content, err := io.ReadAll(reader)
		if err != nil {
			return nil, fmt.Errorf("read --file -: %w", err)
		}
		return content, nil
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read --file: %w", err)
	}
	return content, nil
}

func parseJobCreateDependencies(tokens []string) ([]int64, []string, error) {
	var jobIDs []int64
	var slugs []string
	seenJobIDs := map[int64]bool{}
	seenSlugs := map[string]bool{}
	for _, raw := range tokens {
		token := strings.TrimSpace(raw)
		if token == "" {
			continue
		}
		if strings.HasPrefix(strings.ToUpper(token), "JOB-") || isNumericRef(token) {
			_, idText, err := parseJobRef(token)
			if err != nil {
				return nil, nil, fmt.Errorf("invalid --depends-on %q: expected JOB-123 or a proposal slug", token)
			}
			id, parseErr := strconv.ParseInt(idText, 10, 64)
			if parseErr != nil {
				return nil, nil, fmt.Errorf("invalid --depends-on %q: %w", token, parseErr)
			}
			if !seenJobIDs[id] {
				jobIDs = append(jobIDs, id)
				seenJobIDs[id] = true
			}
			continue
		}
		if !seenSlugs[token] {
			slugs = append(slugs, token)
			seenSlugs[token] = true
		}
	}
	return jobIDs, slugs, nil
}

func isNumericRef(token string) bool {
	if token == "" {
		return false
	}
	for _, r := range token {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
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

func runJobCheckout(cmd *cobra.Command, id string, noHooks bool) error {
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
		return fmt.Errorf("%s has no branch yet", jobSlug(id))
	}
	repo := job.Repository.Slug
	if repo == "" {
		repo = job.Job.RepositorySlug
	}
	current := cliplugin.DetectCurrentRepoSlug()
	if current == "" {
		return errors.New("run from the matching GitHub checkout")
	}
	if current != repo {
		return fmt.Errorf("current checkout is %s, but %s belongs to %s", current, jobSlug(id), repo)
	}
	if err := checkoutJobBranch(cmd.Context(), checkoutRunGit, repo, branch); err != nil {
		return err
	}
	if !noHooks {
		hookOptions := postCheckoutHookOptions{
			baseBranch:    job.Job.EffectiveBaseBranch,
			defaultBranch: job.Repository.DefaultBranch,
			headRef:       "HEAD",
		}
		if err := runPostCheckoutHooks(cmd.Context(), checkoutRunGit, checkoutRunHookCommand, cmd.OutOrStdout(), cmd.ErrOrStderr(), hookOptions); err != nil {
			return err
		}
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Checked out %s. Run: syrus job test-plan %s\n", branch, id)
	return nil
}

func jobSlug(id any) string { return cliplugin.JobSlug(id) }

func epicSlug(number any) string {
	return fmt.Sprintf("EPIC-%v", number)
}

func epicRef(epic api.EpicItem) string {
	if epic.Number != 0 {
		return epicSlug(epic.Number)
	}
	return epicSlug(epic.ID)
}

// displayJobRef formats a job identifier for user-facing output. Numeric IDs
// are shown with the JOB- prefix; slugs are shown as-is.
func displayJobRef(ref string) string {
	return displayRef(ref, "JOB-")
}
