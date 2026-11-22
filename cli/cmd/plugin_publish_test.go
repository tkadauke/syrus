package cmd

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/plugintrust"
)

type fakePublisher struct {
	uploads         []string
	path            string
	entry           []byte
	indexRepository string
}

func (publisher *fakePublisher) Upload(_ context.Context, repository, tag, name string, _ []byte) (string, error) {
	publisher.uploads = append(publisher.uploads, repository+"/"+tag+"/"+name)
	return "https://downloads.example.test/" + name, nil
}
func (publisher *fakePublisher) Submit(_ context.Context, repository string, path string, entry []byte) (string, error) {
	publisher.indexRepository = repository
	publisher.path, publisher.entry = path, entry
	return "https://github.example.test/pull/1", nil
}

func TestGitHubPublisherSubmitsFromForkAgainstRepositoryDefaultBranch(t *testing.T) {
	var pullRequestBase, pullRequestHead string
	written := map[string]map[string]string{}
	forkCreated := false
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch {
		case request.Method == http.MethodGet && request.URL.Path == "/repos/syrus/index":
			json.NewEncoder(response).Encode(map[string]any{"default_branch": "stable", "name": "index", "owner": map[string]string{"login": "syrus"}, "permissions": map[string]bool{"push": false}})
		case request.Method == http.MethodGet && request.URL.Path == "/repos/syrus/index/git/ref/heads/stable":
			json.NewEncoder(response).Encode(map[string]any{"object": map[string]string{"sha": "abc123"}})
		case request.Method == http.MethodGet && request.URL.Path == "/repos/syrus/index/contents/index.json":
			index := `{"format_version":1,"trust_store":"trust-store.json","releases":[]}`
			json.NewEncoder(response).Encode(map[string]string{"sha": "index-sha", "content": base64.StdEncoding.EncodeToString([]byte(index))})
		case request.Method == http.MethodGet && request.URL.Path == "/user":
			json.NewEncoder(response).Encode(map[string]string{"login": "publisher"})
		case request.Method == http.MethodGet && request.URL.Path == "/repos/publisher/index":
			response.WriteHeader(http.StatusNotFound)
			response.Write([]byte(`{"message":"Not Found"}`))
		case request.Method == http.MethodPost && request.URL.Path == "/repos/syrus/index/forks":
			forkCreated = true
			response.WriteHeader(http.StatusAccepted)
			response.Write([]byte(`{"full_name":"publisher/index"}`))
		case request.Method == http.MethodGet && request.URL.Path == "/repos/publisher/index/git/ref/heads/stable":
			json.NewEncoder(response).Encode(map[string]any{"object": map[string]string{"sha": "abc123"}})
		case request.Method == http.MethodPut && strings.HasPrefix(request.URL.Path, "/repos/publisher/index/contents/"):
			var payload map[string]string
			json.NewDecoder(request.Body).Decode(&payload)
			written[strings.TrimPrefix(request.URL.Path, "/repos/publisher/index/contents/")] = payload
			response.WriteHeader(http.StatusCreated)
			response.Write([]byte(`{}`))
		case request.Method == http.MethodPost && request.URL.Path == "/repos/syrus/index/pulls":
			var payload map[string]string
			json.NewDecoder(request.Body).Decode(&payload)
			pullRequestBase = payload["base"]
			pullRequestHead = payload["head"]
			json.NewEncoder(response).Encode(map[string]string{"html_url": "https://example.test/pull/1"})
		default:
			response.WriteHeader(http.StatusCreated)
			response.Write([]byte(`{}`))
		}
	}))
	defer server.Close()
	previousBase := githubAPIBase
	githubAPIBase = server.URL
	t.Cleanup(func() { githubAPIBase = previousBase })
	publisher := &githubPluginPublisher{token: "secret", client: server.Client()}
	if _, err := publisher.Submit(context.Background(), "syrus/index", "acme_weather/1.2.3.json", []byte("entry")); err != nil {
		t.Fatal(err)
	}
	if pullRequestBase != "stable" || pullRequestHead != "publisher:plugin-submission-acme_weather-1-2-3" || !forkCreated {
		t.Fatalf("pull request base=%q head=%q fork=%v", pullRequestBase, pullRequestHead, forkCreated)
	}
	entryWrite, entryOK := written["acme_weather/1.2.3.json"]
	indexWrite, indexOK := written["index.json"]
	if !entryOK || !indexOK || indexWrite["sha"] != "index-sha" || entryWrite["branch"] != indexWrite["branch"] {
		t.Fatalf("submission writes: %#v", written)
	}
	decodedIndex, _ := base64.StdEncoding.DecodeString(indexWrite["content"])
	if !strings.Contains(string(decodedIndex), `"acme_weather/1.2.3.json"`) {
		t.Fatalf("updated index: %s", decodedIndex)
	}
}

func TestPluginPublishUsesHostingInterfaceAndRequiresSubmissionConsent(t *testing.T) {
	root := packageFixture(t)
	gemspec := filepath.Join(root, "weather.gemspec")
	contents, _ := os.ReadFile(gemspec)
	os.WriteFile(gemspec, []byte(strings.ReplaceAll(string(contents), `"weather"`, `"acme_weather"`)), 0644)
	os.MkdirAll(filepath.Join(root, "frontend"), 0755)
	os.WriteFile(filepath.Join(root, "frontend", "entry.tsx"), []byte("export default {}\n"), 0644)
	key, _ := plugintrust.GenerateKey()
	keyBytes, _ := json.Marshal(key)
	keyPath := filepath.Join(t.TempDir(), "publisher.json")
	os.WriteFile(keyPath, keyBytes, 0600)
	publisher := &fakePublisher{}
	previousPublisher, previousRunner := newPluginPublisher, newDockerPluginRunner
	runner := &fakePluginRunner{}
	newPluginPublisher = func(string) pluginPublisher { return publisher }
	newDockerPluginRunner = func() pluginRunner { return runner }
	t.Setenv("GITHUB_TOKEN", "secret-that-must-not-be-printed")
	t.Cleanup(func() { newPluginPublisher, newDockerPluginRunner = previousPublisher, previousRunner })

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"plugin", "publish", root, "--key", keyPath, "--repository", "acme/weather"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if len(publisher.uploads) != 2 || publisher.path != "" {
		t.Fatalf("uploads=%v submitted=%q", publisher.uploads, publisher.path)
	}
	if runner.request.Mode != "build" {
		t.Fatalf("publish runner mode=%q, want frontend build", runner.request.Mode)
	}
	if strings.Contains(output.String(), "secret-that-must-not-be-printed") || !strings.Contains(output.String(), "acme_weather/1.2.3.json") {
		t.Fatalf("unexpected output: %s", output)
	}

	command = NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"plugin", "publish", root, "--key", keyPath, "--repository", "acme/weather", "--submit", "--index-repository", "syrus/index"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if publisher.path != "acme_weather/1.2.3.json" || !bytes.Contains(publisher.entry, []byte(`"package_digest": "sha256:`)) {
		t.Fatalf("submission path=%q entry=%s", publisher.path, publisher.entry)
	}
}

func TestPluginPublishRequiresGitHubToken(t *testing.T) {
	command := NewRootCommand()
	command.SetArgs([]string{"plugin", "publish", "--key", "key", "--repository", "acme/weather"})
	if err := command.Execute(); err == nil || !strings.Contains(err.Error(), "GITHUB_TOKEN") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestPluginPublishRejectsIncompleteSubmissionBeforeUploading(t *testing.T) {
	publisher := &fakePublisher{}
	previousPublisher := newPluginPublisher
	newPluginPublisher = func(string) pluginPublisher { return publisher }
	t.Cleanup(func() { newPluginPublisher = previousPublisher })
	t.Setenv("GITHUB_TOKEN", "secret")
	command := NewRootCommand()
	command.SetArgs([]string{"plugin", "publish", "--key", "unused", "--repository", "acme/weather", "--submit"})
	if err := command.Execute(); err == nil || !strings.Contains(err.Error(), "cannot select submission registry") {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(publisher.uploads) != 0 {
		t.Fatalf("uploaded before validating submission arguments: %v", publisher.uploads)
	}
}

func TestPluginPublishDefaultsAndSelectsRegistryUnlessExplicitlyOverridden(t *testing.T) {
	registries := []configuredPluginRegistry{
		{ID: 1, Name: "canonical", URL: canonicalPluginRegistryURL, Canonical: true},
		{ID: 2, Name: "partners", URL: "git+https://github.com/acme/plugin-index.git"},
		{ID: 3, Name: "mirror", URL: "https://registry.example.test"},
	}
	api := &fakePluginRegistryAPI{registries: registries}
	useFakePluginRegistryAPI(t, api)
	if repository, err := resolveSubmissionRepository(t.Context(), "", ""); err != nil || repository != "tkadauke/syrus-plugins" {
		t.Fatalf("canonical repository=%q error=%v", repository, err)
	}
	if repository, err := resolveSubmissionRepository(t.Context(), "", "partners"); err != nil || repository != "acme/plugin-index" {
		t.Fatalf("selected repository=%q error=%v", repository, err)
	}
	if repository, err := resolveSubmissionRepository(t.Context(), "custom/index", "mirror"); err != nil || repository != "custom/index" {
		t.Fatalf("override repository=%q error=%v", repository, err)
	}
	if _, err := resolveSubmissionRepository(t.Context(), "", "mirror"); err == nil || !strings.Contains(err.Error(), "explicit submission instructions") {
		t.Fatalf("non-GitHub error=%v", err)
	}
}
