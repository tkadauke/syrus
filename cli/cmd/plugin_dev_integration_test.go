package cmd

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestDockerPluginDevReload(t *testing.T) {
	if testing.Short() {
		t.Skip("Docker integration test")
	}
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("Docker is unavailable")
	}
	if err := exec.Command("docker", "info").Run(); err != nil {
		t.Skip("Docker daemon is unavailable")
	}

	plugin := filepath.Join(t.TempDir(), "relocatable_plugin")
	copyPluginDevFixture(t, filepath.Join("..", "..", "spec", "fixtures", "relocatable_plugin"), plugin)
	container := &dockerPluginDevContainer{}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	image := pluginTestImage + ":latest"
	if err := container.Pull(ctx, image, io.Discard, io.Discard); err != nil {
		t.Fatal(err)
	}
	if _, err := container.Start(ctx, pluginDevOptions{Directory: plugin, Image: image, Name: "relocatable_plugin"}, io.Discard, io.Discard); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = container.Stop(context.Background(), false, io.Discard, io.Discard) })

	watcher := newPollingPluginDevWatcher(plugin)
	watcher.interval = 20 * time.Millisecond
	watcher.debounce = 50 * time.Millisecond
	changes, watchErrors := watcher.Changes(ctx)
	callback := filepath.Join(plugin, "lib", "relocatable_plugin.rb")
	file, err := os.OpenFile(callback, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("\n# integration reload probe\n"); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case paths := <-changes:
		if pluginDevActionForPaths(paths) != pluginDevRestartApp {
			t.Fatalf("expected restart for %v", paths)
		}
	case err := <-watchErrors:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if err := container.Restart(ctx, io.Discard, io.Discard); err != nil {
		t.Fatal(err)
	}
	if health, err := container.Health(ctx); err != nil || health.State != "ok" {
		t.Fatalf("health after reload = %#v, %v", health, err)
	}
}

func copyPluginDevFixture(t *testing.T, source, destination string) {
	t.Helper()
	err := filepath.WalkDir(source, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, relative)
		if entry.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, contents, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
}
