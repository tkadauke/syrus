// Package credentialstore is the CLI surface for the bundled credential_store
// plugin.
//
// It lists safe credential metadata through the plugin's management API and
// requests metadata-only broker leases through Syrus runtime CLI
// authentication. It never prints encrypted payload material.
package credentialstore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

const sshAgentToolName = "credential.ssh-agent"

type processResult struct {
	Stdout string
	Stderr string
	Status int
}

type commandRunner interface {
	Run(ctx context.Context, env []string, name string, args ...string) processResult
}

type execCommandRunner struct {
	stdin  io.Reader
	stdout io.Writer
	stderr io.Writer
}

func (runner execCommandRunner) Run(ctx context.Context, env []string, name string, args ...string) processResult {
	command := exec.CommandContext(ctx, name, args...)
	command.Env = env
	command.Stdin = runner.stdin
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	result := processResult{Stdout: stdout.String(), Stderr: stderr.String(), Status: 0}
	if name != "ssh-agent" && name != "ssh-add" {
		fmt.Fprint(runner.stdout, result.Stdout)
		fmt.Fprint(runner.stderr, result.Stderr)
	}
	if err == nil {
		return result
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		result.Status = exitErr.ExitCode()
		return result
	}
	fmt.Fprintf(runner.stderr, "%s: %v\n", name, err)
	result.Status = 1
	return result
}

var sshAgentRunner commandRunner = execCommandRunner{stdin: os.Stdin, stdout: os.Stdout, stderr: os.Stderr}

func NewCredentialStoreCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "credential",
		Aliases: []string{"credential_store"},
		Short:   "Inspect Credential Store records and run credential wrappers",
	}
	cmd.AddCommand(newTypesCommand(), newCredentialsCommand(), newLeaseCommand(), newSSHAgentCommand())
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

func newSSHAgentCommand() *cobra.Command {
	var credential, purpose, toolName, targetJSON string
	var expiresIn int
	cmd := &cobra.Command{
		Use:   "ssh-agent --credential <credential> -- <command> [args...]",
		Short: "Run a command with a brokered SSH key loaded into a temporary ssh-agent",
		Args: func(cmd *cobra.Command, args []string) error {
			if strings.TrimSpace(credential) == "" {
				return errors.New("--credential is required")
			}
			if len(args) == 0 {
				return errors.New("command is required after --")
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			target, err := parseTargetJSON(targetJSON)
			if err != nil {
				return err
			}
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			runCtx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			return runSSHAgentCommand(runCtx, sshAgentRunner, client, sshAgentInput{
				Credential: strings.TrimSpace(credential),
				Purpose:    valueOrDefault(purpose, "ssh-agent command"),
				ToolName:   valueOrDefault(toolName, sshAgentToolName),
				Target:     target,
				ExpiresIn:  expiresIn,
				Command:    args,
			})
		},
	}
	cmd.Flags().StringVar(&credential, "credential", "", "credential name or id")
	cmd.Flags().StringVar(&purpose, "purpose", "", "lease purpose recorded in the access audit")
	cmd.Flags().StringVar(&toolName, "tool", sshAgentToolName, "tool name checked against credential policy")
	cmd.Flags().StringVar(&targetJSON, "target-json", "", "target constraints as a JSON object")
	cmd.Flags().IntVar(&expiresIn, "expires-in", 0, "requested lease TTL in seconds, capped by the server")
	return cmd
}

type sshAgentInput struct {
	Credential string
	Purpose    string
	ToolName   string
	Target     map[string]any
	ExpiresIn  int
	Command    []string
}

func runSSHAgentCommand(ctx context.Context, runner commandRunner, client apiClient, input sshAgentInput) error {
	response, err := RequestSSHAgentMaterial(ctx, client, SSHAgentMaterialRequestBody{
		Credential: input.Credential,
		Purpose:    input.Purpose,
		ToolName:   input.ToolName,
		Target:     input.Target,
		ExpiresIn:  input.ExpiresIn,
	})
	if err != nil {
		return err
	}

	status, duration := runWithSSHAgent(ctx, runner, response.SSHKey, input.Command)
	auditErr := RecordSSHAgentAudit(ctx, client, SSHAgentAuditRequestBody{
		Credential: input.Credential,
		LeaseID:    response.Lease.LeaseID,
		Purpose:    input.Purpose,
		ToolName:   input.ToolName,
		ExitStatus: status,
		DurationMS: duration.Milliseconds(),
	})
	if auditErr != nil && status == 0 {
		return auditErr
	}
	if status != 0 {
		return childExitError(status)
	}
	return auditErr
}

type apiClient interface {
	Do(ctx context.Context, method string, path string, input any, output any) error
}

func runWithSSHAgent(ctx context.Context, runner commandRunner, key SSHKeyData, command []string) (int, time.Duration) {
	start := time.Now()
	agent := runner.Run(ctx, os.Environ(), "ssh-agent", "-s")
	if agent.Status != 0 {
		return agent.Status, time.Since(start)
	}
	agentEnv := parseSSHAgentOutput(agent.Stdout)
	if len(agentEnv) == 0 {
		fmt.Fprintln(os.Stderr, "ssh-agent did not return SSH_AUTH_SOCK")
		return 1, time.Since(start)
	}
	env := mergedEnv(os.Environ(), agentEnv)
	defer runner.Run(context.Background(), env, "ssh-agent", "-k")

	keyPath, cleanupKey, err := writeTempSecret("syrus-ssh-agent-key-*", key.PrivateKey, 0o600)
	if err != nil {
		fmt.Fprintf(os.Stderr, "write temporary SSH key: %v\n", err)
		return 1, time.Since(start)
	}
	defer cleanupKey()

	addEnv := env
	var cleanupAskpass func()
	if strings.TrimSpace(key.Passphrase) != "" {
		askpassPath, cleanup, err := writeTempSecret("syrus-ssh-agent-askpass-*", "#!/bin/sh\nprintf '%s' \"$SYRUS_CREDENTIAL_STORE_SSH_PASSPHRASE\"\n", 0o700)
		if err != nil {
			fmt.Fprintf(os.Stderr, "write temporary SSH askpass helper: %v\n", err)
			return 1, time.Since(start)
		}
		cleanupAskpass = cleanup
		addEnv = mergedEnv(addEnv, map[string]string{
			"DISPLAY":                               valueOrDefault(os.Getenv("DISPLAY"), ":0"),
			"SSH_ASKPASS":                           askpassPath,
			"SSH_ASKPASS_REQUIRE":                   "force",
			"SYRUS_CREDENTIAL_STORE_SSH_PASSPHRASE": key.Passphrase,
		})
	}
	if cleanupAskpass != nil {
		defer cleanupAskpass()
	}

	add := runner.Run(ctx, addEnv, "ssh-add", keyPath)
	if add.Status != 0 {
		return add.Status, time.Since(start)
	}
	child := runner.Run(ctx, env, command[0], command[1:]...)
	return child.Status, time.Since(start)
}

func parseSSHAgentOutput(output string) map[string]string {
	env := map[string]string{}
	for _, field := range strings.Split(output, ";") {
		field = strings.TrimSpace(field)
		if strings.HasPrefix(field, "SSH_AUTH_SOCK=") || strings.HasPrefix(field, "SSH_AGENT_PID=") {
			parts := strings.SplitN(field, "=", 2)
			if len(parts) == 2 && parts[1] != "" {
				env[parts[0]] = parts[1]
			}
		}
	}
	if env["SSH_AUTH_SOCK"] == "" {
		return nil
	}
	return env
}

func writeTempSecret(pattern string, value string, mode os.FileMode) (string, func(), error) {
	file, err := os.CreateTemp("", pattern)
	if err != nil {
		return "", nil, err
	}
	cleanup := func() { _ = os.Remove(file.Name()) }
	if _, err := file.WriteString(value); err != nil {
		file.Close()
		cleanup()
		return "", nil, err
	}
	if err := file.Close(); err != nil {
		cleanup()
		return "", nil, err
	}
	if err := os.Chmod(file.Name(), mode); err != nil {
		cleanup()
		return "", nil, err
	}
	return file.Name(), cleanup, nil
}

func mergedEnv(base []string, values map[string]string) []string {
	index := map[string]int{}
	merged := append([]string{}, base...)
	for i, entry := range merged {
		key, _, ok := strings.Cut(entry, "=")
		if ok {
			index[key] = i
		}
	}
	for key, value := range values {
		entry := key + "=" + value
		if i, ok := index[key]; ok {
			merged[i] = entry
		} else {
			merged = append(merged, entry)
		}
	}
	return merged
}

type childExitError int

func (err childExitError) Error() string {
	return "child command exited with status " + strconv.Itoa(int(err))
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

func valueOrDefault(value string, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func yesNo(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}
