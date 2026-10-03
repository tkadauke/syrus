// Package credentialstore is the CLI surface for the bundled credential_store
// plugin.
//
// It lists safe credential metadata through the plugin's management API and
// requests metadata-only broker leases through Syrus runtime CLI
// authentication. It never prints encrypted payload material.
package credentialstore

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

func NewCredentialStoreCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "credential_store", Short: "Inspect Credential Store records and runtime leases"}
	cmd.AddCommand(newTypesCommand(), newCredentialsCommand(), newLeaseCommand())
	return cmd
}

func newTypesCommand() *cobra.Command {
	var jsonOutput bool
	cmd := &cobra.Command{
		Use:   "types",
		Short: "List credential type names",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			list, err := ListCredentials(cmd.Context(), client)
			if err != nil {
				return err
			}
			if jsonOutput {
				return json.NewEncoder(cmd.OutOrStdout()).Encode(list.Options.CredentialTypes)
			}
			renderTypes(cmd.OutOrStdout(), list.Options.CredentialTypes)
			return nil
		},
	}
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "print JSON")
	return cmd
}

func newCredentialsCommand() *cobra.Command {
	var jsonOutput bool
	var credentialType string
	cmd := &cobra.Command{
		Use:   "credentials",
		Short: "List accessible credential handles",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			list, err := ListCredentials(cmd.Context(), client)
			if err != nil {
				return err
			}
			credentials := filterCredentials(list.Credentials, credentialType)
			if jsonOutput {
				return json.NewEncoder(cmd.OutOrStdout()).Encode(credentials)
			}
			renderCredentials(cmd.OutOrStdout(), credentials)
			return nil
		},
	}
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "print JSON")
	cmd.Flags().StringVar(&credentialType, "type", "", "only show credentials with this type")
	return cmd
}

func newLeaseCommand() *cobra.Command {
	var credentialType, purpose, toolName, targetJSON string
	var expiresIn int
	var jsonOutput bool
	cmd := &cobra.Command{
		Use:   "lease <credential>",
		Short: "Request a scoped runtime broker lease",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if strings.TrimSpace(credentialType) == "" {
				return errors.New("--type is required")
			}
			if strings.TrimSpace(purpose) == "" {
				return errors.New("--purpose is required")
			}
			target, err := parseTargetJSON(targetJSON)
			if err != nil {
				return err
			}
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			response, err := RequestLease(cmd.Context(), client, LeaseRequestBody{
				Credential: strings.TrimSpace(args[0]),
				Type:       strings.TrimSpace(credentialType),
				Purpose:    strings.TrimSpace(purpose),
				ToolName:   strings.TrimSpace(toolName),
				Target:     target,
				ExpiresIn:  expiresIn,
			})
			if err != nil {
				return err
			}
			if jsonOutput {
				return json.NewEncoder(cmd.OutOrStdout()).Encode(response.Lease)
			}
			renderLease(cmd.OutOrStdout(), response.Lease)
			return nil
		},
	}
	cmd.Flags().StringVar(&credentialType, "type", "", "expected credential type name")
	cmd.Flags().StringVar(&purpose, "purpose", "", "lease purpose recorded in the access audit")
	cmd.Flags().StringVar(&toolName, "tool", "", "tool name checked against credential policy")
	cmd.Flags().StringVar(&targetJSON, "target-json", "", "target constraints as a JSON object")
	cmd.Flags().IntVar(&expiresIn, "expires-in", 0, "requested lease TTL in seconds, capped by the server")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "print JSON")
	return cmd
}

func renderTypes(out io.Writer, types []CredentialType) {
	if len(types) == 0 {
		fmt.Fprintln(out, "No credential types.")
		return
	}
	tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "NAME\tLABEL\tPLUGIN\tDESCRIPTION")
	for _, item := range types {
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", item.Name, valueOrDash(item.Label), valueOrDash(item.Plugin), valueOrDash(item.Description))
	}
	tw.Flush()
}

func renderCredentials(out io.Writer, credentials []Credential) {
	if len(credentials) == 0 {
		fmt.Fprintln(out, "No credentials.")
		return
	}
	tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tNAME\tTYPE\tSCOPE\tACTIVE\tSAFE METADATA")
	for _, credential := range credentials {
		fmt.Fprintf(tw, "%d\t%s\t%s\t%s\t%s\t%s\n",
			credential.ID,
			credentialRef(credential),
			credential.CredentialType,
			scopeLabel(credential),
			yesNo(credential.Active),
			formatMap(credential.SafeMetadata),
		)
	}
	tw.Flush()
}

func renderLease(out io.Writer, lease Lease) {
	tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "LEASE\tCREDENTIAL\tTYPE\tEXPIRES\tPURPOSE\tTOOL")
	fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\n",
		lease.LeaseID,
		lease.CredentialName,
		lease.CredentialType,
		lease.ExpiresAt,
		lease.Purpose,
		valueOrDash(lease.ToolName),
	)
	tw.Flush()
}

func filterCredentials(credentials []Credential, credentialType string) []Credential {
	credentialType = strings.TrimSpace(credentialType)
	if credentialType == "" {
		return credentials
	}
	var filtered []Credential
	for _, credential := range credentials {
		if credential.CredentialType == credentialType {
			filtered = append(filtered, credential)
		}
	}
	return filtered
}

func parseTargetJSON(value string) (map[string]any, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil, nil
	}
	var target map[string]any
	if err := json.Unmarshal([]byte(value), &target); err != nil {
		return nil, fmt.Errorf("--target-json must be a JSON object: %w", err)
	}
	if target == nil {
		return nil, errors.New("--target-json must be a JSON object")
	}
	return target, nil
}

func scopeLabel(credential Credential) string {
	if credential.ScopeLabel != "" {
		return credential.ScopeLabel
	}
	if credential.ScopeID == 0 {
		return credential.ScopeType
	}
	return fmt.Sprintf("%s:%d", credential.ScopeType, credential.ScopeID)
}

func formatMap(values map[string]any) string {
	if len(values) == 0 {
		return "-"
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, fmt.Sprintf("%s=%v", key, values[key]))
	}
	return strings.Join(parts, ",")
}

func valueOrDash(value string) string {
	if strings.TrimSpace(value) == "" {
		return "-"
	}
	return value
}

func yesNo(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}
