package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateNewPluginName(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"weather_tools", "a", "plugin2"} {
		if err := validateNewPluginName(name, nil); err != nil {
			t.Errorf("%q: %v", name, err)
		}
	}
	for _, name := range []string{"WeatherTools", "weather-tools", "2weather", "weather__tools", ""} {
		if err := validateNewPluginName(name, nil); err == nil {
			t.Errorf("expected %q to be invalid", name)
		}
	}
	if err := validateNewPluginName("weather_tools", []string{"weather_tools"}); err == nil || !strings.Contains(err.Error(), "collides") {
		t.Fatalf("expected collision, got %v", err)
	}
	if err := validateNewPluginName("rails", bundledPluginNames); err == nil || !strings.Contains(err.Error(), "collides") {
		t.Fatalf("expected bundled collision, got %v", err)
	}
}

func TestGeneratePluginScaffoldFlagCombinations(t *testing.T) {
	for _, test := range []struct {
		name                 string
		frontend, model, cli bool
	}{
		{name: "minimal"}, {name: "frontend", frontend: true}, {name: "model", model: true},
		{name: "cli", cli: true}, {name: "everything", frontend: true, model: true, cli: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			directory := filepath.Join(t.TempDir(), "weather_tools")
			err := generatePluginScaffold(pluginScaffoldOptions{Name: "weather_tools", Destination: directory, Version: "v1.2.3", Frontend: test.frontend, Model: test.model, CLI: test.cli})
			if err != nil {
				t.Fatal(err)
			}
			entry, err := os.ReadFile(filepath.Join(directory, "lib/weather_tools.rb"))
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(entry), `frontend bundle: "dist/frontend/plugin.js"`) {
				t.Fatalf("missing frontend declaration:\n%s", entry)
			}
			assertExists(t, filepath.Join(directory, "app/services/weather_tools/callbacks.rb"), true)
			assertExists(t, filepath.Join(directory, "frontend/entry.tsx"), test.frontend)
			assertExists(t, filepath.Join(directory, "app/models/weather_tools/widget.rb"), test.model)
			assertExists(t, filepath.Join(directory, "app/services/weather_tools/cli/hello.rb"), test.cli)
			gemspec, _ := os.ReadFile(filepath.Join(directory, "weather_tools.gemspec"))
			if !strings.Contains(string(gemspec), `">= 1.2.3"`) {
				t.Fatalf("version missing:\n%s", gemspec)
			}
		})
	}
}

func TestGeneratePluginScaffoldRefusesNonEmptyDirectory(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "keep"), []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := generatePluginScaffold(pluginScaffoldOptions{Name: "weather_tools", Destination: directory, Version: "1.0.0"})
	if err == nil || !strings.Contains(err.Error(), "non-empty") {
		t.Fatalf("expected overwrite refusal, got %v", err)
	}
	content, _ := os.ReadFile(filepath.Join(directory, "keep"))
	if string(content) != "mine" {
		t.Fatal("existing content changed")
	}
}

// The Syrus version is spliced into a Ruby string literal in the generated
// gemspec, which Bundler evaluates as code. It comes from --syrus-version or,
// by default, from whatever the connected instance's bootstrap reports, so a
// version carrying a quote became Ruby that ran on the developer's machine on
// the next bundle or `syrus plugin test`. A version must be a plain version.
func TestGeneratePluginScaffoldRefusesAVersionThatIsNotAPlainVersion(t *testing.T) {
	for _, version := range []string{`1.0"; system("touch pwned"); "`, "1.0\n", "#{`id`}", ""} {
		directory := t.TempDir()
		err := generatePluginScaffold(pluginScaffoldOptions{Name: "weather_tools", Destination: directory, Version: version})
		if err == nil {
			gemspec, _ := os.ReadFile(filepath.Join(directory, "weather_tools.gemspec"))
			t.Errorf("version %q was accepted; gemspec:\n%s", version, gemspec)
		}
	}
	for _, version := range []string{"1.2.3", "v1.2.3", "2026.11.21", "1.0.0-rc.1", "1.0.0+build.5"} {
		if err := generatePluginScaffold(pluginScaffoldOptions{Name: "weather_tools", Destination: t.TempDir(), Version: version}); err != nil {
			t.Errorf("version %q: %v", version, err)
		}
	}
}

func TestInstanceVersionIgnoresAReportedVersionThatIsNotAPlainVersion(t *testing.T) {
	cases := map[string]string{
		"v1.2.3":                      "1.2.3",
		" 2026.11.21 ":                "2026.11.21",
		"1.2.3-4-gabcdef":             "",
		`1.0"; system("touch pwned")`: "",
		"1.0 --privileged":            "",
	}
	for reported, want := range cases {
		if got := instanceVersionFromReported(reported); got != want {
			t.Errorf("instanceVersionFromReported(%q) = %q; want %q", reported, got, want)
		}
	}
}

func assertExists(t *testing.T, path string, expected bool) {
	t.Helper()
	_, err := os.Stat(path)
	if (err == nil) != expected {
		t.Errorf("existence of %s = %v, want %v", path, err == nil, expected)
	}
}
