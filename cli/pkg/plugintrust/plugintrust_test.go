package plugintrust

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestSignAndVerifyTrustLabels(t *testing.T) {
	path := filepath.Join(t.TempDir(), "package.tar.gz")
	if err := os.WriteFile(path, []byte("package"), 0600); err != nil {
		t.Fatal(err)
	}
	key, err := GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	signature, err := Sign(path, key)
	if err != nil {
		t.Fatal(err)
	}
	for _, label := range []string{"official", "verified", "community"} {
		result, err := Verify(path, signature, TrustStore{Publishers: []Publisher{{Fingerprint: key.Fingerprint, Label: label, Prefix: "acme"}}}, false)
		if err != nil || result.TrustLabel != label {
			t.Fatalf("label %s: result=%+v err=%v", label, result, err)
		}
	}
}

func TestVerifyRejectsTamperingWrongAndRevokedKeys(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "package")
	os.WriteFile(path, []byte("package"), 0600)
	key, _ := GenerateKey()
	signature, _ := Sign(path, key)
	store := TrustStore{Publishers: []Publisher{{Fingerprint: key.Fingerprint, Label: "verified", Prefix: "acme"}}}
	os.WriteFile(path, []byte("tampered"), 0600)
	if _, err := Verify(path, signature, store, false); err == nil {
		t.Fatal("accepted tampered package")
	}
	os.WriteFile(path, []byte("package"), 0600)
	other, _ := GenerateKey()
	wrong, _ := Sign(path, other)
	wrong.PublicKey = key.PublicKey
	wrong.Fingerprint = key.Fingerprint
	if _, err := Verify(path, wrong, store, false); err == nil {
		t.Fatal("accepted wrong key")
	}
	store.RevokedKeys = []string{key.Fingerprint}
	if _, err := Verify(path, signature, store, false); err == nil {
		t.Fatal("accepted revoked key")
	}
}

func TestUnsignedLocalAndTrustStoreJSON(t *testing.T) {
	result, err := Verify("unused", Signature{}, TrustStore{}, true)
	if err != nil || result.TrustLabel != "unsigned_local" {
		t.Fatalf("result=%+v err=%v", result, err)
	}
	var store TrustStore
	if err := json.Unmarshal([]byte(`{"revoked_releases":[{"name":"weather","version":"1.0","digest":"abc"}]}`), &store); err != nil {
		t.Fatal(err)
	}
	if store.RevokedReleases[0].Name != "weather" {
		t.Fatalf("bad release: %+v", store.RevokedReleases[0])
	}
}

func TestVerifyRejectsRevokedRelease(t *testing.T) {
	path := filepath.Join(t.TempDir(), "package")
	os.WriteFile(path, []byte("package"), 0600)
	key, _ := GenerateKey()
	signature, _ := Sign(path, key)
	store := TrustStore{
		Publishers:      []Publisher{{Fingerprint: key.Fingerprint, Label: "verified", Prefix: "acme"}},
		RevokedReleases: []RevokedRelease{{Name: "weather", Version: "1.2.3", Digest: signature.Digest}},
	}
	if _, err := VerifyRelease(path, signature, store, false, "weather", "1.2.3"); err == nil {
		t.Fatal("accepted revoked release")
	}
}
