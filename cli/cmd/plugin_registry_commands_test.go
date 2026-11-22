package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/internal/config"
)

type fakePluginRegistryAPI struct {
	registries []configuredPluginRegistry
	catalog    pluginRegistryCatalog
	err        error
	added      bool
	enabled    *bool
	removed    bool
	term       string
	filter     string
}

func (api *fakePluginRegistryAPI) List(context.Context) ([]configuredPluginRegistry, error) {
	return api.registries, api.err
}
func (api *fakePluginRegistryAPI) Add(context.Context, string, string) (configuredPluginRegistry, error) {
	api.added = true
	if len(api.registries) == 0 {
		return configuredPluginRegistry{}, api.err
	}
	return api.registries[0], api.err
}
func (api *fakePluginRegistryAPI) SetEnabled(_ context.Context, _ int, enabled bool) (configuredPluginRegistry, error) {
	api.enabled = &enabled
	return api.registries[0], api.err
}
func (api *fakePluginRegistryAPI) Remove(context.Context, int) error {
	api.removed = true
	return api.err
}
func (api *fakePluginRegistryAPI) Search(_ context.Context, term, registry string) (pluginRegistryCatalog, error) {
	api.term, api.filter = term, registry
	return api.catalog, api.err
}

func useFakePluginRegistryAPI(t *testing.T, api pluginRegistryAPI) {
	t.Helper()
	writePluginTestCredentials(t, "https://syrus.example.test")
	previous := newPluginRegistryAPI
	newPluginRegistryAPI = func(config.Credentials) pluginRegistryAPI { return api }
	t.Cleanup(func() { newPluginRegistryAPI = previous })
}

func TestPluginRegistryListSupportsTextAndJSON(t *testing.T) {
	api := &fakePluginRegistryAPI{registries: []configuredPluginRegistry{{ID: 1, Name: "canonical", URL: canonicalPluginRegistryURL, Canonical: true, Enabled: true, Healthy: true}}}
	useFakePluginRegistryAPI(t, api)
	for _, jsonOutput := range []bool{false, true} {
		command := NewRootCommand()
		var output strings.Builder
		command.SetOut(&output)
		args := []string{"plugin", "registry", "list"}
		if jsonOutput {
			args = append(args, "--json")
		}
		command.SetArgs(args)
		if err := command.Execute(); err != nil {
			t.Fatal(err)
		}
		if jsonOutput {
			var decoded []configuredPluginRegistry
			if err := json.Unmarshal([]byte(output.String()), &decoded); err != nil || len(decoded) != 1 {
				t.Fatalf("JSON output=%q error=%v", output.String(), err)
			}
		} else if !strings.Contains(output.String(), "canonical\t"+canonicalPluginRegistryURL+"\ttrue\ttrue\thealthy") {
			t.Fatalf("output=%q", output.String())
		}
	}
}

func TestPluginRegistryAddRequiresConfirmationAndPrintsTrustNotice(t *testing.T) {
	api := &fakePluginRegistryAPI{registries: []configuredPluginRegistry{{Name: "partners", URL: "https://partners.example.test"}}}
	useFakePluginRegistryAPI(t, api)
	command := NewRootCommand()
	var output strings.Builder
	command.SetOut(&output)
	command.SetIn(strings.NewReader("n\n"))
	command.SetArgs([]string{"plugin", "registry", "add", "https://partners.example.test", "--name", "partners"})
	if err := command.Execute(); err == nil || !strings.Contains(err.Error(), "not confirmed") {
		t.Fatalf("error=%v", err)
	}
	if api.added || !strings.Contains(output.String(), pluginRegistryTrustNotice) {
		t.Fatalf("added=%v output=%q", api.added, output.String())
	}

	command = NewRootCommand()
	command.SetOut(io.Discard)
	command.SetArgs([]string{"plugin", "registry", "add", "https://partners.example.test", "--name", "partners", "--yes"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !api.added {
		t.Fatal("registry was not added")
	}
}

func TestPluginRegistryCommandsExplainAdminRequirement(t *testing.T) {
	api := &fakePluginRegistryAPI{err: errors.New("plugin registry administration requires an administrator (403 Forbidden)")}
	useFakePluginRegistryAPI(t, api)
	command := NewRootCommand()
	command.SetArgs([]string{"plugin", "registry", "list"})
	if err := command.Execute(); err == nil || !strings.Contains(err.Error(), "requires an administrator") {
		t.Fatalf("error=%v", err)
	}
}

func TestPluginRegistryEnableDisableAndRemove(t *testing.T) {
	for _, test := range []struct {
		args    []string
		enabled *bool
		removed bool
	}{
		{args: []string{"enable", "partners"}, enabled: boolPointer(true)},
		{args: []string{"disable", "2"}, enabled: boolPointer(false)},
		{args: []string{"remove", "partners"}, removed: true},
	} {
		api := &fakePluginRegistryAPI{registries: []configuredPluginRegistry{{ID: 2, Name: "partners"}}}
		useFakePluginRegistryAPI(t, api)
		command := NewRootCommand()
		command.SetOut(io.Discard)
		command.SetArgs(append([]string{"plugin", "registry"}, test.args...))
		if err := command.Execute(); err != nil {
			t.Fatal(err)
		}
		if test.enabled != nil && (api.enabled == nil || *api.enabled != *test.enabled) {
			t.Fatalf("args=%v enabled=%v", test.args, api.enabled)
		}
		if api.removed != test.removed {
			t.Fatalf("args=%v removed=%v", test.args, api.removed)
		}
	}
}

func boolPointer(value bool) *bool { return &value }

func TestPluginSearchUsesConnectedCatalogAndRegistryFilter(t *testing.T) {
	api := &fakePluginRegistryAPI{catalog: pluginRegistryCatalog{Entries: []pluginCatalogEntry{{Name: "acme_weather", Version: "1.0.0", RegistryName: "partners", TrustLabel: "verified"}}}}
	useFakePluginRegistryAPI(t, api)
	command := NewRootCommand()
	var output strings.Builder
	command.SetOut(&output)
	command.SetArgs([]string{"plugin", "search", "weather", "--registry", "partners"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if api.term != "weather" || api.filter != "partners" || !strings.Contains(output.String(), "partners") {
		t.Fatalf("term=%q filter=%q output=%q", api.term, api.filter, output.String())
	}
}

func TestGitHubRepositoryForRegistry(t *testing.T) {
	repository, err := githubRepositoryForRegistry(configuredPluginRegistry{Name: "canonical", URL: canonicalPluginRegistryURL})
	if err != nil || repository != "tkadauke/syrus-plugins" {
		t.Fatalf("repository=%q error=%v", repository, err)
	}
	_, err = githubRepositoryForRegistry(configuredPluginRegistry{Name: "mirror", URL: "https://registry.example.test"})
	if err == nil || !strings.Contains(err.Error(), "--index-repository") {
		t.Fatalf("error=%v", err)
	}
}
