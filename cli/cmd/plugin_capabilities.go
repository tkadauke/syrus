package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
)

type pluginCapability struct {
	Family     string `json:"family"`
	Capability string `json:"capability"`
	Provider   string `json:"provider"`
	Key        string `json:"key"`
	Tier       string `json:"tier"`
	Priority   int    `json:"priority"`
}

type pluginCapabilityRow struct {
	Plugin string
	Health []string
	pluginCapability
}

func newPluginCapabilitiesCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "capabilities",
		Short: "List plugin capability-family declarations",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			credentials, err := config.LoadDefaultCredentials()
			if err != nil {
				return fmt.Errorf("load credentials: %w", err)
			}
			capabilities, err := fetchPluginCapabilities(command, credentials)
			if err != nil {
				return err
			}
			writer := tabwriter.NewWriter(command.OutOrStdout(), 0, 4, 2, ' ', 0)
			_, _ = fmt.Fprintln(writer, "PLUGIN\tFAMILY\tPROVIDER IMPLEMENTS\tHEALTH")
			type declaration struct{ plugin, family, provider string }
			grouped := map[declaration][]string{}
			order := []declaration{}
			health := map[string][]string{}
			for _, row := range capabilities {
				key := declaration{row.Plugin, row.Family, row.Provider}
				if _, exists := grouped[key]; !exists {
					order = append(order, key)
				}
				grouped[key] = append(grouped[key], row.Capability)
				health[row.Plugin] = row.Health
			}
			for _, key := range order {
				status := "ok"
				if len(health[key.plugin]) > 0 {
					status = strings.Join(health[key.plugin], "; ")
				}
				_, _ = fmt.Fprintf(writer, "%s\t%s\t%s implements: %s\t%s\n", key.plugin, key.family,
					key.provider, strings.Join(grouped[key], ", "), status)
			}
			return writer.Flush()
		},
	}
}

func fetchPluginCapabilities(command *cobra.Command, credentials config.Credentials) ([]pluginCapabilityRow, error) {
	request, err := http.NewRequestWithContext(command.Context(), http.MethodGet,
		strings.TrimRight(credentials.URL, "/")+"/api/v1/app/admin/plugins", nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+credentials.Token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("list plugin capabilities: server returned %s", response.Status)
	}
	var payload struct {
		Plugins []struct {
			Name         string             `json:"name"`
			Capabilities []pluginCapability `json:"capabilities"`
			Health       struct {
				Reasons []string `json:"reasons"`
			} `json:"health"`
		} `json:"plugins"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 4<<20)).Decode(&payload); err != nil {
		return nil, fmt.Errorf("decode plugin capabilities: %w", err)
	}
	var result []pluginCapabilityRow
	for _, plugin := range payload.Plugins {
		for _, capability := range plugin.Capabilities {
			result = append(result, pluginCapabilityRow{Plugin: plugin.Name, Health: plugin.Health.Reasons, pluginCapability: capability})
		}
	}
	return result, nil
}
