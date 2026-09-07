package globalsearch

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"

	"github.com/tkadauke/syrus/cli/pkg/api"
)

const searchPath = "/api/v1/app/search"

// GroupedMatch is an additional matching message folded under a
// representative chat result (see SearchController#grouped_chat_row).
type GroupedMatch struct {
	ID        int64  `json:"id"`
	Snippet   string `json:"snippet"`
	Path      string `json:"path"`
	CreatedAt string `json:"created_at,omitempty"`
}

// Result mirrors one row of the search API's `results` array. Fields that
// only apply to some result types (Slug, State, RepositorySlug, the chat
// grouping fields) are left zero-valued for types that don't set them.
type Result struct {
	Type            string         `json:"type"`
	ID              int64          `json:"id"`
	Slug            string         `json:"slug,omitempty"`
	Title           string         `json:"title"`
	Snippet         string         `json:"snippet"`
	Rank            float64        `json:"rank"`
	Path            string         `json:"path"`
	State           string         `json:"state,omitempty"`
	RepositorySlug  string         `json:"repository_slug,omitempty"`
	CreatedAt       string         `json:"created_at,omitempty"`
	GroupedMatches  []GroupedMatch `json:"grouped_matches,omitempty"`
	TotalMatchCount int            `json:"total_match_count,omitempty"`
	HasMoreMatches  bool           `json:"has_more_matches,omitempty"`
}

// SearchResponse mirrors the endpoint's top-level JSON. Filter and Controls
// are kept as raw JSON: the CLI's text renderer never needs the facet tree,
// but `--json` should still echo the full payload the API returned.
type SearchResponse struct {
	Results  []Result        `json:"results"`
	Filter   json.RawMessage `json:"filter,omitempty"`
	Controls json.RawMessage `json:"controls,omitempty"`
}

// Search calls GET /api/v1/app/search. types and limit are optional: an
// empty types list searches every built-in type, and limit <= 0 leaves the
// server's own default (30, capped at 100) in place.
func Search(ctx context.Context, c *api.Client, query string, types []string, limit int) (SearchResponse, error) {
	var out SearchResponse
	values := url.Values{}
	values.Set("q", query)
	for _, t := range types {
		values.Add("types[]", t)
	}
	if limit > 0 {
		values.Set("limit", strconv.Itoa(limit))
	}
	path := searchPath
	if encoded := values.Encode(); encoded != "" {
		path += "?" + encoded
	}
	err := c.Do(ctx, http.MethodGet, path, nil, &out)
	return out, err
}
