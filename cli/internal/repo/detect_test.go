package repo

import "testing"

func TestParseRemoteURL(t *testing.T) {
	cases := map[string]string{
		"git@github.com:tkadauke/syrus.git":     "tkadauke/syrus",
		"https://github.com/tkadauke/syrus.git": "tkadauke/syrus",
		"https://github.com/tkadauke/syrus":     "tkadauke/syrus",
	}

	for remote, want := range cases {
		got, ok := ParseRemoteURL(remote)
		if !ok {
			t.Fatalf("ParseRemoteURL(%q) did not parse", remote)
		}
		if got != want {
			t.Fatalf("ParseRemoteURL(%q) = %q, want %q", remote, got, want)
		}
	}
}

func TestParseRemoteURLRejectsNonGithubRemotes(t *testing.T) {
	if got, ok := ParseRemoteURL("https://example.com/tkadauke/syrus.git"); ok {
		t.Fatalf("ParseRemoteURL parsed %q", got)
	}
}
