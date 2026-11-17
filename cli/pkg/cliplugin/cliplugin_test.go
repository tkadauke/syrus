package cliplugin

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestClientUsesExecutableFallbackCredentials(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer executable-token" {
			t.Fatalf("Authorization = %q", got)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	t.Setenv("SYRUS_CLI_INTERNAL", "")
	t.Setenv("SYRUS_URL", server.URL)
	t.Setenv("SYRUS_TOKEN", "executable-token")

	client, err := Client()
	if err != nil {
		t.Fatal(err)
	}
	if err := client.Do(context.Background(), http.MethodGet, "/probe", nil, nil); err != nil {
		t.Fatal(err)
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
