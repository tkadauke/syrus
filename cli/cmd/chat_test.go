package cmd

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestChatCommandStreamsOneTurn(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Write([]byte("event: text_chunk\ndata: {\"content\":\"Done\"}\n\n"))
		w.Write([]byte("event: turn_complete\ndata: {}\n\n"))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

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
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Write([]byte("event: message\ndata: {\"message\":{\"role\":\"tool_use\",\"tool_name\":\"read_job\"}}\n\n"))
		w.Write([]byte("event: message\ndata: {\"message\":{\"role\":\"tool_result\",\"tool_name\":\"read_job\",\"content\":{\"is_error\":false,\"content\":[{\"type\":\"text\",\"text\":\"Job JOB-42 open\"}]}}}\n\n"))
		w.Write([]byte("event: text_chunk\ndata: {\"content\":\"Done\"}\n\n"))
		w.Write([]byte("event: turn_complete\ndata: {}\n\n"))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

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

func TestChatListPrintsChatsFromFakeServer(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/app/chats" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"groups":[{"key":"repository-7","chats":[{"id":42,"title":"Planning","repository":{"id":7,"slug":"tkadauke/syrus"},"updated_at":"2026-06-11T12:00:00Z"}]}],"repositories":[{"id":7,"slug":"tkadauke/syrus"}]}`))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"chat", "list", "--all"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	got := output.String()
	if !strings.Contains(got, "42") || !strings.Contains(got, "tkadauke/syrus") || !strings.Contains(got, "Planning") {
		t.Fatalf("output = %q", got)
	}
}

func TestChatListPrintsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"groups":[{"key":"repository-7","chats":[{"id":42,"title":"Planning","repository":{"id":7,"slug":"tkadauke/syrus"}}]}],"repositories":[{"id":7,"slug":"tkadauke/syrus"}]}`))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"chat", "list", "--all", "--json"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	var payload struct {
		Chats []struct {
			ID int64 `json:"id"`
		} `json:"chats"`
	}
	if err := json.Unmarshal(output.Bytes(), &payload); err != nil {
		t.Fatalf("invalid JSON %q: %v", output.String(), err)
	}
	if len(payload.Chats) != 1 || payload.Chats[0].ID != 42 {
		t.Fatalf("payload = %#v", payload)
	}
}

func TestChatNewCreatesChatWithRepository(t *testing.T) {
	var requests []string
	var createRepositoryID float64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/app/chats":
			w.Write([]byte(`{"chats":[],"repositories":[{"id":7,"slug":"tkadauke/syrus"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/app/chats":
			var payload map[string]float64
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			createRepositoryID = payload["repository_id"]
			w.WriteHeader(http.StatusCreated)
			w.Write([]byte(`{"chat":{"id":99,"title":"syrus","repository":{"id":7,"slug":"tkadauke/syrus"}}}`))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"chat", "new", "--repo", "tkadauke/syrus"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	if strings.TrimSpace(output.String()) != "99" {
		t.Fatalf("output = %q", output.String())
	}
	if createRepositoryID != 7 {
		t.Fatalf("repository_id = %v", createRepositoryID)
	}
	want := []string{"GET /api/v1/app/chats", "POST /api/v1/app/chats"}
	if strings.Join(requests, ",") != strings.Join(want, ",") {
		t.Fatalf("requests = %v, want %v", requests, want)
	}
}

func TestChatNewPrintsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/app/chats" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"chat":{"id":100,"title":"Untitled"}}`))
	}))
	defer server.Close()
	writeJobActionTestCredentials(t, server.URL)

	output := &bytes.Buffer{}
	command := NewRootCommand()
	command.SetOut(output)
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{"chat", "new", "--no-repo", "--json"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(output.Bytes(), &payload); err != nil {
		t.Fatalf("invalid JSON %q: %v", output.String(), err)
	}
	if payload.ID != 100 {
		t.Fatalf("payload = %#v", payload)
	}
}
