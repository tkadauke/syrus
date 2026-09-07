package cmd

import (
	"bufio"
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/tkadauke/syrus/cli/pkg/api"
)

func TestChatPickerModelUsesCursorSelection(t *testing.T) {
	model := newChatPickerModel([]chatPickerItem{
		{title: "First", when: "1d ago"},
		{title: "Second", when: "just now"},
	}, "")

	updated, _ := model.Update(tea.KeyMsg{Type: tea.KeyDown})
	model = updated.(chatPickerModel)
	if model.cursor != 1 {
		t.Fatalf("cursor = %d", model.cursor)
	}

	updated, _ = model.Update(tea.KeyMsg{Type: tea.KeyEnter})
	model = updated.(chatPickerModel)
	if model.selection != 1 {
		t.Fatalf("selection = %d", model.selection)
	}
}

func TestLoadChatHistoryFetchesOlderPagesUpToLimit(t *testing.T) {
	var paths []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.String())
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.String() {
		case "/api/v1/app/chats/42":
			w.Write([]byte(`{"chat":{"id":42},"has_more_older":true,"messages":[{"id":5,"role":"user","text":"five"},{"id":6,"role":"assistant","text":"six"}]}`))
		case "/api/v1/app/chats/42/messages?before=5":
			w.Write([]byte(`{"has_more_older":true,"messages":[{"id":3,"role":"user","text":"three"},{"id":4,"role":"assistant","text":"four"}]}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.String())
		}
	}))
	defer server.Close()

	client, err := api.NewClient(server.URL, "secret-token")
	if err != nil {
		t.Fatal(err)
	}

	messages, err := loadChatHistory(context.Background(), client, "42", 4)
	if err != nil {
		t.Fatalf("loadChatHistory returned error: %v", err)
	}

	var ids []int64
	for _, message := range messages {
		ids = append(ids, message.ID)
	}
	if !reflect.DeepEqual(ids, []int64{3, 4, 5, 6}) {
		t.Fatalf("ids = %#v", ids)
	}
	if !reflect.DeepEqual(paths, []string{"/api/v1/app/chats/42", "/api/v1/app/chats/42/messages?before=5"}) {
		t.Fatalf("paths = %#v", paths)
	}
}

func TestRunChatREPLRendersToolActivityDuringLiveTurn(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Write([]byte("event: message\ndata: {\"message\":{\"role\":\"tool_use\",\"tool_name\":\"read_job\"}}\n\n"))
		w.Write([]byte("event: message\ndata: {\"message\":{\"role\":\"tool_result\",\"tool_name\":\"read_job\",\"content\":{\"is_error\":false,\"content\":[{\"type\":\"text\",\"text\":\"Job JOB-42 open\"}]}}}\n\n"))
		w.Write([]byte("event: turn_complete\ndata: {}\n\n"))
	}))
	defer server.Close()

	client, err := api.NewClient(server.URL, "secret-token")
	if err != nil {
		t.Fatal(err)
	}

	out := &bytes.Buffer{}
	reader := bufio.NewReader(strings.NewReader("check JOB-42\n"))
	if err := runChatREPL(context.Background(), client, "42", reader, out, &bytes.Buffer{}); err != nil {
		t.Fatalf("runChatREPL returned error: %v", err)
	}
	got := out.String()
	if !strings.Contains(got, "read_job") || !strings.Contains(got, "Job JOB-42 open") {
		t.Fatalf("output = %q, expected live tool_use and tool_result activity", got)
	}
}

func TestRunChatREPLStopsTurnOnInterruptAndReturnsToPrompt(t *testing.T) {
	started := make(chan struct{})
	var stopCalled int32

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/app/chats/42/message", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		close(started)
		<-r.Context().Done()
	})
	mux.HandleFunc("/api/v1/app/chats/42/stop", func(w http.ResponseWriter, r *http.Request) {
		atomic.StoreInt32(&stopCalled, 1)
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	client, err := api.NewClient(server.URL, "secret-token")
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	out := &bytes.Buffer{}
	errOut := &bytes.Buffer{}
	reader := bufio.NewReader(strings.NewReader("hello\n"))

	done := make(chan error, 1)
	go func() {
		done <- runChatREPL(ctx, client, "42", reader, out, errOut)
	}()

	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("turn never reached the server")
	}

	// Simulate a Ctrl+C delivered while the turn is in flight.
	cancel()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("runChatREPL returned error after interrupt: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("runChatREPL did not return to its prompt loop after interrupt")
	}

	if atomic.LoadInt32(&stopCalled) != 1 {
		t.Fatal("expected StopChat to be called after interrupt")
	}
}

func TestRenderableChatMessagesSkipNoisySystemAndToolResults(t *testing.T) {
	messages := []api.ChatMessage{
		{ID: 1, Role: "system", Text: "[mcp_servers] syrus-chat-sidecar=connected"},
		{ID: 2, Role: "tool_result", ToolName: "read_job", Text: `{"result":[]}`},
		{ID: 3, Role: "tool_use", ToolName: "read_job"},
		{ID: 4, Role: "assistant", Text: "Ave"},
	}

	renderable := renderableChatMessages(messages)
	var ids []int64
	for _, message := range renderable {
		ids = append(ids, message.ID)
	}
	if !reflect.DeepEqual(ids, []int64{3, 4}) {
		t.Fatalf("ids = %#v", ids)
	}
}
