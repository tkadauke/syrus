package cmd

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/tkadauke/syrus/cli/pkg/api"
)

func newTestChatReplModel(t *testing.T, client *api.Client) chatReplModel {
	t.Helper()
	model := newChatReplModel(context.Background(), client, api.ChatSession{ID: 42, Title: "Planning"}, "", &strings.Builder{}, nil)
	model.applySize(80, 24)
	return model
}

func newTestAPIClient(t *testing.T, baseURL string) *api.Client {
	t.Helper()
	client, err := api.NewClient(baseURL, "secret-token")
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func TestChatReplModelRendersIncomingChunks(t *testing.T) {
	model := newTestChatReplModel(t, newTestAPIClient(t, "https://syrus.example.test"))

	updated, cmd := model.Update(chatChunkMsg("Ave, chat.\n"))
	model = updated.(chatReplModel)

	if !strings.Contains(model.viewport.View(), "Ave, chat.") {
		t.Fatalf("viewport = %q, expected rendered chunk", model.viewport.View())
	}
	if cmd == nil {
		t.Fatal("expected Update to keep listening for further chat events")
	}
}

func TestChatReplModelSubmitAppendsMessageAndStartsTurn(t *testing.T) {
	model := newTestChatReplModel(t, newTestAPIClient(t, "https://syrus.example.test"))
	model.textarea.SetValue("check JOB-42")

	updated, cmd := model.Update(tea.KeyMsg{Type: tea.KeyEnter})
	model = updated.(chatReplModel)

	if !model.busy {
		t.Fatal("expected submit to mark the model busy")
	}
	if model.textarea.Value() != "" {
		t.Fatalf("textarea = %q, expected it to be cleared after submit", model.textarea.Value())
	}
	if !strings.Contains(model.viewport.View(), "check JOB-42") {
		t.Fatalf("viewport = %q, expected the submitted message echoed", model.viewport.View())
	}
	if len(model.history) != 1 || model.history[0] != "check JOB-42" {
		t.Fatalf("history = %#v", model.history)
	}
	if cmd == nil {
		t.Fatal("expected submit to return a command that starts the turn")
	}

	// Submitting again while busy must not start a second turn.
	model.textarea.SetValue("second message")
	updated, cmd = model.Update(tea.KeyMsg{Type: tea.KeyEnter})
	model = updated.(chatReplModel)
	if cmd != nil {
		t.Fatal("expected enter to be ignored while a turn is in flight")
	}
	if model.textarea.Value() != "second message" {
		t.Fatalf("textarea = %q, expected the draft to be left alone while busy", model.textarea.Value())
	}
}

func TestChatReplModelRecallsHistoryWithArrowKeys(t *testing.T) {
	model := newTestChatReplModel(t, newTestAPIClient(t, "https://syrus.example.test"))
	model.history = []string{"first", "second"}
	model.historyPos = len(model.history)

	updated, _ := model.Update(tea.KeyMsg{Type: tea.KeyUp})
	model = updated.(chatReplModel)
	if got := model.textarea.Value(); got != "second" {
		t.Fatalf("textarea = %q, expected the most recent history entry", got)
	}

	updated, _ = model.Update(tea.KeyMsg{Type: tea.KeyUp})
	model = updated.(chatReplModel)
	if got := model.textarea.Value(); got != "first" {
		t.Fatalf("textarea = %q, expected the older history entry", got)
	}

	updated, _ = model.Update(tea.KeyMsg{Type: tea.KeyDown})
	model = updated.(chatReplModel)
	if got := model.textarea.Value(); got != "second" {
		t.Fatalf("textarea = %q, expected to move back down the history", got)
	}

	updated, _ = model.Update(tea.KeyMsg{Type: tea.KeyDown})
	model = updated.(chatReplModel)
	if got := model.textarea.Value(); got != "" {
		t.Fatalf("textarea = %q, expected to return to the empty draft", got)
	}
}

func TestChatReplModelResolvesProposalDecisionViaKeypress(t *testing.T) {
	model := newTestChatReplModel(t, newTestAPIClient(t, "https://syrus.example.test"))
	respond := make(chan proposalDecision, 1)
	proposal := api.ChatProposal{ID: 5, Title: "Add dark mode", ConfirmPath: "/x/confirm", RejectPath: "/x/reject"}

	updated, cmd := model.Update(chatProposalRequestMsg{proposal: proposal, respond: respond})
	model = updated.(chatReplModel)
	if model.pendingProposal == nil {
		t.Fatal("expected a pending proposal after a proposal request event")
	}
	if !strings.Contains(model.viewport.View(), "Add dark mode") {
		t.Fatalf("viewport = %q, expected the proposal rendered", model.viewport.View())
	}
	if cmd == nil {
		t.Fatal("expected Update to keep listening for further chat events")
	}

	updated, _ = model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("c")})
	model = updated.(chatReplModel)
	if model.pendingProposal != nil {
		t.Fatal("expected the pending proposal to clear after a decision")
	}

	select {
	case decision := <-respond:
		if decision != proposalConfirm {
			t.Fatalf("decision = %v, expected proposalConfirm", decision)
		}
	default:
		t.Fatal("expected the decision to be delivered to the respond channel")
	}
}

func TestChatReplModelInterruptsInFlightTurnAndCallsStopChat(t *testing.T) {
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

	model := newTestChatReplModel(t, newTestAPIClient(t, server.URL))
	model.textarea.SetValue("hello")

	updated, cmd := model.Update(tea.KeyMsg{Type: tea.KeyEnter})
	model = updated.(chatReplModel)
	if !model.busy {
		t.Fatal("expected model to be busy after submit")
	}

	batch, ok := cmd().(tea.BatchMsg)
	if !ok {
		t.Fatalf("cmd() = %T, expected tea.BatchMsg", cmd())
	}
	for _, sub := range batch {
		go sub()
	}

	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("turn never reached the server")
	}

	updated, _ = model.Update(tea.KeyMsg{Type: tea.KeyCtrlC})
	model = updated.(chatReplModel)
	if !model.busy {
		t.Fatal("ctrl+c during a turn should interrupt it, not immediately leave the busy state")
	}

	var done chatTurnDoneMsg
	select {
	case msg := <-model.events:
		var ok bool
		done, ok = msg.(chatTurnDoneMsg)
		if !ok {
			t.Fatalf("event = %#v, expected chatTurnDoneMsg", msg)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("turn did not report completion after interrupt")
	}
	if done.err != nil {
		t.Fatalf("turn completion error = %v, expected the interrupt to resolve cleanly", done.err)
	}

	updated, _ = model.Update(done)
	model = updated.(chatReplModel)
	if model.busy {
		t.Fatal("expected the model to leave the busy state once the interrupted turn completes")
	}
	if atomic.LoadInt32(&stopCalled) != 1 {
		t.Fatal("expected StopChat to be called after interrupt")
	}
}

func TestChatReplModelCtrlCQuitsWhenIdle(t *testing.T) {
	model := newTestChatReplModel(t, newTestAPIClient(t, "https://syrus.example.test"))

	updated, cmd := model.Update(tea.KeyMsg{Type: tea.KeyCtrlC})
	model = updated.(chatReplModel)
	if !model.quitting {
		t.Fatal("expected ctrl+c to quit when no turn is in flight")
	}
	if cmd == nil {
		t.Fatal("expected ctrl+c to return tea.Quit when idle")
	}
}
