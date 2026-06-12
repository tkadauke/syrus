package cmd

import "testing"

func TestParseGitHubSlug(t *testing.T) {
	tests := map[string]string{
		"https://github.com/tkadauke/syrus.git": "tkadauke/syrus",
		"git@github.com:tkadauke/syrus.git":    "tkadauke/syrus",
		"https://github.com/acme/my.repo":       "acme/my.repo",
		"https://example.com/acme/my.repo":      "",
	}

	for remote, want := range tests {
		if got := parseGitHubSlug(remote); got != want {
			t.Fatalf("parseGitHubSlug(%q) = %q, want %q", remote, got, want)
		}
	}
}

func TestLast4(t *testing.T) {
	if got := last4("secret-token"); got != "oken" {
		t.Fatalf("last4 returned %q", got)
	}
	if got := last4("abc"); got != "abc" {
		t.Fatalf("last4 short token returned %q", got)
	}
}
