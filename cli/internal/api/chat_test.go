package api

import (
	"bytes"
	"context"
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
