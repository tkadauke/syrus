package cmd

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPluginSearchPrintsCompatibleResultsWithTrust(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/admin/plugin_installer/catalog" || r.URL.Query().Get("q") != "weather" {
			t.Fatalf("request = %s", r.URL.String())
		}
		_, _ = io.WriteString(w, `{"configured":true,"entries":[{"name":"acme_weather","version":"1.2.3","description":"Weather tools","category":"automation","trust_label":"verified"}]}`)
	}))
	defer server.Close()
	writePluginTestCredentials(t, server.URL)
	command := NewRootCommand()
	var output strings.Builder
	command.SetOut(&output)
	command.SetArgs([]string{"plugin", "search", "weather"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "acme_weather	1.2.3	verified	automation	Weather tools") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestPluginSearchExplainsUnconfiguredRegistry(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"configured":false,"entries":[]}`)
	}))
	defer server.Close()
	writePluginTestCredentials(t, server.URL)
	command := NewRootCommand()
	var output strings.Builder
	command.SetOut(&output)
	command.SetArgs([]string{"plugin", "search"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "No plugin registry is configured") {
		t.Fatalf("output = %q", output.String())
	}
}
