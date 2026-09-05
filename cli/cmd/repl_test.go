package cmd

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

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
