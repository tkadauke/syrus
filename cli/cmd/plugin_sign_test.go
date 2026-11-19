package cmd

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
)

func signingFixture(t *testing.T) (string, string, ed25519.PublicKey) {
	t.Helper()
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(private)
	root := t.TempDir()
	keyPath := filepath.Join(root, "publisher.pem")
	packagePath := filepath.Join(root, "weather.tar.gz")
	os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0600)
	if err := writePluginPackage(packagePath, packageManifest{Name: "weather", Version: "1.0"}, map[string][]byte{}); err != nil {
		t.Fatal(err)
	}
	return packagePath, keyPath, public
}

func TestPluginSignatureVerificationAndTrustLabels(t *testing.T) {
	packagePath, keyPath, public := signingFixture(t)
	envelope, err := signPluginPackage(packagePath, keyPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, label := range []string{"official", "verified", "community"} {
		publicDER, _ := x509.MarshalPKIXPublicKey(public)
		store := pluginTrustStore{Version: 1, Keys: []pluginTrustKey{{Fingerprint: envelope.Fingerprint, Label: label, PublicKey: base64.StdEncoding.EncodeToString(publicDER)}}}
		result := verifyPluginPackage(packagePath, envelope, store)
		if !result.Trusted || result.Label != label {
			t.Fatalf("%s: %#v", label, result)
		}
	}
}

func TestPluginSignatureRejectsTamperingWrongKeyAndRevocation(t *testing.T) {
	packagePath, keyPath, public := signingFixture(t)
	envelope, _ := signPluginPackage(packagePath, keyPath)
	publicDER, _ := x509.MarshalPKIXPublicKey(public)
	store := pluginTrustStore{Version: 1, Keys: []pluginTrustKey{{Fingerprint: envelope.Fingerprint, Label: "verified", PublicKey: base64.StdEncoding.EncodeToString(publicDER)}}}
	os.WriteFile(packagePath, []byte("tampered"), 0644)
	if reason := verifyPluginPackage(packagePath, envelope, store).Reason; reason != "invalid_package" {
		t.Fatal(reason)
	}
	packagePath, otherKeyPath, _ := signingFixture(t)
	wrongEnvelope, _ := signPluginPackage(packagePath, otherKeyPath)
	if reason := verifyPluginPackage(packagePath, wrongEnvelope, store).Reason; reason != "unknown_key" {
		t.Fatal(reason)
	}
	store.RevokedKeys = []string{envelope.Fingerprint}
	if reason := verifyPluginPackage(packagePath, envelope, store).Reason; reason != "revoked_key" {
		t.Fatal(reason)
	}
	store.RevokedKeys = nil
	store.RevokedReleases = []revokedPluginRelease{{Name: "weather", Version: "1.0", Digest: envelope.Digest}}
	if reason := verifyPluginPackage(packagePath, envelope, store).Reason; reason != "revoked_release" {
		t.Fatal(reason)
	}
}

func TestPluginKeygenPrintsRegistryMaterial(t *testing.T) {
	output := filepath.Join(t.TempDir(), "publisher.pem")
	command := newPluginKeygenCommand()
	buffer := &bytes.Buffer{}
	command.SetOut(buffer)
	command.SetArgs([]string{"--output", output})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(buffer.Bytes(), []byte("Fingerprint: sha256:")) || !bytes.Contains(buffer.Bytes(), []byte("Public key: ")) {
		t.Fatalf("missing registry material: %s", buffer.String())
	}
}

func TestPluginListShowsTrustLabels(t *testing.T) {
	root := t.TempDir()
	manifest := filepath.Join(root, "manifest.json")
	signature := filepath.Join(root, "manifest.json.sig")
	body := []byte(`{"plugins":[{"name":"weather","version":"1.0","trust_label":"verified"}]}`)
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	os.WriteFile(manifest, body, 0644)
	os.WriteFile(signature, []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(private, body))), 0644)
	command := newPluginListCommand()
	buffer := &bytes.Buffer{}
	command.SetOut(buffer)
	command.SetArgs([]string{"--manifest", manifest, "--signature", signature, "--public-key", base64.StdEncoding.EncodeToString(public)})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if got := buffer.String(); got != "weather\t1.0\tverified\n" {
		t.Fatalf("unexpected list output: %q", got)
	}
}
