package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/spf13/cobra"
)

var statusRunGit gitRunner = runGit
var statusBranchPatterns = []*regexp.Regexp{
	regexp.MustCompile(`^syrus/direct-([0-9]+)$`),
	regexp.MustCompile(`^syrus/local-([0-9]+)$`),
	regexp.MustCompile(`^syrus/issue-[0-9]+-([0-9]+)$`),
	regexp.MustCompile(`^syrus/scheduled-[0-9]+-([0-9]+)$`),
	regexp.MustCompile(`^syrus/(?:issue|cron|scheduled)-([0-9]+)$`),
}

type localStatusOptions struct {
	json bool
}

type localStatus struct {
	JobID  int    `json:"job_id"`
	Branch string `json:"branch"`
	Behind int    `json:"behind"`
}

func NewStatusCommand() *cobra.Command {
	opts := &localStatusOptions{}
	cmd := &cobra.Command{
		Use:           "status",
		Short:         "Show which Syrus job is checked out here",
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runLocalStatus(cmd.Context(), cmd.OutOrStdout(), opts)
		},
	}
	cmd.Flags().BoolVar(&opts.json, "json", false, "Print status as JSON")
	return cmd
}

func runLocalStatus(ctx context.Context, out io.Writer, opts *localStatusOptions) error {
	wd, err := os.Getwd()
	if err != nil {
		return err
	}
	status, err := localSyrusStatus(ctx, statusRunGit, wd)
	if err != nil {
		return err
	}
	if opts.json {
		encoder := json.NewEncoder(out)
		return encoder.Encode(status)
	}
	renderLocalStatus(out, status)
	return nil
}

func localSyrusStatus(ctx context.Context, runner gitRunner, dir string) (localStatus, error) {
	inside, err := runner(ctx, dir, "rev-parse", "--is-inside-work-tree")
	if err != nil || strings.TrimSpace(inside) != "true" {
		return localStatus{}, errors.New("Current directory is not a git repository.")
	}

	branchOutput, err := runner(ctx, dir, "branch", "--show-current")
	if err != nil {
		return localStatus{}, fmt.Errorf("could not read current git branch: %w", err)
	}
	branch := strings.TrimSpace(branchOutput)
	jobID, ok := statusJobIDFromBranch(branch)
	if !ok {
		return localStatus{}, nil
	}

	remoteRef := "refs/remotes/origin/" + branch
	if _, err := runner(ctx, dir, "fetch", "origin", "+refs/heads/"+branch+":"+remoteRef); err != nil {
		return localStatus{}, fmt.Errorf("git fetch failed: %w", err)
	}
	behindOutput, err := runner(ctx, dir, "rev-list", "--count", "HEAD.."+remoteRef)
	if err != nil {
		return localStatus{}, fmt.Errorf("git rev-list failed: %w", err)
	}
	behind, err := strconv.Atoi(strings.TrimSpace(behindOutput))
	if err != nil {
		return localStatus{}, fmt.Errorf("could not parse git behind count %q: %w", strings.TrimSpace(behindOutput), err)
	}

	return localStatus{JobID: jobID, Branch: branch, Behind: behind}, nil
}

func statusJobIDFromBranch(branch string) (int, bool) {
	for _, pattern := range statusBranchPatterns {
		matches := pattern.FindStringSubmatch(branch)
		if matches == nil {
			continue
		}
		id, err := strconv.Atoi(matches[1])
		if err != nil {
			return 0, false
		}
		return id, true
	}
	return 0, false
}

func renderLocalStatus(out io.Writer, status localStatus) {
	if status.JobID == 0 || status.Branch == "" {
		fmt.Fprintln(out, "Not on a Syrus job branch.")
		return
	}
	if status.Behind == 0 {
		fmt.Fprintf(out, "JOB-%d (%s) — up to date\n", status.JobID, status.Branch)
		return
	}
	fmt.Fprintf(out, "JOB-%d (%s) — ⚠ %d commit(s) behind remote\n", status.JobID, status.Branch, status.Behind)
}
