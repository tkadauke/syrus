package cmd

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

type fakePluginRunner struct {
	available error
	pullErr   error
	pulled    string
	request   pluginRunRequest
	runErr    error
}

func (runner *fakePluginRunner) Available() error { return runner.available }
func (runner *fakePluginRunner) Pull(_ context.Context, image string, _, _ io.Writer) error {
	runner.pulled = image
	return runner.pullErr
}
func (runner *fakePluginRunner) Run(_ context.Context, request pluginRunRequest, _ io.Reader, _, _ io.Writer) error {
	runner.request = request
	return runner.runErr
}

func executeLocalPlugin(t *testing.T, runner *fakePluginRunner, args ...string) error {
	t.Helper()
	previousRunner, previousResolver, previousVersion := newDockerPluginRunner, resolveConnectedInstanceVersion, cliReleaseVersion
	newDockerPluginRunner = func() pluginRunner { return runner }
	resolveConnectedInstanceVersion = func(context.Context) string { return "" }
	cliReleaseVersion = "1.2.3"
	t.Cleanup(func() {
		newDockerPluginRunner, resolveConnectedInstanceVersion, cliReleaseVersion = previousRunner, previousResolver, previousVersion
	})
	root := NewRootCommand()
	root.SetOut(&bytes.Buffer{})
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(args)
	return root.Execute()
}

func TestPluginCommandsParseArguments(t *testing.T) {
	directory := t.TempDir()
	runner := &fakePluginRunner{}
	if err := executeLocalPlugin(t, runner, "plugin", "validate", directory, "--json", "--syrus-version", "v2.0.0"); err != nil {
		t.Fatal(err)
	}
	absolute, _ := filepath.Abs(directory)
	if runner.request.Directory != absolute || runner.request.Mode != "validate" || !runner.request.JSON {
		t.Fatalf("unexpected request: %#v", runner.request)
	}
	if runner.pulled != pluginTestImage+":2.0.0" {
		t.Fatalf("unexpected image: %s", runner.pulled)
	}
}

func TestPluginImageSelection(t *testing.T) {
	directory := t.TempDir()
	runner := &fakePluginRunner{}
	previousResolver := resolveConnectedInstanceVersion
	resolveConnectedInstanceVersion = func(context.Context) string { return "3.4.5" }
	t.Cleanup(func() { resolveConnectedInstanceVersion = previousResolver })
	previousRunner := newDockerPluginRunner
	newDockerPluginRunner = func() pluginRunner { return runner }
	t.Cleanup(func() { newDockerPluginRunner = previousRunner })
	root := NewRootCommand()
	root.SetArgs([]string{"plugin", "test", directory})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if runner.pulled != pluginTestImage+":3.4.5" {
		t.Fatalf("unexpected image: %s", runner.pulled)
	}
}

func TestPluginDockerErrorsAndExitStatus(t *testing.T) {
	directory := t.TempDir()
	t.Run("missing", func(t *testing.T) {
		err := executeLocalPlugin(t, &fakePluginRunner{available: errors.New("Docker is required")}, "plugin", "test", directory)
		if err == nil || !strings.Contains(err.Error(), "Docker is required") {
			t.Fatalf("unexpected error: %v", err)
		}
	})
	t.Run("pull", func(t *testing.T) {
		err := executeLocalPlugin(t, &fakePluginRunner{pullErr: errors.New("pull failed")}, "plugin", "test", directory)
		if err == nil || !strings.Contains(err.Error(), "pull failed") {
			t.Fatalf("unexpected error: %v", err)
		}
	})
	t.Run("exit", func(t *testing.T) {
		err := executeLocalPlugin(t, &fakePluginRunner{runErr: cliplugin.ExitStatusError{Status: 7}}, "plugin", "test", directory)
		var status cliplugin.ExitStatusError
		if !errors.As(err, &status) || status.ExitStatus() != 7 {
			t.Fatalf("unexpected error: %v", err)
		}
	})
}

func TestPluginCheckoutSkipsDocker(t *testing.T) {
	directory, checkout := t.TempDir(), t.TempDir()
	entrypoint := filepath.Join(checkout, "bin", "plugin-test")
	if err := os.MkdirAll(filepath.Dir(entrypoint), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(entrypoint, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	root := NewRootCommand()
	root.SetArgs([]string{"plugin", "validate", directory, "--checkout", checkout})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
}
