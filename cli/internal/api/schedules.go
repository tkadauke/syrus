package api

import (
	"context"
	"net/http"
	"net/url"
)

type ScheduledTaskList struct {
	ActiveTasks []ScheduledTask `json:"active_tasks"`
}

type ScheduledTaskDetail struct {
	Task       ScheduledTask `json:"task"`
	RecentJobs []ScheduleJob  `json:"recent_jobs"`
}

type ScheduledTask struct {
	ID                 int64      `json:"id"`
	Name               string     `json:"name"`
	State              string     `json:"state"`
	Kind               string     `json:"kind"`
	Repository         Repository `json:"repository"`
	CronExpression     string     `json:"cron_expression"`
	NextFireAt         string     `json:"next_fire_at"`
	PrPileupPolicy     string     `json:"pr_pileup_policy"`
	AutoApproveMode    string     `json:"auto_approve_mode"`
	Prompt             string     `json:"prompt"`
	ConsecutiveFailure int        `json:"consecutive_failure_count"`
}

type ScheduleJob struct {
	ID             int64  `json:"id"`
	State          string `json:"state"`
	ClosureReason  string `json:"closure_reason"`
	PRNumber       int64  `json:"pr_number"`
	ExternalPR     int64  `json:"external_pr_number"`
	CreatedAt      string `json:"created_at"`
}

type RepositoryList struct {
	ActiveRepositories []Repository `json:"active_repositories"`
	Repositories       []Repository `json:"repositories"`
}

type Repository struct {
	ID   int64  `json:"id"`
	Slug string `json:"slug"`
}

type CreateScheduleRequest struct {
	ScheduledTask CreateScheduleParams `json:"scheduled_task"`
}

type CreateScheduleParams struct {
	Name             string `json:"name"`
	Kind             string `json:"kind"`
	CronExpression   string `json:"cron_expression"`
	PrPileupPolicy   string `json:"pr_pileup_policy"`
	Prompt           string `json:"prompt"`
}

type FireScheduleResponse struct {
	Message    string `json:"message"`
	FireResult struct {
		Fired bool   `json:"fired"`
		JobID int64  `json:"job_id"`
		Reason string `json:"reason"`
	} `json:"fire_result"`
}

func (l RepositoryList) AvailableRepositories() []Repository {
	if len(l.ActiveRepositories) > 0 {
		return l.ActiveRepositories
	}
	return l.Repositories
}

func (c *Client) ListScheduledTasks(ctx context.Context) (ScheduledTaskList, error) {
	var out ScheduledTaskList
	err := c.do(ctx, http.MethodGet, "/api/v1/app/scheduled_tasks", nil, &out)
	return out, err
}

func (c *Client) GetScheduledTask(ctx context.Context, id string) (ScheduledTaskDetail, error) {
	var out ScheduledTaskDetail
	err := c.do(ctx, http.MethodGet, "/api/v1/app/scheduled_tasks/"+url.PathEscape(id), nil, &out)
	return out, err
}

func (c *Client) ListRepositories(ctx context.Context) (RepositoryList, error) {
	var out RepositoryList
	err := c.do(ctx, http.MethodGet, "/api/v1/app/repositories", nil, &out)
	return out, err
}

func (c *Client) CreateScheduledTask(ctx context.Context, repositoryID int64, params CreateScheduleParams) (ScheduledTaskDetail, error) {
	var out ScheduledTaskDetail
	path := "/api/v1/app/repositories/" + url.PathEscape(formatID(repositoryID)) + "/scheduled_tasks"
	err := c.do(ctx, http.MethodPost, path, CreateScheduleRequest{ScheduledTask: params}, &out)
	return out, err
}

func (c *Client) DeleteScheduledTask(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodDelete, "/api/v1/app/scheduled_tasks/"+url.PathEscape(id), nil, nil)
}

func (c *Client) FireScheduledTask(ctx context.Context, id string) (FireScheduleResponse, error) {
	var out FireScheduleResponse
	err := c.do(ctx, http.MethodPost, "/api/v1/app/scheduled_tasks/"+url.PathEscape(id)+"/fire_now", nil, &out)
	return out, err
}
