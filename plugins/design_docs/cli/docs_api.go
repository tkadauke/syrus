package designdocs

import (
	"context"
	"net/http"
	"net/url"
	"strconv"

	"github.com/tkadauke/syrus/cli/pkg/api"
)

const designDocsPath = "/api/v1/app/design_docs"

type DesignDocOwner struct {
	ID           int64  `json:"id"`
	Name         string `json:"name"`
	EmailAddress string `json:"email_address"`
}

type DesignDocRepository struct {
	ID   int64  `json:"id"`
	Slug string `json:"slug"`
}

type DesignDocSummary struct {
	ID                   int64                 `json:"id"`
	DisplayID            string                `json:"display_id"`
	Title                string                `json:"title"`
	Visibility           string                `json:"visibility"`
	State                string                `json:"state"`
	Owner                *DesignDocOwner       `json:"owner"`
	Repositories         []DesignDocRepository `json:"repositories"`
	CurrentVersionNumber *int                  `json:"current_version_number"`
	UpdatedAt            string                `json:"updated_at"`
	CreatedAt            string                `json:"created_at"`
}

type DesignDocDetail struct {
	DesignDocSummary
	RenderedMarkdown string `json:"rendered_markdown"`
}

type DesignDocList struct {
	DesignDocs []DesignDocSummary `json:"design_docs"`
}

type DesignDocShow struct {
	DesignDoc DesignDocDetail `json:"design_doc"`
}

// ListDesignDocs returns every design doc the current user can see,
// unscoped by repository.
func ListDesignDocs(ctx context.Context, c *api.Client) (DesignDocList, error) {
	var out DesignDocList
	err := c.Do(ctx, http.MethodGet, designDocsPath, nil, &out)
	return out, err
}

// ListRepositoryDesignDocs returns design docs attached to one repository.
func ListRepositoryDesignDocs(ctx context.Context, c *api.Client, repositoryID int64) (DesignDocList, error) {
	var out DesignDocList
	path := "/api/v1/app/repositories/" + url.PathEscape(strconv.FormatInt(repositoryID, 10)) + "/design_docs"
	err := c.Do(ctx, http.MethodGet, path, nil, &out)
	return out, err
}

// GetDesignDoc fetches one design doc's detail, including its rendered body.
func GetDesignDoc(ctx context.Context, c *api.Client, id string) (DesignDocShow, error) {
	var out DesignDocShow
	path := designDocsPath + "/" + url.PathEscape(id)
	err := c.Do(ctx, http.MethodGet, path, nil, &out)
	return out, err
}
