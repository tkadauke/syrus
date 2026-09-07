package k8scluster

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/cliplugin/cliplugintest"
)

func requireAuth(t *testing.T, r *http.Request) {
	t.Helper()
	if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
		t.Fatalf("Authorization = %q", got)
	}
}

func TestK8sClustersListsRegisteredClusters(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/admin/kubernetes_clusters" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"kubernetes_clusters":[{"id":1,"label":"prod","api_server_url":"https://k8s.example.com","agentic_access_enabled":true,"allow_writes":false}]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewK8sCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"clusters"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "prod") || !strings.Contains(got, "https://k8s.example.com") {
		t.Fatalf("output = %q", got)
	}
	if !strings.Contains(got, "yes") || !strings.Contains(got, "no") {
		t.Fatalf("expected agentic/writes columns, got %q", got)
	}
}

func TestK8sNamespacesAutoSelectsSingleCluster(t *testing.T) {
	var namespacesSeen bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/admin/kubernetes_clusters":
			w.Write([]byte(`{"kubernetes_clusters":[{"id":7,"label":"prod"}]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/admin/kubernetes_clusters/7/namespaces":
			namespacesSeen = true
			w.Write([]byte(`{"available":true,"namespaces":[{"name":"default","status":"Active"},{"name":"kube-system","status":"Active"}]}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewK8sCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"namespaces"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !namespacesSeen {
		t.Fatal("expected GET .../7/namespaces")
	}
	if !strings.Contains(output.String(), "kube-system") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestK8sNamespacesRequiresClusterFlagWhenMultipleRegistered(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"kubernetes_clusters":[{"id":1,"label":"prod"},{"id":2,"label":"staging"}]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewK8sCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"namespaces"})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected an error when multiple clusters are registered")
	}
	if !strings.Contains(err.Error(), "--cluster") {
		t.Fatalf("error = %q", err.Error())
	}
}

func TestK8sPodsPassesNamespaceFilterAndCluster(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/admin/kubernetes_clusters/9/pods" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		if got := r.URL.Query().Get("namespace"); got != "web" {
			t.Fatalf("namespace query = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"available":true,"pods":[{"name":"web-abc123","namespace":"web","status":"Running","ready":"1/1","restart_count":2,"node_name":"node-1"}]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewK8sCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"pods", "--cluster", "9", "--namespace", "web"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "web-abc123") || !strings.Contains(got, "node-1") {
		t.Fatalf("output = %q", got)
	}
}

func TestK8sLogsRequiresNamespace(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewK8sCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"logs", "web-abc123"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "--namespace") {
		t.Fatalf("expected --namespace error, got %v", err)
	}
}

func TestK8sLogsPrintsLogTail(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/admin/kubernetes_clusters/3/pods/web-abc123/logs" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		query := r.URL.Query()
		if query.Get("namespace") != "web" || query.Get("container") != "app" || query.Get("tail_lines") != "50" {
			t.Fatalf("query = %v", query)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"available":true,"pod":"web-abc123","namespace":"web","container":"app","log":"line one\nline two\n"}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewK8sCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"logs", "web-abc123", "--cluster", "3", "--namespace", "web", "--container", "app", "--tail", "50"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if output.String() != "line one\nline two\n" {
		t.Fatalf("output = %q", output.String())
	}
}

func TestK8sOverviewReportsUnavailableMetrics(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/admin/kubernetes_clusters/4/overview" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"generated_at":"2026-09-06T00:00:00Z","nodes":{"available":false,"reason":"metrics_unavailable","message":"connection refused"},"pods":{"available":false,"reason":"metrics_unavailable","message":"connection refused"}}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewK8sCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"overview", "--cluster", "4"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "Nodes: unavailable (connection refused)") || !strings.Contains(got, "Pods: unavailable (connection refused)") {
		t.Fatalf("output = %q", got)
	}
}

func TestK8sOverviewReportsAggregateUsage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"nodes":{"available":true,"items":[{"name":"node-1","cpu_millicores":500,"memory_bytes":1073741824}],"total_cpu_millicores":500,"total_memory_bytes":1073741824},"pods":{"available":true,"items":[],"total_cpu_millicores":0,"total_memory_bytes":0}}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewK8sCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"overview", "--cluster", "1"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "Nodes: 500 millicores, 1.0GiB across 1 item(s)") {
		t.Fatalf("output = %q", got)
	}
}

func TestK8sEventsFormatsInvolvedObject(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/admin/kubernetes_clusters/2/events" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"available":true,"events":[{"namespace":"web","type":"Warning","reason":"BackOff","message":"back-off restarting failed container","involved_object":{"kind":"Pod","name":"web-abc123"}}]}`))
	}))
	defer server.Close()
	cliplugintest.WithCredentials(t, server.URL, "secret-token")

	command := NewK8sCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"events", "--cluster", "2"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "Pod/web-abc123") || !strings.Contains(got, "BackOff") {
		t.Fatalf("output = %q", got)
	}
}
