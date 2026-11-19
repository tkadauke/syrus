package cmd

import (
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
	os.WriteFile(packagePath, []byte("package"), 0644)
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
		result := verifyPluginPackage(packagePath, envelope, store, "weather", "1.0")
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
	if reason := verifyPluginPackage(packagePath, envelope, store, "weather", "1.0").Reason; reason != "invalid_signature" {
		t.Fatal(reason)
	}
	packagePath, otherKeyPath, _ := signingFixture(t)
	wrongEnvelope, _ := signPluginPackage(packagePath, otherKeyPath)
	if reason := verifyPluginPackage(packagePath, wrongEnvelope, store, "weather", "1.0").Reason; reason != "unknown_key" {
		t.Fatal(reason)
	}
	store.RevokedKeys = []string{envelope.Fingerprint}
	if reason := verifyPluginPackage(packagePath, envelope, store, "weather", "1.0").Reason; reason != "revoked_key" {
		t.Fatal(reason)
	}
	store.RevokedKeys = nil
	store.RevokedReleases = []revokedPluginRelease{{Name: "weather", Version: "1.0"}}
	if reason := verifyPluginPackage(packagePath, envelope, store, "weather", "1.0").Reason; reason != "revoked_release" {
		t.Fatal(reason)
	}
}
