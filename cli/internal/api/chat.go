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
	"strings"
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
		return handleChatStreamEvent(ctx, event, out, renderer, options.ProposalHandler)
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

func handleChatStreamEvent(ctx context.Context, event ChatStreamEvent, out io.Writer, renderer ChatTurnRenderer, proposalHandler func(context.Context, ChatProposal) error) error {
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
			Message string `json:"message"`
		}
		if err := json.Unmarshal(event.Data, &payload); err != nil {
			return err
		}
		if payload.Message != "" {
			_, err := fmt.Fprintf(out, "Error: %s\n", payload.Message)
			return err
		}
	case "turn_complete":
		return nil
	}
	return nil
}
