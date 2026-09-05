// Package cliplugintest is the test harness half of the plugin CLI contract.
//
// A plugin's command tests live in the plugin's own module and cannot reach
// the CLI's unexported test helpers, so the two a command test actually needs
// -- a credentials file pointing at an httptest server, and a stubbed repo
// detection -- are exported here.
package cliplugintest

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

// WithCredentials points the CLI at url/token for the duration of the test by
// writing a credentials file into a temporary HOME.
func WithCredentials(t *testing.T, url string, token string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, ".syrus", "credentials")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("url="+url+"\ntoken="+token+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
}

// WithRepoSlug makes repo detection report slug, as if the command ran inside
// that checkout.
func WithRepoSlug(t *testing.T, slug string) {
	t.Helper()
	previous := cliplugin.DetectCurrentRepoSlug
	cliplugin.DetectCurrentRepoSlug = func() string { return slug }
	t.Cleanup(func() { cliplugin.DetectCurrentRepoSlug = previous })
}
