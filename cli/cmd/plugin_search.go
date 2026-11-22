package cmd

import (
	"fmt"
	"os"
	"strings"

	gem "github.com/aquasecurity/go-gem-version"
	"github.com/spf13/cobra"
)

type pluginCatalogEntry struct {
	Name              string `json:"name"`
	Version           string `json:"version"`
	Description       string `json:"description"`
	Category          string `json:"category"`
	TrustLabel        string `json:"trust_label"`
	RegistryName      string `json:"registry_name,omitempty"`
	RegistryID        int    `json:"registry_id,omitempty"`
	RegistryCanonical bool   `json:"registry_canonical,omitempty"`
}

func newPluginSearchCommand() *cobra.Command {
	var registry string
	command := &cobra.Command{Use: "search [TERM]", Short: "Search enabled plugin registries", Args: cobra.MaximumNArgs(1), RunE: func(command *cobra.Command, args []string) error {
		term := ""
		if len(args) == 1 {
			term = args[0]
		}
		runningVersion := selectedPluginVersion(command.Context(), "")
		if _, parseErr := gem.NewVersion(runningVersion); parseErr != nil {
			runningVersion = ""
		}
		if creds, credentialErr := loadCredentials(); credentialErr == nil {
			catalog, err := newPluginRegistryAPI(creds).Search(command.Context(), term, registry)
			if err == nil {
				for name, warning := range catalog.Errors {
					fmt.Fprintf(command.ErrOrStderr(), "Warning: %s: %s\n", name, warning)
				}
				return printPluginSearchResults(command, catalog.Entries)
			}
			fmt.Fprintf(command.ErrOrStderr(), "Warning: connected instance unavailable; using a direct registry: %s\n", err)
		}
		registryURL := strings.TrimSpace(os.Getenv("SYRUS_PLUGIN_REGISTRY_URL"))
		if registryURL == "" {
			registryURL = "git+" + canonicalPluginRegistryURL
		}
		if registry != "" && registry != "canonical" {
			return fmt.Errorf("registry %q is unavailable without a connected instance", registry)
		}
		entries, err := (pluginRegistryClient{URL: registryURL, SyrusVersion: runningVersion}).search(command.Context(), term)
		if err != nil && len(entries) == 0 {
			return fmt.Errorf("plugin registry unavailable: %w", err)
		}
		if err != nil {
			fmt.Fprintf(command.ErrOrStderr(), "Warning: %s\n", err)
		}
		for index := range entries {
			entries[index].RegistryName = "canonical"
		}
		return printPluginSearchResults(command, entries)
	}}
	command.Flags().StringVar(&registry, "registry", "", "Restrict results to a registry name or ID")
	return command
}

func printPluginSearchResults(command *cobra.Command, entries []pluginCatalogEntry) error {
	if len(entries) == 0 {
		fmt.Fprintln(command.OutOrStdout(), "No compatible plugins found.")
		return nil
	}
	for _, entry := range entries {
		fmt.Fprintf(command.OutOrStdout(), "%s\t%s\t%s\t%s\t%s\t%s\n", entry.Name, entry.Version, entry.TrustLabel, entry.Category, strings.TrimSpace(entry.Description), entry.RegistryName)
	}
	return nil
}
