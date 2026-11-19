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

// This acceptance check uses the released host image in CI. Local runs avoid a
// surprise multi-gigabyte pull, but use an already-present image when possible.
func TestPluginDevDockerIntegrationReloadsFixture(t *testing.T) {
	if testing.Short() {
		t.Skip("Docker integration test")
	}
	if _, err := exec.LookPath("docker"); err != nil || exec.Command("docker", "info").Run() != nil {
		t.Skip("Docker is unavailable")
	}
	image := os.Getenv("SYRUS_PLUGIN_DEV_INTEGRATION_IMAGE")
	if image == "" {
		image = pluginBackendImage + ":latest"
	}
	runtime := dockerPluginDevRuntime{}
	if exec.Command("docker", "image", "inspect", image).Run() != nil {
		if os.Getenv("CI") == "" {
			t.Skip("plugin development image is not present locally")
		}
		if err := runtime.Pull(context.Background(), image, io.Discard, io.Discard); err != nil {
			t.Fatalf("pull integration image: %v", err)
		}
	}

	directory := t.TempDir()
	fixture := filepath.Join("..", "..", "spec", "fixtures", "relocatable_plugin")
	if err := os.CopyFS(directory, os.DirFS(fixture)); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	instance, err := runtime.Start(ctx, pluginDevRequest{Directory: directory, Image: image}, io.Discard, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stopCtx, stopCancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer stopCancel()
		_ = runtime.Stop(stopCtx, instance, false, io.Discard, io.Discard)
	})

	before, err := runtime.Health(ctx, instance)
	if err != nil {
		t.Fatalf("initial health: %v", err)
	}
	rubyFile := filepath.Join(directory, "lib", "relocatable_plugin.rb")
	contents, err := os.ReadFile(rubyFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(rubyFile, append(contents, []byte("\n# reload fixture\n")...), 0644); err != nil {
		t.Fatal(err)
	}
	if pluginDevActionForPath("lib/relocatable_plugin.rb") != pluginDevRestart {
		t.Fatal("Ruby fixture edit did not select restart")
	}
	if err := runtime.Restart(ctx, instance, io.Discard, io.Discard); err != nil {
		t.Fatalf("reload fixture: %v", err)
	}
	after, err := runtime.Health(ctx, instance)
	if err != nil {
		t.Fatalf("health after reload: %v", err)
	}
	if before != after {
		t.Fatalf("health changed after reload: before %q, after %q", before, after)
	}
}
