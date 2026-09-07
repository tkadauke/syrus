package api

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

type ChatRepository struct {
	ID   int64  `json:"id"`
	Slug string `json:"slug"`
}

type ChatSession struct {
	ID            int64           `json:"id"`
	Title         string          `json:"title"`
	TitlePending  bool            `json:"title_pending"`
	Repository    *ChatRepository `json:"repository"`
	LastMessageAt string          `json:"last_message_at"`
	CreatedAt     string          `json:"created_at"`
	UpdatedAt     string          `json:"updated_at"`
}

type ChatList struct {
	Chats        []ChatSession    `json:"chats"`
	Repositories []ChatRepository `json:"repositories"`
}

type ChatMessage struct {
	ID       int64          `json:"id"`
	Role     string         `json:"role"`
	ToolName string         `json:"tool_name"`
	Content  map[string]any `json:"content"`
	Text     string         `json:"text"`
	Proposal *ChatProposal  `json:"proposal"`
}

type ChatPayload struct {
	Chat         ChatSession   `json:"chat"`
	HasMoreOlder bool          `json:"has_more_older"`
	Messages     []ChatMessage `json:"messages"`
}

type ChatMessagesPayload struct {
	HasMoreOlder bool          `json:"has_more_older"`
	Messages     []ChatMessage `json:"messages"`
}

type ChatProposal struct {
	ID                  int64  `json:"id"`
	Kind                string `json:"kind"`
	KindLabel           string `json:"kind_label"`
	Title               string `json:"title"`
	Slug                string `json:"slug"`
	Proposed            bool   `json:"proposed"`
	EpicBundle          bool   `json:"epic_bundle"`
	ActiveChildrenCount int    `json:"active_children_count"`
	ScopedRepository    string `json:"scoped_repository_slug"`
	ConfirmPath         string `json:"app_confirm_path"`
	RejectPath          string `json:"app_reject_path"`
}

type CreateChatRequest struct {
	RepositoryID int64 `json:"repository_id,omitempty"`
}

type CreateChatResponse struct {
	Chat ChatSession `json:"chat"`
}

type ChatTurnRenderer interface {
	Render(markdown string) (string, error)
}

type PlainRenderer struct{}

func (PlainRenderer) Render(markdown string) (string, error) {
	return markdown, nil
}

type StreamTurnOptions struct {
	Out             io.Writer
	DebugOut        io.Writer
	Renderer        ChatTurnRenderer
	ProposalHandler func(context.Context, ChatProposal) error
}

type ChatStreamEvent struct {
	Event string
	Data  json.RawMessage
}

func (c *Client) ListChats(ctx context.Context) (ChatList, error) {
	var out ChatList
	err := c.do(ctx, http.MethodGet, "/api/v1/app/chats", nil, &out)
	return out, err
}

func (c *Client) GetChat(ctx context.Context, chatID string) (ChatPayload, error) {
	var out ChatPayload
	err := c.do(ctx, http.MethodGet, "/api/v1/app/chats/"+url.PathEscape(chatID), nil, &out)
	return out, err
}

func (c *Client) GetChatMessages(ctx context.Context, chatID string, beforeID int64) (ChatMessagesPayload, error) {
	path := "/api/v1/app/chats/" + url.PathEscape(chatID) + "/messages"
	if beforeID > 0 {
		values := url.Values{}
		values.Set("before", strconv.FormatInt(beforeID, 10))
		path += "?" + values.Encode()
	}

	var out ChatMessagesPayload
	err := c.do(ctx, http.MethodGet, path, nil, &out)
	return out, err
}

func (c *Client) CreateChat(ctx context.Context, repositoryID int64) (ChatSession, error) {
	var out CreateChatResponse
	err := c.do(ctx, http.MethodPost, "/api/v1/app/chats", CreateChatRequest{RepositoryID: repositoryID}, &out)
	return out.Chat, err
}

func (c *Client) StreamTurn(ctx context.Context, chatID string, message string, options StreamTurnOptions) error {
	out := options.Out
	if out == nil {
		out = io.Discard
	}
	renderer := options.Renderer
	if renderer == nil {
		renderer = PlainRenderer{}
	}

	payload, err := json.Marshal(map[string]string{"content": message})
	if err != nil {
		return err
	}
	req, err := c.newRequest(ctx, http.MethodPost, "/api/v1/app/chats/"+url.PathEscape(chatID)+"/message", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Content-Type", "application/json")

	streamClient := *c.httpClient
	streamClient.Timeout = 0
	resp, err := streamClient.Do(req)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled) {
			return context.Canceled
		}
		var netErr net.Error
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) || (errors.As(err, &netErr) && netErr.Timeout()) {
			return fmt.Errorf("connection timeout: %w", err)
		}
		return fmt.Errorf("network error: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return responseError(resp)
	}

	return ParseChatStream(resp.Body, func(event ChatStreamEvent) error {
		return handleChatStreamEvent(ctx, event, out, options.DebugOut, renderer, options.ProposalHandler)
	})
}

func (c *Client) StopChat(ctx context.Context, chatID string) error {
	return c.do(ctx, http.MethodPost, "/api/v1/app/chats/"+url.PathEscape(chatID)+"/stop", nil, nil)
}

func (c *Client) ConfirmChatProposal(ctx context.Context, path string) error {
	return c.do(ctx, http.MethodPost, path, nil, nil)
}

func (c *Client) RejectChatProposal(ctx context.Context, path string) error {
	return c.do(ctx, http.MethodPost, path, nil, nil)
}

func ParseChatStream(r io.Reader, handle func(ChatStreamEvent) error) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	var eventName string
	var dataLines []string
	dispatch := func() error {
		if eventName == "" && len(dataLines) == 0 {
			return nil
		}
		event := ChatStreamEvent{
			Event: eventName,
			Data:  json.RawMessage(strings.Join(dataLines, "\n")),
		}
		if event.Event == "" {
			event.Event = "message"
		}
		eventName = ""
		dataLines = nil
		return handle(event)
	}

	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			if err := dispatch(); err != nil {
				return err
			}
			continue
		}
		if strings.HasPrefix(line, ":") {
			continue
		}
		field, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		value = strings.TrimPrefix(value, " ")
		switch field {
		case "event":
			eventName = value
		case "data":
			dataLines = append(dataLines, value)
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("stream error: %w", err)
	}
	return dispatch()
}

type chatStreamMessageRecord struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

func handleChatStreamEvent(ctx context.Context, event ChatStreamEvent, out, debugOut io.Writer, renderer ChatTurnRenderer, proposalHandler func(context.Context, ChatProposal) error) error {
	switch event.Event {
	case "text_chunk":
		var payload struct {
			Content string `json:"content"`
			Text    string `json:"text"`
			Message struct {
				Proposal *ChatProposal `json:"proposal"`
			} `json:"message"`
		}
		if err := json.Unmarshal(event.Data, &payload); err != nil {
			return err
		}
		if payload.Message.Proposal != nil {
			return nil
		}
		text := payload.Content
		if text == "" {
			text = payload.Text
		}
		if text == "" {
			return nil
		}
		rendered, err := renderer.Render(text)
		if err != nil {
			return err
		}
		if _, err := fmt.Fprint(out, rendered); err != nil {
			return err
		}
		if !strings.HasSuffix(rendered, "\n") {
			_, err = fmt.Fprintln(out)
			return err
		}
	case "proposal":
		var payload struct {
			Proposal ChatProposal `json:"proposal"`
		}
		if err := json.Unmarshal(event.Data, &payload); err != nil {
			return err
		}
		if payload.Proposal.ID == 0 {
			return nil
		}
		if proposalHandler != nil {
			return proposalHandler(ctx, payload.Proposal)
		}
	case "error":
		var payload struct {
			Message       string                   `json:"message"`
			MessageRecord *chatStreamMessageRecord `json:"message_record"`
		}
		if err := json.Unmarshal(event.Data, &payload); err != nil {
			return err
		}
		if payload.Message != "" {
			if hiddenChatSystemMessage(payload.Message, payload.MessageRecord) {
				writeChatDebug(debugOut, payload.Message)
				return nil
			}
			_, err := fmt.Fprintf(out, "Error: %s\n", payload.Message)
			return err
		}
	case "message":
		var payload struct {
			Message ChatMessage `json:"message"`
		}
		if err := json.Unmarshal(event.Data, &payload); err != nil {
			return err
		}
		return renderLiveToolActivity(out, payload.Message)
	case "turn_complete":
		return nil
	}
	return nil
}

// renderLiveToolActivity renders the mid-turn activity events the server
// emits for any message role that isn't "assistant" or "system" (those get
// their own "text_chunk"/"proposal"/"error" events) — in practice tool_use
// and tool_result. The initial "message" event of a turn echoes the user's
// own message back (role "user"); that and any other role are a silent
// no-op here, since the caller already knows what it sent and renders
// assistant text itself.
func renderLiveToolActivity(out io.Writer, message ChatMessage) error {
	switch message.Role {
	case "tool_use":
		return RenderToolUseActivity(out, message.ToolName)
	case "tool_result":
		return renderToolResultActivity(out, message)
	}
	return nil
}

var toolActivityMarkerStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))

// RenderToolUseActivity writes a single compact "› toolname" line for a
// tool_use chat message. Shared by the live SSE stream (above) and the
// REPL's history-load renderer so a tool call renders identically whether
// it arrives live or is replayed from history.
func RenderToolUseActivity(out io.Writer, toolName string) error {
	name := strings.TrimSpace(toolName)
	if name == "" {
		name = "tool"
	}
	_, err := fmt.Fprintf(out, "%s %s\n\n", toolActivityMarkerStyle.Render("›"), name)
	return err
}

const maxToolResultSummaryRunes = 160

// renderToolResultActivity writes a one-line summary of a tool_result
// message ("  ⎿ <summary>", or "  ⎿ ✗ <summary>" on error). Tool results
// carry no top-level "text" (ChatMessagePayload#text_from_content only
// reads content["text"], and a tool_result's content Hash keys its payload
// under "content" instead), so the summary is derived straight from
// message.Content. A successful result with no extractable text summary
// (a bare acknowledgement, a big structured payload with no text block) is
// intentionally silent — full JSON dumps mid-turn are noise, not signal.
func renderToolResultActivity(out io.Writer, message ChatMessage) error {
	summary, isError := toolResultSummary(message.Content)
	if summary == "" && !isError {
		return nil
	}
	marker := "⎿"
	if isError {
		marker = "⎿ ✗"
		if summary == "" {
			summary = "error"
		}
	}
	_, err := fmt.Fprintf(out, "  %s %s\n\n", toolActivityMarkerStyle.Render(marker), truncateToolResultSummary(summary))
	return err
}

func toolResultSummary(content map[string]any) (summary string, isError bool) {
	if content == nil {
		return "", false
	}
	if v, ok := content["is_error"].(bool); ok {
		isError = v
	}
	return toolResultBodySummary(content["content"]), isError
}

// toolResultBodySummary mirrors the Ruby AgentEventAbbreviator.result_body
// shape: a plain string result, or the Anthropic content-blocks array
// (only "text" and "tool_reference" blocks carry anything worth showing).
// Anything else (numbers, bare objects, nil) summarizes to "" — silent by
// design, see renderToolResultActivity.
func toolResultBodySummary(body any) string {
	switch v := body.(type) {
	case string:
		return firstLine(v)
	case []any:
		var parts []string
		for _, item := range v {
			block, ok := item.(map[string]any)
			if !ok {
				continue
			}
			switch block["type"] {
			case "text":
				if text, ok := block["text"].(string); ok {
					parts = append(parts, text)
				}
			case "tool_reference":
				if name, ok := block["tool_name"].(string); ok {
					parts = append(parts, "→ "+name)
				}
			}
		}
		return firstLine(strings.Join(parts, " "))
	default:
		return ""
	}
}

func firstLine(s string) string {
	if idx := strings.IndexByte(s, '\n'); idx >= 0 {
		s = s[:idx]
	}
	return strings.TrimSpace(s)
}

func truncateToolResultSummary(s string) string {
	runes := []rune(s)
	if len(runes) <= maxToolResultSummaryRunes {
		return s
	}
	return string(runes[:maxToolResultSummaryRunes-1]) + "…"
}

func hiddenChatSystemMessage(message string, record *chatStreamMessageRecord) bool {
	text := strings.TrimSpace(message)
	if text == "" {
		return true
	}
	return strings.HasPrefix(text, "[mcp_servers]") || strings.HasPrefix(text, "[result]")
}

func writeChatDebug(debugOut io.Writer, message string) {
	if debugOut == nil {
		return
	}
	fmt.Fprintf(debugOut, "Debug: %s\n", message)
}
