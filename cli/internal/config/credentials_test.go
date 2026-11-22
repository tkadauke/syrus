package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseCredentialsReadsKeyValueFile(t *testing.T) {
	creds, err := ParseCredentials(strings.NewReader(`
# Syrus CLI
url = "https://syrus.example.com"
token=secret-token
`))
	if err != nil {
		t.Fatalf("ParseCredentials returned error: %v", err)
	}

	if creds.URL != "https://syrus.example.com" {
		t.Fatalf("URL = %q", creds.URL)
	}
	if creds.Token != "secret-token" {
		t.Fatalf("Token = %q", creds.Token)
	}
}

func TestLoadCredentialsRejectsIncompleteFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "credentials")
	if err := os.WriteFile(path, []byte("url=https://syrus.example.com\n"), 0600); err != nil {
		t.Fatal(err)
	}

	_, err := LoadCredentials(path)
	if !errors.Is(err, ErrIncompleteCredentials) {
		t.Fatalf("expected ErrIncompleteCredentials, got %v", err)
	}
}

func TestSaveCredentialsCreatesPrivateFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".syrus", "credentials")
	if err := SaveCredentials(path, Credentials{URL: "https://syrus.example.com", Token: "secret"}); err != nil {
		t.Fatalf("SaveCredentials returned error: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0600 {
		t.Fatalf("file mode = %v, want 0600", got)
	}

	creds, err := LoadCredentials(path)
	if err != nil {
		t.Fatalf("LoadCredentials returned error: %v", err)
	}
	if creds.URL != "https://syrus.example.com" || creds.Token != "secret" {
		t.Fatalf("credentials = %#v", creds)
	}
}

func TestSaveCredentialsTightensPermissionsOnExistingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "credentials")
	if err := os.WriteFile(path, []byte("url=https://stale.example.com\ntoken=stale\n"), 0644); err != nil {
		t.Fatal(err)
	}

	if err := SaveCredentials(path, Credentials{URL: "https://syrus.example.com", Token: "secret"}); err != nil {
		t.Fatalf("SaveCredentials returned error: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0600 {
		t.Fatalf("file mode = %v, want 0600", got)
	}
}

func TestLoadDefaultCredentialsPrefersInvocationContext(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("SYRUS_CLI_URL", "https://syrus.example.com")
	t.Setenv("SYRUS_CLI_INVOCATION_CONTEXT", "signed-context")
	if err := SaveCredentials(filepath.Join(home, ".syrus", "credentials"), Credentials{URL: "https://human.example.com", Token: "human-token"}); err != nil {
		t.Fatal(err)
	}

	creds, err := LoadDefaultCredentials()
	if err != nil {
		t.Fatalf("LoadDefaultCredentials returned error: %v", err)
	}
	if !creds.Internal || creds.URL != "https://syrus.example.com" || creds.Token != "signed-context" {
		t.Fatalf("credentials = %#v", creds)
	}
}

func TestLoadDefaultCredentialsReportsIncompleteInvocationContext(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SYRUS_CLI_INTERNAL", "1")
	t.Setenv("SYRUS_CLI_URL", "https://syrus.example.com")

	_, err := LoadDefaultCredentials()
	if !errors.Is(err, ErrMissingInvocationContext) {
		t.Fatalf("expected ErrMissingInvocationContext, got %v", err)
	}
}

// SaveCredentials wrote the token into whatever the path pointed at and only
// then tightened its mode, so a credentials path that is a symlink sent the
// token into the link's target (with that file's permissions), and a
// pre-existing loose file held the new token readable until the chmod. The
// token is now written to a fresh 0600 file beside the path and renamed over
// it, replacing the link itself.
func TestSaveCredentialsNeverWritesThroughASymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(t.TempDir(), "elsewhere")
	if err := os.WriteFile(target, []byte("unrelated\n"), 0644); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "credentials")
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}

	if err := SaveCredentials(path, Credentials{URL: "https://syrus.example.com", Token: "secret-token"}); err != nil {
		t.Fatalf("SaveCredentials: %v", err)
	}

	contents, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(contents), "secret-token") {
		t.Fatalf("token was written through the symlink into %s", target)
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("credentials path is still a symlink")
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("mode = %v, want 0600", info.Mode().Perm())
	}
	saved, err := LoadCredentials(path)
	if err != nil || saved.Token != "secret-token" {
		t.Fatalf("LoadCredentials = %+v, %v", saved, err)
	}
}
