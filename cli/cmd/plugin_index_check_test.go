package cmd

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/plugintrust"
)

func TestMinimumSyrusVersion(t *testing.T) {
	for requirement, expected := range map[string]string{
		">= 1.2.3":      "1.2.3",
		"~> 2.4, < 3.0": "2.4",
		"< 2.0":         "",
		"anything":      "",
	} {
		if actual := minimumSyrusVersion(requirement); actual != expected {
			t.Errorf("minimumSyrusVersion(%q)=%q, want %q", requirement, actual, expected)
		}
	}
}

func TestRegistryReleaseRequiresPublisherPrefix(t *testing.T) {
	release := pluginRegistryRelease{Name: "weather", Version: "1.0.0"}
	if err := validateRegistryRelease("weather/1.0.0.json", release); err == nil {
		t.Fatal("expected unprefixed plugin name to be rejected")
	}
}

func TestIndexCheckRejectsInvalidPackage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "invalid.tar.gz")
	file, _ := os.Create(path)
	gz := gzip.NewWriter(file)
	tarball := tar.NewWriter(gz)
	tarball.WriteHeader(&tar.Header{Name: "../escape", Mode: 0644, Size: 1})
	tarball.Write([]byte("x"))
	tarball.Close()
	gz.Close()
	file.Close()
	if _, err := extractSubmittedPackage(path, t.TempDir()); err == nil || !strings.Contains(err.Error(), "unsafe") {
		t.Fatalf("unexpected invalid-package result: %v", err)
	}
}

func TestPluginIndexCheckEndToEndAndFailureClasses(t *testing.T) {
	plugin := packageFixture(t)
	gemspec := filepath.Join(plugin, "weather.gemspec")
	data, _ := os.ReadFile(gemspec)
	os.WriteFile(gemspec, []byte(strings.ReplaceAll(string(data), `"weather"`, `"acme_weather"`)), 0644)
	manifest, files, _ := inspectPluginPackage(plugin)
	archive := filepath.Join(t.TempDir(), "package.tar.gz")
	writePluginPackage(archive, manifest, files)
	packageBytes, _ := os.ReadFile(archive)
	key, _ := plugintrust.GenerateKey()
	signature, _ := plugintrust.Sign(archive, key)
	signatureBytes, _ := json.Marshal(signature)
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if strings.HasSuffix(request.URL.Path, ".sig") {
			response.Write(signatureBytes)
		} else {
			response.Write(packageBytes)
		}
	}))
	defer server.Close()
	previousHTTP, previousRunner := pluginIndexCheckHTTP, newDockerPluginRunner
	pluginIndexCheckHTTP = server.Client()
	runner := &fakePluginRunner{}
	newDockerPluginRunner = func() pluginRunner { return runner }
	t.Cleanup(func() { pluginIndexCheckHTTP, newDockerPluginRunner = previousHTTP, previousRunner })
	sum := sha256.Sum256(packageBytes)
	entry := pluginRegistryRelease{Name: "acme_weather", Version: "1.2.3", Description: "Weather", Category: "automation", Author: "Acme", Homepage: "https://example.test", License: "MIT", RequiresSyrus: ">= 1.0", PackageURL: server.URL + "/package", PackageDigest: "sha256:" + hex.EncodeToString(sum[:]), SignatureURL: server.URL + "/package.sig", PublisherKeyFingerprint: key.Fingerprint, TrustLabelInputs: json.RawMessage(`{}`), CapabilitySummary: mustJSON(manifest)}
	trust, _ := json.Marshal(plugintrust.TrustStore{Publishers: []plugintrust.Publisher{{Fingerprint: key.Fingerprint, Label: "community"}}})
	root := t.TempDir()
	trustPath := filepath.Join(root, "trust.json")
	os.WriteFile(trustPath, trust, 0644)
	run := func(value pluginRegistryRelease) error {
		payload, _ := json.Marshal(value)
		path := filepath.Join(root, value.Name, value.Version+".json")
		os.MkdirAll(filepath.Dir(path), 0755)
		os.WriteFile(path, payload, 0644)
		command := NewRootCommand()
		command.SetOut(&bytes.Buffer{})
		command.SetErr(&bytes.Buffer{})
		command.SetArgs([]string{"plugin", "index-check", path, "--trust-store", trustPath})
		return command.Execute()
	}
	if err := run(entry); err != nil {
		t.Fatalf("good submission failed: %v", err)
	}
	bad := entry
	bad.Author = "Other"
	if err := run(bad); err == nil || !strings.Contains(err.Error(), "prefix") {
		t.Fatalf("wrong prefix: %v", err)
	}
	bad = entry
	bad.PackageDigest = "sha256:" + strings.Repeat("0", 64)
	if err := run(bad); err == nil || !strings.Contains(err.Error(), "digest") {
		t.Fatalf("digest mismatch: %v", err)
	}
	bad = entry
	bad.PublisherKeyFingerprint = strings.Repeat("0", 64)
	if err := run(bad); err == nil {
		t.Fatal("expected bad signature metadata failure")
	}
	badSignature := signature
	badSignature.Signature = "AAAA"
	signatureBytes, _ = json.Marshal(badSignature)
	if err := run(entry); err == nil || !strings.Contains(err.Error(), "signature verification failed") {
		t.Fatalf("bad cryptographic signature: %v", err)
	}
	signatureBytes, _ = json.Marshal(signature)
	bad = entry
	bad.CapabilitySummary = json.RawMessage(`{"name":"acme_weather"}`)
	if err := run(bad); err == nil || !strings.Contains(err.Error(), "capability summary") {
		t.Fatalf("capability mismatch: %v", err)
	}
	runner.runErr = os.ErrInvalid
	if err := run(entry); err == nil || !strings.Contains(err.Error(), "contract tests") {
		t.Fatalf("failing tests: %v", err)
	}
}
