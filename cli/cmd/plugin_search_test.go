package cmd

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPluginSearchPrintsCompatibleResultsWithTrust(t *testing.T) {
	server := pluginRegistryServer(t)
	defer server.Close()
	t.Setenv("SYRUS_PLUGIN_REGISTRY_URL", server.URL)
	pluginRegistryCacheDir = func() (string, error) { return t.TempDir(), nil }
	pluginRegistryHTTP = server.Client()
	t.Cleanup(func() {
		pluginRegistryCacheDir = os.UserCacheDir
		pluginRegistryHTTP = &http.Client{Timeout: 30 * time.Second}
	})
	command := NewRootCommand()
	var output strings.Builder
	command.SetOut(&output)
	command.SetArgs([]string{"plugin", "search", "weather"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "acme_weather\t1.2.3\tverified\tautomation\tWeather tools") {
		t.Fatalf("output = %q", output.String())
	}
	if strings.Contains(output.String(), "acme_future") {
		t.Fatalf("incompatible result was printed: %q", output.String())
	}
}

func TestPluginRegistryClientFiltersIncompatibleAndRevokedEntries(t *testing.T) {
	server := pluginRegistryServer(t)
	defer server.Close()
	pluginRegistryCacheDir = func() (string, error) { return t.TempDir(), nil }
	pluginRegistryHTTP = server.Client()
	t.Cleanup(func() {
		pluginRegistryCacheDir = os.UserCacheDir
		pluginRegistryHTTP = &http.Client{Timeout: 30 * time.Second}
	})

	entries, err := (pluginRegistryClient{URL: server.URL, SyrusVersion: "2.0.0"}).search(t.Context(), "")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name != "acme_weather" {
		t.Fatalf("entries = %#v", entries)
	}
}

func TestPluginRegistryClientUsesConditionalCache(t *testing.T) {
	requests := 0
	server := pluginRegistryServerWithIndexHook(t, func(r *http.Request, w http.ResponseWriter) bool {
		requests++
		if requests == 2 {
			if r.Header.Get("If-None-Match") != `"v1"` {
				t.Fatalf("If-None-Match = %q", r.Header.Get("If-None-Match"))
			}
			w.WriteHeader(http.StatusNotModified)
			return true
		}
		return false
	})
	defer server.Close()
	directory := t.TempDir()
	pluginRegistryCacheDir = func() (string, error) { return directory, nil }
	pluginRegistryHTTP = server.Client()
	pluginRegistryNow = func() time.Time { return time.Unix(int64(requests)*600, 0) }
	t.Cleanup(func() {
		pluginRegistryCacheDir = os.UserCacheDir
		pluginRegistryNow = time.Now
		pluginRegistryHTTP = &http.Client{Timeout: 30 * time.Second}
	})
	client := pluginRegistryClient{URL: server.URL, SyrusVersion: "2.0.0"}
	if _, err := client.search(t.Context(), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := client.search(t.Context(), ""); err != nil {
		t.Fatal(err)
	}
}

func TestPluginRegistryClientReadsFreshGitCacheWithoutPulling(t *testing.T) {
	directory := t.TempDir()
	pluginRegistryCacheDir = func() (string, error) { return directory, nil }
	pluginRegistryNow = time.Now
	called := false
	pluginRegistryCommand = func(context.Context, string, ...string) *exec.Cmd { called = true; return exec.Command("false") }
	t.Cleanup(func() { pluginRegistryCacheDir = os.UserCacheDir; pluginRegistryCommand = exec.CommandContext })
	client := pluginRegistryClient{URL: "git+https://registry.example.test/plugins.git", SyrusVersion: "2.0.0"}
	root, err := registryCachePath(client.URL, "git")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "acme_weather"), 0700); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"index.json":              `{"format_version":1,"trust_store":"trust-store.json","releases":["acme_weather/1.2.3.json"]}`,
		"trust-store.json":        `{"publishers":[{"fingerprint":"abc","label":"verified"}]}`,
		"acme_weather/1.2.3.json": registryReleaseJSON("acme_weather", "1.2.3", ">= 1.0", "abc", "Weather tools"),
	}
	for path, body := range files {
		if err := os.WriteFile(filepath.Join(root, filepath.FromSlash(path)), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, ".syrus-refreshed-at"), nil, 0600); err != nil {
		t.Fatal(err)
	}

	entries, err := client.search(t.Context(), "weather")
	if err != nil {
		t.Fatal(err)
	}
	if called || len(entries) != 1 {
		t.Fatalf("called = %v, entries = %#v", called, entries)
	}
}

func TestPluginSearchExplainsUnconfiguredRegistry(t *testing.T) {
	t.Setenv("SYRUS_PLUGIN_REGISTRY_URL", "")
	command := NewRootCommand()
	var output strings.Builder
	command.SetOut(&output)
	command.SetArgs([]string{"plugin", "search"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "No plugin registry is configured") {
		t.Fatalf("output = %q", output.String())
	}
}

func pluginRegistryServer(t *testing.T) *httptest.Server {
	return pluginRegistryServerWithIndexHook(t, nil)
}

func pluginRegistryServerWithIndexHook(t *testing.T, hook func(*http.Request, http.ResponseWriter) bool) *httptest.Server {
	t.Helper()
	files := map[string]string{
		"/index.json":              `{"format_version":1,"trust_store":"trust-store.json","releases":["acme_weather/1.2.3.json","acme_future/3.0.0.json","acme_revoked/1.0.0.json"]}`,
		"/trust-store.json":        `{"publishers":[{"fingerprint":"abc","label":"verified"}],"revoked_keys":["revoked"]}`,
		"/acme_weather/1.2.3.json": registryReleaseJSON("acme_weather", "1.2.3", ">= 0", "abc", "Weather tools"),
		"/acme_future/3.0.0.json":  registryReleaseJSON("acme_future", "3.0.0", ">= 3.0", "abc", "Future tools"),
		"/acme_revoked/1.0.0.json": registryReleaseJSON("acme_revoked", "1.0.0", ">= 1.0", "revoked", "Revoked tools"),
	}
	return httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/index.json" && hook != nil && hook(r, w) {
			return
		}
		body, ok := files[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		if r.URL.Path == "/index.json" {
			w.Header().Set("ETag", `"v1"`)
		}
		_, _ = io.WriteString(w, body)
	}))
}

func registryReleaseJSON(name, version, requirement, fingerprint, description string) string {
	return fmt.Sprintf(`{"name":%q,"version":%q,"description":%q,"category":"automation","author":"Acme","homepage":"https://example.test","license":"MIT","requires_syrus":%q,"package_url":"https://example.test/package.tgz","package_digest":"sha256:0000","signature_url":"https://example.test/package.sig","publisher_key_fingerprint":%q,"trust_label_inputs":{},"capability_summary":{}}`, name, version, description, requirement, fingerprint)
}
