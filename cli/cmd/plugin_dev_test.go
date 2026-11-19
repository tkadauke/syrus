package cmd

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestPluginDevActionForPath(t *testing.T) {
	tests := map[string]pluginDevAction{
		"frontend/entry.tsx":                        pluginDevRebuild,
		"frontend/card.tsx":                         pluginDevRebuild,
		"package.json":                              pluginDevRebuild,
		"lib/weather.rb":                            pluginDevRestart,
		"weather.gemspec":                           pluginDevRestart,
		"config/manifest.yml":                       pluginDevRestart,
		"app/frontend/i18n/locales/de/weather.json": pluginDevRestart,
		"README.md":                                 pluginDevIgnore,
		"dist/frontend/plugin.js":                   pluginDevIgnore,
	}
	for path, want := range tests {
		if got := pluginDevActionForPath(path); got != want {
			t.Errorf("pluginDevActionForPath(%q) = %v, want %v", path, got, want)
		}
	}
}

func TestChangedPluginDevPathsDetectsCreateModifyAndDelete(t *testing.T) {
	before := map[string]pluginDevFile{"deleted.rb": {Size: 1}, "changed.rb": {Size: 1}}
	after := map[string]pluginDevFile{"created.rb": {Size: 1}, "changed.rb": {Size: 2}}
	got := changedPluginDevPaths(before, after)
	want := []string{"changed.rb", "created.rb", "deleted.rb"}
	if len(got) != len(want) {
		t.Fatalf("changed paths = %v", got)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("changed paths = %v, want %v", got, want)
		}
	}
}

func TestMarkedPluginDevOutputIgnoresContainerLogs(t *testing.T) {
	got, err := markedPluginDevOutput("booting Rails\nSYRUS_PLUGIN_DEV={\"state\":\"ok\"}\n")
	if err != nil || got != `{"state":"ok"}` {
		t.Fatalf("marked output = %q, %v", got, err)
	}
}

type recordingPluginDevRuntime struct {
	mu       sync.Mutex
	builds   int
	restarts int
	actions  chan string
}

func (runtime *recordingPluginDevRuntime) Available() error { return nil }
func (runtime *recordingPluginDevRuntime) Pull(context.Context, string, io.Writer, io.Writer) error {
	return nil
}
func (runtime *recordingPluginDevRuntime) Start(context.Context, pluginDevRequest, io.Writer, io.Writer) (pluginDevInstance, error) {
	return pluginDevInstance{}, nil
}
func (runtime *recordingPluginDevRuntime) BuildFrontend(context.Context, pluginDevInstance, io.Writer, io.Writer) error {
	runtime.mu.Lock()
	runtime.builds++
	runtime.mu.Unlock()
	runtime.actions <- "build"
	return nil
}
func (runtime *recordingPluginDevRuntime) Restart(context.Context, pluginDevInstance, io.Writer, io.Writer) error {
	runtime.mu.Lock()
	runtime.restarts++
	runtime.mu.Unlock()
	runtime.actions <- "restart"
	return nil
}
func (runtime *recordingPluginDevRuntime) Health(context.Context, pluginDevInstance) (string, error) {
	return "ok", nil
}
func (runtime *recordingPluginDevRuntime) Stop(context.Context, pluginDevInstance, bool, io.Writer, io.Writer) error {
	return nil
}

func TestPluginDevIntegrationWatchesFixtureDebouncesAndPrefersRestart(t *testing.T) {
	directory := t.TempDir()
	runtime := &recordingPluginDevRuntime{actions: make(chan string, 4)}
	previousInterval, previousDebounce := pluginDevScanInterval, pluginDevDebounce
	pluginDevScanInterval, pluginDevDebounce = 5*time.Millisecond, 25*time.Millisecond
	t.Cleanup(func() { pluginDevScanInterval, pluginDevDebounce = previousInterval, previousDebounce })
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- watchPluginDev(ctx, directory, runtime, pluginDevInstance{}, filesystemPluginDevScanner{}, io.Discard, io.Discard)
	}()
	time.Sleep(12 * time.Millisecond)
	if err := os.MkdirAll(filepath.Join(directory, "frontend"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "frontend", "entry.tsx"), []byte("one"), 0644); err != nil {
		t.Fatal(err)
	}
	time.Sleep(10 * time.Millisecond)
	if err := os.WriteFile(filepath.Join(directory, "lib.rb"), []byte("one"), 0644); err != nil {
		t.Fatal(err)
	}
	select {
	case action := <-runtime.actions:
		if action != "restart" {
			t.Fatalf("action = %q, want restart", action)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for debounced reload")
	}
	time.Sleep(40 * time.Millisecond)
	runtime.mu.Lock()
	if runtime.restarts != 1 || runtime.builds != 0 {
		t.Fatalf("restarts=%d builds=%d", runtime.restarts, runtime.builds)
	}
	runtime.mu.Unlock()
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestPluginDevCommandUsesReleaseSelectionAndKeepData(t *testing.T) {
	directory := t.TempDir()
	runtime := &commandPluginDevRuntime{started: make(chan struct{}), stopped: make(chan bool, 1)}
	previousRuntime, previousResolver, previousVersion := newPluginDevRuntime, resolveConnectedInstanceVersion, cliReleaseVersion
	newPluginDevRuntime = func() pluginDevRuntime { return runtime }
	resolveConnectedInstanceVersion = func(context.Context) string { return "4.5.6" }
	cliReleaseVersion = "latest"
	t.Cleanup(func() {
		newPluginDevRuntime, resolveConnectedInstanceVersion, cliReleaseVersion = previousRuntime, previousResolver, previousVersion
	})
	ctx, cancel := context.WithCancel(context.Background())
	root := NewRootCommand()
	root.SetContext(ctx)
	root.SetOut(&bytes.Buffer{})
	root.SetErr(&bytes.Buffer{})
	root.SetArgs([]string{"plugin", "dev", directory, "--keep-data"})
	done := make(chan error, 1)
	go func() { done <- root.Execute() }()
	select {
	case <-runtime.started:
	case <-time.After(time.Second):
		t.Fatal("dev instance did not start")
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if runtime.request.Image != pluginBackendImage+":4.5.6" {
		t.Fatalf("image = %q", runtime.request.Image)
	}
	if keep := <-runtime.stopped; !keep {
		t.Fatal("expected data to be kept")
	}
}

type commandPluginDevRuntime struct {
	request pluginDevRequest
	started chan struct{}
	stopped chan bool
}

func (r *commandPluginDevRuntime) Available() error { return nil }
func (r *commandPluginDevRuntime) Pull(context.Context, string, io.Writer, io.Writer) error {
	return nil
}
func (r *commandPluginDevRuntime) Start(_ context.Context, request pluginDevRequest, _, _ io.Writer) (pluginDevInstance, error) {
	r.request = request
	close(r.started)
	return pluginDevInstance{URL: "http://localhost"}, nil
}
func (r *commandPluginDevRuntime) BuildFrontend(context.Context, pluginDevInstance, io.Writer, io.Writer) error {
	return nil
}
func (r *commandPluginDevRuntime) Restart(context.Context, pluginDevInstance, io.Writer, io.Writer) error {
	return nil
}
func (r *commandPluginDevRuntime) Health(context.Context, pluginDevInstance) (string, error) {
	return "ok", nil
}
func (r *commandPluginDevRuntime) Stop(_ context.Context, _ pluginDevInstance, keep bool, _, _ io.Writer) error {
	r.stopped <- keep
	return nil
}
