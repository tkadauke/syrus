package cmd

import (
	"fmt"
	"os"
	"strings"

	gem "github.com/aquasecurity/go-gem-version"
	"github.com/spf13/cobra"
)

type pluginCatalogEntry struct {
	Name        string `json:"name"`
	Version     string `json:"version"`
	Description string `json:"description"`
	Category    string `json:"category"`
	TrustLabel  string `json:"trust_label"`
}

func newPluginSearchCommand() *cobra.Command {
	return &cobra.Command{Use: "search [TERM]", Short: "Search the configured plugin registry", Args: cobra.MaximumNArgs(1), RunE: func(command *cobra.Command, args []string) error {
		registryURL := strings.TrimSpace(os.Getenv("SYRUS_PLUGIN_REGISTRY_URL"))
		if registryURL == "" {
			fmt.Fprintln(command.OutOrStdout(), "No plugin registry is configured. Set SYRUS_PLUGIN_REGISTRY_URL.")
			return nil
		}
		term := ""
		if len(args) == 1 {
			term = args[0]
		}
		runningVersion := selectedPluginVersion(command.Context(), "")
		if _, parseErr := gem.NewVersion(runningVersion); parseErr != nil {
			runningVersion = ""
		}
		entries, err := (pluginRegistryClient{URL: registryURL, SyrusVersion: runningVersion}).search(command.Context(), term)
		if err != nil && len(entries) == 0 {
			return fmt.Errorf("plugin registry unavailable: %w", err)
		}
		if err != nil {
			fmt.Fprintf(command.ErrOrStderr(), "Warning: %s\n", err)
		}
		if len(entries) == 0 {
			fmt.Fprintln(command.OutOrStdout(), "No compatible plugins found.")
			return nil
		}
		for _, entry := range entries {
			fmt.Fprintf(command.OutOrStdout(), "%s\t%s\t%s\t%s\t%s\n", entry.Name, entry.Version, entry.TrustLabel, entry.Category, strings.TrimSpace(entry.Description))
		}
		return nil
	}}
}
