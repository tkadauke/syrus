package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
	"github.com/tkadauke/syrus/cli/internal/config"
)

var jobSlugPattern = regexp.MustCompile(`(?i)^JOB-(\d+)$`)
var jobIDPattern = regexp.MustCompile(`(?i)^(?:JOB-)?(\d+)$`)
var jobBranchPatterns = []*regexp.Regexp{
	regexp.MustCompile(`^syrus/issue-\d+-(\d+)$`),
	regexp.MustCompile(`^syrus/direct-(\d+)$`),
	regexp.MustCompile(`^syrus/scheduled-\d+-(\d+)$`),
	regexp.MustCompile(`^syrus/local-(\d+)$`),
}

type appJobPayload struct {
	Job      appJobRecord      `json:"job"`
	TestPlan *testPlanArtifact `json:"test_plan"`
}

type testPlanArtifact struct {
	Steps []string `json:"steps"`
	Notes string   `json:"notes"`
}

type appJobRecord struct {
	ID         int    `json:"id"`
	IssueTitle string `json:"issue_title"`
}

func NewTestPlanCommand() *cobra.Command {
	return &cobra.Command{
		Use:           "test-plan [JOB-ID]",
		Short:         "Print the latest completed Job test plan",
		Args:          cobra.MaximumNArgs(1),
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runTestPlanCommand(cmd, args)
		},
	}
}

// parseJobID parses a job identifier for the test-plan command. Accepts the
// JOB-<n> format, bare numeric IDs, and human-readable slugs. Numeric IDs
// and the JOB- prefix are normalized; slugs are forwarded as-is to the API.
func parseJobID(slug string) (string, error) {
	trimmed := strings.TrimSpace(slug)
	if trimmed == "" {
		return "", errors.New("job ID is required")
	}
	if matches := jobIDPattern.FindStringSubmatch(trimmed); matches != nil {
		return matches[1], nil
	}
	return trimmed, nil
}

func runTestPlanCommand(cmd *cobra.Command, args []string) error {
	slug := ""
	if len(args) > 0 {
		slug = args[0]
	} else {
		inferred, err := inferJobSlugFromCurrentBranch(cmd.Context(), checkoutRunGit)
		if err != nil {
			return err
		}
		slug = inferred
	}
	return runTestPlan(cmd.Context(), slug, cmd.OutOrStdout())
}

func inferJobSlugFromCurrentBranch(ctx context.Context, runner gitRunner) (string, error) {
	inside, err := runner(ctx, "", "rev-parse", "--is-inside-work-tree")
	if err != nil || strings.TrimSpace(inside) != "true" {
		return "", errors.New("job argument required when not in a git checkout")
	}

	branch, err := runner(ctx, "", "branch", "--show-current")
	if err != nil {
		return "", fmt.Errorf("could not read current git branch: %w", err)
	}
	jobID, ok := jobIDFromBranch(strings.TrimSpace(branch))
	if !ok {
		return "", errors.New("job argument required unless current branch is a Syrus job branch")
	}
	return "JOB-" + jobID, nil
}

func jobIDFromBranch(branch string) (string, bool) {
	for _, pattern := range jobBranchPatterns {
		matches := pattern.FindStringSubmatch(branch)
		if matches != nil {
			return matches[1], true
		}
	}
	return "", false
}

func runTestPlan(ctx context.Context, slug string, stdout io.Writer) error {
	jobID, err := parseJobID(slug)
	if err != nil {
		return err
	}

	creds, err := config.LoadDefaultCredentials()
	if err != nil {
		if errors.Is(err, config.ErrMissingCredentials) || errors.Is(err, config.ErrIncompleteCredentials) {
			return errors.New(loginMessage)
		}
		return err
	}

	client, err := api.NewClient(creds.URL, creds.Token)
	if err != nil {
		return err
	}

	payload, err := fetchAppJob(ctx, client, jobID)
	if err != nil {
		return err
	}

	if payload.TestPlan == nil || len(payload.TestPlan.Steps) == 0 {
		fmt.Fprintf(stdout, "No test plan available for %s yet — the job may still be implementing.\n", displayJobRef(jobID))
		return nil
	}

	printTestPlan(stdout, payload, *payload.TestPlan)
	return nil
}

func fetchAppJob(ctx context.Context, client *api.Client, jobID string) (appJobPayload, error) {
	raw, err := client.GetAppJob(ctx, jobID)
	if err != nil {
		return appJobPayload{}, err
	}

	var payload appJobPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return appJobPayload{}, err
	}

	return payload, nil
}

func printTestPlan(stdout io.Writer, payload appJobPayload, plan testPlanArtifact) {
	fmt.Fprintf(stdout, "Test plan for JOB-%d: %s\n\n", payload.Job.ID, payload.Job.IssueTitle)
	for index, step := range plan.Steps {
		fmt.Fprintf(stdout, "%d. %s\n", index+1, step)
	}

	notes := strings.TrimSpace(plan.Notes)
	if notes == "" {
		return
	}

	fmt.Fprintf(stdout, "\nNotes: %s\n", notes)
}
