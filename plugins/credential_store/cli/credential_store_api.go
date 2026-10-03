package credentialstore

import (
	"context"
	"net/http"
	"net/url"
	"strconv"

	"github.com/tkadauke/syrus/cli/pkg/api"
)

const credentialsPath = "/api/v1/app/credential_store/credentials"
const leasesPath = "/api/v1/app/credential_store/leases"
const sshAgentPath = "/api/v1/app/credential_store/ssh_agent"
const sshAgentAuditPath = "/api/v1/app/credential_store/ssh_agent/audit"

type CredentialType struct {
	Name        string `json:"name"`
	Label       string `json:"label"`
	Description string `json:"description"`
	Plugin      string `json:"plugin"`
}

type Credential struct {
	ID                int64          `json:"id"`
	Name              string         `json:"name"`
	Description       string         `json:"description"`
	CredentialType    string         `json:"credential_type"`
	ScopeType         string         `json:"scope_type"`
	ScopeID           int64          `json:"scope_id"`
	ScopeLabel        string         `json:"scope_label"`
	SafeMetadata      map[string]any `json:"safe_metadata"`
	TargetConstraints map[string]any `json:"target_constraints"`
	AllowedSurfaces   []string       `json:"allowed_surfaces"`
	AllowedTools      []string       `json:"allowed_tools"`
	ExpiresAt         string         `json:"expires_at"`
	RevokedAt         string         `json:"revoked_at"`
	Active            bool           `json:"active"`
}

type CredentialOptions struct {
	CredentialTypes []CredentialType `json:"credential_types"`
}

type CredentialList struct {
	Credentials []Credential      `json:"credentials"`
	Options     CredentialOptions `json:"options"`
}

func ListCredentials(ctx context.Context, c *api.Client) (CredentialList, error) {
	var out CredentialList
	err := c.Do(ctx, http.MethodGet, credentialsPath, nil, &out)
	return out, err
}

func GetCredential(ctx context.Context, c *api.Client, id string) (struct {
	Credential Credential        `json:"credential"`
	Options    CredentialOptions `json:"options"`
}, error) {
	var out struct {
		Credential Credential        `json:"credential"`
		Options    CredentialOptions `json:"options"`
	}
	err := c.Do(ctx, http.MethodGet, credentialsPath+"/"+url.PathEscape(id), nil, &out)
	return out, err
}

type LeaseRequest struct {
	Lease LeaseRequestBody `json:"lease"`
}

type LeaseRequestBody struct {
	Credential string         `json:"credential"`
	Type       string         `json:"type"`
	Purpose    string         `json:"purpose"`
	ToolName   string         `json:"tool_name,omitempty"`
	Target     map[string]any `json:"target,omitempty"`
	ExpiresIn  int            `json:"expires_in,omitempty"`
}

type LeaseResponse struct {
	Lease Lease `json:"lease"`
}

type Lease struct {
	LeaseID           string         `json:"lease_id"`
	CredentialID      int64          `json:"credential_id"`
	CredentialName    string         `json:"credential_name"`
	CredentialType    string         `json:"credential_type"`
	IssuedAt          string         `json:"issued_at"`
	ExpiresAt         string         `json:"expires_at"`
	Purpose           string         `json:"purpose"`
	ToolName          string         `json:"tool_name"`
	SafeMetadata      map[string]any `json:"safe_metadata"`
	TargetConstraints map[string]any `json:"target_constraints"`
}

func RequestLease(ctx context.Context, c *api.Client, input LeaseRequestBody) (LeaseResponse, error) {
	var out LeaseResponse
	err := c.Do(ctx, http.MethodPost, leasesPath, LeaseRequest{Lease: input}, &out)
	return out, err
}

type SSHAgentMaterialRequest struct {
	SSHAgent SSHAgentMaterialRequestBody `json:"ssh_agent"`
}

type SSHAgentMaterialRequestBody struct {
	Credential string         `json:"credential"`
	Purpose    string         `json:"purpose,omitempty"`
	ToolName   string         `json:"tool_name,omitempty"`
	Target     map[string]any `json:"target,omitempty"`
	ExpiresIn  int            `json:"expires_in,omitempty"`
}

type SSHAgentMaterialResponse struct {
	Lease  Lease      `json:"lease"`
	SSHKey SSHKeyData `json:"ssh_key"`
}

type SSHKeyData struct {
	PrivateKey string `json:"private_key"`
	Passphrase string `json:"passphrase"`
}

func RequestSSHAgentMaterial(ctx context.Context, c interface {
	Do(context.Context, string, string, any, any) error
}, input SSHAgentMaterialRequestBody) (SSHAgentMaterialResponse, error) {
	var out SSHAgentMaterialResponse
	err := c.Do(ctx, http.MethodPost, sshAgentPath, SSHAgentMaterialRequest{SSHAgent: input}, &out)
	return out, err
}

type SSHAgentAuditRequest struct {
	SSHAgentAudit SSHAgentAuditRequestBody `json:"ssh_agent_audit"`
}

type SSHAgentAuditRequestBody struct {
	Credential string `json:"credential"`
	LeaseID    string `json:"lease_id,omitempty"`
	Purpose    string `json:"purpose,omitempty"`
	ToolName   string `json:"tool_name,omitempty"`
	ExitStatus int    `json:"exit_status"`
	DurationMS int64  `json:"duration_ms"`
}

func RecordSSHAgentAudit(ctx context.Context, c interface {
	Do(context.Context, string, string, any, any) error
}, input SSHAgentAuditRequestBody) error {
	return c.Do(ctx, http.MethodPost, sshAgentAuditPath, SSHAgentAuditRequest{SSHAgentAudit: input}, nil)
}

func credentialRef(credential Credential) string {
	if credential.Name != "" {
		return credential.Name
	}
	return strconv.FormatInt(credential.ID, 10)
}
