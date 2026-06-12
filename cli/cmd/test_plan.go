package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

var jobSlugPattern = regexp.MustCompile(`(?i)^JOB-(\d+)$`)

type adminJobPayload struct {
	ID         int               `json:"id"`
	IssueTitle string            `json:"issue_title"`
	Workflows  []workflowPayload `json:"workflows"`
}

type workflowPayload struct {
	ID         int                        `json:"id"`
	State      string                     `json:"state"`
	FinishedAt string                    `json:"finished_at"`
	CreatedAt  string                    `json:"created_at"`
	Artifacts  map[string]json.RawMessage `json:"artifacts"`
}

type testPlanArtifact struct {
	Steps []string `json:"steps"`
	Notes string   `json:"notes"`
}

func (r runner) runTestPlan(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: syrus test-plan JOB-<id>")
	}

	jobID, err := parseJobID(args[0])
	if err != nil {
		return err
	}

	payload, err := r.fetchAdminJob(jobID)
	if err != nil {
		return err
	}

	plan, ok := latestCompletedTestPlan(payload.Workflows)
	if !ok {
		fmt.Fprintf(r.stdout, "No test plan available for JOB-%s yet — the job may still be implementing.\n", jobID)
		return nil
	}

	printTestPlan(r.stdout, payload, plan)
	return nil
}

func parseJobID(slug string) (string, error) {
	matches := jobSlugPattern.FindStringSubmatch(slug)
	if matches == nil {
		return "", errors.New("job must use JOB-<id> format")
	}

	return matches[1], nil
}

func (r runner) fetchAdminJob(jobID string) (adminJobPayload, error) {
	base := strings.TrimSpace(r.getenv("SYRUS_URL"))
	if base == "" {
		base = strings.TrimSpace(r.getenv("SYRUS_APP_HOST"))
	}
	if base == "" {
		return adminJobPayload{}, errors.New("SYRUS_URL or SYRUS_APP_HOST is required")
	}
	if !strings.HasPrefix(strings.ToLower(base), "http://") && !strings.HasPrefix(strings.ToLower(base), "https://") {
		base = "https://" + base
	}

	token := strings.TrimSpace(r.getenv("SYRUS_API_TOKEN"))
	if token == "" {
		return adminJobPayload{}, errors.New("SYRUS_API_TOKEN is required")
	}

	uri, err := url.Parse(strings.TrimRight(base, "/") + "/api/v1/admin/jobs/" + jobID)
	if err != nil {
		return adminJobPayload{}, err
	}

	request, err := http.NewRequest(http.MethodGet, uri.String(), nil)
	if err != nil {
		return adminJobPayload{}, err
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/json")

	response, err := r.client.Do(request)
	if err != nil {
		return adminJobPayload{}, err
	}
	defer response.Body.Close()

	if response.StatusCode < 200 || response.StatusCode > 299 {
		return adminJobPayload{}, fmt.Errorf("GET %s failed with HTTP %d", uri.Path, response.StatusCode)
	}

	var payload adminJobPayload
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		return adminJobPayload{}, err
	}

	return payload, nil
}

func latestCompletedTestPlan(workflows []workflowPayload) (testPlanArtifact, bool) {
	var newest workflowPayload
	var plan testPlanArtifact
	found := false

	for _, workflow := range workflows {
		if !terminalWorkflowState(workflow.State) {
			continue
		}

		rawPlan, ok := workflow.Artifacts["test_plan"]
		if !ok || len(rawPlan) == 0 || string(rawPlan) == "null" {
			continue
		}

		var candidate testPlanArtifact
		if err := json.Unmarshal(rawPlan, &candidate); err != nil {
			continue
		}
		if len(candidate.Steps) == 0 {
			continue
		}

		if !found || workflowAfter(workflow, newest) {
			newest = workflow
			plan = candidate
			found = true
		}
	}

	return plan, found
}

func terminalWorkflowState(state string) bool {
	switch state {
	case "succeeded", "failed", "cancelled":
		return true
	default:
		return false
	}
}

func workflowAfter(left workflowPayload, right workflowPayload) bool {
	leftFinished := parseAPITime(left.FinishedAt)
	rightFinished := parseAPITime(right.FinishedAt)
	if !leftFinished.Equal(rightFinished) {
		return leftFinished.After(rightFinished)
	}

	leftCreated := parseAPITime(left.CreatedAt)
	rightCreated := parseAPITime(right.CreatedAt)
	if !leftCreated.Equal(rightCreated) {
		return leftCreated.After(rightCreated)
	}

	return left.ID > right.ID
}

func parseAPITime(value string) time.Time {
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return time.Time{}
	}

	return parsed
}

func printTestPlan(stdout io.Writer, payload adminJobPayload, plan testPlanArtifact) {
	fmt.Fprintf(stdout, "Test plan for JOB-%d: %s\n\n", payload.ID, payload.IssueTitle)
	for index, step := range plan.Steps {
		fmt.Fprintf(stdout, "%d. %s\n", index+1, step)
	}

	notes := strings.TrimSpace(plan.Notes)
	if notes == "" {
		return
	}

	fmt.Fprintf(stdout, "\nNotes: %s\n", notes)
}
