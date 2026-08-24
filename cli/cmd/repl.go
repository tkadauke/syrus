package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
	"github.com/tkadauke/syrus/cli/internal/render"
	"github.com/tkadauke/syrus/cli/internal/repo"
	"golang.org/x/term"
)

const chatHistoryMessageLimit = 90

var errChatPickerCancelled = errors.New("chat selection cancelled")

func runInteractiveChat(cmd *cobra.Command) error {
	client, _, err := apiClient()
	if err != nil {
		return err
	}

	input := cmd.InOrStdin()
	out := cmd.OutOrStdout()
	reader := bufio.NewReader(input)
	chat, err := pickChatSession(cmd.Context(), client, input, reader, out)
	if errors.Is(err, errChatPickerCancelled) {
		return nil
	}
	if err != nil {
		return err
	}
	if terminalPair(input, out) {
		reader = bufio.NewReader(input)
	}

	chatID := strconv.FormatInt(chat.ID, 10)
	if err := renderInitialChatHistory(cmd.Context(), client, chatID, out); err != nil {
		return err
	}
	return runChatREPL(cmd.Context(), client, chatID, reader, out, cmd.ErrOrStderr())
}

func pickChatSession(ctx context.Context, client *api.Client, input io.Reader, reader *bufio.Reader, out io.Writer) (api.ChatSession, error) {
	list, err := client.ListChats(ctx)
	if err != nil {
		return api.ChatSession{}, err
	}

	currentSlug, _ := repo.DetectSlug()
	chats := orderChatsForRepository(list.Chats, currentSlug)
	newSessionIndex := len(chats) + 1
	newSessionLabel := "New session"
	if currentSlug != "" {
		newSessionLabel = "New session in " + currentSlug
	}

	if terminalPair(input, out) {
		return pickChatSessionWithCursor(ctx, client, input, out, chats, list.Repositories, currentSlug, newSessionLabel)
	}
	return pickChatSessionByNumber(ctx, client, reader, out, chats, list.Repositories, currentSlug, newSessionIndex, newSessionLabel)
}

func pickChatSessionByNumber(ctx context.Context, client *api.Client, reader *bufio.Reader, out io.Writer, chats []api.ChatSession, repositories []api.ChatRepository, currentSlug string, newSessionIndex int, newSessionLabel string) (api.ChatSession, error) {
	fmt.Fprintln(out, "Recent sessions:")
	if currentSlug != "" {
		current, other := partitionChatsForRepository(chats, currentSlug)
		index := 1
		if len(current) > 0 {
			fmt.Fprintf(out, "  %s:\n", currentSlug)
			for _, chat := range current {
				fmt.Fprintf(out, "    %d. %s\n", index, chatPickerLabel(chat, false))
				index++
			}
		}
		if len(other) > 0 {
			fmt.Fprintln(out, "  Other repositories:")
			for _, chat := range other {
				fmt.Fprintf(out, "    %d. %s\n", index, chatPickerLabel(chat, true))
				index++
			}
		}
	} else {
		for index, chat := range chats {
			fmt.Fprintf(out, "  %d. %s\n", index+1, chatPickerLabel(chat, true))
		}
	}
	fmt.Fprintf(out, "  %d. %s\n", newSessionIndex, newSessionLabel)

	for {
		fmt.Fprintf(out, "Choose [1-%d]: ", newSessionIndex)
		line, err := reader.ReadString('\n')
		if err != nil && !(errors.Is(err, io.EOF) && strings.TrimSpace(line) != "") {
			return api.ChatSession{}, err
		}
		selection, parseErr := strconv.Atoi(strings.TrimSpace(line))
		if parseErr == nil && selection >= 1 && selection <= newSessionIndex {
			if selection == newSessionIndex {
				repositoryID := chatRepositoryIDForSlug(repositories, currentSlug)
				return client.CreateChat(ctx, repositoryID)
			}
			return chats[selection-1], nil
		}
		fmt.Fprintln(out, "Choose one of the listed sessions.")
	}
}

func pickChatSessionWithCursor(ctx context.Context, client *api.Client, input io.Reader, out io.Writer, chats []api.ChatSession, repositories []api.ChatRepository, currentSlug string, newSessionLabel string) (api.ChatSession, error) {
	items := chatPickerItems(chats, repositories, currentSlug, newSessionLabel)
	model := newChatPickerModel(items, currentSlug)
	finalModel, err := tea.NewProgram(model, tea.WithInput(input), tea.WithOutput(out)).Run()
	if err != nil {
		return api.ChatSession{}, err
	}
	model, ok := finalModel.(chatPickerModel)
	if !ok || model.cancelled || model.selection < 0 || model.selection >= len(model.items) {
		return api.ChatSession{}, errChatPickerCancelled
	}
	item := model.items[model.selection]
	if item.newSession {
		return client.CreateChat(ctx, item.repositoryID)
	}
	if item.chat == nil {
		return api.ChatSession{}, errChatPickerCancelled
	}
	return *item.chat, nil
}

func runChatREPL(ctx context.Context, client *api.Client, chatID string, reader *bufio.Reader, out, errOut io.Writer) error {
	for {
		fmt.Fprint(out, "> ")
		line, err := reader.ReadString('\n')
		if errors.Is(err, io.EOF) && strings.TrimSpace(line) == "" {
			fmt.Fprintln(out)
			return nil
		}
		if err != nil && !errors.Is(err, io.EOF) {
			return err
		}

		message := strings.TrimSpace(line)
		if message == "" {
			if errors.Is(err, io.EOF) {
				fmt.Fprintln(out)
				return nil
			}
			continue
		}
		if err := streamTurnWithClient(ctx, client, chatID, message, reader, out, errOut); err != nil {
			return err
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
	}
}

type chatPickerItem struct {
	chat         *api.ChatSession
	newSession   bool
	repositoryID int64
	title        string
	repository   string
	when         string
}

type chatPickerModel struct {
	items     []chatPickerItem
	scope     string
	cursor    int
	selection int
	width     int
	cancelled bool
}

func newChatPickerModel(items []chatPickerItem, scope string) chatPickerModel {
	return chatPickerModel{
		items:     items,
		scope:     scope,
		selection: -1,
		width:     defaultInboxWidth,
	}
}

func (m chatPickerModel) Init() tea.Cmd {
	return nil
}

func (m chatPickerModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		if msg.Width > 0 {
			m.width = msg.Width
		}
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q", "esc":
			m.cancelled = true
			return m, tea.Quit
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < len(m.items)-1 {
				m.cursor++
			}
		case "enter":
			if len(m.items) == 0 {
				return m, nil
			}
			m.selection = m.cursor
			return m, tea.Quit
		default:
			selection, err := strconv.Atoi(msg.String())
			if err == nil && selection >= 1 && selection <= len(m.items) {
				m.selection = selection - 1
				return m, tea.Quit
			}
		}
	}
	return m, nil
}

func (m chatPickerModel) View() string {
	if len(m.items) == 0 {
		return "No chat sessions.\n"
	}
	width := m.width
	if width < 40 {
		width = defaultInboxWidth
	}
	scope := "all repositories"
	if m.scope != "" {
		scope = m.scope
	}
	lines := []string{
		fmt.Sprintf("%s  %d sessions · %s", headerStyle.Render("SYRUS CHAT"), len(m.items)-1, scope),
		ruleStyle.Render(strings.Repeat("─", width)),
	}
	titleWidth := max(20, width-34)
	for i, item := range m.items {
		pointer := " "
		if i == m.cursor {
			pointer = "▶"
		}
		title := truncate(item.title, titleWidth)
		detail := item.when
		if item.repository != "" {
			detail = item.repository + " · " + detail
		}
		lines = append(lines, fmt.Sprintf("%s %-*s %s", pointer, titleWidth, title, subtleStyle.Render(detail)))
	}
	lines = append(lines, ruleStyle.Render(strings.Repeat("─", width)))
	lines = append(lines, "↑/↓ j/k navigate · enter attach · q quit")
	return strings.Join(lines, "\n") + "\n"
}

func chatPickerItems(chats []api.ChatSession, repositories []api.ChatRepository, currentSlug string, newSessionLabel string) []chatPickerItem {
	items := make([]chatPickerItem, 0, len(chats)+1)
	for index := range chats {
		chat := &chats[index]
		repository := ""
		if chat.Repository != nil && chat.Repository.Slug != "" {
			repository = chat.Repository.Slug
		}
		title := strings.TrimSpace(chat.Title)
		if title == "" {
			title = "Untitled chat"
		}
		items = append(items, chatPickerItem{
			chat:       chat,
			title:      title,
			repository: repository,
			when:       relativeChatTime(*chat),
		})
	}
	items = append(items, chatPickerItem{
		newSession:   true,
		repositoryID: chatRepositoryIDForSlug(repositories, currentSlug),
		title:        newSessionLabel,
		when:         "new",
	})
	return items
}

func terminalPair(input io.Reader, out io.Writer) bool {
	inFile, inputOK := input.(interface{ Fd() uintptr })
	outFile, outputOK := out.(interface{ Fd() uintptr })
	return inputOK && outputOK && term.IsTerminal(int(inFile.Fd())) && term.IsTerminal(int(outFile.Fd()))
}

func renderInitialChatHistory(ctx context.Context, client *api.Client, chatID string, out io.Writer) error {
	messages, err := loadChatHistory(ctx, client, chatID, chatHistoryMessageLimit)
	if err != nil {
		return err
	}
	renderable := renderableChatMessages(messages)
	if len(renderable) == 0 {
		return nil
	}

	fmt.Fprintln(out)
	fmt.Fprintln(out, headerStyle.Render("RECENT MESSAGES"))
	markdown := render.NewMarkdownRenderer(out)
	for _, message := range renderable {
		if err := renderChatHistoryMessage(out, markdown, message); err != nil {
			return err
		}
	}
	return nil
}

func loadChatHistory(ctx context.Context, client *api.Client, chatID string, limit int) ([]api.ChatMessage, error) {
	payload, err := client.GetChat(ctx, chatID)
	if err != nil {
		return nil, err
	}
	messages := payload.Messages
	hasMoreOlder := payload.HasMoreOlder

	for hasMoreOlder && len(messages) < limit {
		oldestID := oldestChatMessageID(messages)
		if oldestID == 0 {
			break
		}
		page, err := client.GetChatMessages(ctx, chatID, oldestID)
		if err != nil {
			return nil, err
		}
		messages = mergeOlderChatMessages(page.Messages, messages)
		hasMoreOlder = page.HasMoreOlder
	}
	if len(messages) > limit {
		messages = messages[len(messages)-limit:]
	}
	return messages, nil
}

func oldestChatMessageID(messages []api.ChatMessage) int64 {
	for _, message := range messages {
		if message.ID > 0 {
			return message.ID
		}
	}
	return 0
}

func mergeOlderChatMessages(older []api.ChatMessage, newer []api.ChatMessage) []api.ChatMessage {
	seen := map[int64]bool{}
	for _, message := range older {
		if message.ID > 0 {
			seen[message.ID] = true
		}
	}
	merged := append([]api.ChatMessage{}, older...)
	for _, message := range newer {
		if message.ID > 0 && seen[message.ID] {
			continue
		}
		merged = append(merged, message)
	}
	return merged
}

func renderableChatMessages(messages []api.ChatMessage) []api.ChatMessage {
	var out []api.ChatMessage
	for _, message := range messages {
		if chatHistoryMessageVisible(message) {
			out = append(out, message)
		}
	}
	return out
}

func chatHistoryMessageVisible(message api.ChatMessage) bool {
	switch message.Role {
	case "user", "assistant", "tool_use":
		return strings.TrimSpace(message.Text) != "" || message.Proposal != nil || message.ToolName != ""
	default:
		return false
	}
}

func renderChatHistoryMessage(out io.Writer, markdown render.MarkdownRenderer, message api.ChatMessage) error {
	switch message.Role {
	case "user":
		text := strings.TrimSpace(message.Text)
		if text == "" {
			return nil
		}
		fmt.Fprintf(out, "%s %s\n\n", subtleStyle.Render("›"), text)
	case "assistant":
		if message.Proposal != nil {
			renderProposal(out, *message.Proposal)
			fmt.Fprintln(out)
			return nil
		}
		text := strings.TrimSpace(message.Text)
		if text == "" {
			return nil
		}
		rendered, err := markdown.Render(text)
		if err != nil {
			return err
		}
		fmt.Fprint(out, rendered)
		if !strings.HasSuffix(rendered, "\n") {
			fmt.Fprintln(out)
		}
		fmt.Fprintln(out)
	case "tool_use":
		name := strings.TrimSpace(message.ToolName)
		if name == "" {
			name = "tool"
		}
		fmt.Fprintf(out, "%s %s\n\n", subtleStyle.Render("›"), name)
	}
	return nil
}

func orderChatsForRepository(chats []api.ChatSession, slug string) []api.ChatSession {
	if slug == "" {
		return chats
	}
	ordered := make([]api.ChatSession, 0, len(chats))
	for _, chat := range chats {
		if chat.Repository != nil && chat.Repository.Slug == slug {
			ordered = append(ordered, chat)
		}
	}
	for _, chat := range chats {
		if chat.Repository == nil || chat.Repository.Slug != slug {
			ordered = append(ordered, chat)
		}
	}
	return ordered
}

func partitionChatsForRepository(chats []api.ChatSession, slug string) ([]api.ChatSession, []api.ChatSession) {
	var current []api.ChatSession
	var other []api.ChatSession
	for _, chat := range chats {
		if chat.Repository != nil && chat.Repository.Slug == slug {
			current = append(current, chat)
		} else {
			other = append(other, chat)
		}
	}
	return current, other
}

func chatRepositoryIDForSlug(repositories []api.ChatRepository, slug string) int64 {
	for _, repository := range repositories {
		if repository.Slug == slug {
			return repository.ID
		}
	}
	return 0
}

func chatPickerLabel(chat api.ChatSession, showRepository bool) string {
	title := strings.TrimSpace(chat.Title)
	if title == "" {
		title = "Untitled chat"
	}
	if !showRepository {
		return fmt.Sprintf("%s (%s)", title, relativeChatTime(chat))
	}
	repository := "No repository"
	if chat.Repository != nil && chat.Repository.Slug != "" {
		repository = chat.Repository.Slug
	}
	return fmt.Sprintf("%s  - %s (%s)", repository, title, relativeChatTime(chat))
}

func relativeChatTime(chat api.ChatSession) string {
	raw := chat.LastMessageAt
	if raw == "" {
		raw = chat.UpdatedAt
	}
	if raw == "" {
		raw = chat.CreatedAt
	}
	timestamp, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return "recently"
	}
	now := time.Now()
	if timestamp.After(now) {
		return "just now"
	}
	if yesterday(timestamp, now) {
		return "yesterday"
	}
	elapsed := now.Sub(timestamp)
	switch {
	case elapsed < time.Minute:
		return "just now"
	case elapsed < time.Hour:
		return fmt.Sprintf("%dm ago", int(elapsed.Minutes()))
	case elapsed < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(elapsed.Hours()))
	case elapsed < 7*24*time.Hour:
		return fmt.Sprintf("%dd ago", int(elapsed.Hours()/24))
	default:
		return timestamp.Format("2006-01-02")
	}
}

func yesterday(timestamp, now time.Time) bool {
	year, month, day := now.Date()
	today := time.Date(year, month, day, 0, 0, 0, 0, now.Location())
	yesterdayStart := today.AddDate(0, 0, -1)
	localTimestamp := timestamp.In(now.Location())
	return !localTimestamp.Before(yesterdayStart) && localTimestamp.Before(today)
}
