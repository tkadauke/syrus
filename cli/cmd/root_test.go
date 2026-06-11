package cmd

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRootCommandReportsMissingCredentials(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected missing credentials error")
	}
	if err.Error() != loginMessage {
		t.Fatalf("error = %q", err.Error())
	}
}

func TestLoginCommandWritesCredentials(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	input := strings.NewReader("https://syrus.example.com\nsecret-token\n")
	output := &bytes.Buffer{}
	command := NewLoginCommand()
	command.SetIn(input)
	command.SetOut(output)

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	contents, err := os.ReadFile(filepath.Join(home, ".syrus", "credentials"))
	if err != nil {
		t.Fatal(err)
	}
	if got := string(contents); got != "url=https://syrus.example.com\ntoken=secret-token\n" {
		t.Fatalf("credentials file = %q", got)
	}
}

func TestApproveCommandApprovesJob(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s", r.Method)
		}
		if r.URL.Path != "/api/v1/app/jobs/456/approve" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
			t.Fatalf("Authorization = %q", got)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	writeCredentials(t, home, server.URL, "secret-token")

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"approve", "JOB-456"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); got != "Approved JOB-456. Landing will begin shortly.\n" {
		t.Fatalf("output = %q", got)
	}
}

func TestApproveCommandReturnsAPIErrorMessage(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		w.Write([]byte(`{"error":{"message":"Job is not ready for approval."}}`))
	}))
	defer server.Close()

	writeCredentials(t, home, server.URL, "secret-token")

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"approve", "JOB-456"})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected API error")
	}
	if err.Error() != "Job is not ready for approval." {
		t.Fatalf("error = %q", err.Error())
	}
}

func writeCredentials(t *testing.T, home string, url string, token string) {
	t.Helper()

	path := filepath.Join(home, ".syrus", "credentials")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	contents := "url=" + url + "\ntoken=" + token + "\n"
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
}
