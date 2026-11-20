package cmd

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPluginCapabilitiesListsManifestDeclarations(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/admin/plugins" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer secret-token" {
			t.Fatalf("authorization = %q", r.Header.Get("Authorization"))
		}
		_, _ = w.Write([]byte(`{"plugins":[{"name":"kotlin","capabilities":[{"family":"ecosystem","capability":"detect_prepare","provider":"Kotlin::Ecosystem","key":"kotlin","tier":"stable","priority":10}]}]}`))
	}))
	defer server.Close()
	writePluginTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	root := NewRootCommand()
	root.SetOut(output)
	root.SetArgs([]string{"plugin", "capabilities"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{"PLUGIN", "FAMILY", "CAPABILITY", "kotlin", "ecosystem", "detect_prepare", "Kotlin::Ecosystem", "stable"} {
		if !strings.Contains(output.String(), value) {
			t.Fatalf("output missing %q:\n%s", value, output.String())
		}
	}
}
