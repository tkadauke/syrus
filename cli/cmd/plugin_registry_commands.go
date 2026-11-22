package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
)

const (
	canonicalPluginRegistryURL = "https://github.com/tkadauke/syrus-plugins"
	pluginRegistryTrustNotice  = "Publisher trust labels apply only within this registry and are capped below Official. Plugin capability manifests are disclosure, not enforcement."
)

type configuredPluginRegistry struct {
	ID        int     `json:"id"`
	Name      string  `json:"name"`
	URL       string  `json:"url"`
	Canonical bool    `json:"canonical"`
	Enabled   bool    `json:"enabled"`
	Healthy   bool    `json:"healthy"`
	ReadOnly  bool    `json:"read_only"`
	Error     *string `json:"error"`
}
type pluginRegistryCatalog struct {
	Entries []pluginCatalogEntry `json:"entries"`
	Errors  map[string]string    `json:"errors"`
}
type pluginRegistryAPI interface {
	List(context.Context) ([]configuredPluginRegistry, error)
	Add(context.Context, string, string) (configuredPluginRegistry, error)
	SetEnabled(context.Context, int, bool) (configuredPluginRegistry, error)
	Remove(context.Context, int) error
	Search(context.Context, string, string) (pluginRegistryCatalog, error)
}

var newPluginRegistryAPI = func(creds config.Credentials) pluginRegistryAPI {
	return &httpPluginRegistryAPI{credentials: creds, client: http.DefaultClient}
}

type httpPluginRegistryAPI struct {
	credentials config.Credentials
	client      *http.Client
}

func (api *httpPluginRegistryAPI) request(ctx context.Context, method, path string, body any, target any) error {
	var reader io.Reader
	if body != nil {
		payload, _ := json.Marshal(body)
		reader = bytes.NewReader(payload)
	}
	request, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(api.credentials.URL, "/")+path, reader)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+api.credentials.Token)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := api.client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		message, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		if response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusUnauthorized {
			return fmt.Errorf("plugin registry administration requires an administrator (%s): %s", response.Status, strings.TrimSpace(string(message)))
		}
		return fmt.Errorf("plugin registry request failed (%s): %s", response.Status, strings.TrimSpace(string(message)))
	}
	if target == nil || response.StatusCode == http.StatusNoContent {
		return nil
	}
	return json.NewDecoder(response.Body).Decode(target)
}
func (api *httpPluginRegistryAPI) List(ctx context.Context) ([]configuredPluginRegistry, error) {
	var p struct {
		Registries []configuredPluginRegistry `json:"registries"`
	}
	err := api.request(ctx, http.MethodGet, "/api/v1/app/admin/plugin_installer/registries", nil, &p)
	return p.Registries, err
}
func (api *httpPluginRegistryAPI) Add(ctx context.Context, name, registryURL string) (configuredPluginRegistry, error) {
	var r configuredPluginRegistry
	err := api.request(ctx, http.MethodPost, "/api/v1/app/admin/plugin_installer/registries", map[string]string{"name": name, "url": registryURL}, &r)
	return r, err
}
func (api *httpPluginRegistryAPI) SetEnabled(ctx context.Context, id int, enabled bool) (configuredPluginRegistry, error) {
	var r configuredPluginRegistry
	err := api.request(ctx, http.MethodPatch, fmt.Sprintf("/api/v1/app/admin/plugin_installer/registries/%d", id), map[string]bool{"enabled": enabled}, &r)
	return r, err
}
func (api *httpPluginRegistryAPI) Remove(ctx context.Context, id int) error {
	return api.request(ctx, http.MethodDelete, fmt.Sprintf("/api/v1/app/admin/plugin_installer/registries/%d", id), nil, nil)
}
func (api *httpPluginRegistryAPI) Search(ctx context.Context, term, registry string) (pluginRegistryCatalog, error) {
	q := url.Values{}
	if term != "" {
		q.Set("q", term)
	}
	if registry != "" {
		q.Set("registry", registry)
	}
	path := "/api/v1/app/admin/plugin_installer/catalog"
	if q.Encode() != "" {
		path += "?" + q.Encode()
	}
	var c pluginRegistryCatalog
	err := api.request(ctx, http.MethodGet, path, nil, &c)
	return c, err
}

func newPluginRegistryCommand() *cobra.Command {
	c := &cobra.Command{Use: "registry", Short: "Manage plugin registries on the connected instance"}
	c.AddCommand(newPluginRegistryListCommand(), newPluginRegistryAddCommand(), newPluginRegistryStateCommand("enable", true), newPluginRegistryStateCommand("disable", false), newPluginRegistryRemoveCommand())
	return c
}
func registryAPI() (pluginRegistryAPI, error) {
	creds, err := loadCredentials()
	if err != nil {
		return nil, err
	}
	return newPluginRegistryAPI(creds), nil
}
func newPluginRegistryListCommand() *cobra.Command {
	var jsonOutput bool
	c := &cobra.Command{Use: "list", Short: "List configured plugin registries", Args: cobra.NoArgs, RunE: func(command *cobra.Command, _ []string) error {
		api, err := registryAPI()
		if err != nil {
			return err
		}
		registries, err := api.List(command.Context())
		if err != nil {
			return err
		}
		if jsonOutput {
			return json.NewEncoder(command.OutOrStdout()).Encode(registries)
		}
		fmt.Fprintln(command.OutOrStdout(), "NAME\tURL\tCANONICAL\tENABLED\tHEALTH")
		for _, r := range registries {
			health := "unhealthy"
			if r.Healthy {
				health = "healthy"
			}
			fmt.Fprintf(command.OutOrStdout(), "%s\t%s\t%t\t%t\t%s\n", r.Name, r.URL, r.Canonical, r.Enabled, health)
		}
		return nil
	}}
	c.Flags().BoolVar(&jsonOutput, "json", false, "Print registries as JSON")
	return c
}
func newPluginRegistryAddCommand() *cobra.Command {
	var name string
	var yes bool
	c := &cobra.Command{Use: "add URL", Short: "Add a plugin registry", Args: cobra.ExactArgs(1), RunE: func(command *cobra.Command, args []string) error {
		registryURL := args[0]
		if name == "" {
			parsed, err := url.Parse(strings.TrimPrefix(registryURL, "git+"))
			if err != nil || parsed.Hostname() == "" {
				return fmt.Errorf("--name is required when a registry name cannot be derived from its URL")
			}
			name = "registry-" + strings.Trim(strings.Map(func(ch rune) rune {
				if ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' {
					return ch
				}
				return '-'
			}, strings.ToLower(parsed.Hostname())), "-")
		}
		fmt.Fprintln(command.OutOrStdout(), pluginRegistryTrustNotice)
		if !yes {
			fmt.Fprint(command.OutOrStdout(), "Add this plugin registry? [y/N] ")
			var answer string
			_, _ = fmt.Fscanln(command.InOrStdin(), &answer)
			if !confirmed(answer) {
				return fmt.Errorf("registry addition was not confirmed")
			}
		}
		api, err := registryAPI()
		if err != nil {
			return err
		}
		r, err := api.Add(command.Context(), name, registryURL)
		if err == nil {
			fmt.Fprintf(command.OutOrStdout(), "Added plugin registry %s (%s).\n", r.Name, r.URL)
		}
		return err
	}}
	c.Flags().StringVar(&name, "name", "", "Registry name")
	c.Flags().BoolVar(&yes, "yes", false, "Confirm without prompting")
	return c
}
func newPluginRegistryStateCommand(action string, enabled bool) *cobra.Command {
	return &cobra.Command{Use: action + " NAME|ID", Short: strings.ToUpper(action[:1]) + action[1:] + " a plugin registry", Args: cobra.ExactArgs(1), RunE: func(command *cobra.Command, args []string) error {
		api, r, err := findConfiguredRegistry(command.Context(), args[0])
		if err != nil {
			return err
		}
		updated, err := api.SetEnabled(command.Context(), r.ID, enabled)
		if err == nil {
			fmt.Fprintf(command.OutOrStdout(), "%s plugin registry %s.\n", strings.ToUpper(action[:1])+action[1:], updated.Name)
		}
		return err
	}}
}
func newPluginRegistryRemoveCommand() *cobra.Command {
	return &cobra.Command{Use: "remove NAME|ID", Short: "Remove a plugin registry", Args: cobra.ExactArgs(1), RunE: func(command *cobra.Command, args []string) error {
		api, r, err := findConfiguredRegistry(command.Context(), args[0])
		if err != nil {
			return err
		}
		if err := api.Remove(command.Context(), r.ID); err != nil {
			return err
		}
		fmt.Fprintf(command.OutOrStdout(), "Removed plugin registry %s.\n", r.Name)
		return nil
	}}
}
func findConfiguredRegistry(ctx context.Context, reference string) (pluginRegistryAPI, configuredPluginRegistry, error) {
	api, err := registryAPI()
	if err != nil {
		return nil, configuredPluginRegistry{}, err
	}
	registries, err := api.List(ctx)
	if err != nil {
		return nil, configuredPluginRegistry{}, err
	}
	for _, r := range registries {
		if r.Name == reference || fmt.Sprint(r.ID) == reference {
			return api, r, nil
		}
	}
	return nil, configuredPluginRegistry{}, fmt.Errorf("plugin registry %q was not found", reference)
}
func githubRepositoryForRegistry(registry configuredPluginRegistry) (string, error) {
	parsed, err := url.Parse(strings.TrimSuffix(strings.TrimPrefix(registry.URL, "git+"), ".git"))
	if err != nil || !strings.EqualFold(parsed.Hostname(), "github.com") {
		return "", fmt.Errorf("plugin registry %q is not a GitHub repository; pass --index-repository OWNER/REPO with explicit submission instructions", registry.Name)
	}
	parts := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", fmt.Errorf("plugin registry %q is not a GitHub repository; pass --index-repository OWNER/REPO with explicit submission instructions", registry.Name)
	}
	return parts[0] + "/" + parts[1], nil
}
