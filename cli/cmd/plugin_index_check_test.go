package cmd

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"
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

func TestIndexCheckExtractsValidatorApprovedDirectoryEntries(t *testing.T) {
	path := filepath.Join(t.TempDir(), "directories.tar.gz")
	file, _ := os.Create(path)
	gz := gzip.NewWriter(file)
	tarball := tar.NewWriter(gz)
	tarball.WriteHeader(&tar.Header{Name: "plugin/", Mode: 0755, Typeflag: tar.TypeDir})
	manifest := packageManifest{FormatVersion: 1, Name: "acme_weather", Version: "1.2.3", RequiresSyrus: ">= 1.0", Files: []packageFile{}}
	manifestBytes, _ := json.Marshal(manifest)
	tarball.WriteHeader(&tar.Header{Name: "package.json", Mode: 0644, Size: int64(len(manifestBytes)), Typeflag: tar.TypeReg})
	tarball.Write(manifestBytes)
	tarball.Close()
	gz.Close()
	file.Close()
	root := t.TempDir()
	if _, err := extractSubmittedPackage(path, root); err != nil {
		t.Fatalf("directory entry rejected: %v", err)
	}
	if info, err := os.Stat(filepath.Join(root, "plugin")); err != nil || !info.IsDir() {
		t.Fatalf("plugin directory was not extracted: %v", err)
	}
}

func TestIndexResourceURLRejectsPrivateAndReservedDestinations(t *testing.T) {
	for _, raw := range []string{
		"http://example.com/package",
		"https://127.0.0.1/package",
		"https://169.254.169.254/latest/meta-data",
		"https://[::1]/package",
		"https://192.0.2.1/package",
	} {
		if err := validateIndexResourceURL(t.Context(), raw); err == nil {
			t.Errorf("expected %s to be rejected", raw)
		}
	}
}

func TestIndexResourceDownloadValidatesRedirectDestinations(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		http.Redirect(response, request, "https://169.254.169.254/latest/meta-data", http.StatusFound)
	}))
	defer server.Close()
	previousHTTP, previousLookup, previousDial := pluginIndexCheckHTTP, pluginIndexCheckLookupIP, pluginIndexCheckDialContext
	pluginIndexCheckHTTP = server.Client()
	pluginIndexCheckLookupIP = func(_ context.Context, host string) ([]net.IPAddr, error) {
		if host == "127.0.0.1" {
			return []net.IPAddr{{IP: net.ParseIP("93.184.216.34")}}, nil
		}
		return nil, errors.New("unsafe redirect destination")
	}
	pluginIndexCheckDialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}
	t.Cleanup(func() {
		pluginIndexCheckHTTP, pluginIndexCheckLookupIP, pluginIndexCheckDialContext = previousHTTP, previousLookup, previousDial
	})
	command := &cobra.Command{}
	command.SetContext(t.Context())
	if _, err := downloadIndexResource(command, server.URL); err == nil || !strings.Contains(err.Error(), "unsafe redirect destination") {
		t.Fatalf("redirect validation error: %v", err)
	}
}

func TestIndexResourceDownloadRejectsDNSRebindingAtDialTime(t *testing.T) {
	previousLookup, previousDial := pluginIndexCheckLookupIP, pluginIndexCheckDialContext
	lookups := 0
	pluginIndexCheckLookupIP = func(context.Context, string) ([]net.IPAddr, error) {
		lookups++
		if lookups == 1 {
			return []net.IPAddr{{IP: net.ParseIP("93.184.216.34")}}, nil
		}
		return []net.IPAddr{{IP: net.ParseIP("127.0.0.1")}}, nil
	}
	dialed := false
	pluginIndexCheckDialContext = func(context.Context, string, string) (net.Conn, error) {
		dialed = true
		return nil, errors.New("unexpected dial")
	}
	t.Cleanup(func() { pluginIndexCheckLookupIP, pluginIndexCheckDialContext = previousLookup, previousDial })
	command := &cobra.Command{}
	command.SetContext(t.Context())
	if _, err := downloadIndexResource(command, "https://rebind.example/package"); err == nil || !strings.Contains(err.Error(), "private or reserved") {
		t.Fatalf("DNS rebinding result: %v", err)
	}
	if dialed {
		t.Fatal("dialed an address after DNS rebinding resolved to a private destination")
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
	previousHTTP, previousRunner, previousLookup, previousDial := pluginIndexCheckHTTP, newDockerPluginRunner, pluginIndexCheckLookupIP, pluginIndexCheckDialContext
	pluginIndexCheckHTTP = server.Client()
	pluginIndexCheckLookupIP = func(context.Context, string) ([]net.IPAddr, error) {
		return []net.IPAddr{{IP: net.ParseIP("93.184.216.34")}}, nil
	}
	pluginIndexCheckDialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}
	runner := &fakePluginRunner{}
	newDockerPluginRunner = func() pluginRunner { return runner }
	t.Cleanup(func() {
		pluginIndexCheckHTTP, newDockerPluginRunner = previousHTTP, previousRunner
		pluginIndexCheckLookupIP, pluginIndexCheckDialContext = previousLookup, previousDial
	})
	sum := sha256.Sum256(packageBytes)
	entry := pluginRegistryRelease{Name: "acme_weather", Version: "1.2.3", Description: "Weather", Category: "automation", Author: "Acme", Homepage: "https://example.test", License: "MIT", RequiresSyrus: ">= 1.0", PackageURL: server.URL + "/package", PackageDigest: "sha256:" + hex.EncodeToString(sum[:]), SignatureURL: server.URL + "/package.sig", PublisherKeyFingerprint: key.Fingerprint, TrustLabelInputs: json.RawMessage(`{}`), CapabilitySummary: mustJSON(manifest)}
	trustStore := plugintrust.TrustStore{Publishers: []plugintrust.Publisher{{Fingerprint: key.Fingerprint, Label: "community", Prefix: "acme"}}}
	trust, _ := json.Marshal(trustStore)
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
	trustStore.Publishers[0].Prefix = "other"
	wrongPublisherTrust, _ := json.Marshal(trustStore)
	os.WriteFile(trustPath, wrongPublisherTrust, 0644)
	if err := run(entry); err == nil || !strings.Contains(err.Error(), "not listed for the plugin name prefix") {
		t.Fatalf("cross-publisher key: %v", err)
	}
	os.WriteFile(trustPath, trust, 0644)
	runner.runErrors = map[string]error{"package-validate": os.ErrInvalid}
	if err := run(entry); err == nil || !strings.Contains(err.Error(), "package validator failed") {
		t.Fatalf("invalid canonical package: %v", err)
	}
	runner.runErrors = nil
	runner.runErrors = map[string]error{"test": os.ErrInvalid}
	if err := run(entry); err == nil || !strings.Contains(err.Error(), "contract tests") {
		t.Fatalf("failing tests: %v", err)
	}
}
