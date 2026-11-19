package cmd

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func packageFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "weather.gemspec"), []byte(`Gem::Specification.new do |spec|
  spec.name = "weather"
  spec.version = "1.2.3"
  spec.metadata["requires_syrus"] = ">= 1.0"
end
`), 0644)
	os.MkdirAll(filepath.Join(root, "lib"), 0755)
	os.WriteFile(filepath.Join(root, "lib", "weather.rb"), []byte("module Weather; end\n"), 0644)
	return root
}

func TestPluginPackageIsDeterministic(t *testing.T) {
	root := packageFixture(t)
	manifest, files, err := inspectPluginPackage(root)
	if err != nil {
		t.Fatal(err)
	}
	one := filepath.Join(t.TempDir(), "one.tar.gz")
	two := filepath.Join(t.TempDir(), "two.tar.gz")
	if err := writePluginPackage(one, manifest, files); err != nil {
		t.Fatal(err)
	}
	if err := writePluginPackage(two, manifest, files); err != nil {
		t.Fatal(err)
	}
	a, _ := os.ReadFile(one)
	b, _ := os.ReadFile(two)
	if sha256.Sum256(a) != sha256.Sum256(b) {
		t.Fatal("packages differ")
	}
}

func TestPluginPackRefusesFailedValidation(t *testing.T) {
	root := packageFixture(t)
	runner := &fakePluginRunner{runErr: fmt.Errorf("invalid plugin")}
	previous := newDockerPluginRunner
	newDockerPluginRunner = func() pluginRunner { return runner }
	t.Cleanup(func() { newDockerPluginRunner = previous })
	cmd := NewRootCommand()
	cmd.SetOut(&bytes.Buffer{})
	cmd.SetErr(&bytes.Buffer{})
	cmd.SetArgs([]string{"plugin", "pack", root, "--output", filepath.Join(t.TempDir(), "package.tar.gz")})
	err := cmd.Execute()
	if err == nil || !strings.Contains(err.Error(), "refusing to pack because validation failed") {
		t.Fatalf("unexpected error: %v", err)
	}
}
