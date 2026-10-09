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
	ID                  int64          `json:"id"`
	State               string         `json:"state"`
	SummaryState        string         `json:"summary_state"`
	Title               string         `json:"title"`
	IssueTitle          string         `json:"issue_title"`
	RepositorySlug      string         `json:"repository_slug"`
	BranchName          string         `json:"branch_name"`
	EffectiveBaseBranch string         `json:"effective_base_branch"`
	DependsOnJobIDs     []int64        `json:"depends_on_job_ids"`
	PRNumber            int64          `json:"pr_number"`
	PRURL               string         `json:"pr_url"`
	CreatedAt           string         `json:"created_at"`
	UpdatedAt           string         `json:"updated_at"`
	StartedAt           string         `json:"started_at"`
	FinishedAt          string         `json:"finished_at"`
	CurrentStep         string         `json:"current_step"`
	LatestRunID         int64          `json:"latest_run_id"`
	Workflow            *WorkflowBrief `json:"workflow"`
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
		Slug          string `json:"slug"`
		DefaultBranch string `json:"default_branch"`
	} `json:"repository"`
	Summary   *JobSummary     `json:"summary"`
	TestPlan  *JobTestPlan    `json:"test_plan"`
	Workflows []WorkflowBrief `json:"workflows"`
}

type JobSummary struct {
	RunID      int64  `json:"run_id"`
	Text       string `json:"text"`
	FinishedAt string `json:"finished_at"`
}

type JobTestPlan struct {
	WorkflowID int64    `json:"workflow_id"`
	Steps      []string `json:"steps"`
	Notes      string   `json:"notes"`
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

type DiffReviewComments struct {
	JobID               int64                       `json:"job_id"`
	DiffReviewVersionID *int64                      `json:"diff_review_version_id"`
	LatestVersionID     *int64                      `json:"latest_version_id"`
	Comments            []DiffReviewComment         `json:"comments"`
	ByPath              map[string]map[string][]any `json:"by_path,omitempty"`
}

type DiffReviewComment struct {
	ID                  int64          `json:"id"`
	JobID               int64          `json:"job_id"`
	DiffReviewVersionID int64          `json:"diff_review_version_id"`
	ParentID            *int64         `json:"parent_id"`
	UserID              int64          `json:"user_id"`
	User                map[string]any `json:"user,omitempty"`
	WorkflowID          *int64         `json:"workflow_id"`
	RunID               *int64         `json:"run_id"`
	Surface             string         `json:"surface"`
	BaseRef             string         `json:"base_ref"`
	HeadRef             string         `json:"head_ref"`
	AnchorKind          string         `json:"anchor_kind"`
	Path                string         `json:"path"`
	Side                string         `json:"side"`
	OldLine             *int64         `json:"old_line"`
	NewLine             *int64         `json:"new_line"`
	AnchorKey           string         `json:"anchor_key"`
	DiffHunk            string         `json:"diff_hunk"`
	Context             map[string]any `json:"context"`
	Body                string         `json:"body"`
	State               string         `json:"state"`
	CreatedAt           string         `json:"created_at"`
	UpdatedAt           string         `json:"updated_at"`
	SubmittedAt         string         `json:"submitted_at"`
	ResolvedAt          string         `json:"resolved_at"`
	SupersededAt        string         `json:"superseded_at"`
}

type CreateDiffReviewCommentRequest struct {
	DiffReviewComment DiffReviewCommentInput `json:"diff_review_comment"`
}

type DiffReviewCommentInput struct {
	Surface             string         `json:"surface,omitempty"`
	DiffReviewVersionID int64          `json:"diff_review_version_id,omitempty"`
	BaseRef             string         `json:"base_ref,omitempty"`
	HeadRef             string         `json:"head_ref,omitempty"`
	AnchorKind          string         `json:"anchor_kind,omitempty"`
	Path                string         `json:"path,omitempty"`
	Side                string         `json:"side,omitempty"`
	OldLine             int64          `json:"old_line,omitempty"`
	NewLine             int64          `json:"new_line,omitempty"`
	DiffHunk            string         `json:"diff_hunk,omitempty"`
	Body                string         `json:"body,omitempty"`
	State               string         `json:"state,omitempty"`
	WorkflowID          int64          `json:"workflow_id,omitempty"`
	RunID               int64          `json:"run_id,omitempty"`
	Context             map[string]any `json:"context,omitempty"`
}

type SubmitDiffReviewCommentsRequest struct {
	CommentIDs          []int64 `json:"comment_ids,omitempty"`
	DiffReviewVersionID int64   `json:"diff_review_version_id,omitempty"`
}

type DiffReviewSubmitResponse struct {
	Message  string              `json:"message"`
	Workflow *WorkflowBrief      `json:"workflow"`
	Comments []DiffReviewComment `json:"comments"`
}

type CreateJobRequest struct {
	RepositoryID    int64    `json:"repository_id,omitempty"`
	Title           string   `json:"title,omitempty"`
	Prompt          string   `json:"prompt"`
	Priority        string   `json:"priority,omitempty"`
	AgentProvider   string   `json:"agent_provider,omitempty"`
	EpicID          int64    `json:"epic_id,omitempty"`
	OwnerUserID     int64    `json:"owner_user_id,omitempty"`
	DependsOn       []string `json:"depends_on,omitempty"`
	DependsOnJobIDs []int64  `json:"depends_on_job_ids,omitempty"`
}

type CreateJobParams struct {
	Repository      string   `json:"repository,omitempty"`
	RepositoryID    int64    `json:"repository_id,omitempty"`
	Title           string   `json:"title,omitempty"`
	Prompt          string   `json:"prompt"`
	Priority        string   `json:"priority,omitempty"`
	AgentProvider   string   `json:"agent_provider,omitempty"`
	EpicID          int64    `json:"epic_id,omitempty"`
	OwnerUserID     int64    `json:"owner_user_id,omitempty"`
	DependsOn       []string `json:"depends_on,omitempty"`
	DependsOnJobIDs []int64  `json:"depends_on_job_ids,omitempty"`
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

func (c *Client) ListDiffReviewComments(ctx context.Context, id string, filters url.Values) (DiffReviewComments, error) {
	var out DiffReviewComments
	path := "/api/v1/app/jobs/" + url.PathEscape(id) + "/diff_review_comments"
	if encoded := filters.Encode(); encoded != "" {
		path += "?" + encoded
	}
	err := c.do(ctx, http.MethodGet, path, nil, &out)
	return out, err
}

func (c *Client) CreateDiffReviewComment(ctx context.Context, id string, input DiffReviewCommentInput) (DiffReviewComments, error) {
	var out DiffReviewComments
	err := c.do(ctx, http.MethodPost, "/api/v1/app/jobs/"+url.PathEscape(id)+"/diff_review_comments", CreateDiffReviewCommentRequest{
		DiffReviewComment: input,
	}, &out)
	return out, err
}

func (c *Client) SubmitDiffReviewComments(ctx context.Context, id string, commentIDs []int64, versionID int64) (DiffReviewSubmitResponse, error) {
	var out DiffReviewSubmitResponse
	err := c.do(ctx, http.MethodPost, "/api/v1/app/jobs/"+url.PathEscape(id)+"/diff_review_comments/submit", SubmitDiffReviewCommentsRequest{
		CommentIDs:          commentIDs,
		DiffReviewVersionID: versionID,
	}, &out)
	return out, err
}

func (c *Client) ResolveDiffReviewComment(ctx context.Context, id string, commentID int64, versionID int64) (DiffReviewComments, error) {
	var out DiffReviewComments
	err := c.do(ctx, http.MethodPost, diffReviewCommentPath(id, commentID, versionID, "resolve"), nil, &out)
	return out, err
}

func (c *Client) ReplyToDiffReviewComment(ctx context.Context, id string, commentID int64, body string, versionID int64) (DiffReviewComments, error) {
	var out DiffReviewComments
	err := c.do(ctx, http.MethodPost, diffReviewCommentPath(id, commentID, versionID, "reply"), map[string]string{"body": body}, &out)
	return out, err
}

func (c *Client) CreateDirectJob(ctx context.Context, params CreateJobParams) (JobDetail, error) {
	var out JobDetail
	err := c.do(ctx, http.MethodPost, "/api/v1/app/jobs", CreateJobRequest{
		RepositoryID:    params.RepositoryID,
		Title:           params.Title,
		Prompt:          params.Prompt,
		Priority:        params.Priority,
		AgentProvider:   params.AgentProvider,
		EpicID:          params.EpicID,
		OwnerUserID:     params.OwnerUserID,
		DependsOn:       params.DependsOn,
		DependsOnJobIDs: params.DependsOnJobIDs,
	}, &out)
	return out, err
}

func (c *Client) RunJobAction(ctx context.Context, id string, action string) error {
	return c.do(ctx, http.MethodPost, "/api/v1/app/jobs/"+url.PathEscape(id)+"/"+url.PathEscape(action), nil, nil)
}

func (c *Client) ApproveJob(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodPost, "/api/v1/app/jobs/"+url.PathEscape(id)+"/approve", nil, nil)
}

func (c *Client) RetryJob(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodPost, "/api/v1/app/jobs/"+url.PathEscape(id)+"/run_again", nil, nil)
}

func diffReviewCommentPath(jobID string, commentID int64, versionID int64, action string) string {
	path := "/api/v1/app/jobs/" + url.PathEscape(jobID) + "/diff_review_comments/" + url.PathEscape(formatID(commentID))
	if action != "" {
		path += "/" + url.PathEscape(action)
	}
	if versionID != 0 {
		path += "?diff_review_version_id=" + url.QueryEscape(formatID(versionID))
	}
	return path
}
