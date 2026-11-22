package cmd

import (
	"context"
	"errors"
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
	previousVersion := cliReleaseVersion
	cliReleaseVersion = "2.0.0"
	t.Cleanup(func() {
		pluginRegistryCacheDir = os.UserCacheDir
		pluginRegistryHTTP = &http.Client{Timeout: 30 * time.Second}
		cliReleaseVersion = previousVersion
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

func TestPluginRegistryClientPreservesHTTPMirrorPathPrefix(t *testing.T) {
	server := pluginRegistryServerWithPrefix(t, "/registry")
	defer server.Close()
	pluginRegistryCacheDir = func() (string, error) { return t.TempDir(), nil }
	pluginRegistryHTTP = server.Client()
	t.Cleanup(func() {
		pluginRegistryCacheDir = os.UserCacheDir
		pluginRegistryHTTP = &http.Client{Timeout: 30 * time.Second}
	})

	entries, err := (pluginRegistryClient{URL: server.URL + "/registry", SyrusVersion: "2.0.0"}).search(t.Context(), "")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name != "acme_weather" {
		t.Fatalf("entries = %#v", entries)
	}
}

func TestPluginRegistryClientRejectsParentRegistryPath(t *testing.T) {
	if _, err := safeRegistryPath(".."); err == nil {
		t.Fatal("expected parent path to be rejected")
	}
}

func TestPluginRegistryClientSupportsRubyStyleRequirementsAndPrereleases(t *testing.T) {
	tests := []struct {
		requirement string
		version     string
		want        bool
	}{
		{requirement: ">=1.0, != 2.0.0", version: "1.5.0", want: true},
		{requirement: ">=1.0, != 2.0.0", version: "2.0.0", want: false},
		{requirement: "~> 2.0", version: "2.9.0", want: true},
		{requirement: "~> 2.0", version: "3.0.0", want: false},
		{requirement: ">= 2.0.0", version: "2.0.0-rc1", want: false},
		{requirement: ">= 2.0.0", version: "2.0.0.rc1", want: false},
	}
	for _, test := range tests {
		t.Run(test.requirement+"/"+test.version, func(t *testing.T) {
			got, err := versionRequirementSatisfied(test.requirement, test.version)
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("got %v, want %v", got, test.want)
			}
		})
	}
}

func TestPluginRegistryClientPropagatesContextToResourceRequests(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/index.json":
			_, _ = io.WriteString(w, `{"format_version":1,"trust_store":"trust-store.json","releases":[]}`)
		case "/trust-store.json":
			close(started)
			<-r.Context().Done()
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	pluginRegistryCacheDir = func() (string, error) { return t.TempDir(), nil }
	client := pluginRegistryClient{URL: server.URL, SyrusVersion: "2.0.0", HTTPClient: server.Client()}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { _, err := client.search(ctx, ""); done <- err }()
	<-started
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v", err)
	}
}

func TestPluginRegistryClientReturnsCachedEntriesWithRefreshWarning(t *testing.T) {
	directory := t.TempDir()
	pluginRegistryCacheDir = func() (string, error) { return directory, nil }
	pluginRegistryNow = func() time.Time { return time.Unix(3600, 0) }
	t.Cleanup(func() { pluginRegistryCacheDir = os.UserCacheDir; pluginRegistryNow = time.Now })
	client := pluginRegistryClient{URL: "https://registry.example.test", SyrusVersion: "2.0.0",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) { return nil, errors.New("offline") })}}
	path, err := registryCachePath(client.cacheKey(), "catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	cache := pluginRegistryCache{FetchedAt: time.Unix(0, 0), Entries: []pluginCatalogEntry{{Name: "acme_weather"}}}
	if err := writePluginRegistryCache(path, cache); err != nil {
		t.Fatal(err)
	}

	entries, err := client.search(t.Context(), "")
	if len(entries) != 1 || err == nil || !strings.Contains(err.Error(), "using cached") {
		t.Fatalf("entries = %#v, error = %v", entries, err)
	}
}

func TestPluginRegistryHTTPCacheIsScopedBySyrusVersion(t *testing.T) {
	first := pluginRegistryClient{URL: "https://registry.example.test", SyrusVersion: "1.0.0"}
	second := pluginRegistryClient{URL: first.URL, SyrusVersion: "2.0.0"}
	if first.cacheKey() == second.cacheKey() {
		t.Fatal("registry caches for different Syrus versions must not collide")
	}
}

func TestPluginSearchPrintsStaleCacheWarningAndResults(t *testing.T) {
	server := pluginRegistryServer(t)
	directory := t.TempDir()
	pluginRegistryCacheDir = func() (string, error) { return directory, nil }
	pluginRegistryHTTP = server.Client()
	pluginRegistryNow = func() time.Time { return time.Unix(0, 0) }
	previousVersion := cliReleaseVersion
	cliReleaseVersion = "2.0.0"
	t.Setenv("SYRUS_PLUGIN_REGISTRY_URL", server.URL)
	client := pluginRegistryClient{URL: server.URL, SyrusVersion: "2.0.0"}
	if _, err := client.search(t.Context(), ""); err != nil {
		t.Fatal(err)
	}
	server.Close()
	pluginRegistryNow = func() time.Time { return time.Unix(3600, 0) }
	t.Cleanup(func() {
		pluginRegistryCacheDir = os.UserCacheDir
		pluginRegistryHTTP = &http.Client{Timeout: 30 * time.Second}
		pluginRegistryNow = time.Now
		cliReleaseVersion = previousVersion
	})
	command := NewRootCommand()
	var output, errors strings.Builder
	command.SetOut(&output)
	command.SetErr(&errors)
	command.SetArgs([]string{"plugin", "search", "weather"})

	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "acme_weather") || !strings.Contains(errors.String(), "using cached") {
		t.Fatalf("output = %q, stderr = %q", output.String(), errors.String())
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
	stamp, err := registryCachePath(client.URL, "git-refreshed-at")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stamp, nil, 0600); err != nil {
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

func TestPluginRegistryClientRejectsGitSymlinkEscapingCache(t *testing.T) {
	directory := t.TempDir()
	pluginRegistryCacheDir = func() (string, error) { return directory, nil }
	t.Cleanup(func() { pluginRegistryCacheDir = os.UserCacheDir })
	client := pluginRegistryClient{URL: "git+https://registry.example.test/plugins.git", SyrusVersion: "2.0.0"}
	root, err := registryCachePath(client.URL, "git")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "acme_weather"), 0700); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"index.json":       `{"format_version":1,"trust_store":"trust-store.json","releases":["acme_weather/1.2.3.json"]}`,
		"trust-store.json": `{"publishers":[{"fingerprint":"abc","label":"verified"}]}`,
	}
	for path, body := range files {
		if err := os.WriteFile(filepath.Join(root, path), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	outside := filepath.Join(directory, "outside.json")
	if err := os.WriteFile(outside, []byte(registryReleaseJSON("acme_weather", "1.2.3", ">= 1.0", "abc", "Weather tools")), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "acme_weather", "1.2.3.json")); err != nil {
		t.Fatal(err)
	}
	stamp, err := registryCachePath(client.URL, "git-refreshed-at")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stamp, nil, 0600); err != nil {
		t.Fatal(err)
	}

	_, err = client.search(t.Context(), "")
	if err == nil || !strings.Contains(err.Error(), "escapes the index root") {
		t.Fatalf("error = %v", err)
	}
}

func TestPluginRegistryClientStoresRefreshMetadataOutsideCheckout(t *testing.T) {
	directory := t.TempDir()
	pluginRegistryCacheDir = func() (string, error) { return directory, nil }
	pluginRegistryNow = time.Now
	t.Cleanup(func() {
		pluginRegistryCacheDir = os.UserCacheDir
		pluginRegistryCommand = exec.CommandContext
	})
	client := pluginRegistryClient{URL: "git+https://registry.example.test/plugins.git", SyrusVersion: "2.0.0"}
	root, err := registryCachePath(client.URL, "git")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0700); err != nil {
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
	outside := filepath.Join(directory, "outside.txt")
	if err := os.WriteFile(outside, []byte("preserve me"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, ".syrus-refreshed-at")); err != nil {
		t.Fatal(err)
	}
	pluginRegistryCommand = func(context.Context, string, ...string) *exec.Cmd { return exec.Command("true") }

	entries, err := client.search(t.Context(), "")
	if err != nil || len(entries) != 1 {
		t.Fatalf("entries = %#v, error = %v", entries, err)
	}
	payload, err := os.ReadFile(outside)
	if err != nil || string(payload) != "preserve me" {
		t.Fatalf("outside payload = %q, error = %v", payload, err)
	}
	stamp, err := registryCachePath(client.URL, "git-refreshed-at")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stamp); err != nil {
		t.Fatalf("external refresh marker: %v", err)
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
	return pluginRegistryServerWithPrefix(t, "")
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func pluginRegistryServerWithPrefix(t *testing.T, prefix string) *httptest.Server {
	return pluginRegistryServerWithIndexHookAndPrefix(t, prefix, nil)
}

func pluginRegistryServerWithIndexHook(t *testing.T, hook func(*http.Request, http.ResponseWriter) bool) *httptest.Server {
	return pluginRegistryServerWithIndexHookAndPrefix(t, "", hook)
}

func pluginRegistryServerWithIndexHookAndPrefix(t *testing.T, prefix string, hook func(*http.Request, http.ResponseWriter) bool) *httptest.Server {
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
		path := strings.TrimPrefix(r.URL.Path, prefix)
		body, ok := files[path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		if path == "/index.json" {
			w.Header().Set("ETag", `"v1"`)
		}
		_, _ = io.WriteString(w, body)
	}))
}

func registryReleaseJSON(name, version, requirement, fingerprint, description string) string {
	return fmt.Sprintf(`{"name":%q,"version":%q,"description":%q,"category":"automation","author":"Acme","homepage":"https://example.test","license":"MIT","requires_syrus":%q,"package_url":"https://example.test/package.tgz","package_digest":"sha256:0000","signature_url":"https://example.test/package.sig","publisher_key_fingerprint":%q,"trust_label_inputs":{},"capability_summary":{}}`, name, version, description, requirement, fingerprint)
}
