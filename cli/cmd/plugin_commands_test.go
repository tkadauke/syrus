package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/tkadauke/syrus/cli/internal/config"
)

func TestDynamicPluginCommandRegistrationValidationAndRendering(t *testing.T) {
	cacheDir := usePluginCatalogTestCache(t)
	_ = cacheDir
	var executionBody map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/cli_commands":
			w.Header().Set("ETag", `"catalog-v1"`)
			_, _ = w.Write([]byte(`{"commands":[{"plugin":"fixture","path":["remote","list"],"summary":"List remote things","arguments":[{"name":"query","type":"string","required":true}],"flags":[{"name":"state","type":"enum","required":true,"values":["open","closed"]},{"name":"limit","type":"integer","default":10}]}]}`))
		case "/api/v1/app/cli_commands/execute":
			json.NewDecoder(r.Body).Decode(&executionBody)
			json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"kind": "table", "columns": []string{"name", "count"}, "rows": []any{[]any{"alpha", 2}}}})
		default:
			t.Fatalf("unexpected request path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writePluginTestCredentials(t, server.URL)

	root := NewRootCommand()
	args := []string{"remote", "list", "needle", "--state", "open"}
	if handled, err := resolvePluginCommand(context.Background(), root, args); handled || err != nil {
		t.Fatalf("resolvePluginCommand() = handled %v, err %v", handled, err)
	}
	output := &bytes.Buffer{}
	root.SetOut(output)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(args)
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); got != "name   count\nalpha  2\n" {
		t.Fatalf("table output = %q", got)
	}
	if executionBody["plugin"] != "fixture" {
		t.Fatalf("execution body = %#v", executionBody)
	}
	flags := executionBody["flags"].(map[string]any)
	if flags["state"] != "open" || flags["limit"] != float64(10) {
		t.Fatalf("flags = %#v", flags)
	}

	invalid := NewRootCommand()
	if handled, err := resolvePluginCommand(context.Background(), invalid, []string{"remote", "list", "needle", "--state", "invalid"}); handled || err != nil {
		t.Fatalf("resolve invalid command: handled %v, err %v", handled, err)
	}
	invalid.SetArgs([]string{"remote", "list", "needle", "--state", "invalid"})
	if err := invalid.Execute(); err == nil || !strings.Contains(err.Error(), "must be one of") {
		t.Fatalf("enum validation error = %v", err)
	}
}

func TestRenderPluginResultKinds(t *testing.T) {
	tests := []struct {
		result pluginCommandResult
		want   string
	}{
		{pluginCommandResult{Kind: "text", Text: "hello"}, "hello\n"},
		{pluginCommandResult{Kind: "raw_text", Text: "hello\n"}, "hello\n"},
		{pluginCommandResult{Kind: "raw_text", Text: "partial"}, "partial"},
		{pluginCommandResult{Kind: "json", Value: json.RawMessage(`{"ok":true}`)}, "{\n  \"ok\": true\n}\n"},
		{pluginCommandResult{Kind: "table", Columns: []string{"a", "b"}, Rows: [][]any{{"x", true}}}, "a  b\nx  true\n"},
	}
	for _, test := range tests {
		output := &bytes.Buffer{}
		if err := renderPluginResult(output, test.result); err != nil {
			t.Fatalf("render %s: %v", test.result.Kind, err)
		}
		if output.String() != test.want {
			t.Fatalf("render %s = %q, want %q", test.result.Kind, output.String(), test.want)
		}
	}
}

func TestExecutePluginCommandPreservesRawTextBytes(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/cli_commands/execute" {
			t.Fatalf("unexpected request path %s", r.URL.Path)
		}
		json.NewEncoder(w).Encode(map[string]any{
			"result": map[string]any{"kind": "raw_text", "text": "hello\n"},
		})
	}))
	defer server.Close()

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetContext(context.Background())
	command.SetOut(output)
	declaration := pluginCommandDeclaration{Plugin: "k8s_cluster", Path: []string{"k8s", "logs"}}
	credentials := config.Credentials{URL: server.URL, Token: "secret-token"}

	if err := executePluginCommand(command, declaration, []string{"web-1"}, map[string]any{"namespace": "default"}, credentials); err != nil {
		t.Fatalf("executePluginCommand returned error: %v", err)
	}
	if got := output.String(); got != "hello\n" {
		t.Fatalf("raw text output = %q, want exact trailing-newline payload", got)
	}
}

func TestPluginCatalogUsesETagAndStaleCacheOffline(t *testing.T) {
	usePluginCatalogTestCache(t)
	now := time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)
	pluginCatalogNow = func() time.Time { return now }
	t.Cleanup(func() { pluginCatalogNow = time.Now })
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if requests == 2 {
			if r.Header.Get("If-None-Match") != `"v1"` {
				t.Fatalf("If-None-Match = %q", r.Header.Get("If-None-Match"))
			}
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", `"v1"`)
		io := map[string]any{"commands": []any{map[string]any{"plugin": "p", "path": []string{"cached"}, "summary": "Cached"}}}
		json.NewEncoder(w).Encode(io)
	}))
	creds := config.Credentials{URL: server.URL, Token: "secret"}
	first, err := loadPluginCatalog(context.Background(), creds)
	if err != nil || len(first.Commands) != 1 {
		t.Fatalf("first load = %#v, %v", first, err)
	}
	if _, err := loadPluginCatalog(context.Background(), creds); err != nil || requests != 1 {
		t.Fatalf("fresh cache requests = %d, err = %v", requests, err)
	}
	now = now.Add(pluginCatalogTTL + time.Second)
	if _, err := loadPluginCatalog(context.Background(), creds); err != nil || requests != 2 {
		t.Fatalf("conditional load requests = %d, err = %v", requests, err)
	}
	server.Close()
	now = now.Add(pluginCatalogTTL + time.Second)
	offline, err := loadPluginCatalog(context.Background(), creds)
	if err != nil || len(offline.Commands) != 1 {
		t.Fatalf("offline stale load = %#v, %v", offline, err)
	}

	_, err = loadPluginCatalog(context.Background(), config.Credentials{URL: "http://127.0.0.1:1", Token: "secret"})
	if err == nil {
		t.Fatal("expected offline load without cache to fail")
	}
}

func TestExecutableFallbackPrefersLongestMatchAndPassesEnvironment(t *testing.T) {
	usePluginCatalogTestCache(t)
	home := writePluginTestCredentials(t, "http://127.0.0.1:1")
	bin := t.TempDir()
	outputPath := filepath.Join(home, "plugin-output")
	script := "#!/bin/sh\nprintf '%s\\n%s\\n%s\\n' \"$SYRUS_URL\" \"$SYRUS_TOKEN\" \"$*\" > \"$PLUGIN_OUTPUT\"\n"
	for _, name := range []string{"syrus-foo", "syrus-foo-bar"} {
		path := filepath.Join(bin, name)
		if err := os.WriteFile(path, []byte(script), 0755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin)
	t.Setenv("PLUGIN_OUTPUT", outputPath)
	root := NewRootCommand()
	handled, err := resolvePluginCommand(context.Background(), root, []string{"foo", "bar", "tail"})
	if !handled || err != nil {
		t.Fatalf("fallback = handled %v, err %v", handled, err)
	}
	payload, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(payload); got != "http://127.0.0.1:1\nsecret-token\ntail\n" {
		t.Fatalf("fallback environment/output = %q", got)
	}
}

func TestExecutableFallbackTracksMatchedWordsAroundFlags(t *testing.T) {
	usePluginCatalogTestCache(t)
	home := writePluginTestCredentials(t, "http://127.0.0.1:1")
	bin := t.TempDir()
	outputPath := filepath.Join(home, "plugin-output")
	plugin := filepath.Join(bin, "syrus-foo-bar")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$PLUGIN_OUTPUT\"\n"
	if err := os.WriteFile(plugin, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	t.Setenv("PLUGIN_OUTPUT", outputPath)

	tests := []struct {
		name string
		args []string
		want string
	}{
		{name: "root flag before path", args: []string{"--debug", "foo", "bar", "tail"}, want: "tail\n"},
		{name: "plugin flag between path words", args: []string{"foo", "--plugin-flag", "bar", "tail"}, want: "--plugin-flag tail\n"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := NewRootCommand()
			handled, err := resolvePluginCommand(context.Background(), root, test.args)
			if !handled || err != nil {
				t.Fatalf("fallback = handled %v, err %v", handled, err)
			}
			payload, err := os.ReadFile(outputPath)
			if err != nil {
				t.Fatal(err)
			}
			if got := string(payload); got != test.want {
				t.Fatalf("fallback arguments = %q, want %q", got, test.want)
			}
		})
	}
}

func TestExecutableFallbackPreservesInternalInvocationAuthentication(t *testing.T) {
	bin := t.TempDir()
	outputPath := filepath.Join(t.TempDir(), "plugin-output")
	plugin := filepath.Join(bin, "syrus-credential")
	script := "#!/bin/sh\nprintf '%s\\n%s\\n%s\\n' \"$SYRUS_CLI_INTERNAL\" \"$SYRUS_CLI_URL\" \"$SYRUS_CLI_INVOCATION_CONTEXT\" > \"$PLUGIN_OUTPUT\"\n"
	if err := os.WriteFile(plugin, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	t.Setenv("PLUGIN_OUTPUT", outputPath)
	root := NewRootCommand()
	err := runPluginExecutable(context.Background(), root, plugin, []string{"lease"}, config.Credentials{URL: "https://syrus.example", Token: "invocation-token", Internal: true})
	if err != nil {
		t.Fatal(err)
	}
	payload, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(payload); got != "1\nhttps://syrus.example\ninvocation-token\n" {
		t.Fatalf("internal invocation environment = %q", got)
	}
}

func TestCompiledCommandWinsOverCatalogCollision(t *testing.T) {
	root := NewRootCommand()
	existing := commandAtPath(root, []string{"docs"})
	registerPluginCommands(root, []pluginCommandDeclaration{
		{Plugin: "fixture", Path: []string{"docs"}, Summary: "Remote docs"},
		{Plugin: "fixture", Path: []string{"insights", "remote"}, Summary: "Remote insight"},
	}, config.Credentials{})
	if commandAtPath(root, []string{"docs"}) != existing {
		t.Fatal("catalog replaced the compiled-in docs command")
	}
	if commandAtPath(root, []string{"insights", "remote"}) == nil {
		t.Fatal("catalog command was not attached below a built-in command group")
	}
}

func usePluginCatalogTestCache(t *testing.T) string {
	directory := t.TempDir()
	pluginCatalogCacheDir = func() (string, error) { return directory, nil }
	t.Cleanup(func() { pluginCatalogCacheDir = os.UserCacheDir })
	return directory
}

func writePluginTestCredentials(t *testing.T, instanceURL string) string {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("SYRUS_CLI_INTERNAL", "")
	t.Setenv("SYRUS_CLI_URL", "")
	t.Setenv("SYRUS_CLI_INVOCATION_CONTEXT", "")
	path := filepath.Join(home, ".syrus", "credentials")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("url="+instanceURL+"\ntoken=secret-token\n"), 0600); err != nil {
		t.Fatal(err)
	}
	return home
}
