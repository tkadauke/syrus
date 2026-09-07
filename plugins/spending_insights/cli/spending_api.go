package spendinginsights

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"

	"github.com/tkadauke/syrus/cli/pkg/api"
)

const spendingPath = "/api/v1/app/insights/spending"

// Scope mirrors SpendingInsights::Payload#scope_json. Admin is the signal
// the CLI renders as "instance-wide" vs. "your spend" -- non-admins only
// ever see their own totals, admins see every user's.
type Scope struct {
	Admin  bool   `json:"admin"`
	UserID int64  `json:"user_id"`
	Label  string `json:"label"`
}

// AgentProviderOption is one entry of filters.agent_providers.
type AgentProviderOption struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

// Filters mirrors SpendingInsights::Payload#filters_json -- the resolved
// window and any active scoping, echoed back regardless of whether the
// caller passed explicit dates.
type Filters struct {
	StartDate         string                `json:"start_date"`
	EndDate           string                `json:"end_date"`
	DefaultWindowDays int                   `json:"default_window_days"`
	AgentProvider     string                `json:"agent_provider"`
	RepositoryID      *int64                `json:"repository_id"`
	EpicID            *int64                `json:"epic_id"`
	UserID            *int64                `json:"user_id"`
	TriggerKind       string                `json:"trigger_kind"`
	AgentProviders    []AgentProviderOption `json:"agent_providers"`
}

// Totals mirrors SpendingInsights::Payload#totals_json.
type Totals struct {
	WeekUSD               float64 `json:"week_usd"`
	MonthUSD              float64 `json:"month_usd"`
	LifetimeUSD           float64 `json:"lifetime_usd"`
	WorkflowLifetimeUSD   float64 `json:"workflow_lifetime_usd"`
	ChatLifetimeUSD       float64 `json:"chat_lifetime_usd"`
	AverageJob30dUSD      float64 `json:"average_job_30d_usd"`
	AverageMergedPr30dUSD float64 `json:"average_merged_pr_30d_usd"`
}

// BreakdownRow is one row of the epics/users/repositories breakdown arrays
// (SpendingInsights::Payload#breakdown_row). DisplayNumber only appears on
// epic rows; Last30DaysUSD only appears on user rows -- both left nil/empty
// on the others.
type BreakdownRow struct {
	ID            int64    `json:"id"`
	Label         string   `json:"label"`
	Path          string   `json:"path"`
	JobsCount     int      `json:"jobs_count"`
	TotalUSD      float64  `json:"total_usd"`
	AverageJobUSD float64  `json:"average_job_usd"`
	DisplayNumber string   `json:"display_number,omitempty"`
	Last30DaysUSD *float64 `json:"last_30_days_usd,omitempty"`
}

// TriggerKindRow is one row of breakdowns.trigger_kinds
// (SpendingInsights::Payload#trigger_kind_breakdown) -- it has no id/label/
// path, just the trigger kind name, so it gets its own shape.
type TriggerKindRow struct {
	TriggerKind string  `json:"trigger_kind"`
	JobsCount   int     `json:"jobs_count"`
	RunsCount   int     `json:"runs_count"`
	TotalUSD    float64 `json:"total_usd"`
	AverageUSD  float64 `json:"average_usd"`
}

// Breakdowns mirrors SpendingInsights::Payload#as_json's breakdowns key.
// Note: there is no agent_provider breakdown in the API response today --
// agent_provider is only a *filter*, not a groupable dimension.
type Breakdowns struct {
	Epics        []BreakdownRow   `json:"epics"`
	Users        []BreakdownRow   `json:"users"`
	Repositories []BreakdownRow   `json:"repositories"`
	TriggerKinds []TriggerKindRow `json:"trigger_kinds"`
}

// SpendingPayload mirrors the full /api/v1/app/insights/spending response.
// Filter, Controls, TopRuns, and Trend are kept as raw JSON: the CLI's text
// summary never needs the FilterBar AST, the filter-schema controls tree, or
// the per-run/per-day detail, but --json should still echo the full payload
// the API returned (same pattern as the global_search CLI's SearchResponse).
type SpendingPayload struct {
	Scope      Scope           `json:"scope"`
	Filter     json.RawMessage `json:"filter,omitempty"`
	Filters    Filters         `json:"filters"`
	Controls   json.RawMessage `json:"controls,omitempty"`
	Totals     Totals          `json:"totals"`
	Breakdowns Breakdowns      `json:"breakdowns"`
	TopRuns    json.RawMessage `json:"top_runs,omitempty"`
	Trend      json.RawMessage `json:"trend,omitempty"`
}

// GetSpending calls GET /api/v1/app/insights/spending. since/until are
// optional ISO dates (YYYY-MM-DD); when either is blank the server applies
// its own default window (SpendingInsights::Filter::DEFAULT_WINDOW_DAYS).
// Access control is entirely server-side: the endpoint scopes to the
// authenticated user's own spend unless that user is an admin, and this
// client just renders whatever scope the response says it used.
func GetSpending(ctx context.Context, c *api.Client, since string, until string) (SpendingPayload, error) {
	var out SpendingPayload
	values := url.Values{}
	if since != "" {
		values.Set("start_date", since)
	}
	if until != "" {
		values.Set("end_date", until)
	}
	path := spendingPath
	if encoded := values.Encode(); encoded != "" {
		path += "?" + encoded
	}
	err := c.Do(ctx, http.MethodGet, path, nil, &out)
	return out, err
}
