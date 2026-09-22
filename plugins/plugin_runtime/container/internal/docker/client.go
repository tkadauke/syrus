// Package docker is a minimal Docker Engine API client over the Unix socket.
//
// It is hand-written rather than the Docker SDK so the manager's entire
// trusted surface -- the one process in the stack with daemon access -- stays
// small enough to read in one sitting.
package docker

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"time"
)

// APIError is a non-2xx response from the daemon.
type APIError struct {
	Status  int
	Message string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("docker: %d %s", e.Status, e.Message)
}

// IsNotFound reports whether err is a 404 from the daemon.
func IsNotFound(err error) bool {
	var api *APIError
	return errors.As(err, &api) && api.Status == http.StatusNotFound
}

// IsConflict reports whether err is a 409 from the daemon (e.g. name in use).
func IsConflict(err error) bool {
	var api *APIError
	return errors.As(err, &api) && api.Status == http.StatusConflict
}

// Client talks to the daemon.
type Client struct {
	http *http.Client
}

// New returns a client for the daemon listening on socketPath.
func New(socketPath string) *Client {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, "unix", socketPath)
		},
	}
	// No client-wide timeout: image pulls stream for minutes. Callers bound
	// individual requests with their context instead.
	return &Client{http: &http.Client{Transport: transport}}
}

func (c *Client) do(ctx context.Context, method, path string, query url.Values, body any, out any) error {
	resp, err := c.send(ctx, method, path, query, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if out == nil {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *Client) send(ctx context.Context, method, path string, query url.Values, body any) (*http.Response, error) {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(raw)
	}
	target := "http://docker" + path
	if len(query) > 0 {
		target += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, target, reader)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 200 && resp.StatusCode < 300 || resp.StatusCode == http.StatusNotModified {
		return resp, nil
	}
	defer resp.Body.Close()
	var payload struct {
		Message string `json:"message"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&payload)
	return nil, &APIError{Status: resp.StatusCode, Message: payload.Message}
}

func labelFilter(labels map[string]string) url.Values {
	var pairs []string
	for key, value := range labels {
		pairs = append(pairs, key+"="+value)
	}
	raw, _ := json.Marshal(map[string][]string{"label": pairs})
	return url.Values{"filters": {string(raw)}}
}

// ImageExists reports whether the image is present locally.
func (c *Client) ImageExists(ctx context.Context, ref string) (bool, error) {
	err := c.do(ctx, http.MethodGet, "/images/"+url.PathEscape(ref)+"/json", nil, nil, nil)
	if IsNotFound(err) {
		return false, nil
	}
	return err == nil, err
}

// PullImage pulls an image, reporting aggregate byte progress across layers.
// The daemon streams one JSON object per event; an error mid-stream arrives as
// an object with an "error" field inside a 200 response, so it has to be read
// out of the stream rather than the status code.
func (c *Client) PullImage(ctx context.Context, fromImage, tag string, progress func(current, total int64, status string)) error {
	query := url.Values{"fromImage": {fromImage}}
	if tag != "" {
		query.Set("tag", tag)
	}
	resp, err := c.send(ctx, http.MethodPost, "/images/create", query, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	type layer struct{ current, total int64 }
	layers := map[string]*layer{}
	decoder := json.NewDecoder(resp.Body)
	for {
		var event struct {
			ID             string `json:"id"`
			Status         string `json:"status"`
			Error          string `json:"error"`
			ProgressDetail struct {
				Current int64 `json:"current"`
				Total   int64 `json:"total"`
			} `json:"progressDetail"`
		}
		if err := decoder.Decode(&event); err == io.EOF {
			return nil
		} else if err != nil {
			return err
		}
		if event.Error != "" {
			return errors.New(event.Error)
		}
		if event.ID != "" {
			l := layers[event.ID]
			if l == nil {
				l = &layer{}
				layers[event.ID] = l
			}
			switch event.Status {
			case "Downloading":
				l.current, l.total = event.ProgressDetail.Current, event.ProgressDetail.Total
			case "Download complete", "Pull complete", "Already exists":
				if l.total > 0 {
					l.current = l.total
				}
			}
		}
		if progress != nil {
			var current, total int64
			for _, l := range layers {
				current += l.current
				total += l.total
			}
			progress(current, total, event.Status)
		}
	}
}

// ListContainers returns every container (running or not) carrying all labels.
func (c *Client) ListContainers(ctx context.Context, labels map[string]string) ([]ContainerSummary, error) {
	query := labelFilter(labels)
	query.Set("all", "1")
	var out []ContainerSummary
	return out, c.do(ctx, http.MethodGet, "/containers/json", query, nil, &out)
}

// InspectContainer returns details for one container by id or name.
func (c *Client) InspectContainer(ctx context.Context, id string) (ContainerInspect, error) {
	var out ContainerInspect
	return out, c.do(ctx, http.MethodGet, "/containers/"+url.PathEscape(id)+"/json", nil, nil, &out)
}

// CreateContainer creates a container and returns its id.
func (c *Client) CreateContainer(ctx context.Context, name string, req CreateContainerRequest) (string, error) {
	var out struct {
		ID string `json:"Id"`
	}
	err := c.do(ctx, http.MethodPost, "/containers/create", url.Values{"name": {name}}, req, &out)
	return out.ID, err
}

// StartContainer starts a container. Starting a running container is a no-op.
func (c *Client) StartContainer(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodPost, "/containers/"+url.PathEscape(id)+"/start", nil, nil, nil)
}

// StopContainer stops a container, giving it timeout to exit cleanly.
func (c *Client) StopContainer(ctx context.Context, id string, timeout time.Duration) error {
	query := url.Values{"t": {fmt.Sprint(int(timeout.Seconds()))}}
	return c.do(ctx, http.MethodPost, "/containers/"+url.PathEscape(id)+"/stop", query, nil, nil)
}

// RestartContainer restarts a container, giving it timeout to exit cleanly.
func (c *Client) RestartContainer(ctx context.Context, id string, timeout time.Duration) error {
	query := url.Values{"t": {fmt.Sprint(int(timeout.Seconds()))}}
	return c.do(ctx, http.MethodPost, "/containers/"+url.PathEscape(id)+"/restart", query, nil, nil)
}

// ContainerLogs returns the last `tail` lines of a container's stdout and
// stderr, each prefixed with its timestamp, reading at most maxBytes.
//
// Managed containers run without a TTY, so the daemon multiplexes the two
// streams into frames: an 8-byte header (stream type, three zero bytes, a
// big-endian payload length) followed by the payload. DemuxLogs strips them.
func (c *Client) ContainerLogs(ctx context.Context, id string, tail int, maxBytes int64) (string, error) {
	query := url.Values{
		"stdout":     {"1"},
		"stderr":     {"1"},
		"timestamps": {"1"},
		"tail":       {fmt.Sprint(tail)},
	}
	resp, err := c.send(ctx, http.MethodGet, "/containers/"+url.PathEscape(id)+"/logs", query, nil)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	return DemuxLogs(io.LimitReader(resp.Body, maxBytes))
}

// DemuxLogs turns the daemon's multiplexed log stream into plain text. A
// stream that does not start with a frame header (a TTY container) is
// returned as is.
func DemuxLogs(r io.Reader) (string, error) {
	raw, err := io.ReadAll(r)
	if err != nil {
		return "", err
	}
	if len(raw) < 8 || raw[0] > 2 || raw[1] != 0 || raw[2] != 0 || raw[3] != 0 {
		return string(raw), nil
	}
	var out bytes.Buffer
	for len(raw) >= 8 {
		size := int(binary.BigEndian.Uint32(raw[4:8]))
		raw = raw[8:]
		if size > len(raw) {
			// Cut off by the byte limit: keep what arrived.
			size = len(raw)
		}
		out.Write(raw[:size])
		raw = raw[size:]
	}
	return out.String(), nil
}

// RemoveContainer force-removes a container. Its named volumes are kept.
func (c *Client) RemoveContainer(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodDelete, "/containers/"+url.PathEscape(id), url.Values{"force": {"1"}}, nil, nil)
}

// CreateVolume creates a named volume. Creating one that exists is a no-op.
func (c *Client) CreateVolume(ctx context.Context, name string, labels map[string]string) error {
	body := map[string]any{"Name": name, "Labels": labels}
	return c.do(ctx, http.MethodPost, "/volumes/create", nil, body, nil)
}

// ListVolumes returns volumes carrying all labels.
func (c *Client) ListVolumes(ctx context.Context, labels map[string]string) ([]VolumeSummary, error) {
	var out struct {
		Volumes []VolumeSummary `json:"Volumes"`
	}
	err := c.do(ctx, http.MethodGet, "/volumes", labelFilter(labels), nil, &out)
	return out.Volumes, err
}

// RemoveVolume deletes a named volume.
func (c *Client) RemoveVolume(ctx context.Context, name string) error {
	return c.do(ctx, http.MethodDelete, "/volumes/"+url.PathEscape(name), nil, nil, nil)
}
