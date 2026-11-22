package cmd

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPluginListShowsInstalledReleaseTrustAndHealth(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/admin/plugin_installer" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		_, _ = io.WriteString(w, `{"installations":[{"name":"weather","version":"1.2.3","source":"upload","trust_label":"verified","health":"healthy"}]}`)
	}))
	defer server.Close()
	writePluginTestCredentials(t, server.URL)
	command := NewRootCommand()
	var output strings.Builder
	command.SetOut(&output)
	command.SetArgs([]string{"plugin", "list"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "weather\t1.2.3\tverified\tupload\thealthy") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestPluginRemoveRequiresConfirmationAndConfirmsWithYes(t *testing.T) {
	confirmed := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/admin/plugin_installer/stage_remove":
			_, _ = io.WriteString(w, `{"id":7,"name":"weather","action":"remove","capability_manifest":{}}`)
		case "/api/v1/app/admin/plugin_installer/changes/7/confirm":
			confirmed = true
			_, _ = io.WriteString(w, `{"restart_required":true}`)
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writePluginTestCredentials(t, server.URL)
	command := NewRootCommand()
	command.SetOut(io.Discard)
	command.SetArgs([]string{"plugin", "remove", "weather", "--yes"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !confirmed {
		t.Fatal("confirmation endpoint was not called")
	}
}

func TestPluginInstallUploadsArchiveAndConfirms(t *testing.T) {
	confirmed := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/admin/plugin_installer/stage":
			if err := r.ParseMultipartForm(1024); err != nil {
				t.Fatal(err)
			}
			file, _, err := r.FormFile("archive")
			if err != nil {
				t.Fatal(err)
			}
			file.Close()
			_, _ = io.WriteString(w, `{"id":9,"name":"weather","action":"install","version":"1.0.0","source":"upload","trust_label":"unsigned_local","capability_manifest":{}}`)
		case "/api/v1/app/admin/plugin_installer/changes/9/confirm":
			confirmed = true
			_, _ = io.WriteString(w, `{"restart_required":true}`)
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writePluginTestCredentials(t, server.URL)
	archive := filepath.Join(t.TempDir(), "weather.tar.gz")
	if err := os.WriteFile(archive, []byte("package"), 0600); err != nil {
		t.Fatal(err)
	}
	command := NewRootCommand()
	command.SetOut(io.Discard)
	command.SetArgs([]string{"plugin", "install", archive, "--yes"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !confirmed {
		t.Fatal("confirmation endpoint was not called")
	}
}

func TestPluginInstallStagesStoredVersionAndConfirms(t *testing.T) {
	confirmed := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/app/admin/plugin_installer/stage_release":
			body, _ := io.ReadAll(r.Body)
			if !strings.Contains(string(body), `"name":"weather"`) || !strings.Contains(string(body), `"version":"1.0.0"`) {
				t.Fatalf("body = %s", body)
			}
			_, _ = io.WriteString(w, `{"id":10,"name":"weather","action":"update","version":"1.0.0","source":"registry","trust_label":"verified","capability_manifest":{"routes":["/weather"]}}`)
		case "/api/v1/app/admin/plugin_installer/changes/10/confirm":
			confirmed = true
			_, _ = io.WriteString(w, `{"restart_required":true}`)
		default:
			t.Fatalf("path = %s", r.URL.Path)
		}
	}))
	defer server.Close()
	writePluginTestCredentials(t, server.URL)
	command := NewRootCommand()
	command.SetOut(io.Discard)
	command.SetArgs([]string{"plugin", "install", "weather@1.0.0", "--yes"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !confirmed {
		t.Fatal("confirmation endpoint was not called")
	}
}
