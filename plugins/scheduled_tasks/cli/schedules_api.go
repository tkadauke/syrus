package scheduledtasks

import (
	"context"
	"net/http"
	"net/url"
	"strconv"

	"github.com/tkadauke/syrus/cli/pkg/api"
)

type ScheduledTaskList struct {
	ActiveTasks []ScheduledTask `json:"active_tasks"`
}

type ScheduledTaskDetail struct {
	Task       ScheduledTask `json:"task"`
	RecentJobs []ScheduleJob `json:"recent_jobs"`
}

type ScheduledTask struct {
	ID                 int64              `json:"id"`
	Name               string             `json:"name"`
	State              string             `json:"state"`
	Kind               string             `json:"kind"`
	Repository         api.RepositoryItem `json:"repository"`
	CronExpression     string             `json:"cron_expression"`
	NextFireAt         string             `json:"next_fire_at"`
	PrPileupPolicy     string             `json:"pr_pileup_policy"`
	AutoApproveMode    string             `json:"auto_approve_mode"`
	Prompt             string             `json:"prompt"`
	ConsecutiveFailure int                `json:"consecutive_failure_count"`
}

type ScheduleJob struct {
	ID            int64  `json:"id"`
	State         string `json:"state"`
	ClosureReason string `json:"closure_reason"`
	PRNumber      int64  `json:"pr_number"`
	ExternalPR    int64  `json:"external_pr_number"`
	CreatedAt     string `json:"created_at"`
}

type CreateScheduleRequest struct {
	ScheduledTask CreateScheduleParams `json:"scheduled_task"`
}

type CreateScheduleParams struct {
	Name           string `json:"name"`
	Kind           string `json:"kind"`
	CronExpression string `json:"cron_expression"`
	PrPileupPolicy string `json:"pr_pileup_policy"`
	Prompt         string `json:"prompt"`
}

type FireScheduleResponse struct {
	Message    string `json:"message"`
	FireResult struct {
		Fired  bool   `json:"fired"`
		JobID  int64  `json:"job_id"`
		Reason string `json:"reason"`
	} `json:"fire_result"`
}

func ListScheduledTasks(ctx context.Context, c *api.Client) (ScheduledTaskList, error) {
	var out ScheduledTaskList
	err := c.Do(ctx, http.MethodGet, "/api/v1/app/scheduled_tasks", nil, &out)
	return out, err
}

func GetScheduledTask(ctx context.Context, c *api.Client, id string) (ScheduledTaskDetail, error) {
	var out ScheduledTaskDetail
	err := c.Do(ctx, http.MethodGet, "/api/v1/app/scheduled_tasks/"+url.PathEscape(id), nil, &out)
	return out, err
}

func CreateScheduledTask(ctx context.Context, c *api.Client, repositoryID int64, params CreateScheduleParams) (ScheduledTaskDetail, error) {
	var out ScheduledTaskDetail
	path := "/api/v1/app/repositories/" + url.PathEscape(strconv.FormatInt(repositoryID, 10)) + "/scheduled_tasks"
	err := c.Do(ctx, http.MethodPost, path, CreateScheduleRequest{ScheduledTask: params}, &out)
	return out, err
}

func DeleteScheduledTask(ctx context.Context, c *api.Client, id string) error {
	return c.Do(ctx, http.MethodDelete, "/api/v1/app/scheduled_tasks/"+url.PathEscape(id), nil, nil)
}

func FireScheduledTask(ctx context.Context, c *api.Client, id string) (FireScheduleResponse, error) {
	var out FireScheduleResponse
	err := c.Do(ctx, http.MethodPost, "/api/v1/app/scheduled_tasks/"+url.PathEscape(id)+"/fire_now", nil, &out)
	return out, err
}
