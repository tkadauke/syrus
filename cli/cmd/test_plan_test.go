package cmd

import (
	"bytes"
	"io"
	"net/http"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) Do(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func TestPlanFetchesAdminJobAndPrintsNewestCompletedPlan(t *testing.T) {
	var stdout bytes.Buffer
	var requestedURL string
	var requestedToken string
	payload := `{
		"id": 456,
		"issue_title": "Add user avatar upload",
		"workflows": [
			{
				"id": 1,
				"state": "succeeded",
				"finished_at": "2026-06-10T10:00:00Z",
				"created_at": "2026-06-10T09:00:00Z",
				"artifacts": {
					"test_plan": {
						"steps": ["Old step"],
						"notes": "Old notes."
					}
				}
			},
			{
				"id": 2,
				"state": "running",
				"finished_at": null,
				"created_at": "2026-06-11T09:00:00Z",
				"artifacts": {
					"test_plan": {
						"steps": ["Ignore running workflow"],
						"notes": null
					}
				}
			},
			{
				"id": 3,
				"state": "succeeded",
				"finished_at": "2026-06-11T10:00:00Z",
				"created_at": "2026-06-11T09:00:00Z",
				"artifacts": {
					"test_plan": {
						"steps": [
							"Navigate to /settings/profile",
							"Click \"Upload avatar\" and select a PNG under 2 MB",
							"Verify the avatar appears in the nav bar immediately"
						],
						"notes": "Avatar storage uses ActiveStorage."
					}
				}
			}
		]
	}`

	exitCode := execute(
		[]string{"test-plan", "JOB-456"},
		&stdout,
		io.Discard,
		func(key string) string {
			switch key {
			case "SYRUS_URL":
				return "https://syrus.example.com/"
			case "SYRUS_API_TOKEN":
				return "syrus_secret"
			default:
				return ""
			}
		},
		roundTripFunc(func(request *http.Request) (*http.Response, error) {
			requestedURL = request.URL.String()
			requestedToken = request.Header.Get("Authorization")
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(payload)),
			}, nil
		}),
	)

	if exitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", exitCode)
	}
	if requestedURL != "https://syrus.example.com/api/v1/admin/jobs/456" {
		t.Fatalf("unexpected request URL: %s", requestedURL)
	}
	if requestedToken != "Bearer syrus_secret" {
		t.Fatalf("unexpected authorization header: %s", requestedToken)
	}

	expected := `Test plan for JOB-456: Add user avatar upload

1. Navigate to /settings/profile
2. Click "Upload avatar" and select a PNG under 2 MB
3. Verify the avatar appears in the nav bar immediately

Notes: Avatar storage uses ActiveStorage.
`
	if stdout.String() != expected {
		t.Fatalf("unexpected output:\n%s", stdout.String())
	}
}

func TestPlanPrintsPendingMessageWhenNoCompletedWorkflowHasPlan(t *testing.T) {
	var stdout bytes.Buffer
	payload := `{
		"id": 456,
		"issue_title": "Add user avatar upload",
		"workflows": [
			{"id": 1, "state": "running", "artifacts": {"test_plan": {"steps": ["Run smoke test"]}}},
			{"id": 2, "state": "succeeded", "artifacts": {}}
		]
	}`

	exitCode := execute(
		[]string{"test-plan", "JOB-456"},
		&stdout,
		io.Discard,
		func(key string) string {
			switch key {
			case "SYRUS_APP_HOST":
				return "syrus.example.com"
			case "SYRUS_API_TOKEN":
				return "syrus_secret"
			default:
				return ""
			}
		},
		roundTripFunc(func(_ *http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(payload)),
			}, nil
		}),
	)

	if exitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", exitCode)
	}

	expected := "No test plan available for JOB-456 yet — the job may still be implementing.\n"
	if stdout.String() != expected {
		t.Fatalf("unexpected output: %q", stdout.String())
	}
}

func TestPlanRequiresJobSlug(t *testing.T) {
	var stderr bytes.Buffer
	exitCode := execute(
		[]string{"test-plan", "456"},
		io.Discard,
		&stderr,
		func(_ string) string { return "" },
		roundTripFunc(func(_ *http.Request) (*http.Response, error) {
			t.Fatal("HTTP client should not be called")
			return nil, nil
		}),
	)

	if exitCode != 1 {
		t.Fatalf("expected exit code 1, got %d", exitCode)
	}
	if !strings.Contains(stderr.String(), "job must use JOB-<id> format") {
		t.Fatalf("unexpected stderr: %s", stderr.String())
	}
}
