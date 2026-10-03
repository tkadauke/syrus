package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

type Client struct {
	baseURL          *url.URL
	token            string
	httpClient       *http.Client
	unauthorizedHint string
}

var apiIDPattern = regexp.MustCompile(`^[0-9]+$`)

type Error struct {
	StatusCode int
	Message    string
}

func (e *Error) Error() string {
	return e.Message
}

func NewClient(baseURL string, token string) (*Client, error) {
	return NewClientWithOptions(baseURL, token, ClientOptions{})
}

type ClientOptions struct {
	InternalAuth bool
}

func NewClientWithOptions(baseURL string, token string, options ClientOptions) (*Client, error) {
	parsed, err := url.Parse(strings.TrimSpace(baseURL))
	if err != nil {
		return nil, err
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return nil, errors.New("Syrus instance URL must include scheme and host")
	}
	if strings.TrimSpace(token) == "" {
		return nil, errors.New("API token is required")
	}
	hint := "Your saved token may be stale — run 'syrus login' to refresh it."
	if options.InternalAuth {
		hint = "The Syrus invocation context was rejected or expired; check the worker runtime configuration."
	}

	return &Client{
		baseURL: parsed,
		token:   strings.TrimSpace(token),
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		unauthorizedHint: hint,
	}, nil
}

func (c *Client) newRequest(ctx context.Context, method string, path string, body io.Reader) (*http.Request, error) {
	relative, err := url.Parse(path)
	if err != nil {
		return nil, err
	}
	endpoint := c.baseURL.ResolveReference(relative)
	req, err := http.NewRequestWithContext(ctx, method, endpoint.String(), body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("X-Syrus-CLI-Command", commandNamespace(method, relative))
	return req, nil
}

// Do performs an authenticated JSON request against the Syrus instance.
//
// Exported because plugin CLI modules live outside this module and cannot
// reach unexported helpers: it is the whole request surface a plugin command
// needs, so a plugin does not reimplement auth, profiles, or error decoding.
func (c *Client) Do(ctx context.Context, method string, path string, input any, output any) error {
	return c.do(ctx, method, path, input, output)
}

func (c *Client) do(ctx context.Context, method string, path string, input any, output any) error {
	var body io.Reader
	if input != nil {
		payload, err := json.Marshal(input)
		if err != nil {
			return err
		}
		body = bytes.NewReader(payload)
	}

	req, err := c.newRequest(ctx, method, path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	if input != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("network error: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return c.responseError(resp)
	}

	if output == nil || resp.StatusCode == http.StatusNoContent {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(output)
}

func (c *Client) responseError(resp *http.Response) error {
	var payload struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	message := resp.Status
	if err := json.NewDecoder(resp.Body).Decode(&payload); err == nil && payload.Error.Message != "" {
		message = payload.Error.Message
	}

	// The server's bare "Sign in to use the app API." gives no path forward;
	// a stale token (e.g. the instance's database was rebuilt) is by far the
	// most common cause.
	if resp.StatusCode == http.StatusUnauthorized {
		message += " " + c.unauthorizedHint
	}

	return &Error{StatusCode: resp.StatusCode, Message: message}
}

func commandNamespace(method string, endpoint *url.URL) string {
	parts := strings.Split(strings.Trim(endpoint.Path, "/"), "/")
	if len(parts) >= 3 && parts[0] == "api" && parts[1] == "v1" {
		parts = parts[3:]
	}
	cleaned := make([]string, 0, len(parts)+1)
	cleaned = append(cleaned, strings.ToLower(method))
	for _, part := range parts {
		if part == "" || apiIDPattern.MatchString(part) {
			continue
		}
		cleaned = append(cleaned, part)
	}
	return strings.Join(cleaned, ".")
}
