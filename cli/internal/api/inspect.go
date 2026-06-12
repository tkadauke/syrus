package api

import (
	"context"
	"net/http"
	"net/url"
)

type EpicList struct {
	Count int        `json:"count"`
	Epics []EpicItem `json:"epics"`
}

type EpicItem struct {
	ID             int64     `json:"id"`
	Number         int64     `json:"number"`
	Title          string    `json:"title"`
	State          string    `json:"state"`
	RepositorySlug string    `json:"repository_slug"`
	DoneJobsCount  int       `json:"done_jobs_count"`
	TotalJobsCount int       `json:"total_jobs_count"`
	Jobs           []JobItem `json:"jobs"`
}

type EpicDetail struct {
	Epic EpicItem  `json:"epic"`
	Jobs []JobItem `json:"jobs"`
}

type RepositoryList struct {
	Repositories []RepositoryItem `json:"repositories"`
}

type RepositoryItem struct {
	ID              int64    `json:"id"`
	Slug            string   `json:"slug"`
	Archived        bool     `json:"archived"`
	ActiveJobsCount int      `json:"active_jobs_count"`
	LastJob         *JobItem `json:"last_job"`
}

type Bootstrap struct {
	Whoami struct {
		Email       string `json:"email"`
		TokenSuffix string `json:"token_suffix"`
	} `json:"whoami"`
}

func (c *Client) ListEpics(ctx context.Context, filters url.Values) (EpicList, error) {
	var out EpicList
	path := "/api/v1/app/epics"
	if encoded := filters.Encode(); encoded != "" {
		path += "?" + encoded
	}
	err := c.do(ctx, http.MethodGet, path, nil, &out)
	return out, err
}

func (c *Client) GetEpic(ctx context.Context, id string) (EpicDetail, error) {
	var out EpicDetail
	err := c.do(ctx, http.MethodGet, "/api/v1/app/epics/"+url.PathEscape(id), nil, &out)
	return out, err
}

func (c *Client) ListRepositories(ctx context.Context) (RepositoryList, error) {
	var out RepositoryList
	err := c.do(ctx, http.MethodGet, "/api/v1/app/repositories", nil, &out)
	return out, err
}

func (c *Client) Whoami(ctx context.Context) (Bootstrap, error) {
	var out Bootstrap
	err := c.do(ctx, http.MethodGet, "/api/v1/app/bootstrap", nil, &out)
	return out, err
}
