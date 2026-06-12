package cmd

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
	"github.com/tkadauke/syrus/cli/internal/config"
)

type gitRunner func(ctx context.Context, dir string, args ...string) (string, error)

var checkoutRunGit gitRunner = runGit

func NewCheckoutCommand() *cobra.Command {
	return &cobra.Command{
		Use:           "checkout JOB-ID",
		Short:         "Check out a Syrus Job branch",
		Args:          cobra.ExactArgs(1),
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			jobRef, jobID, err := parseJobRef(args[0])
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
			job, err := client.GetJobDetail(cmd.Context(), jobID)
			if err != nil {
				return err
			}
			if strings.TrimSpace(job.Job.BranchName) == "" {
				return fmt.Errorf("Job %s does not have a branch yet (state: %s)", jobRef, job.Job.State)
			}
			if strings.TrimSpace(job.Repository.Slug) == "" {
				return fmt.Errorf("Job %s response did not include a repository slug", jobRef)
			}

			if err := checkoutJobBranch(cmd.Context(), checkoutRunGit, job.Repository.Slug, job.Job.BranchName); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Checked out %s — run 'syrus test-plan %s' to see the test plan.\n", job.Job.BranchName, jobRef)
			return nil
		},
	}
}

func parseJobRef(input string) (string, string, error) {
	ref := strings.TrimSpace(input)
	if ref == "" {
		return "", "", errors.New("job id is required")
	}
	upper := strings.ToUpper(ref)
	if strings.HasPrefix(upper, "JOB-") {
		id := strings.TrimSpace(ref[4:])
		if id == "" {
			return "", "", fmt.Errorf("invalid job id %q", input)
		}
		return "JOB-" + id, id, nil
	}
	return "JOB-" + ref, ref, nil
}

func checkoutJobBranch(ctx context.Context, runner gitRunner, repoSlug string, branchName string) error {
	inside, err := runner(ctx, "", "rev-parse", "--is-inside-work-tree")
	if err != nil || strings.TrimSpace(inside) != "true" {
		return errors.New("Current directory is not a git repository.")
	}

	remoteURL, err := runner(ctx, "", "remote", "get-url", "origin")
	if err != nil {
		return fmt.Errorf("Could not read git remote origin: %w", err)
	}
	remoteURL = strings.TrimSpace(remoteURL)
	if !remoteMatchesSlug(remoteURL, repoSlug) {
		return fmt.Errorf("Current git remote origin (%s) does not match job repository %s.", remoteURL, repoSlug)
	}

	fetchArgs := []string{"fetch", "origin", branchName + ":" + branchName}
	currentBranch, err := runner(ctx, "", "branch", "--show-current")
	if err == nil && strings.TrimSpace(currentBranch) == branchName {
		fetchArgs = []string{"fetch", "origin", branchName}
	}

	if _, err := runner(ctx, "", fetchArgs...); err != nil {
		return fmt.Errorf("git fetch failed: %w", err)
	}
	if _, err := runner(ctx, "", "checkout", branchName); err != nil {
		return fmt.Errorf("git checkout failed: %w", err)
	}
	return nil
}

func runGit(ctx context.Context, dir string, args ...string) (string, error) {
	command := exec.CommandContext(ctx, "git", args...)
	command.Dir = dir
	output, err := command.CombinedOutput()
	if err != nil {
		message := strings.TrimSpace(string(output))
		if message != "" {
			return string(output), fmt.Errorf("%w: %s", err, message)
		}
		return string(output), err
	}
	return string(output), nil
}

func remoteMatchesSlug(remoteURL string, repoSlug string) bool {
	return strings.EqualFold(normalizeGitRemote(remoteURL), strings.TrimSuffix(repoSlug, ".git"))
}

func normalizeGitRemote(remoteURL string) string {
	value := strings.TrimSpace(remoteURL)
	value = strings.TrimSuffix(value, ".git")

	for _, prefix := range []string{
		"https://github.com/",
		"http://github.com/",
		"ssh://git@github.com/",
		"git://github.com/",
	} {
		if strings.HasPrefix(value, prefix) {
			return strings.TrimPrefix(value, prefix)
		}
	}

	if strings.HasPrefix(value, "git@github.com:") {
		return strings.TrimPrefix(value, "git@github.com:")
	}

	return value
}
