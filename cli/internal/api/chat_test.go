package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type stubRenderer struct{}

func (stubRenderer) Render(markdown string) (string, error) {
	return "rendered:" + markdown, nil
}

func TestListChatsSendsBearerToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/chats" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
			t.Fatalf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"chats":[{"id":42,"title":"Planning","repository":{"id":7,"slug":"tkadauke/syrus"}}],"repositories":[{"id":7,"slug":"tkadauke/syrus"}]}`))
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "secret-token")
	if err != nil {
		t.Fatal(err)
	}

	list, err := client.ListChats(context.Background())
	if err != nil {
		t.Fatalf("ListChats returned error: %v", err)
	}
	if len(list.Chats) != 1 || list.Chats[0].ID != 42 {
		t.Fatalf("chats = %#v", list.Chats)
	}
	if len(list.Repositories) != 1 || list.Repositories[0].Slug != "tkadauke/syrus" {
		t.Fatalf("repositories = %#v", list.Repositories)
	}
}

func TestCreateChatPostsRepositoryID(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/chats" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		var payload CreateChatRequest
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.RepositoryID != 7 {
			t.Fatalf("repository_id = %d", payload.RepositoryID)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"chat":{"id":99,"title":"syrus","repository":{"id":7,"slug":"tkadauke/syrus"}}}`))
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "secret-token")
	if err != nil {
		t.Fatal(err)
	}

	chat, err := client.CreateChat(context.Background(), 7)
	if err != nil {
		t.Fatalf("CreateChat returned error: %v", err)
	}
	if chat.ID != 99 {
		t.Fatalf("chat ID = %d", chat.ID)
	}
}

func TestParseChatStreamDispatchesMultilineSSEEvents(t *testing.T) {
	var events []ChatStreamEvent
	err := ParseChatStream(strings.NewReader("event: text_chunk\ndata: {\"content\":\"hello\"}\n\nevent: turn_complete\ndata: {}\n\n"), func(event ChatStreamEvent) error {
		events = append(events, event)
		return nil
	})
	if err != nil {
		t.Fatalf("ParseChatStream returned error: %v", err)
	}
	if len(events) != 2 {
		t.Fatalf("events = %d", len(events))
	}
	if events[0].Event != "text_chunk" || string(events[0].Data) != `{"content":"hello"}` {
		t.Fatalf("first event = %#v", events[0])
	}
	if events[1].Event != "turn_complete" {
		t.Fatalf("second event = %#v", events[1])
	}
}

func TestStreamTurnPostsContentAndRendersTextChunks(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/app/chats/42/message" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer secret-token" {
			t.Fatalf("Authorization = %q", got)
		}
		if got := r.Header.Get("Accept"); got != "text/event-stream" {
			t.Fatalf("Accept = %q", got)
		}
		body := new(bytes.Buffer)
		body.ReadFrom(r.Body)
		if got := body.String(); got != `{"content":"Map **Rome**"}` {
			t.Fatalf("body = %q", got)
		}

		w.Header().Set("Content-Type", "text/event-stream")
		w.Write([]byte("event: text_chunk\ndata: {\"content\":\"**Done**\"}\n\n"))
		w.Write([]byte("event: turn_complete\ndata: {}\n\n"))
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "secret-token")
	if err != nil {
		t.Fatal(err)
	}
	out := &bytes.Buffer{}
	err = client.StreamTurn(context.Background(), "42", "Map **Rome**", StreamTurnOptions{
		Out:      out,
		Renderer: stubRenderer{},
	})
	if err != nil {
		t.Fatalf("StreamTurn returned error: %v", err)
	}
	if got := out.String(); got != "rendered:**Done**\n" {
		t.Fatalf("output = %q", got)
	}
}

func TestStreamTurnReturnsCanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	client, err := NewClient("https://syrus.example.test", "secret-token")
	if err != nil {
		t.Fatal(err)
	}

	err = client.StreamTurn(ctx, "42", "hello", StreamTurnOptions{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
}
