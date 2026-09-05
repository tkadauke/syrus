package cliplugin

import "testing"

func TestParseGitHubSlug(t *testing.T) {
	tests := map[string]string{
		"https://github.com/tkadauke/syrus.git": "tkadauke/syrus",
		"git@github.com:tkadauke/syrus.git":     "tkadauke/syrus",
		"https://github.com/acme/my.repo":       "acme/my.repo",
		"https://example.com/acme/my.repo":      "",
	}

	for remote, want := range tests {
		if got := parseGitHubSlug(remote); got != want {
			t.Fatalf("parseGitHubSlug(%q) = %q, want %q", remote, got, want)
		}
	}
}
