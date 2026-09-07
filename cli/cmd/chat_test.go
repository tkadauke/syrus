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

func TestChatCommandStreamsOneTurn(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Write([]byte("event: text_chunk\ndata: {\"content\":\"Done\"}\n\n"))
		w.Write([]byte("event: turn_complete\ndata: {}\n\n"))
	}))
	defer server.Close()

	if err := os.MkdirAll(filepath.Join(home, ".syrus"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".syrus", "credentials"), []byte("url="+server.URL+"\ntoken=secret-token\n"), 0600); err != nil {
		t.Fatal(err)
	}

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"chat", "42", "hello"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if output.String() == "" {
		t.Fatal("expected streamed output")
	}
}

func TestChatCommandRendersToolActivityDuringLiveTurn(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Write([]byte("event: message\ndata: {\"message\":{\"role\":\"tool_use\",\"tool_name\":\"read_job\"}}\n\n"))
		w.Write([]byte("event: message\ndata: {\"message\":{\"role\":\"tool_result\",\"tool_name\":\"read_job\",\"content\":{\"is_error\":false,\"content\":[{\"type\":\"text\",\"text\":\"Job JOB-42 open\"}]}}}\n\n"))
		w.Write([]byte("event: text_chunk\ndata: {\"content\":\"Done\"}\n\n"))
		w.Write([]byte("event: turn_complete\ndata: {}\n\n"))
	}))
	defer server.Close()

	if err := os.MkdirAll(filepath.Join(home, ".syrus"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".syrus", "credentials"), []byte("url="+server.URL+"\ntoken=secret-token\n"), 0600); err != nil {
		t.Fatal(err)
	}

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"chat", "42", "check JOB-42"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if got := output.String(); !strings.Contains(got, "read_job") || !strings.Contains(got, "Job JOB-42 open") {
		t.Fatalf("output = %q, expected live tool_use and tool_result activity", got)
	}
}
