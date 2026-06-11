package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
)

type JobList struct {
	Count int             `json:"count"`
	Jobs  json.RawMessage `json:"jobs"`
}

type JobResponse json.RawMessage

type JobDetail struct {
	ID         int    `json:"id"`
	State      string `json:"state"`
	BranchName string `json:"branch_name"`
	Repository struct {
		Slug string `json:"slug"`
	} `json:"repository"`
}

type CreateJobRequest struct {
	Job CreateJobParams `json:"job"`
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
	path := "/api/v1/admin/jobs"
	if encoded := filters.Encode(); encoded != "" {
		path += "?" + encoded
	}
	err := c.do(ctx, http.MethodGet, path, nil, &out)
	return out, err
}

func (c *Client) GetJob(ctx context.Context, id string) (JobResponse, error) {
	var out json.RawMessage
	err := c.do(ctx, http.MethodGet, "/api/v1/admin/jobs/"+url.PathEscape(id), nil, &out)
	return JobResponse(out), err
}

func (c *Client) GetJobDetail(ctx context.Context, id string) (JobDetail, error) {
	var out JobDetail
	err := c.do(ctx, http.MethodGet, "/api/v1/admin/jobs/"+url.PathEscape(id), nil, &out)
	return out, err
}

func (c *Client) CreateDirectJob(ctx context.Context, params CreateJobParams) (JobResponse, error) {
	var out json.RawMessage
	err := c.do(ctx, http.MethodPost, "/api/v1/admin/jobs", CreateJobRequest{Job: params}, &out)
	return JobResponse(out), err
}
