package credentialstore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin/cliplugintest"
)

func requireAuth(t *testing.T, r *http.Request) {
	t.Helper()
	if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
		t.Fatalf("Authorization = %q", got)
	}
}

func withCredentials(t *testing.T, url string) {
	t.Helper()
	t.Setenv("SYRUS_CLI_URL", "")
	t.Setenv("SYRUS_CLI_INVOCATION_CONTEXT", "")
	t.Setenv("SYRUS_CLI_INTERNAL", "")
	cliplugintest.WithCredentials(t, url, "secret-token")
}

func TestCredentialStoreCredentialsListsSafeHandles(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/credential_store/credentials" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"credentials":[{"id":7,"name":"deploy-token","credential_type":"credential_store.url_token","scope_type":"repository","scope_id":3,"scope_label":"acme/widgets","safe_metadata":{"host":"api.example.com"},"active":true}],"options":{"credential_types":[]}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	command := NewCredentialStoreCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"credentials"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "deploy-token") || !strings.Contains(got, "api.example.com") {
		t.Fatalf("output = %q", got)
	}
	if strings.Contains(got, "super-secret") || strings.Contains(got, "payload") {
		t.Fatalf("output included secret-shaped data: %q", got)
	}
}

func TestCredentialStoreTypesSurfacesPluginDisabled(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte(`{"error":{"code":"plugin_disabled","message":"Plugin credential_store is disabled."}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	command := NewCredentialStoreCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"types"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "credential_store is disabled") {
		t.Fatalf("expected plugin_disabled error, got %v", err)
	}
}

func TestCredentialStoreLeasePostsScopedRequestAndRedactsOutput(t *testing.T) {
	var requestBody map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/app/credential_store/leases" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&requestBody); err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"lease":{"lease_id":"lease-123","credential_id":7,"credential_name":"deploy-token","credential_type":"credential_store.url_token","issued_at":"2026-10-03T00:00:00Z","expires_at":"2026-10-03T00:02:00Z","purpose":"deploy","tool_name":"deploy.push","safe_metadata":{"host":"api.example.com"}}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	command := NewCredentialStoreCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{
		"lease", "deploy-token",
		"--type", "credential_store.url_token",
		"--purpose", "deploy",
		"--tool", "deploy.push",
		"--target-json", `{"host":"api.example.com"}`,
		"--expires-in", "30",
	})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	lease := requestBody["lease"].(map[string]any)
	if lease["credential"] != "deploy-token" || lease["type"] != "credential_store.url_token" || lease["purpose"] != "deploy" {
		t.Fatalf("lease body = %#v", lease)
	}
	got := output.String()
	if !strings.Contains(got, "lease-123") || !strings.Contains(got, "deploy-token") {
		t.Fatalf("output = %q", got)
	}
	if strings.Contains(got, "super-secret") || strings.Contains(got, "payload") {
		t.Fatalf("output included secret-shaped data: %q", got)
	}
}

func TestCredentialStoreLeaseRequiresPolicyFlagsBeforeNetwork(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	command := NewCredentialStoreCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"lease", "deploy-token", "--purpose", "deploy"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "--type is required") {
		t.Fatalf("expected --type error, got %v", err)
	}
}

func TestCredentialStoreLeaseSurfacesAuthorizationFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		w.Write([]byte(`{"error":{"code":"forbidden","message":"credential access denied: tool not allowed"}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	command := NewCredentialStoreCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"lease", "deploy-token", "--type", "credential_store.url_token", "--purpose", "deploy", "--tool", "deploy.push"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "tool not allowed") {
		t.Fatalf("expected authorization failure, got %v", err)
	}
}

func TestCredentialStoreExecEnvVarRunsChildAuditsAndRedactsOutput(t *testing.T) {
	var materialRequest map[string]any
	var auditRequest map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/app/credential_store/exec_material":
			if r.Method != http.MethodPost {
				t.Fatalf("unexpected material method %s", r.Method)
			}
			if err := json.NewDecoder(r.Body).Decode(&materialRequest); err != nil {
				t.Fatal(err)
			}
			w.Write([]byte(`{"lease":{"lease_id":"lease-exec","credential_id":7,"credential_name":"deploy-token","credential_type":"credential_store.url_token","issued_at":"2026-10-03T00:00:00Z","expires_at":"2026-10-03T00:02:00Z","purpose":"deploy","tool_name":"credential.exec"},"material":{"payload":"super-secret-token-123"}}`))
		case "/api/v1/app/credential_store/exec/audit":
			if r.Method != http.MethodPost {
				t.Fatalf("unexpected audit method %s", r.Method)
			}
			if err := json.NewDecoder(r.Body).Decode(&auditRequest); err != nil {
				t.Fatal(err)
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	output := &bytes.Buffer{}
	original := credentialExecRunner
	credentialExecRunner = execCommandRunner{stdin: strings.NewReader(""), stdout: output, stderr: output}
	t.Cleanup(func() { credentialExecRunner = original })

	command := NewCredentialStoreCommand()
	command.SetOut(output)
	command.SetErr(output)
	command.SetArgs([]string{
		"exec",
		"--credential", "deploy-token",
		"--type", "credential_store.url_token",
		"--env-var", "SERVICE_TOKEN",
		"--purpose", "deploy",
		"--target-json", `{"host":"api.example.com"}`,
		"--", "sh", "-c", `printf "%s" "$SERVICE_TOKEN"; printf "%s" "$SERVICE_TOKEN" >&2`,
	})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if strings.Contains(got, "super-secret-token-123") {
		t.Fatalf("output included secret material: %q", got)
	}
	if strings.Count(got, "[credential redacted]") != 2 {
		t.Fatalf("expected redacted stdout and stderr, got %q", got)
	}
	material := materialRequest["credential_exec"].(map[string]any)
	if material["credential"] != "deploy-token" || material["type"] != "credential_store.url_token" || material["tool_name"] != "credential.exec" {
		t.Fatalf("material request = %#v", material)
	}
	audit := auditRequest["credential_exec_audit"].(map[string]any)
	if audit["credential"] != "deploy-token" || audit["lease_id"] != "lease-exec" || audit["mode"] != "env-var" || audit["exit_status"].(float64) != 0 {
		t.Fatalf("audit request = %#v", audit)
	}
}

func TestCredentialStoreExecFileEnvSmokeRunsChildAuditsRedactsAndCleansUp(t *testing.T) {
	var materialRequest map[string]any
	var auditRequest map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/app/credential_store/exec_material":
			if r.Method != http.MethodPost {
				t.Fatalf("unexpected material method %s", r.Method)
			}
			if err := json.NewDecoder(r.Body).Decode(&materialRequest); err != nil {
				t.Fatal(err)
			}
			w.Write([]byte(`{"lease":{"lease_id":"lease-exec","credential_id":7,"credential_name":"deploy-token","credential_type":"credential_store.url_token","issued_at":"2026-10-03T00:00:00Z","expires_at":"2026-10-03T00:02:00Z","purpose":"deploy","tool_name":"credential.exec"},"material":{"payload":"super-secret-token-123"}}`))
		case "/api/v1/app/credential_store/exec/audit":
			if r.Method != http.MethodPost {
				t.Fatalf("unexpected audit method %s", r.Method)
			}
			if err := json.NewDecoder(r.Body).Decode(&auditRequest); err != nil {
				t.Fatal(err)
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	marker := filepath.Join(t.TempDir(), "credential-path")
	output := &bytes.Buffer{}
	original := credentialExecRunner
	credentialExecRunner = execCommandRunner{stdin: strings.NewReader(""), stdout: output, stderr: output}
	t.Cleanup(func() { credentialExecRunner = original })

	command := NewCredentialStoreCommand()
	command.SetOut(output)
	command.SetErr(output)
	command.SetArgs([]string{
		"exec",
		"--credential", "deploy-token",
		"--type", "credential_store.url_token",
		"--file-env", "SERVICE_TOKEN_FILE",
		"--purpose", "deploy",
		"--target-json", `{"host":"api.example.com"}`,
		"--", "sh", "-c", `test -f "$SERVICE_TOKEN_FILE" && cat "$SERVICE_TOKEN_FILE" && printf "%s" "$SERVICE_TOKEN_FILE" > "$1"`, "sh", marker,
	})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if strings.Contains(got, "super-secret-token-123") {
		t.Fatalf("output included secret material: %q", got)
	}
	if !strings.Contains(got, "[credential redacted]") {
		t.Fatalf("expected redacted child output, got %q", got)
	}
	tempPathBytes, err := os.ReadFile(marker)
	if err != nil {
		t.Fatalf("read child marker: %v", err)
	}
	tempPath := string(tempPathBytes)
	if tempPath == "" {
		t.Fatal("expected child to receive credential file path")
	}
	if _, err := os.Stat(tempPath); !os.IsNotExist(err) {
		t.Fatalf("expected temporary credential file cleanup, stat err = %v", err)
	}
	material := materialRequest["credential_exec"].(map[string]any)
	if material["credential"] != "deploy-token" || material["type"] != "credential_store.url_token" || material["tool_name"] != "credential.exec" {
		t.Fatalf("material request = %#v", material)
	}
	audit := auditRequest["credential_exec_audit"].(map[string]any)
	if audit["credential"] != "deploy-token" || audit["lease_id"] != "lease-exec" || audit["mode"] != "file-env" || audit["exit_status"].(float64) != 0 {
		t.Fatalf("audit request = %#v", audit)
	}
}

func TestCredentialStoreExecFileEnvUsesPrivateTempFileAndCleansUp(t *testing.T) {
	runner := &fakeProcessRunner{childStatus: 0}
	status, _ := runWithCredentialExecMaterial(context.Background(), runner, credentialExecInput{
		Mode:    credentialExecModeFileEnv,
		EnvKey:  "KUBECONFIG",
		Command: []string{"kubectl", "get", "pods"},
	}, "apiVersion: v1\nsecret-token")

	if status != 0 {
		t.Fatalf("status = %d", status)
	}
	if runner.credentialExecFilePath == "" {
		t.Fatal("expected file-env temp path")
	}
	if runner.credentialExecFileMode != 0o600 {
		t.Fatalf("temp file mode = %#o", runner.credentialExecFileMode)
	}
	if !strings.Contains(runner.credentialExecFileContent, "secret-token") {
		t.Fatalf("temp file content = %q", runner.credentialExecFileContent)
	}
	if _, err := os.Stat(runner.credentialExecFilePath); !os.IsNotExist(err) {
		t.Fatalf("expected temporary credential file cleanup, stat err = %v", err)
	}
	if got := envValue(runner.credentialExecEnv, "KUBECONFIG"); got != runner.credentialExecFilePath {
		t.Fatalf("KUBECONFIG = %q, want %q", got, runner.credentialExecFilePath)
	}
}

func TestCredentialStoreExecFileEnvIgnoresRepoLocalTempDir(t *testing.T) {
	repoDir := t.TempDir()
	repoTempDir := filepath.Join(repoDir, "tmp")
	if err := os.MkdirAll(repoTempDir, 0o700); err != nil {
		t.Fatal(err)
	}
	previousDir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(repoDir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(previousDir); err != nil {
			t.Fatalf("restore working directory: %v", err)
		}
	})
	t.Setenv("TMPDIR", repoTempDir)

	runner := &fakeProcessRunner{childStatus: 0}
	status, _ := runWithCredentialExecMaterial(context.Background(), runner, credentialExecInput{
		Mode:    credentialExecModeFileEnv,
		EnvKey:  "KUBECONFIG",
		Command: []string{"kubectl", "get", "pods"},
	}, "apiVersion: v1\nsecret-token")

	if status != 0 {
		t.Fatalf("status = %d", status)
	}
	if runner.credentialExecFilePath == "" {
		t.Fatal("expected file-env temp path")
	}
	if pathInside(runner.credentialExecFilePath, repoDir) {
		t.Fatalf("credential temp file was created inside repo: %s under %s", runner.credentialExecFilePath, repoDir)
	}
	if runner.credentialExecFileMode != 0o600 {
		t.Fatalf("temp file mode = %#o", runner.credentialExecFileMode)
	}
	if _, err := os.Stat(runner.credentialExecFilePath); !os.IsNotExist(err) {
		t.Fatalf("expected temporary credential file cleanup, stat err = %v", err)
	}
}

func TestCredentialStoreExecStdinFeedsPayloadWithoutChildEnv(t *testing.T) {
	runner := &fakeProcessRunner{childStatus: 0}
	status, _ := runWithCredentialExecMaterial(context.Background(), runner, credentialExecInput{
		Mode:    credentialExecModeStdin,
		Command: []string{"./script.sh"},
	}, "stdin-secret-token")

	if status != 0 {
		t.Fatalf("status = %d", status)
	}
	if runner.credentialExecStdin != "stdin-secret-token" {
		t.Fatalf("stdin = %q", runner.credentialExecStdin)
	}
	if joined := strings.Join(runner.credentialExecEnv, "\n"); strings.Contains(joined, "stdin-secret-token") {
		t.Fatalf("child env included stdin credential: %#v", runner.credentialExecEnv)
	}
}

func TestCredentialStoreExecRequiresExactlyOneMaterializationMode(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	command := NewCredentialStoreCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"exec", "--credential", "deploy-token", "--type", "credential_store.url_token", "--env-var", "SERVICE_TOKEN", "--stdin", "--", "./script.sh"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("expected mode validation error, got %v", err)
	}
}

func TestCredentialStoreSSHAgentRunsChildAuditsAndCleansUp(t *testing.T) {
	var materialRequest map[string]any
	var auditRequest map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requireAuth(t, r)
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/app/credential_store/ssh_agent":
			if r.Method != http.MethodPost {
				t.Fatalf("unexpected material method %s", r.Method)
			}
			if err := json.NewDecoder(r.Body).Decode(&materialRequest); err != nil {
				t.Fatal(err)
			}
			w.Write([]byte(`{"lease":{"lease_id":"lease-ssh","credential_id":9,"credential_name":"homeassistant-ssh","credential_type":"ssh_private_key","issued_at":"2026-10-03T00:00:00Z","expires_at":"2026-10-03T00:02:00Z","purpose":"deploy","tool_name":"credential.ssh-agent"},"ssh_key":{"private_key":"-----BEGIN OPENSSH PRIVATE KEY-----\nsecret-key-material\n-----END OPENSSH PRIVATE KEY-----\n","passphrase":"key-passphrase"}}`))
		case "/api/v1/app/credential_store/ssh_agent/audit":
			if r.Method != http.MethodPost {
				t.Fatalf("unexpected audit method %s", r.Method)
			}
			if err := json.NewDecoder(r.Body).Decode(&auditRequest); err != nil {
				t.Fatal(err)
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	runner := &fakeProcessRunner{childStatus: 0}
	original := sshAgentRunner
	sshAgentRunner = runner
	defer func() { sshAgentRunner = original }()

	command := NewCredentialStoreCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetErr(output)
	command.SetArgs([]string{
		"ssh-agent",
		"--credential", "homeassistant-ssh",
		"--purpose", "deploy",
		"--target-json", `{"host":"ha.example.com"}`,
		"--", "./deploy.sh", "--prod",
	})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if !runner.killed {
		t.Fatal("expected ssh-agent -k cleanup")
	}
	if runner.keyPath == "" {
		t.Fatal("expected ssh-add to receive a key path")
	}
	if _, err := os.Stat(runner.keyPath); !os.IsNotExist(err) {
		t.Fatalf("expected temporary key to be removed, stat err = %v", err)
	}
	if runner.askpassPath == "" {
		t.Fatal("expected passphrase askpass helper")
	}
	if _, err := os.Stat(runner.askpassPath); !os.IsNotExist(err) {
		t.Fatalf("expected askpass helper to be removed, stat err = %v", err)
	}
	if !reflect.DeepEqual(runner.childCommand, []string{"./deploy.sh", "--prod"}) {
		t.Fatalf("child command = %#v", runner.childCommand)
	}
	if got := envValue(runner.childEnv, "SSH_AUTH_SOCK"); got != "/tmp/syrus-agent.sock" {
		t.Fatalf("SSH_AUTH_SOCK = %q", got)
	}
	if got := envValue(runner.childEnv, "SYRUS_CLI_INVOCATION_CONTEXT"); got != "" {
		t.Fatalf("child inherited invocation context: %q", got)
	}
	if got := envValue(runner.childEnv, "SYRUS_CREDENTIAL_STORE_SSH_PASSPHRASE"); got != "" {
		t.Fatalf("child inherited SSH passphrase env: %q", got)
	}
	sshAgent := materialRequest["ssh_agent"].(map[string]any)
	if sshAgent["credential"] != "homeassistant-ssh" || sshAgent["tool_name"] != "credential.ssh-agent" {
		t.Fatalf("material request = %#v", sshAgent)
	}
	audit := auditRequest["ssh_agent_audit"].(map[string]any)
	if audit["credential"] != "homeassistant-ssh" || audit["lease_id"] != "lease-ssh" || audit["exit_status"].(float64) != 0 {
		t.Fatalf("audit request = %#v", audit)
	}
	if strings.Contains(output.String(), "secret-key-material") || strings.Contains(output.String(), "key-passphrase") {
		t.Fatalf("output included secret material: %q", output.String())
	}
}

func TestCredentialStoreSSHAgentPropagatesChildFailureAndStillAudits(t *testing.T) {
	var audited bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/app/credential_store/ssh_agent":
			w.Write([]byte(`{"lease":{"lease_id":"lease-ssh","credential_id":9,"credential_name":"homeassistant-ssh","credential_type":"ssh_private_key"},"ssh_key":{"private_key":"secret-key-material"}}`))
		case "/api/v1/app/credential_store/ssh_agent/audit":
			audited = true
			var request map[string]any
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Fatal(err)
			}
			if request["ssh_agent_audit"].(map[string]any)["exit_status"].(float64) != 37 {
				t.Fatalf("audit request = %#v", request)
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			t.Fatalf("unexpected request %s", r.URL.Path)
		}
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	runner := &fakeProcessRunner{childStatus: 37}
	original := sshAgentRunner
	sshAgentRunner = runner
	defer func() { sshAgentRunner = original }()

	command := NewCredentialStoreCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"ssh-agent", "--credential", "homeassistant-ssh", "--", "./deploy.sh"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "status 37") {
		t.Fatalf("expected child status error, got %v", err)
	}
	var exitStatus cliplugin.ExitStatusError
	if !errors.As(err, &exitStatus) || exitStatus.ExitStatus() != 37 {
		t.Fatalf("expected exit status 37 error, got %#v", err)
	}
	if !audited {
		t.Fatal("expected audit request for nonzero child exit")
	}
	if !runner.killed {
		t.Fatal("expected agent cleanup after child failure")
	}
}

func TestCredentialStoreSSHAgentSurfacesAuthorizationFailureWithoutStartingAgent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		w.Write([]byte(`{"error":{"code":"forbidden","message":"credential access denied: tool not allowed"}}`))
	}))
	defer server.Close()
	withCredentials(t, server.URL)

	runner := &fakeProcessRunner{}
	original := sshAgentRunner
	sshAgentRunner = runner
	defer func() { sshAgentRunner = original }()

	command := NewCredentialStoreCommand()
	output := &bytes.Buffer{}
	command.SetOut(output)
	command.SetArgs([]string{"ssh-agent", "--credential", "missing", "--", "./deploy.sh"})

	err := command.Execute()
	if err == nil || !strings.Contains(err.Error(), "tool not allowed") {
		t.Fatalf("expected authorization error, got %v", err)
	}
	if len(runner.calls) != 0 {
		t.Fatalf("expected no process starts, got %#v", runner.calls)
	}
}

func TestCredentialStoreSSHAgentChildEnvironmentIsSanitized(t *testing.T) {
	t.Setenv("PATH", "/usr/bin")
	t.Setenv("HOME", "/tmp/syrus-home")
	t.Setenv("LANG", "C.UTF-8")
	t.Setenv("LC_ALL", "C.UTF-8")
	t.Setenv("SYRUS_CLI_URL", "https://syrus.example.test")
	t.Setenv("SYRUS_CLI_INVOCATION_CONTEXT", "runtime-token")
	t.Setenv("SYRUS_CLI_INTERNAL", "1")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "cloud-secret")

	runner := &fakeProcessRunner{childStatus: 0}
	status, _ := runWithSSHAgent(
		context.Background(),
		runner,
		SSHKeyData{PrivateKey: "secret-key-material", Passphrase: "key-passphrase"},
		[]string{"./deploy.sh"},
	)

	if status != 0 {
		t.Fatalf("status = %d", status)
	}
	expected := map[string]string{
		"PATH":          "/usr/bin",
		"HOME":          "/tmp/syrus-home",
		"LANG":          "C.UTF-8",
		"LC_ALL":        "C.UTF-8",
		"SSH_AUTH_SOCK": "/tmp/syrus-agent.sock",
		"SSH_AGENT_PID": "123",
	}
	for key, want := range expected {
		if got := envValue(runner.childEnv, key); got != want {
			t.Fatalf("%s = %q, want %q in child env %#v", key, got, want, runner.childEnv)
		}
	}
	for _, key := range []string{
		"SYRUS_CLI_URL",
		"SYRUS_CLI_INVOCATION_CONTEXT",
		"SYRUS_CLI_INTERNAL",
		"AWS_SECRET_ACCESS_KEY",
		"SYRUS_CREDENTIAL_STORE_SSH_PASSPHRASE",
		"SSH_ASKPASS",
		"SSH_ASKPASS_REQUIRE",
	} {
		if got := envValue(runner.childEnv, key); got != "" {
			t.Fatalf("child env included %s=%q", key, got)
		}
	}
}

type fakeProcessRunner struct {
	childStatus  int
	calls        []string
	keyPath      string
	askpassPath  string
	childCommand []string
	childEnv     []string
	killed       bool

	credentialExecCommand     []string
	credentialExecEnv         []string
	credentialExecStdin       string
	credentialExecFilePath    string
	credentialExecFileMode    os.FileMode
	credentialExecFileContent string
}

func (runner *fakeProcessRunner) Run(_ context.Context, env []string, name string, args ...string) processResult {
	runner.calls = append(runner.calls, name+" "+strings.Join(args, " "))
	switch name {
	case "ssh-agent":
		if len(args) == 1 && args[0] == "-s" {
			return processResult{Stdout: "SSH_AUTH_SOCK=/tmp/syrus-agent.sock; export SSH_AUTH_SOCK;\nSSH_AGENT_PID=123; export SSH_AGENT_PID;\n", Status: 0}
		}
		if len(args) == 1 && args[0] == "-k" {
			runner.killed = true
			return processResult{Status: 0}
		}
	case "ssh-add":
		runner.keyPath = args[0]
		if got := envValue(env, "SSH_ASKPASS"); got != "" {
			runner.askpassPath = got
		}
		if content, err := os.ReadFile(runner.keyPath); err != nil || !strings.Contains(string(content), "secret-key-material") {
			return processResult{Status: 2}
		}
		return processResult{Status: 0}
	default:
		runner.childCommand = append([]string{name}, args...)
		runner.childEnv = append([]string{}, env...)
		return processResult{Status: runner.childStatus}
	}
	return processResult{Status: 1}
}

func (runner *fakeProcessRunner) RunCredentialExec(_ context.Context, env []string, stdin io.Reader, _ []string, name string, args ...string) processResult {
	runner.credentialExecCommand = append([]string{name}, args...)
	runner.credentialExecEnv = append([]string{}, env...)
	if stdin != nil {
		content, _ := io.ReadAll(stdin)
		runner.credentialExecStdin = string(content)
	}
	if path := envValue(env, "KUBECONFIG"); path != "" {
		runner.credentialExecFilePath = path
		if stat, err := os.Stat(path); err == nil {
			runner.credentialExecFileMode = stat.Mode() & 0o777
		}
		if content, err := os.ReadFile(path); err == nil {
			runner.credentialExecFileContent = string(content)
		}
	}
	return processResult{Status: runner.childStatus}
}

func envValue(env []string, key string) string {
	prefix := key + "="
	for _, entry := range env {
		if strings.HasPrefix(entry, prefix) {
			return strings.TrimPrefix(entry, prefix)
		}
	}
	return ""
}
