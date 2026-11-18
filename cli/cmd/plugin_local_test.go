package cmd

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

func pluginHelperCommand(ctx context.Context, _ string, args ...string) *exec.Cmd {
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=TestPluginProcessHelper", "--")
	command.Env = append(os.Environ(), "GO_WANT_PLUGIN_HELPER=1", "PLUGIN_HELPER_ARGS="+strings.Join(args, " "))
	return command
}

func TestPluginProcessHelper(t *testing.T) {
	if os.Getenv("GO_WANT_PLUGIN_HELPER") != "1" {
		return
	}
	args := os.Getenv("PLUGIN_HELPER_ARGS")
	if strings.HasPrefix(args, "pull ") && strings.Contains(args, "pull-fail") {
		os.Exit(9)
	}
	if strings.HasPrefix(args, "pull ") {
		fmt.Fprintln(os.Stdout, "pull progress")
	}
	if strings.HasPrefix(args, "run ") && strings.Contains(args, "runner-fail") {
		os.Exit(7)
	}
	jsonRequested := os.Getenv("SYRUS_PLUGIN_TEST_JSON") == "1" || strings.Contains(args, "SYRUS_PLUGIN_TEST_JSON=1")
	if jsonRequested {
		fmt.Fprintln(os.Stdout, `{"schema":"syrus.plugin-test.v1","status":"passed"}`)
	} else if !strings.HasPrefix(args, "pull ") {
		fmt.Fprintln(os.Stdout, "runner progress")
		fmt.Fprintln(os.Stdout, `{"schema":"syrus.plugin-test.v1","status":"passed"}`)
	}
	os.Exit(0)
}

type recordingPluginRunner struct {
	mode, dir, version, checkout string
	json                         bool
	err                          error
}

func (r *recordingPluginRunner) Run(_ context.Context, _, _ io.Writer, mode, dir, version, checkout string, json bool) error {
	r.mode, r.dir, r.version, r.checkout, r.json = mode, dir, version, checkout, json
	return r.err
}

func TestPluginCommandParsesArgumentsAndExplicitVersion(t *testing.T) {
	runner := &recordingPluginRunner{}
	previous := localPluginRunner
	localPluginRunner = runner
	t.Cleanup(func() { localPluginRunner = previous })
	dir := t.TempDir()
	checkout := t.TempDir()
	cmd := NewRootCommand()
	cmd.SetArgs([]string{"plugin", "validate", dir, "--syrus-version", "1.2.3", "--checkout", checkout, "--json"})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	absolute, _ := filepath.Abs(dir)
	if runner.mode != "validate" || runner.dir != absolute || runner.version != "1.2.3" || runner.checkout != checkout || !runner.json {
		t.Fatalf("unexpected invocation: %#v", runner)
	}
}

func TestPluginCommandUsesConnectedInstanceVersion(t *testing.T) {
	t.Setenv("SYRUS_CLI_INTERNAL", "")
	t.Setenv("SYRUS_CLI_URL", "")
	t.Setenv("SYRUS_CLI_INVOCATION_CONTEXT", "")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.Header().Set("X-Syrus-Version", "2.4.0") }))
	defer server.Close()
	home := t.TempDir()
	t.Setenv("HOME", home)
	os.MkdirAll(filepath.Join(home, ".syrus"), 0700)
	os.WriteFile(filepath.Join(home, ".syrus", "credentials"), []byte("url="+server.URL+"\ntoken=test\n"), 0600)
	runner := &recordingPluginRunner{}
	previous := localPluginRunner
	localPluginRunner = runner
	t.Cleanup(func() { localPluginRunner = previous })
	cmd := NewRootCommand()
	cmd.SetArgs([]string{"plugin", "test", t.TempDir(), "--checkout", t.TempDir()})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	if runner.version != "2.4.0" {
		t.Fatalf("version = %q", runner.version)
	}
}

func TestPluginCommandFallsBackToCLIVersion(t *testing.T) {
	t.Setenv("SYRUS_CLI_INTERNAL", "")
	t.Setenv("SYRUS_CLI_URL", "")
	t.Setenv("SYRUS_CLI_INVOCATION_CONTEXT", "")
	t.Setenv("HOME", t.TempDir())
	oldVersion := pluginCLIVersion
	pluginCLIVersion = "3.1.0"
	t.Cleanup(func() { pluginCLIVersion = oldVersion })
	runner := &recordingPluginRunner{}
	previous := localPluginRunner
	localPluginRunner = runner
	t.Cleanup(func() { localPluginRunner = previous })
	cmd := NewRootCommand()
	cmd.SetArgs([]string{"plugin", "test", t.TempDir(), "--checkout", t.TempDir()})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	if runner.version != "3.1.0" {
		t.Fatalf("version = %q", runner.version)
	}
}

func TestContainerPluginRunnerReportsMissingDocker(t *testing.T) {
	previous := pluginLookPath
	pluginLookPath = func(string) (string, error) { return "", exec.ErrNotFound }
	t.Cleanup(func() { pluginLookPath = previous })
	err := (containerPluginRunner{}).Run(context.Background(), io.Discard, io.Discard, "test", t.TempDir(), "1.0", "", false)
	if err == nil || !strings.Contains(err.Error(), "Docker is required") {
		t.Fatalf("error = %v", err)
	}
}

func TestContainerPluginRunnerReportsPullFailure(t *testing.T) {
	oldLook, oldCommand := pluginLookPath, pluginLocalCommand
	pluginLookPath = func(string) (string, error) { return "/docker", nil }
	pluginLocalCommand = pluginHelperCommand
	t.Cleanup(func() { pluginLookPath, pluginLocalCommand = oldLook, oldCommand })
	err := (containerPluginRunner{}).Run(context.Background(), io.Discard, io.Discard, "test", t.TempDir(), "pull-fail", "", false)
	if err == nil || !strings.Contains(err.Error(), "could not pull") {
		t.Fatalf("error = %v", err)
	}
}

func TestContainerPluginRunnerPropagatesExitStatus(t *testing.T) {
	oldLook, oldCommand := pluginLookPath, pluginLocalCommand
	pluginLookPath = func(string) (string, error) { return "/docker", nil }
	pluginLocalCommand = pluginHelperCommand
	t.Cleanup(func() { pluginLookPath, pluginLocalCommand = oldLook, oldCommand })
	err := (containerPluginRunner{}).Run(context.Background(), io.Discard, io.Discard, "test", t.TempDir(), "runner-fail", "", false)
	status, ok := err.(cliplugin.ExitStatusError)
	if !ok || status.ExitStatus() != 7 {
		t.Fatalf("error = %#v", err)
	}
}

func TestContainerPluginRunnerRequestsJSONOnlyCheckoutOutput(t *testing.T) {
	oldCommand := pluginLocalCommand
	pluginLocalCommand = pluginHelperCommand
	t.Cleanup(func() { pluginLocalCommand = oldCommand })
	assertJSONOnlyPluginOutput(t, t.TempDir())
}

func TestContainerPluginRunnerRequestsJSONOnlyDockerOutput(t *testing.T) {
	oldLook, oldCommand := pluginLookPath, pluginLocalCommand
	pluginLookPath = func(string) (string, error) { return "/docker", nil }
	pluginLocalCommand = pluginHelperCommand
	t.Cleanup(func() { pluginLookPath, pluginLocalCommand = oldLook, oldCommand })
	assertJSONOnlyPluginOutput(t, "")
}

func assertJSONOnlyPluginOutput(t *testing.T, checkout string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	err := (containerPluginRunner{}).Run(context.Background(), &stdout, &stderr, "test", t.TempDir(), "1.0", checkout, true)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := stdout.String(), "{\"schema\":\"syrus.plugin-test.v1\",\"status\":\"passed\"}\n"; got != want {
		t.Fatalf("stdout = %q, want %q", got, want)
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestPluginVersionHTTPClientHasTimeout(t *testing.T) {
	if pluginVersionHTTPClient.Timeout != 5*time.Second {
		t.Fatalf("timeout = %s", pluginVersionHTTPClient.Timeout)
	}
}
