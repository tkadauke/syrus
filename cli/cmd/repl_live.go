package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/tkadauke/syrus/cli/internal/render"
	"github.com/tkadauke/syrus/cli/pkg/api"
)

const (
	chatInputHeight       = 3
	chatInputHistoryLimit = 100
	chatBusyTickInterval  = 120 * time.Millisecond
)

// chatTurnStreamer matches (*api.Client).StreamTurn's signature. Tests
// substitute a fake implementation here instead of making real HTTP calls.
type chatTurnStreamer func(ctx context.Context, client *api.Client, chatID, message string, options api.StreamTurnOptions) error

func defaultChatTurnStreamer(ctx context.Context, client *api.Client, chatID, message string, options api.StreamTurnOptions) error {
	return client.StreamTurn(ctx, chatID, message, options)
}

type proposalDecision int

const (
	proposalConfirm proposalDecision = iota
	proposalSkip
)

// chatChunkMsg carries a slice of already-rendered stream output (text,
// live tool activity, proposal boxes, etc.) from the in-flight turn's
// goroutine into the Elm update loop.
type chatChunkMsg string

// chatProposalRequestMsg asks the update loop to collect a confirm/skip
// decision from the user; respond delivers that decision back to the
// blocked ProposalHandler goroutine.
type chatProposalRequestMsg struct {
	proposal api.ChatProposal
	respond  chan proposalDecision
}

// chatTurnDoneMsg reports that the in-flight turn's StreamTurn call
// returned. err is nil for both success and a user-initiated interrupt.
type chatTurnDoneMsg struct{ err error }

type busyTickMsg time.Time

// chatEventWriter adapts the streaming io.Writer contract StreamTurn writes
// through into chatChunkMsg values delivered over the model's event channel.
type chatEventWriter struct {
	events chan tea.Msg
}

func (w chatEventWriter) Write(p []byte) (int, error) {
	w.events <- chatChunkMsg(string(p))
	return len(p), nil
}

// waitForChatEvent is the standard bubbletea "external event source"
// pattern: block for exactly one value from the channel and re-issue the
// same command after each message so the model keeps listening for the
// life of the program.
func waitForChatEvent(events chan tea.Msg) tea.Cmd {
	return func() tea.Msg {
		return <-events
	}
}

func tickBusyCmd() tea.Cmd {
	return tea.Tick(chatBusyTickInterval, func(t time.Time) tea.Msg { return busyTickMsg(t) })
}

// chatReplModel is the live chat REPL's bubbletea model: a scrollback
// viewport, a multi-line input area, and a thin status line. It replaces
// the bufio prompt loop for real terminals; runChatREPL (the bufio loop)
// remains the fallback used for piped/non-terminal input.
type chatReplModel struct {
	ctx    context.Context
	client *api.Client
	chatID string

	statusTitle string
	markdown    render.MarkdownRenderer
	debugOut    io.Writer
	streamTurn  chatTurnStreamer

	viewport   viewport.Model
	textarea   textarea.Model
	transcript string

	history    []string
	historyPos int
	draft      string

	events          chan tea.Msg
	busy            bool
	busyPhrase      string
	busyFrame       int
	turnCancel      context.CancelFunc
	pendingProposal *chatProposalRequestMsg

	width, height int
	quitting      bool
	err           error
}

func newChatReplModel(ctx context.Context, client *api.Client, chat api.ChatSession, transcript string, out, debugOut io.Writer) chatReplModel {
	ta := textarea.New()
	ta.Placeholder = "Message Syrus..."
	ta.Prompt = "› "
	ta.ShowLineNumbers = false
	ta.SetHeight(chatInputHeight)
	ta.Focus()

	vp := viewport.New(defaultInboxWidth, defaultInboxWidth/2)
	vp.KeyMap = chatViewportKeyMap()
	vp.MouseWheelEnabled = true

	m := chatReplModel{
		ctx:         ctx,
		client:      client,
		chatID:      strconv.FormatInt(chat.ID, 10),
		statusTitle: chatStatusTitle(chat),
		markdown:    render.NewMarkdownRenderer(out),
		debugOut:    debugOut,
		streamTurn:  defaultChatTurnStreamer,
		viewport:    vp,
		textarea:    ta,
		events:      make(chan tea.Msg),
		width:       defaultInboxWidth,
		height:      24,
	}
	m.transcript = transcript
	m.viewport.SetContent(m.transcript)
	m.viewport.GotoBottom()
	return m
}

// chatViewportKeyMap keeps only PageUp/PageDown scrolling. The default
// viewport keymap also binds plain letters ("j", "k", "u", "d", "b", "f",
// space) which would otherwise be stolen from the chat input.
func chatViewportKeyMap() viewport.KeyMap {
	defaults := viewport.DefaultKeyMap()
	return viewport.KeyMap{PageUp: defaults.PageUp, PageDown: defaults.PageDown}
}

func chatStatusTitle(chat api.ChatSession) string {
	title := strings.TrimSpace(chat.Title)
	if title == "" {
		title = "Untitled chat"
	}
	if chat.Repository != nil && chat.Repository.Slug != "" {
		return fmt.Sprintf("%s · %s", chat.Repository.Slug, title)
	}
	return title
}

func (m chatReplModel) Init() tea.Cmd {
	return tea.Batch(textarea.Blink, waitForChatEvent(m.events))
}

func (m chatReplModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.applySize(msg.Width, msg.Height)
		return m, nil

	case tea.KeyMsg:
		return m.updateKey(msg)

	case tea.MouseMsg:
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd

	case chatChunkMsg:
		m.appendTranscript(string(msg))
		return m, waitForChatEvent(m.events)

	case chatProposalRequestMsg:
		proposal := msg
		m.pendingProposal = &proposal
		var box strings.Builder
		renderProposal(&box, msg.proposal)
		m.appendTranscript(box.String())
		return m, waitForChatEvent(m.events)

	case chatTurnDoneMsg:
		m.busy = false
		m.turnCancel = nil
		m.pendingProposal = nil
		if msg.err != nil {
			m.err = msg.err
			m.quitting = true
			return m, tea.Quit
		}
		return m, waitForChatEvent(m.events)

	case busyTickMsg:
		if !m.busy {
			return m, nil
		}
		m.busyFrame++
		return m, tickBusyCmd()
	}

	return m, nil
}

func (m chatReplModel) updateKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.quitting {
		return m, nil
	}

	if m.pendingProposal != nil {
		return m.resolveProposalKey(msg)
	}

	switch msg.Type {
	case tea.KeyCtrlC:
		if m.busy {
			m.cancelTurn()
			return m, nil
		}
		m.quitting = true
		return m, tea.Quit
	case tea.KeyCtrlJ:
		m.textarea.InsertRune('\n')
		return m, nil
	case tea.KeyEnter:
		if m.busy {
			return m, nil
		}
		return m.submit()
	case tea.KeyUp:
		if m.textarea.Line() == 0 {
			m.recallHistory(-1)
			return m, nil
		}
	case tea.KeyDown:
		if m.textarea.Line() == m.textarea.LineCount()-1 {
			m.recallHistory(1)
			return m, nil
		}
	}

	var cmd tea.Cmd
	m.textarea, cmd = m.textarea.Update(msg)
	return m, cmd
}

func (m chatReplModel) resolveProposalKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	pending := m.pendingProposal
	switch strings.ToLower(msg.String()) {
	case "c":
		pending.respond <- proposalConfirm
		m.pendingProposal = nil
	case "s", "esc":
		pending.respond <- proposalSkip
		m.pendingProposal = nil
	}
	return m, nil
}

func (m *chatReplModel) cancelTurn() {
	if m.turnCancel != nil {
		m.turnCancel()
	}
}

func (m *chatReplModel) submit() (tea.Model, tea.Cmd) {
	text := strings.TrimSpace(m.textarea.Value())
	if text == "" {
		return *m, nil
	}
	m.textarea.Reset()
	m.pushHistory(text)
	m.appendTranscript(fmt.Sprintf("%s %s\n\n", subtleStyle.Render("›"), text))

	ctx, cancel := context.WithCancel(m.ctx)
	m.turnCancel = cancel
	m.busy = true
	m.busyFrame = 0
	phrases := chatBusyPhrases()
	m.busyPhrase = phrases[int(time.Now().UnixNano())%len(phrases)]

	return *m, tea.Batch(m.startTurnCmd(ctx, text), tickBusyCmd())
}

func (m *chatReplModel) pushHistory(text string) {
	m.history = append(m.history, text)
	if len(m.history) > chatInputHistoryLimit {
		m.history = m.history[len(m.history)-chatInputHistoryLimit:]
	}
	m.historyPos = len(m.history)
	m.draft = ""
}

// recallHistory moves the input up or down the in-memory sent-message ring.
// It only fires when the cursor is already at the first (up) or last (down)
// line of the input, so ordinary multi-line cursor movement still works.
func (m *chatReplModel) recallHistory(direction int) {
	if len(m.history) == 0 {
		return
	}
	if m.historyPos == len(m.history) {
		m.draft = m.textarea.Value()
	}
	next := m.historyPos + direction
	if next < 0 {
		next = 0
	}
	if next > len(m.history) {
		next = len(m.history)
	}
	m.historyPos = next
	if m.historyPos == len(m.history) {
		m.textarea.SetValue(m.draft)
	} else {
		m.textarea.SetValue(m.history[m.historyPos])
	}
	m.textarea.CursorEnd()
}

func (m *chatReplModel) appendTranscript(text string) {
	m.transcript += text
	m.viewport.SetContent(m.transcript)
	m.viewport.GotoBottom()
}

func (m *chatReplModel) applySize(width, height int) {
	if width < 20 {
		width = 20
	}
	if height < 8 {
		height = 8
	}
	m.width = width
	m.height = height

	const reserved = chatInputHeight + 2 // status line + rule
	viewportHeight := height - reserved
	if viewportHeight < 3 {
		viewportHeight = 3
	}
	m.viewport.Width = width
	m.viewport.Height = viewportHeight
	m.textarea.SetWidth(width)
	m.viewport.GotoBottom()
}

// startTurnCmd runs the turn's StreamTurn call as the body of a bubbletea
// command (already async by construction) and reports completion back over
// the model's event channel. Interrupt handling mirrors streamTurnWithClient
// in chat.go: a context.Canceled error (from Ctrl+C cancelling the turn)
// calls StopChat and resolves to no error instead of surfacing as a failure.
func (m *chatReplModel) startTurnCmd(ctx context.Context, message string) tea.Cmd {
	client := m.client
	chatID := m.chatID
	events := m.events
	renderer := m.markdown
	debugOut := m.debugOut
	streamTurn := m.streamTurn

	return func() tea.Msg {
		err := streamTurn(ctx, client, chatID, message, api.StreamTurnOptions{
			Out:             chatEventWriter{events: events},
			DebugOut:        debugOut,
			Renderer:        renderer,
			ProposalHandler: chatProposalHandlerFor(events, client),
		})
		if errors.Is(err, context.Canceled) {
			if stopErr := client.StopChat(context.Background(), chatID); stopErr != nil {
				err = fmt.Errorf("cancel requested, but stop failed: %w", stopErr)
			} else {
				err = nil
			}
		}
		events <- chatTurnDoneMsg{err: err}
		return nil
	}
}

// chatProposalHandlerFor bridges StreamTurn's synchronous ProposalHandler
// callback (invoked from the turn's own goroutine) to the update loop: it
// posts a decision request over events and blocks until the user's keypress
// resolves it, without stalling the Elm update loop itself.
func chatProposalHandlerFor(events chan tea.Msg, client *api.Client) func(context.Context, api.ChatProposal) error {
	return func(ctx context.Context, proposal api.ChatProposal) error {
		respond := make(chan proposalDecision, 1)
		select {
		case events <- chatProposalRequestMsg{proposal: proposal, respond: respond}:
		case <-ctx.Done():
			return ctx.Err()
		}
		select {
		case decision := <-respond:
			return applyProposalDecision(ctx, client, proposal, decision, events)
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func applyProposalDecision(ctx context.Context, client *api.Client, proposal api.ChatProposal, decision proposalDecision, events chan tea.Msg) error {
	if decision == proposalConfirm {
		if proposal.ConfirmPath == "" {
			return errors.New("proposal cannot be confirmed from the stream payload")
		}
		if err := client.ConfirmChatProposal(ctx, proposal.ConfirmPath); err != nil {
			return err
		}
		events <- chatChunkMsg(subtleStyle.Render("Filed.") + "\n\n")
		return nil
	}
	if proposal.RejectPath == "" {
		return errors.New("proposal cannot be skipped from the stream payload")
	}
	if err := client.RejectChatProposal(ctx, proposal.RejectPath); err != nil {
		return err
	}
	events <- chatChunkMsg(subtleStyle.Render("Skipped.") + "\n\n")
	return nil
}

func (m chatReplModel) View() string {
	if m.quitting {
		return ""
	}
	rule := ruleStyle.Render(strings.Repeat("─", max(1, m.width)))
	return m.statusLine() + "\n" + m.viewport.View() + "\n" + rule + "\n" + m.inputView()
}

func (m chatReplModel) statusLine() string {
	left := headerStyle.Render(m.statusTitle)
	right := subtleStyle.Render("ctrl+c interrupt/quit · enter send · ctrl+j newline")
	if m.busy {
		frames := []string{"|", "/", "-", "\\"}
		frame := frames[m.busyFrame%len(frames)]
		right = subtleStyle.Render(fmt.Sprintf("%s %s...", frame, m.busyPhrase))
	}
	pad := m.width - lipgloss.Width(left) - lipgloss.Width(right)
	if pad < 1 {
		pad = 1
	}
	return left + strings.Repeat(" ", pad) + right
}

func (m chatReplModel) inputView() string {
	if m.pendingProposal != nil {
		return subtleStyle.Render(fmt.Sprintf("Proposal pending — [c]onfirm  [s]kip: %s", proposalTitleOrSlug(m.pendingProposal.proposal)))
	}
	return m.textarea.View()
}

func proposalTitleOrSlug(proposal api.ChatProposal) string {
	title := strings.TrimSpace(proposal.Title)
	if title == "" {
		title = strings.TrimSpace(proposal.Slug)
	}
	if title == "" {
		return "Untitled proposal"
	}
	return title
}

// runChatREPLInteractive drives the bubbletea live chat model for a real
// terminal pair. runInteractiveChat falls back to runChatREPL's bufio loop
// when input/output aren't a terminal (piped usage, tests).
func runChatREPLInteractive(ctx context.Context, client *api.Client, chat api.ChatSession, input io.Reader, out, errOut io.Writer) error {
	chatID := strconv.FormatInt(chat.ID, 10)
	messages, err := loadChatHistory(ctx, client, chatID, chatHistoryMessageLimit)
	if err != nil {
		return err
	}

	markdown := render.NewMarkdownRenderer(out)
	var transcript strings.Builder
	for _, message := range renderableChatMessages(messages) {
		if err := renderChatHistoryMessage(&transcript, markdown, message); err != nil {
			return err
		}
	}

	var debugOut io.Writer
	if chatDebugEnabled() {
		debugOut = errOut
	}
	model := newChatReplModel(ctx, client, chat, transcript.String(), out, debugOut)
	program := tea.NewProgram(model,
		tea.WithContext(ctx),
		tea.WithInput(input),
		tea.WithOutput(out),
		tea.WithAltScreen(),
		tea.WithMouseCellMotion(),
	)
	finalModel, err := program.Run()
	if err != nil {
		return err
	}
	if final, ok := finalModel.(chatReplModel); ok && final.err != nil {
		return final.err
	}
	return nil
}
