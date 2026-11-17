package cmd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

const pluginCatalogTTL = 5 * time.Minute

var (
	pluginCatalogNow      = time.Now
	pluginCatalogCacheDir = os.UserCacheDir
	pluginExecCommand     = exec.CommandContext
)

type pluginParameter struct {
	Name     string   `json:"name"`
	Type     string   `json:"type"`
	Required bool     `json:"required"`
	Default  any      `json:"default,omitempty"`
	Values   []string `json:"values,omitempty"`
}

type pluginCommandDeclaration struct {
	Plugin    string            `json:"plugin"`
	Path      []string          `json:"path"`
	Summary   string            `json:"summary"`
	Arguments []pluginParameter `json:"arguments"`
	Flags     []pluginParameter `json:"flags"`
}

type pluginCatalog struct {
	Commands []pluginCommandDeclaration `json:"commands"`
}

type pluginCatalogCache struct {
	ETag      string        `json:"etag"`
	FetchedAt time.Time     `json:"fetched_at"`
	Catalog   pluginCatalog `json:"catalog"`
}

type pluginCommandResult struct {
	Kind    string          `json:"kind"`
	Text    string          `json:"text,omitempty"`
	Columns []string        `json:"columns,omitempty"`
	Rows    [][]any         `json:"rows,omitempty"`
	Value   json.RawMessage `json:"value,omitempty"`
}

// resolvePluginCommand is called only after the static command tree is built.
// It leaves known commands alone, then consults the remote catalog, and finally
// delegates to a kubectl-style executable when neither command tree matches.
func resolvePluginCommand(ctx context.Context, root *cobra.Command, args []string) (bool, error) {
	resolutionArgs := pluginResolutionArgs(args)
	commandWords := commandWordsFromArgs(resolutionArgs)
	if len(commandWords) == 0 || staticCommandMatches(root, args) {
		return false, nil
	}

	creds, credentialsErr := config.LoadDefaultCredentials()
	if credentialsErr == nil {
		catalog, err := loadPluginCatalog(ctx, creds)
		if err == nil {
			registerPluginCommands(root, catalog.Commands, creds)
			if staticCommandMatches(root, args) {
				return false, nil
			}
		}
	}

	match, remaining, ok := findPluginExecutable(commandWords, resolutionArgs)
	if !ok {
		return false, nil
	}
	if credentialsErr != nil {
		if errors.Is(credentialsErr, config.ErrMissingCredentials) || errors.Is(credentialsErr, config.ErrIncompleteCredentials) {
			return true, errors.New(loginMessage)
		}
		if errors.Is(credentialsErr, config.ErrMissingInvocationContext) {
			return true, errors.New(invocationContextMessage)
		}
		return true, credentialsErr
	}
	return true, runPluginExecutable(ctx, root, match, remaining, creds)
}

func pluginResolutionArgs(args []string) []string {
	cleaned := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		if args[i] == "--profile" && i+1 < len(args) {
			config.ProfileFlag = args[i+1]
			i++
			continue
		}
		if value, ok := strings.CutPrefix(args[i], "--profile="); ok {
			config.ProfileFlag = value
			continue
		}
		if args[i] == "--debug" || strings.HasPrefix(args[i], "--debug=") {
			continue
		}
		cleaned = append(cleaned, args[i])
	}
	return cleaned
}

func commandWordsFromArgs(args []string) []string {
	words := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--profile" {
			i++
			continue
		}
		if strings.HasPrefix(arg, "--profile=") || strings.HasPrefix(arg, "-") {
			continue
		}
		words = append(words, arg)
	}
	return words
}

func staticCommandMatches(root *cobra.Command, args []string) bool {
	found, remaining, err := root.Find(args)
	if err != nil {
		return false
	}
	if found == root {
		return len(remaining) == 0
	}
	// Cobra treats unknown words below a non-runnable command group as that
	// group's arguments. They may instead be a remotely declared child.
	if found.Run == nil && found.RunE == nil && found.HasSubCommands() && len(commandWordsFromArgs(remaining)) > 0 {
		return false
	}
	return true
}

func loadPluginCatalog(ctx context.Context, creds config.Credentials) (pluginCatalog, error) {
	cache, cachePath := readPluginCatalogCache(creds.URL)
	if cache != nil && pluginCatalogNow().Sub(cache.FetchedAt) < pluginCatalogTTL {
		return cache.Catalog, nil
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(creds.URL, "/")+"/api/v1/app/cli_commands", nil)
	if err != nil {
		return staleCatalog(cache, err)
	}
	request.Header.Set("Authorization", "Bearer "+creds.Token)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("X-Syrus-CLI-Command", "get.cli_commands")
	if cache != nil && cache.ETag != "" {
		request.Header.Set("If-None-Match", cache.ETag)
	}

	response, err := (&http.Client{Timeout: 5 * time.Second}).Do(request)
	if err != nil {
		return staleCatalog(cache, err)
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotModified && cache != nil {
		cache.FetchedAt = pluginCatalogNow()
		_ = writePluginCatalogCache(cachePath, *cache)
		return cache.Catalog, nil
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return staleCatalog(cache, fmt.Errorf("command catalog returned %s", response.Status))
	}
	var catalog pluginCatalog
	if err := json.NewDecoder(io.LimitReader(response.Body, 4<<20)).Decode(&catalog); err != nil {
		return staleCatalog(cache, err)
	}
	updated := pluginCatalogCache{ETag: response.Header.Get("ETag"), FetchedAt: pluginCatalogNow(), Catalog: catalog}
	_ = writePluginCatalogCache(cachePath, updated)
	return catalog, nil
}

func staleCatalog(cache *pluginCatalogCache, err error) (pluginCatalog, error) {
	if cache != nil {
		return cache.Catalog, nil
	}
	return pluginCatalog{}, err
}

func readPluginCatalogCache(instanceURL string) (*pluginCatalogCache, string) {
	directory, err := pluginCatalogCacheDir()
	if err != nil {
		return nil, ""
	}
	digest := sha256.Sum256([]byte(strings.TrimRight(instanceURL, "/")))
	path := filepath.Join(directory, "syrus", "cli-command-catalog-"+hex.EncodeToString(digest[:8])+".json")
	payload, err := os.ReadFile(path)
	if err != nil {
		return nil, path
	}
	var cache pluginCatalogCache
	if json.Unmarshal(payload, &cache) != nil {
		return nil, path
	}
	return &cache, path
}

func writePluginCatalogCache(path string, cache pluginCatalogCache) error {
	if path == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	payload, err := json.Marshal(cache)
	if err != nil {
		return err
	}
	return os.WriteFile(path, payload, 0600)
}

func registerPluginCommands(root *cobra.Command, declarations []pluginCommandDeclaration, creds config.Credentials) {
	for _, declaration := range declarations {
		if len(declaration.Path) == 0 || commandAtPath(root, declaration.Path) != nil {
			continue
		}
		parent := root
		for _, word := range declaration.Path[:len(declaration.Path)-1] {
			child := directChild(parent, word)
			if child == nil {
				child = &cobra.Command{Use: word, Short: "Plugin commands discovered from the configured Syrus instance"}
				parent.AddCommand(child)
			}
			parent = child
		}
		parent.AddCommand(newPluginCommand(declaration, creds))
	}
}

func newPluginCommand(declaration pluginCommandDeclaration, creds config.Credentials) *cobra.Command {
	use := declaration.Path[len(declaration.Path)-1]
	for _, argument := range declaration.Arguments {
		name := "<" + argument.Name + ">"
		if !argument.Required {
			name = "[" + argument.Name + "]"
		}
		use += " " + name
	}
	values := map[string]any{}
	cmd := &cobra.Command{Use: use, Short: declaration.Summary, Args: argumentValidator(declaration.Arguments)}
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		flags := make(map[string]any, len(values))
		for name, value := range values {
			if cmd.Flags().Changed(name) || value != nil {
				flags[name] = value
			}
		}
		return executePluginCommand(cmd, declaration, args, flags, creds)
	}
	for _, flag := range declaration.Flags {
		addPluginFlag(cmd, flag, values)
		if flag.Required {
			_ = cmd.MarkFlagRequired(flag.Name)
		}
	}
	return cmd
}

func argumentValidator(arguments []pluginParameter) cobra.PositionalArgs {
	return func(_ *cobra.Command, args []string) error {
		required := 0
		for _, argument := range arguments {
			if argument.Required {
				required++
			}
		}
		if len(args) < required || len(args) > len(arguments) {
			return fmt.Errorf("accepts between %d and %d arg(s), received %d", required, len(arguments), len(args))
		}
		return nil
	}
}

func addPluginFlag(cmd *cobra.Command, parameter pluginParameter, values map[string]any) {
	description := parameter.Name
	switch parameter.Type {
	case "boolean":
		value, _ := parameter.Default.(bool)
		cmd.Flags().Bool(parameter.Name, value, description)
		values[parameter.Name] = flagValue{cmd: cmd, name: parameter.Name, kind: parameter.Type, hasDefault: parameter.Default != nil}
	case "integer":
		value := 0
		if number, ok := parameter.Default.(float64); ok {
			value = int(number)
		}
		cmd.Flags().Int(parameter.Name, value, description)
		values[parameter.Name] = flagValue{cmd: cmd, name: parameter.Name, kind: parameter.Type, hasDefault: parameter.Default != nil}
	case "repeatable_string":
		defaults := stringSlice(parameter.Default)
		cmd.Flags().StringSlice(parameter.Name, defaults, description)
		values[parameter.Name] = flagValue{cmd: cmd, name: parameter.Name, kind: parameter.Type, hasDefault: parameter.Default != nil}
	default:
		value, _ := parameter.Default.(string)
		cmd.Flags().String(parameter.Name, value, description)
		if parameter.Type == "enum" {
			_ = cmd.RegisterFlagCompletionFunc(parameter.Name, func(*cobra.Command, []string, string) ([]string, cobra.ShellCompDirective) {
				return parameter.Values, cobra.ShellCompDirectiveNoFileComp
			})
		}
		values[parameter.Name] = flagValue{cmd: cmd, name: parameter.Name, kind: parameter.Type, allowed: parameter.Values, hasDefault: parameter.Default != nil}
	}
}

type flagValue struct {
	cmd        *cobra.Command
	name       string
	kind       string
	allowed    []string
	hasDefault bool
}

func (value flagValue) resolved() (any, error) {
	switch value.kind {
	case "boolean":
		return value.cmd.Flags().GetBool(value.name)
	case "integer":
		return value.cmd.Flags().GetInt(value.name)
	case "repeatable_string":
		return value.cmd.Flags().GetStringSlice(value.name)
	default:
		result, err := value.cmd.Flags().GetString(value.name)
		if err == nil && value.kind == "enum" && result != "" && !contains(value.allowed, result) {
			return nil, fmt.Errorf("--%s must be one of: %s", value.name, strings.Join(value.allowed, ", "))
		}
		return result, err
	}
}

func executePluginCommand(cmd *cobra.Command, declaration pluginCommandDeclaration, args []string, rawFlags map[string]any, creds config.Credentials) error {
	flags := make(map[string]any, len(rawFlags))
	for name, raw := range rawFlags {
		if deferred, ok := raw.(flagValue); ok {
			value, err := deferred.resolved()
			if err != nil {
				return err
			}
			if cmd.Flags().Changed(name) || deferred.hasDefault {
				flags[name] = value
			}
		}
	}
	payload := struct {
		Plugin string         `json:"plugin"`
		Path   []string       `json:"path"`
		Args   []string       `json:"args"`
		Flags  map[string]any `json:"flags"`
	}{declaration.Plugin, declaration.Path, args, flags}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(cmd.Context(), http.MethodPost, strings.TrimRight(creds.URL, "/")+"/api/v1/app/cli_commands/execute", strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+creds.Token)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("X-Syrus-CLI-Command", "post.cli_commands.execute")
	response, err := (&http.Client{Timeout: 30 * time.Second}).Do(request)
	if err != nil {
		return fmt.Errorf("network error: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("plugin command failed: %s", response.Status)
	}
	var envelope struct {
		Result pluginCommandResult `json:"result"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 64<<20)).Decode(&envelope); err != nil {
		return err
	}
	return renderPluginResult(cmd.OutOrStdout(), envelope.Result)
}

func renderPluginResult(out io.Writer, result pluginCommandResult) error {
	switch result.Kind {
	case "text":
		_, err := fmt.Fprintln(out, result.Text)
		return err
	case "json":
		var value any
		if err := json.Unmarshal(result.Value, &value); err != nil {
			return err
		}
		encoder := json.NewEncoder(out)
		encoder.SetIndent("", "  ")
		return encoder.Encode(value)
	case "table":
		writer := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
		fmt.Fprintln(writer, strings.Join(result.Columns, "\t"))
		for _, row := range result.Rows {
			cells := make([]string, len(row))
			for i, cell := range row {
				cells[i] = fmt.Sprint(cell)
			}
			fmt.Fprintln(writer, strings.Join(cells, "\t"))
		}
		return writer.Flush()
	default:
		return fmt.Errorf("unsupported plugin command result kind %q", result.Kind)
	}
}

func findPluginExecutable(words, originalArgs []string) (string, []string, bool) {
	wordIndexes := make([]int, 0, len(words))
	for index, arg := range originalArgs {
		if !strings.HasPrefix(arg, "-") {
			wordIndexes = append(wordIndexes, index)
		}
	}
	for length := len(words); length >= 1; length-- {
		name := "syrus-" + strings.Join(words[:length], "-")
		path, err := exec.LookPath(name)
		if err == nil {
			consumed := make(map[int]struct{}, length)
			for _, index := range wordIndexes[:length] {
				consumed[index] = struct{}{}
			}
			remaining := make([]string, 0, len(originalArgs)-length)
			for index, arg := range originalArgs {
				if _, matchedWord := consumed[index]; !matchedWord {
					remaining = append(remaining, arg)
				}
			}
			return path, remaining, true
		}
	}
	return "", nil, false
}

func runPluginExecutable(ctx context.Context, root *cobra.Command, executable string, args []string, creds config.Credentials) error {
	process := pluginExecCommand(ctx, executable, args...)
	process.Stdin = root.InOrStdin()
	process.Stdout = root.OutOrStdout()
	process.Stderr = root.ErrOrStderr()
	process.Env = append(os.Environ(), "SYRUS_URL="+creds.URL, "SYRUS_TOKEN="+creds.Token)
	err := process.Run()
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return cliplugin.ExitStatusError{Status: exitError.ExitCode()}
	}
	return err
}

func commandAtPath(root *cobra.Command, path []string) *cobra.Command {
	current := root
	for _, word := range path {
		current = directChild(current, word)
		if current == nil {
			return nil
		}
	}
	return current
}

func directChild(parent *cobra.Command, name string) *cobra.Command {
	for _, child := range parent.Commands() {
		if child.Name() == name || child.HasAlias(name) {
			return child
		}
	}
	return nil
}

func stringSlice(value any) []string {
	items, ok := value.([]any)
	if !ok {
		return nil
	}
	result := make([]string, len(items))
	for i, item := range items {
		result[i] = fmt.Sprint(item)
	}
	return result
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
