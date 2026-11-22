package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/plugintrust"
)

type fakePublisher struct {
	uploads []string
	path    string
	entry   []byte
}

func (publisher *fakePublisher) Upload(_ context.Context, repository, tag, name string, _ []byte) (string, error) {
	publisher.uploads = append(publisher.uploads, repository+"/"+tag+"/"+name)
	return "https://downloads.example.test/" + name, nil
}
func (publisher *fakePublisher) Submit(_ context.Context, _ string, path string, entry []byte) (string, error) {
	publisher.path, publisher.entry = path, entry
	return "https://github.example.test/pull/1", nil
}

func TestPluginPublishUsesHostingInterfaceAndRequiresSubmissionConsent(t *testing.T) {
	root := packageFixture(t)
	gemspec := filepath.Join(root, "weather.gemspec")
	contents, _ := os.ReadFile(gemspec)
	os.WriteFile(gemspec, []byte(strings.ReplaceAll(string(contents), `"weather"`, `"acme_weather"`)), 0644)
	key, _ := plugintrust.GenerateKey()
	keyBytes, _ := json.Marshal(key)
	keyPath := filepath.Join(t.TempDir(), "publisher.json")
	os.WriteFile(keyPath, keyBytes, 0600)
	publisher := &fakePublisher{}
	previousPublisher, previousRunner := newPluginPublisher, newDockerPluginRunner
	newPluginPublisher = func(string) pluginPublisher { return publisher }
	newDockerPluginRunner = func() pluginRunner { return &fakePluginRunner{} }
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
