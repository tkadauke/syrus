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

func TestExitStatusErrorNormalizesProcessStatus(t *testing.T) {
	tests := map[int]int{
		-1:  1,
		0:   1,
		37:  37,
		300: 255,
	}

	for status, want := range tests {
		if got := (ExitStatusError{Status: status}).ExitStatus(); got != want {
			t.Fatalf("ExitStatusError{%d}.ExitStatus() = %d, want %d", status, got, want)
		}
	}
}
