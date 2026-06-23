package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
)

type JobList struct {
	Count int       `json:"count"`
	Jobs  []JobItem `json:"jobs"`
}

type JobResponse json.RawMessage

type JobItem struct {
	ID             int64          `json:"id"`
	State          string         `json:"state"`
	SummaryState   string         `json:"summary_state"`
	Title          string         `json:"title"`
	IssueTitle     string         `json:"issue_title"`
	RepositorySlug string         `json:"repository_slug"`
	BranchName     string         `json:"branch_name"`
	PRNumber       int64          `json:"pr_number"`
	PRURL          string         `json:"pr_url"`
	CreatedAt      string         `json:"created_at"`
	UpdatedAt      string         `json:"updated_at"`
	StartedAt      string         `json:"started_at"`
	FinishedAt     string         `json:"finished_at"`
	CurrentStep    string         `json:"current_step"`
	LatestRunID    int64          `json:"latest_run_id"`
	Workflow       *WorkflowBrief `json:"workflow"`
}

type WorkflowBrief struct {
	ID        int64          `json:"id"`
	State     string         `json:"state"`
	Artifacts map[string]any `json:"artifacts"`
	Steps     []StepBrief    `json:"steps"`
}

type StepBrief struct {
	ID          int64  `json:"id"`
	Kind        string `json:"kind"`
	DisplayName string `json:"display_name"`
	State       string `json:"state"`
	StartedAt   string `json:"started_at"`
	FinishedAt  string `json:"finished_at"`
	RunID       int64  `json:"run_id"`
	RunState    string `json:"run_state"`
}

type JobDetail struct {
	Job        JobItem `json:"job"`
	Repository struct {
		Slug string `json:"slug"`
	} `json:"repository"`
	Summary   *JobSummary     `json:"summary"`
	Workflows []WorkflowBrief `json:"workflows"`
}

type AdminJobDetail struct {
	ID         int64           `json:"id"`
	IssueTitle string          `json:"issue_title"`
	BranchName string          `json:"branch_name"`
	Repository AdminRepository `json:"repository"`
	Workflows  []AdminWorkflow `json:"workflows"`
}

type AdminRepository struct {
	Slug string `json:"slug"`
}

type AdminWorkflow struct {
	ID         int64          `json:"id"`
	State      string         `json:"state"`
	FinishedAt string         `json:"finished_at"`
	CreatedAt  string         `json:"created_at"`
	Artifacts  map[string]any `json:"artifacts"`
}

type JobSummary struct {
	RunID      int64  `json:"run_id"`
	Text       string `json:"text"`
	FinishedAt string `json:"finished_at"`
}

type JobTranscript struct {
	JobID    int64    `json:"job_id"`
	RunID    int64    `json:"run_id"`
	State    string   `json:"state"`
	Complete bool     `json:"complete"`
	Lines    []string `json:"lines"`
}

type JobDiff struct {
	JobID         int64  `json:"job_id"`
	PRURL         string `json:"pr_url"`
	Diff          string `json:"diff"`
	NoGithubToken bool   `json:"no_github_token"`
}

type CreateJobRequest struct {
	RepositoryID  int64  `json:"repository_id,omitempty"`
	Title         string `json:"title,omitempty"`
	Prompt        string `json:"prompt"`
	Priority      string `json:"priority,omitempty"`
	AgentProvider string `json:"agent_provider,omitempty"`
}

type CreateJobParams struct {
	Repository    string `json:"repository,omitempty"`
	RepositoryID  int64  `json:"repository_id,omitempty"`
	Title         string `json:"title,omitempty"`
	Prompt        string `json:"prompt"`
	Priority      string `json:"priority,omitempty"`
	AgentProvider string `json:"agent_provider,omitempty"`
	EpicID        int64  `json:"epic_id,omitempty"`
	OwnerUserID   int64  `json:"owner_user_id,omitempty"`
}

func (c *Client) ListJobs(ctx context.Context, filters url.Values) (JobList, error) {
	var out JobList
	path := "/api/v1/app/jobs"
	if encoded := filters.Encode(); encoded != "" {
		path += "?" + encoded
	}
	err := c.do(ctx, http.MethodGet, path, nil, &out)
	return out, err
}

func (c *Client) GetJob(ctx context.Context, id string) (JobResponse, error) {
	var out json.RawMessage
	err := c.do(ctx, http.MethodGet, "/api/v1/app/jobs/"+url.PathEscape(id), nil, &out)
	return JobResponse(out), err
}

func (c *Client) GetAppJob(ctx context.Context, id string) ([]byte, error) {
	var out json.RawMessage
	err := c.do(ctx, http.MethodGet, "/api/v1/app/jobs/"+url.PathEscape(id), nil, &out)
	return []byte(out), err
}

func (c *Client) GetAdminJobRaw(ctx context.Context, id string) (JobResponse, error) {
	var out json.RawMessage
	err := c.do(ctx, http.MethodGet, "/api/v1/admin/jobs/"+url.PathEscape(id), nil, &out)
	return JobResponse(out), err
}

func (c *Client) GetJobDetail(ctx context.Context, id string) (JobDetail, error) {
	var out JobDetail
	err := c.do(ctx, http.MethodGet, "/api/v1/app/jobs/"+url.PathEscape(id), nil, &out)
	return out, err
}

func (c *Client) GetJobTranscript(ctx context.Context, id string) (JobTranscript, error) {
	var out JobTranscript
	err := c.do(ctx, http.MethodGet, "/api/v1/app/jobs/"+url.PathEscape(id)+"/transcript", nil, &out)
	return out, err
}

func (c *Client) GetJobDiff(ctx context.Context, id string) (JobDiff, error) {
	var out JobDiff
	err := c.do(ctx, http.MethodGet, "/api/v1/app/jobs/"+url.PathEscape(id)+"/diff", nil, &out)
	return out, err
}

func (c *Client) CreateDirectJob(ctx context.Context, params CreateJobParams) (JobDetail, error) {
	var out JobDetail
	err := c.do(ctx, http.MethodPost, "/api/v1/app/jobs", CreateJobRequest{
		RepositoryID:  params.RepositoryID,
		Title:         params.Title,
		Prompt:        params.Prompt,
		Priority:      params.Priority,
		AgentProvider: params.AgentProvider,
	}, &out)
	return out, err
}

func (c *Client) RunJobAction(ctx context.Context, id string, action string) error {
	return c.do(ctx, http.MethodPost, "/api/v1/app/jobs/"+url.PathEscape(id)+"/"+url.PathEscape(action), nil, nil)
}

func (c *Client) GetAdminJob(ctx context.Context, id string) (AdminJobDetail, error) {
	var out AdminJobDetail
	err := c.do(ctx, http.MethodGet, "/api/v1/admin/jobs/"+url.PathEscape(id), nil, &out)
	return out, err
}

func (c *Client) ApproveJob(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodPost, "/api/v1/app/jobs/"+url.PathEscape(id)+"/approve", nil, nil)
}

func (c *Client) RetryJob(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodPost, "/api/v1/app/jobs/"+url.PathEscape(id)+"/run_again", nil, nil)
}
