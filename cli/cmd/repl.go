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

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
	"github.com/tkadauke/syrus/cli/internal/config"
	"github.com/tkadauke/syrus/cli/internal/repo"
)

func runInteractiveChat(cmd *cobra.Command) error {
	creds, err := config.LoadDefaultCredentials()
	if err != nil {
		if errors.Is(err, config.ErrMissingCredentials) || errors.Is(err, config.ErrIncompleteCredentials) {
			return errors.New(loginMessage)
		}
		return err
	}
	client, err := api.NewClient(creds.URL, creds.Token)
	if err != nil {
		return err
	}

	reader := bufio.NewReader(cmd.InOrStdin())
	chat, err := pickChatSession(cmd.Context(), client, reader, cmd.OutOrStdout())
	if err != nil {
		return err
	}
	return runChatREPL(cmd.Context(), client, strconv.FormatInt(chat.ID, 10), reader, cmd.OutOrStdout(), cmd.ErrOrStderr())
}

func pickChatSession(ctx context.Context, client *api.Client, reader *bufio.Reader, out io.Writer) (api.ChatSession, error) {
	list, err := client.ListChats(ctx)
	if err != nil {
		return api.ChatSession{}, err
	}

	currentSlug, _ := repo.DetectSlug()
	chats := orderChatsForRepository(list.Chats, currentSlug)
	newSessionIndex := len(chats) + 1

	fmt.Fprintln(out, "Recent sessions:")
	for index, chat := range chats {
		fmt.Fprintf(out, "  %d. %s\n", index+1, chatPickerLabel(chat))
	}
	fmt.Fprintf(out, "  %d. New session\n", newSessionIndex)

	for {
		fmt.Fprintf(out, "Attach to [1-%d]: ", newSessionIndex)
		line, err := reader.ReadString('\n')
		if err != nil && !(errors.Is(err, io.EOF) && strings.TrimSpace(line) != "") {
			return api.ChatSession{}, err
		}
		selection, parseErr := strconv.Atoi(strings.TrimSpace(line))
		if parseErr == nil && selection >= 1 && selection <= newSessionIndex {
			if selection == newSessionIndex {
				repositoryID := repositoryIDForSlug(list.Repositories, currentSlug)
				return client.CreateChat(ctx, repositoryID)
			}
			return chats[selection-1], nil
		}
		fmt.Fprintln(out, "Choose one of the listed sessions.")
	}
}

func runChatREPL(ctx context.Context, client *api.Client, chatID string, reader *bufio.Reader, out, errOut io.Writer) error {
	for {
		fmt.Fprint(out, "You: ")
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
		if err := streamTurnWithClient(ctx, client, chatID, message, out, errOut); err != nil {
			return err
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
	}
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

func repositoryIDForSlug(repositories []api.ChatRepository, slug string) int64 {
	for _, repository := range repositories {
		if repository.Slug == slug {
			return repository.ID
		}
	}
	return 0
}

func chatPickerLabel(chat api.ChatSession) string {
	repository := "No repository"
	if chat.Repository != nil && chat.Repository.Slug != "" {
		repository = chat.Repository.Slug
	}
	title := strings.TrimSpace(chat.Title)
	if title == "" {
		title = "Untitled chat"
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
