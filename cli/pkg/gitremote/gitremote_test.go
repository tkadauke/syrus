package gitremote

import "testing"

func TestGitHubSlug(t *testing.T) {
	tests := map[string]string{
		"https://github.com/tkadauke/syrus.git":                      "tkadauke/syrus",
		"https://x-access-token:ghs_SECRET@github.com/acme/repo.git": "acme/repo",
		"ssh://git@github.com/acme/repo.git":                         "acme/repo",
		"git@github.com:acme/repo.git":                               "acme/repo",
		"https://example.com/acme/repo.git":                          "",
	}

	for remote, want := range tests {
		if got := GitHubSlug(remote); got != want {
			t.Fatalf("GitHubSlug(%q) = %q, want %q", remote, got, want)
		}
	}
}

func TestRedact(t *testing.T) {
	input := "fatal: unable to access 'https://x-access-token:ghs_SECRET@github.com/acme/repo.git/': denied"
	want := "fatal: unable to access 'https://github.com/acme/repo.git/': denied"
	if got := Redact(input); got != want {
		t.Fatalf("Redact() = %q, want %q", got, want)
	}
}
