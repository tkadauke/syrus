package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
	"go.yaml.in/yaml/v3"
)

type gitRunner func(ctx context.Context, dir string, args ...string) (string, error)
type hookCommandRunner func(ctx context.Context, dir string, command string, stdout io.Writer, stderr io.Writer) error

var checkoutRunGit gitRunner = runGit
var checkoutRunHookCommand hookCommandRunner = runHookCommand
var checkoutBackupTimestamp = func() string {
	return time.Now().UTC().Format("20060102T150405Z")
}
var epicPickerFunc = func(epicRef string, candidates []epicCandidate) (*api.JobItem, error) {
	m := epicPickerModel{epicRef: epicRef, candidates: candidates, width: defaultInboxWidth}
	result, err := tea.NewProgram(m).Run()
	if err != nil {
		return nil, err
	}
	if final, ok := result.(epicPickerModel); ok && final.chosen != nil {
		return final.chosen, nil
	}
	return nil, nil
}

func NewCheckoutCommand() *cobra.Command {
	var noHooks bool
	command := &cobra.Command{
		Use:           "checkout JOB-ID|EPIC-ID",
		Short:         "Check out a Syrus Job branch",
		Args:          cobra.ExactArgs(1),
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			upper := strings.ToUpper(strings.TrimSpace(args[0]))
			if strings.HasPrefix(upper, "EPIC-") {
				return runEpicCheckout(cmd, args[0], noHooks)
			}

			jobRef, jobID, err := parseJobRef(args[0])
			if err != nil {
				return err
			}

			client, _, err := apiClient()
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
			if !noHooks {
				if err := runPostCheckoutHooks(cmd.Context(), checkoutRunGit, checkoutRunHookCommand, cmd.OutOrStdout(), cmd.ErrOrStderr()); err != nil {
					return err
				}
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Checked out %s — run 'syrus test-plan %s' to see the test plan.\n", job.Job.BranchName, jobRef)
			return nil
		},
	}
	command.Flags().BoolVar(&noHooks, "no-hooks", false, "skip .syrus.yml hooks.post_checkout commands")
	return command
}

func runEpicCheckout(cmd *cobra.Command, input string, noHooks bool) error {
	epicRef, epicID, err := parseEpicRef(input)
	if err != nil {
		return err
	}

	client, _, err := apiClient()
	if err != nil {
		return err
	}
	epic, err := client.GetEpic(cmd.Context(), epicID)
	if err != nil {
		return err
	}
	if len(epic.Jobs) == 0 {
		return fmt.Errorf("Epic %s has no jobs", epicRef)
	}
	if strings.TrimSpace(epic.Epic.RepositorySlug) == "" {
		return fmt.Errorf("Epic %s response did not include a repository slug", epicRef)
	}

	candidates := epicCheckoutCandidates(epic.Jobs)
	if len(candidates) == 0 {
		return fmt.Errorf("Epic %s has no jobs with a branch yet", epicRef)
	}

	var selected *api.JobItem
	if len(candidates) == 1 {
		selected = &candidates[0].job
	} else {
		selected, err = epicPickerFunc(epicTitleRef(epicRef, epic.Epic.Title, len(epic.Jobs)), candidates)
		if err != nil {
			return err
		}
		if selected == nil {
			fmt.Fprintln(cmd.OutOrStdout(), "Cancelled.")
			return nil
		}
	}

	if err := checkoutJobBranch(cmd.Context(), checkoutRunGit, epic.Epic.RepositorySlug, selected.BranchName); err != nil {
		return err
	}
	if !noHooks {
		if err := runPostCheckoutHooks(cmd.Context(), checkoutRunGit, checkoutRunHookCommand, cmd.OutOrStdout(), cmd.ErrOrStderr()); err != nil {
			return err
		}
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Checked out %s — run 'syrus test-plan JOB-%d' to see the test plan.\n", selected.BranchName, selected.ID)
	return nil
}

func parseEpicRef(input string) (string, string, error) {
	ref := strings.TrimSpace(input)
	upper := strings.ToUpper(ref)
	if !strings.HasPrefix(upper, "EPIC-") {
		return "", "", fmt.Errorf("invalid epic id %q", input)
	}
	id := strings.TrimSpace(ref[5:])
	if id == "" {
		return "", "", fmt.Errorf("invalid epic id %q", input)
	}
	return "EPIC-" + id, id, nil
}

type epicCandidate struct {
	job       api.JobItem
	ancestors []api.JobItem
}

func epicCheckoutCandidates(jobs []api.JobItem) []epicCandidate {
	byID := make(map[int64]api.JobItem, len(jobs))
	for _, job := range jobs {
		byID[job.ID] = job
	}

	hasDependent := map[int64]bool{}
	for _, job := range jobs {
		for _, dependencyID := range job.DependsOnJobIDs {
			if _, ok := byID[dependencyID]; ok {
				hasDependent[dependencyID] = true
			}
		}
	}

	candidates := []epicCandidate{}
	for _, job := range jobs {
		if hasDependent[job.ID] || strings.TrimSpace(job.BranchName) == "" {
			continue
		}
		candidates = append(candidates, epicCandidate{
			job:       job,
			ancestors: epicAncestors(job, byID),
		})
	}
	return candidates
}

func epicAncestors(job api.JobItem, byID map[int64]api.JobItem) []api.JobItem {
	seen := map[int64]bool{}
	ancestors := []api.JobItem{}
	var visit func(api.JobItem)
	visit = func(current api.JobItem) {
		for _, dependencyID := range current.DependsOnJobIDs {
			dependency, ok := byID[dependencyID]
			if !ok || seen[dependencyID] {
				continue
			}
			seen[dependencyID] = true
			visit(dependency)
			ancestors = append(ancestors, dependency)
		}
	}
	visit(job)
	return ancestors
}

type epicPickerModel struct {
	epicRef    string
	candidates []epicCandidate
	cursor     int
	chosen     *api.JobItem
	quitting   bool
	width      int
}

func (m epicPickerModel) Init() tea.Cmd {
	return nil
}

func (m epicPickerModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < len(m.candidates)-1 {
				m.cursor++
			}
		case "enter":
			if len(m.candidates) > 0 {
				m.chosen = &m.candidates[m.cursor].job
			}
			return m, tea.Quit
		case "ctrl+c", "q":
			m.quitting = true
			return m, tea.Quit
		}
	case tea.WindowSizeMsg:
		if msg.Width > 0 {
			m.width = msg.Width
		}
	}
	return m, nil
}

func (m epicPickerModel) View() string {
	lines := []string{
		headerStyle.Render(m.epicRef),
		"",
	}
	for i, candidate := range m.candidates {
		pointer := "  "
		if i == m.cursor {
			pointer = "▶ "
		}
		lines = append(lines, pointer+epicJobLine(candidate.job, m.width-2))
		for _, ancestor := range candidate.ancestors {
			lines = append(lines, subtleStyle.Render("    "+epicJobLine(ancestor, m.width-4)))
		}
		lines = append(lines, "")
	}
	lines = append(lines, subtleStyle.Render("↑/↓ navigate · enter checkout · q cancel"))
	return strings.Join(lines, "\n")
}

func epicTitleRef(epicRef string, title string, jobsCount int) string {
	title = strings.TrimSpace(title)
	if title == "" {
		return fmt.Sprintf("%s (%d jobs)", epicRef, jobsCount)
	}
	return fmt.Sprintf("%s · %s (%d jobs)", epicRef, title, jobsCount)
}

func epicJobLine(job api.JobItem, width int) string {
	title := strings.TrimSpace(job.Title)
	if title == "" {
		title = strings.TrimSpace(job.IssueTitle)
	}
	if title == "" {
		title = "Untitled"
	}
	prefix := fmt.Sprintf("JOB-%d · ", job.ID)
	suffix := fmt.Sprintf("  [%s]", inspectColorState(job.State))
	if width > len(prefix)+len(job.State)+5 {
		title = truncate(title, width-len(prefix)-len(job.State)-5)
	}
	return prefix + title + suffix
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

	remoteRef := "refs/remotes/origin/" + branchName
	localRef := "refs/heads/" + branchName

	if _, err := runner(ctx, "", "fetch", "origin", "+refs/heads/"+branchName+":"+remoteRef); err != nil {
		return fmt.Errorf("git fetch failed: %w", err)
	}

	currentBranch, err := runner(ctx, "", "branch", "--show-current")
	currentBranchName := ""
	if err == nil {
		currentBranchName = strings.TrimSpace(currentBranch)
	}

	branchExists := true
	if _, err := runner(ctx, "", "show-ref", "--verify", "--quiet", localRef); err != nil {
		branchExists = false
	}

	if !branchExists {
		if _, err := runner(ctx, "", "checkout", "--track", "-b", branchName, remoteRef); err != nil {
			return fmt.Errorf("git checkout failed: %w", err)
		}
		return nil
	}

	if currentBranchName == branchName {
		status, err := runner(ctx, "", "status", "--porcelain")
		if err != nil {
			return fmt.Errorf("git status failed: %w", err)
		}
		if strings.TrimSpace(status) != "" {
			return fmt.Errorf("cannot update %s because it is currently checked out with local changes; commit or stash them first", branchName)
		}
		if err := backupLocalBranchIfNeeded(ctx, runner, branchName, localRef, remoteRef); err != nil {
			return err
		}
		if _, err := runner(ctx, "", "reset", "--hard", remoteRef); err != nil {
			return fmt.Errorf("git reset failed: %w", err)
		}
		return nil
	}

	if err := backupLocalBranchIfNeeded(ctx, runner, branchName, localRef, remoteRef); err != nil {
		return err
	}
	if _, err := runner(ctx, "", "branch", "-f", branchName, remoteRef); err != nil {
		return fmt.Errorf("git branch update failed: %w", err)
	}
	if _, err := runner(ctx, "", "checkout", branchName); err != nil {
		return fmt.Errorf("git checkout failed: %w", err)
	}
	return nil
}

type checkoutSyrusYml struct {
	Hooks checkoutHooks `yaml:"hooks"`
}

type checkoutHooks struct {
	PostCheckout []string `yaml:"post_checkout"`
}

func runPostCheckoutHooks(ctx context.Context, runner gitRunner, hookRunner hookCommandRunner, stdout io.Writer, stderr io.Writer) error {
	repoRootOutput, err := runner(ctx, "", "rev-parse", "--show-toplevel")
	if err != nil {
		return fmt.Errorf("could not find git repository root for post-checkout hooks: %w", err)
	}
	repoRoot := strings.TrimSpace(repoRootOutput)
	if repoRoot == "" {
		return errors.New("could not find git repository root for post-checkout hooks")
	}

	configPath := filepath.Join(repoRoot, ".syrus.yml")
	contents, err := os.ReadFile(configPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("could not read %s: %w", configPath, err)
	}

	var config checkoutSyrusYml
	if err := yaml.Unmarshal(contents, &config); err != nil {
		return fmt.Errorf("could not parse %s: %w", configPath, err)
	}

	for _, command := range config.Hooks.PostCheckout {
		command = strings.TrimSpace(command)
		if command == "" {
			continue
		}
		if err := hookRunner(ctx, repoRoot, command, stdout, stderr); err != nil {
			if exitCode, ok := exitCodeFromError(err); ok {
				return fmt.Errorf("post-checkout hook failed: %q exited with status %d", command, exitCode)
			}
			return fmt.Errorf("post-checkout hook failed: %q: %w", command, err)
		}
	}

	return nil
}

func backupLocalBranchIfNeeded(ctx context.Context, runner gitRunner, branchName string, localRef string, remoteRef string) error {
	localHead, err := runner(ctx, "", "rev-parse", "--verify", localRef)
	if err != nil {
		return fmt.Errorf("git rev-parse failed for %s: %w", branchName, err)
	}
	remoteHead, err := runner(ctx, "", "rev-parse", "--verify", remoteRef)
	if err != nil {
		return fmt.Errorf("git rev-parse failed for origin/%s: %w", branchName, err)
	}
	if strings.TrimSpace(localHead) == strings.TrimSpace(remoteHead) {
		return nil
	}
	if _, err := runner(ctx, "", "merge-base", "--is-ancestor", localRef, remoteRef); err == nil {
		return nil
	}

	backupName := "syrus/backup/" + sanitizeBranchForBackup(branchName) + "-" + checkoutBackupTimestamp()
	if _, err := runner(ctx, "", "branch", backupName, localRef); err != nil {
		return fmt.Errorf("git backup branch failed: %w", err)
	}
	return nil
}

func sanitizeBranchForBackup(branchName string) string {
	value := strings.NewReplacer(
		"/", "-",
		"\\", "-",
		" ", "-",
		"~", "-",
		"^", "-",
		":", "-",
		"?", "-",
		"*", "-",
		"[", "-",
		"]", "-",
	).Replace(strings.TrimSpace(branchName))
	value = strings.Trim(value, "-")
	if value == "" {
		return "branch"
	}
	return value
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

func runHookCommand(ctx context.Context, dir string, command string, stdout io.Writer, stderr io.Writer) error {
	shell := exec.CommandContext(ctx, "sh", "-c", command)
	shell.Dir = dir
	shell.Stdout = stdout
	shell.Stderr = stderr
	return shell.Run()
}

func exitCodeFromError(err error) (int, bool) {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode(), true
	}
	return 0, false
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
