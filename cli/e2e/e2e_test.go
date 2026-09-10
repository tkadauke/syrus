package e2e_test

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const (
	e2eToken     = "syrus_e2e_cli_token"
	e2eRepoSlug  = "demo/syrus-preview"
	e2eJobTitle = "CLI golden path fixture"
)

type jobListPayload struct {
	Jobs []struct {
		ID         int    `json:"id"`
		Title      string `json:"title"`
		BranchName string `json:"branch_name"`
	} `json:"jobs"`
}

func TestCLIGoldenPathAgainstPreviewServer(t *testing.T) {
	if os.Getenv("SYRUS_CLI_E2E") != "1" {
		t.Skip("set SYRUS_CLI_E2E=1 to run the CLI E2E suite")
	}

	root := repoRoot(t)
	baseURL := strings.TrimSpace(os.Getenv("E2E_BASE_URL"))
	if baseURL == "" {
		baseURL = "http://127.0.0.1:3101"
	}

	binary := buildCLI(t, root)
	home := t.TempDir()

	login := runCLI(t, binary, home, "", "login", "--url", baseURL, "--token", e2eToken)
	assertContains(t, login, "Syrus credentials saved.")

	listJSON := runCLI(t, binary, home, "", "job", "list", "--repo", e2eRepoSlug, "--state", "all", "--json")
	var list jobListPayload
	if err := json.Unmarshal([]byte(listJSON), &list); err != nil {
		t.Fatalf("could not parse job list JSON:\n%s\nerror: %v", listJSON, err)
	}
	jobID, branchName := findFixtureJob(t, list)

	listOutput := runCLI(t, binary, home, "", "job", "list", "--repo", e2eRepoSlug, "--state", "all")
	assertContains(t, listOutput, fmt.Sprintf("%d", jobID))
	assertContains(t, listOutput, e2eRepoSlug)
	assertContains(t, listOutput, e2eJobTitle)

	show := runCLI(t, binary, home, "", "job", "show", fmt.Sprintf("JOB-%d", jobID))
	assertContains(t, show, fmt.Sprintf("JOB-%d", jobID))
	assertContains(t, show, e2eJobTitle)
	assertContains(t, show, "State: implemented")
	assertContains(t, show, "Repo: "+e2eRepoSlug)

	repoDir := initCheckoutFixture(t, branchName)
	checkout := runCLI(t, binary, home, repoDir, "checkout", "--no-hooks", fmt.Sprintf("JOB-%d", jobID))
	assertContains(t, checkout, "Checked out "+branchName)
	assertContains(t, checkout, fmt.Sprintf("syrus test-plan JOB-%d", jobID))

	status := runCLI(t, binary, home, repoDir, "status")
	assertContains(t, status, fmt.Sprintf("JOB-%d (%s)", jobID, branchName))
	assertContains(t, status, "up to date")

	testPlan := runCLI(t, binary, home, repoDir, "test-plan")
	assertContains(t, testPlan, fmt.Sprintf("Test plan for JOB-%d: %s", jobID, e2eJobTitle))
	assertContains(t, testPlan, "Run `syrus status` from the checked-out fixture branch.")
	assertContains(t, testPlan, "Confirm the CLI can read this seeded test plan from the app API.")
}

func findFixtureJob(t *testing.T, list jobListPayload) (int, string) {
	t.Helper()

	for _, job := range list.Jobs {
		if job.Title == e2eJobTitle {
			if job.ID == 0 {
				t.Fatalf("fixture job has no ID: %+v", job)
			}
			if strings.TrimSpace(job.BranchName) == "" {
				t.Fatalf("fixture job has no branch_name: %+v", job)
			}
			return job.ID, job.BranchName
		}
	}

	t.Fatalf("could not find %q in job list: %+v", e2eJobTitle, list.Jobs)
	return 0, ""
}

func buildCLI(t *testing.T, root string) string {
	t.Helper()

	binary := filepath.Join(t.TempDir(), "syrus")
	if runtime.GOOS == "windows" {
		binary += ".exe"
	}
	cmd := exec.Command("go", "build", "-o", binary, "./cli")
	cmd.Dir = root
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go build ./cli failed: %v\n%s", err, string(output))
	}
	return binary
}

func runCLI(t *testing.T, binary string, home string, dir string, args ...string) string {
	t.Helper()

	cmd := exec.Command(binary, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = append(os.Environ(),
		"HOME="+home,
		"NO_COLOR=1",
		"TERM=dumb",
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("syrus %s failed: %v\n%s", strings.Join(args, " "), err, string(output))
	}
	return string(output)
}

func initCheckoutFixture(t *testing.T, branchName string) string {
	t.Helper()

	work := t.TempDir()
	remoteParent := filepath.Join(work, "demo")
	if err := os.MkdirAll(remoteParent, 0o755); err != nil {
		t.Fatal(err)
	}
	remoteDir := filepath.Join(remoteParent, "syrus-preview")
	runGit(t, "", "init", "--bare", remoteDir)

	sourceDir := filepath.Join(work, "source")
	runGit(t, "", "init", sourceDir)
	runGit(t, sourceDir, "config", "user.email", "cli-e2e@syrus.local")
	runGit(t, sourceDir, "config", "user.name", "CLI E2E")
	if err := os.WriteFile(filepath.Join(sourceDir, "README.md"), []byte("# CLI E2E\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, sourceDir, "add", "README.md")
	runGit(t, sourceDir, "commit", "-m", "Initial commit")
	runGit(t, sourceDir, "branch", "-M", "main")
	runGit(t, sourceDir, "remote", "add", "origin", remoteDir)
	runGit(t, sourceDir, "push", "origin", "main")
	runGit(t, sourceDir, "checkout", "-b", branchName)
	if err := os.WriteFile(filepath.Join(sourceDir, "fixture.txt"), []byte("checked out by CLI E2E\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, sourceDir, "add", "fixture.txt")
	runGit(t, sourceDir, "commit", "-m", "Add CLI fixture branch")
	runGit(t, sourceDir, "push", "origin", branchName)

	repoDir := filepath.Join(work, "checkout")
	runGit(t, "", "clone", remoteDir, repoDir)
	return repoDir
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()

	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, string(output))
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()

	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not resolve caller path")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
}

func assertContains(t *testing.T, got string, want string) {
	t.Helper()

	if !strings.Contains(got, want) {
		t.Fatalf("output missing %q:\n%s", want, got)
	}
}
