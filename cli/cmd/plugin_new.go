package cmd

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
)

//go:embed plugin_scaffold/templates
var pluginScaffoldFS embed.FS

var pluginNamePattern = regexp.MustCompile(`^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$`)

var bundledPluginNames = strings.Fields(`admin_mysql agent_activity agent_insights agent_memory agy_agent alertmanager_investigations attention_report browser build_cache calendar claude_agent codex_agent cognitive_review container_execution coworkers credential_store design_docs discord django git_history git_mirror github_host github_source global_search go ios java javascript k8s_cluster kotlin linear_source metrics_dashboard mockups muse_agent mysql_db_browser operator_briefing plugin_runtime python rails ruby runtime_terminal scheduled_tasks sdlc_pipeline spending_insights syrus_dev tailscale telegram team_directory terminal test_insights theming_tools throughput video_walkthroughs whisper_stt whiteboard worker_timeline`)

type pluginScaffoldOptions struct {
	Name, Destination, Version string
	Frontend, Model, CLI       bool
}

func newPluginNewCommand() *cobra.Command {
	options := pluginScaffoldOptions{}
	command := &cobra.Command{
		Use:   "new NAME",
		Short: "Create a tested external plugin project",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			options.Name = args[0]
			if options.Destination == "" {
				options.Destination = options.Name
			}
			if options.Version == "" {
				options.Version = resolveConnectedInstanceVersion(command.Context())
			}
			if options.Version == "" || options.Version == "latest" {
				options.Version = cliReleaseVersion
			}
			collisions := append([]string{}, bundledPluginNames...)
			collisions = append(collisions, connectedPluginNames(command.Context())...)
			if err := validateNewPluginName(options.Name, collisions); err != nil {
				return err
			}
			if err := generatePluginScaffold(options); err != nil {
				return err
			}
			fmt.Fprintf(command.OutOrStdout(), "Created %s\nRun: cd %s && syrus plugin test .\n", options.Destination, options.Destination)
			return nil
		},
	}
	command.Flags().StringVarP(&options.Destination, "path", "p", "", "destination directory (defaults to ./NAME)")
	command.Flags().StringVar(&options.Version, "syrus-version", "", "oldest supported Syrus release")
	command.Flags().BoolVar(&options.Frontend, "frontend", false, "include an admin-page frontend example")
	command.Flags().BoolVar(&options.Model, "model", false, "include a model and migration example")
	command.Flags().BoolVar(&options.CLI, "cli", false, "include a server-backed CLI command example")
	return command
}

func validateNewPluginName(name string, collisions []string) error {
	if !pluginNamePattern.MatchString(name) {
		return fmt.Errorf("invalid plugin name %q: use lower-case snake_case that maps to a Ruby namespace", name)
	}
	for _, collision := range collisions {
		if name == collision {
			return fmt.Errorf("plugin name %q collides with an installed or bundled plugin", name)
		}
	}
	return nil
}

func generatePluginScaffold(options pluginScaffoldOptions) error {
	// The version lands inside a Ruby string literal in the gemspec.
	if version := strings.TrimPrefix(options.Version, "v"); !plainVersion(version) {
		return fmt.Errorf("invalid Syrus version %q: use a release version such as 1.2.3", options.Version)
	}
	destination, err := filepath.Abs(options.Destination)
	if err != nil {
		return err
	}
	if entries, readErr := os.ReadDir(destination); readErr == nil && len(entries) > 0 {
		return fmt.Errorf("refusing to overwrite non-empty directory: %s", destination)
	} else if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
		return fmt.Errorf("inspect destination: %w", readErr)
	}
	if err := os.MkdirAll(destination, 0o755); err != nil {
		return err
	}

	files := map[string]string{
		"plugin.gemspec": options.Name + ".gemspec", "lib/plugin.rb": "lib/" + options.Name + ".rb",
		"app/services/plugin/callbacks.rb": "app/services/" + options.Name + "/callbacks.rb",
		"locales/en.json":                  "app/frontend/i18n/locales/en/" + options.Name + ".json",
		"locales/de.json":                  "app/frontend/i18n/locales/de/" + options.Name + ".json",
		"locales/la.json":                  "app/frontend/i18n/locales/la/" + options.Name + ".json",
		"dist/plugin.js":                   "dist/frontend/plugin.js", "dist/manifest.json": "dist/frontend/manifest.json",
		"spec/plugin_spec.rb": "spec/" + options.Name + "_spec.rb", "README.md": "README.md", "gitignore": ".gitignore",
		"github/workflows/test.yml": ".github/workflows/test.yml",
	}
	if options.Frontend {
		delete(files, "dist/plugin.js")
		delete(files, "dist/manifest.json")
		files["dist/plugin_frontend.js"] = "dist/frontend/plugin.js"
		files["dist/manifest_frontend.json"] = "dist/frontend/manifest.json"
		files["app/services/plugin/admin_pages.rb"] = "app/services/" + options.Name + "/admin_pages.rb"
		files["frontend/entry.tsx"] = "frontend/entry.tsx"
		files["frontend/style.css"] = "frontend/style.css"
		files["dist/plugin.css"] = "dist/frontend/plugin.css"
	}
	if options.Model {
		files["app/models/plugin/widget.rb"] = "app/models/" + options.Name + "/widget.rb"
		files["db/migrate/create_widgets.rb"] = "db/migrate/20200101000000_create_" + options.Name + "_widgets.rb"
	}
	if options.CLI {
		files["app/services/plugin/cli/hello.rb"] = "app/services/" + options.Name + "/cli/hello.rb"
	}
	keys := make([]string, 0, len(files))
	for key := range files {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, source := range keys {
		content, readErr := fs.ReadFile(pluginScaffoldFS, "plugin_scaffold/templates/"+source)
		if readErr != nil {
			return readErr
		}
		rendered := renderPluginTemplate(string(content), options)
		target := filepath.Join(destination, files[source])
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(target, []byte(rendered), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func renderPluginTemplate(content string, options pluginScaffoldOptions) string {
	moduleName := ""
	for _, part := range strings.Split(options.Name, "_") {
		runes := []rune(part)
		runes[0] = unicode.ToUpper(runes[0])
		moduleName += string(runes)
	}
	displayName := strings.ReplaceAll(options.Name, "_", " ")
	displayRunes := []rune(displayName)
	displayRunes[0] = unicode.ToUpper(displayRunes[0])
	displayName = string(displayRunes)
	frontend := `bundle: "dist/frontend/plugin.js", i18n: [ "app/frontend/i18n/locales/*/` + options.Name + `.json" ]`
	providers, cli := "", ""
	if options.Frontend {
		frontend = `bundle: "dist/frontend/plugin.js", css: "dist/frontend/plugin.css", i18n: [ "app/frontend/i18n/locales/*/` + options.Name + `.json" ]`
		providers = `    provides admin_page: "` + moduleName + `::AdminPages"` + "\n"
	}
	if options.CLI {
		cli = `    cli_commands [ { path: %w[` + options.Name + ` hello], summary: "Say hello", handler: "` + moduleName + `::Cli::Hello" } ]` + "\n"
	}
	replacer := strings.NewReplacer("{{PLUGIN_NAME}}", options.Name, "{{MODULE_NAME}}", moduleName, "{{DISPLAY_NAME}}", displayName,
		"{{SYRUS_VERSION}}", strings.TrimPrefix(options.Version, "v"), "{{FRONTEND_DECLARATION}}", frontend,
		"{{OPTIONAL_PROVIDERS}}", providers, "{{OPTIONAL_CLI}}", cli)
	return replacer.Replace(content)
}

func connectedPluginNames(ctx context.Context) []string {
	credentials, err := config.LoadDefaultCredentials()
	if err != nil {
		return nil
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(credentials.URL, "/")+"/api/v1/app/admin/plugins", nil)
	if err != nil {
		return nil
	}
	request.Header.Set("Authorization", "Bearer "+credentials.Token)
	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return nil
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil
	}
	var payload struct {
		Plugins []struct {
			Name string `json:"name"`
		} `json:"plugins"`
	}
	if json.NewDecoder(response.Body).Decode(&payload) != nil {
		return nil
	}
	names := make([]string, 0, len(payload.Plugins))
	for _, plugin := range payload.Plugins {
		names = append(names, plugin.Name)
	}
	return names
}
