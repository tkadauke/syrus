package cmd

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakePluginDevContainer struct {
	available error
	pulled    string
	options   pluginDevOptions
	actions   []string
	health    pluginDevHealth
	mu        sync.Mutex
}

func (container *fakePluginDevContainer) Available() error { return container.available }
func (container *fakePluginDevContainer) Pull(_ context.Context, image string, _, _ io.Writer) error {
	container.pulled = image
	return nil
}
func (container *fakePluginDevContainer) Start(_ context.Context, options pluginDevOptions, _, _ io.Writer) (string, error) {
	container.options = options
	return "http://127.0.0.1:1234", nil
}
func (container *fakePluginDevContainer) RebuildFrontend(context.Context, io.Writer, io.Writer) error {
	container.record("rebuild")
	return nil
}
func (container *fakePluginDevContainer) Restart(context.Context, io.Writer, io.Writer) error {
	container.record("restart")
	return nil
}
func (container *fakePluginDevContainer) Health(context.Context) (pluginDevHealth, error) {
	return container.health, nil
}
func (container *fakePluginDevContainer) Stop(context.Context, bool, io.Writer, io.Writer) error {
	container.record("stop")
	return nil
}
func (container *fakePluginDevContainer) record(action string) {
	container.mu.Lock()
	defer container.mu.Unlock()
	container.actions = append(container.actions, action)
}

type channelPluginDevWatcher struct {
	changes chan []string
	errors  chan error
}

func (watcher channelPluginDevWatcher) Changes(context.Context) (<-chan []string, <-chan error) {
	return watcher.changes, watcher.errors
}

func TestPluginDevActionForPaths(t *testing.T) {
	tests := []struct {
		name   string
		paths  []string
		action pluginDevAction
	}{
		{"frontend source", []string{"frontend/entry.tsx"}, pluginDevRebuildFrontend},
		{"frontend stylesheet", []string{"frontend/style.css"}, pluginDevRebuildFrontend},
		{"ruby", []string{"app/services/weather/callbacks.rb"}, pluginDevRestartApp},
		{"manifest", []string{"weather.gemspec"}, pluginDevRestartApp},
		{"locale", []string{"app/frontend/i18n/locales/de/weather.json"}, pluginDevRestartApp},
		{"root locale", []string{"locales/en.json"}, pluginDevRestartApp},
		{"backend wins batch", []string{"frontend/entry.tsx", "lib/weather.rb"}, pluginDevRestartApp},
		{"generated bundle", []string{"dist/frontend/plugin.js"}, pluginDevIgnore},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := pluginDevActionForPaths(test.paths); got != test.action {
				t.Fatalf("pluginDevActionForPaths(%v) = %v, want %v", test.paths, got, test.action)
			}
		})
	}
}

func TestPollingPluginDevWatcherDebouncesChanges(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "frontend", "entry.tsx")
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("one"), 0o644); err != nil {
		t.Fatal(err)
	}
	watcher := newPollingPluginDevWatcher(root)
	watcher.interval = 10 * time.Millisecond
	watcher.debounce = 40 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	changes, watchErrors := watcher.Changes(ctx)
	time.Sleep(20 * time.Millisecond)
	for _, content := range []string{"two", "three", "four"} {
		if err := os.WriteFile(file, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		time.Sleep(15 * time.Millisecond)
	}
	select {
	case paths := <-changes:
		if !reflect.DeepEqual(paths, []string{"frontend/entry.tsx"}) {
			t.Fatalf("unexpected paths: %v", paths)
		}
	case err := <-watchErrors:
		t.Fatalf("watch failed: %v", err)
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for debounced change")
	}
	select {
	case paths := <-changes:
		t.Fatalf("expected one debounced batch, got %v", paths)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestRunPluginDevLoopRebuildsAndRestarts(t *testing.T) {
	watcher := channelPluginDevWatcher{changes: make(chan []string, 2), errors: make(chan error)}
	watcher.changes <- []string{"frontend/entry.tsx"}
	watcher.changes <- []string{"lib/weather.rb"}
	close(watcher.changes)
	container := &fakePluginDevContainer{health: pluginDevHealth{State: "ok"}}
	if err := runPluginDevLoop(context.Background(), watcher, container, io.Discard, io.Discard); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(container.actions, []string{"rebuild", "restart"}) {
		t.Fatalf("unexpected actions: %v", container.actions)
	}
}

func TestPluginDevCommandSelectsImageAndPrintsInstructions(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "weather.gemspec"), []byte("Gem::Specification.new"), 0o644); err != nil {
		t.Fatal(err)
	}
	container := &fakePluginDevContainer{health: pluginDevHealth{State: "ok"}}
	previousContainer, previousWatcher, previousResolver, previousVersion := newPluginDevContainer, newPluginDevWatcher, resolveConnectedInstanceVersion, cliReleaseVersion
	newPluginDevContainer = func() pluginDevContainer { return container }
	newPluginDevWatcher = func(string) pluginDevWatcher {
		changes := make(chan []string)
		close(changes)
		return channelPluginDevWatcher{changes: changes, errors: make(chan error)}
	}
	resolveConnectedInstanceVersion = func(context.Context) string { return "2.3.4" }
	cliReleaseVersion = "1.0.0"
	t.Cleanup(func() {
		newPluginDevContainer, newPluginDevWatcher, resolveConnectedInstanceVersion, cliReleaseVersion = previousContainer, previousWatcher, previousResolver, previousVersion
	})
	output := &bytes.Buffer{}
	root := NewRootCommand()
	root.SetOut(output)
	root.SetErr(output)
	root.SetArgs([]string{"plugin", "dev", directory, "--keep-data"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if container.pulled != pluginTestImage+":2.3.4" || !container.options.KeepData {
		t.Fatalf("unexpected dev invocation: image=%s options=%#v", container.pulled, container.options)
	}
	if container.options.Name != "weather" {
		t.Fatalf("plugin name = %q", container.options.Name)
	}
	if text := output.String(); !strings.Contains(text, "http://127.0.0.1:1234") || !strings.Contains(text, "demo@syrus.local / password") || !strings.Contains(text, "Plugin health: ok") {
		t.Fatalf("missing instructions in %q", text)
	}
}
