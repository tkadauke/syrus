package cmd

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNormalizeJobIDAcceptsSlugs(t *testing.T) {
	cases := []struct {
		input string
		want  string
		isErr bool
	}{
		{"JOB-123", "123", false},
		{"job-456", "456", false},
		{"123", "123", false},
		{"my-feature-slug", "my-feature-slug", false},
		{"add-user-avatar-upload", "add-user-avatar-upload", false},
		{"", "", true},
		{"JOB-", "", true},
	}
	for _, tc := range cases {
		got, err := normalizeJobID(tc.input)
		if tc.isErr {
			if err == nil {
				t.Errorf("normalizeJobID(%q) expected error, got %q", tc.input, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("normalizeJobID(%q) error: %v", tc.input, err)
			continue
		}
		if got != tc.want {
			t.Errorf("normalizeJobID(%q) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

func TestApproveCommandAcceptsJobSlug(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	var requestedURL string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestedURL = r.URL.String()
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	writeCredentials(t, home, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"approve", "my-feature-slug"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if requestedURL != "/api/v1/app/jobs/my-feature-slug/approve" {
		t.Fatalf("unexpected request URL: %s", requestedURL)
	}
	if got := output.String(); got != "Approved my-feature-slug. Landing will begin shortly.\n" {
		t.Fatalf("output = %q", got)
	}
}
