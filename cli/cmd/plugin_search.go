package cmd

import (
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/spf13/cobra"
)

type pluginCatalogEntry struct {
	Name        string `json:"name"`
	Version     string `json:"version"`
	Description string `json:"description"`
	Category    string `json:"category"`
	TrustLabel  string `json:"trust_label"`
}

type pluginCatalogPayload struct {
	Configured bool                 `json:"configured"`
	Error      string               `json:"error"`
	Entries    []pluginCatalogEntry `json:"entries"`
}

func newPluginSearchCommand() *cobra.Command {
	return &cobra.Command{Use: "search [TERM]", Short: "Search the configured plugin registry", Args: cobra.MaximumNArgs(1), RunE: func(command *cobra.Command, args []string) error {
		creds, err := loadCredentials()
		if err != nil {
			return err
		}
		path := "/api/v1/app/admin/plugin_installer/catalog"
		if len(args) == 1 {
			path += "?q=" + url.QueryEscape(args[0])
		}
		var payload pluginCatalogPayload
		if err := pluginInstallerJSON(command, http.MethodGet, creds, path, nil, "", &payload); err != nil {
			return err
		}
		if !payload.Configured {
			fmt.Fprintln(command.OutOrStdout(), "No plugin registry is configured. Set SYRUS_PLUGIN_REGISTRY_URL on the Syrus instance.")
			return nil
		}
		if payload.Error != "" && len(payload.Entries) == 0 {
			return fmt.Errorf("plugin registry unavailable: %s", payload.Error)
		}
		if len(payload.Entries) == 0 {
			fmt.Fprintln(command.OutOrStdout(), "No compatible plugins found.")
			return nil
		}
		for _, entry := range payload.Entries {
			fmt.Fprintf(command.OutOrStdout(), "%s\t%s\t%s\t%s\t%s\n", entry.Name, entry.Version, entry.TrustLabel, entry.Category, strings.TrimSpace(entry.Description))
		}
		return nil
	}}
}
