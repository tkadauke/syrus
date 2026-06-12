package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
	"github.com/tkadauke/syrus/cli/internal/config"
	"github.com/tkadauke/syrus/cli/internal/render"
)

func NewChatCommand() *cobra.Command {
	return &cobra.Command{
		Use:           "chat CHAT_ID MESSAGE",
		Short:         "Send one streaming chat turn",
		Args:          cobra.MinimumNArgs(2),
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return streamTurn(cmd.Context(), args[0], strings.Join(args[1:], " "), cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr())
		},
	}
}

func StreamTurn(chatID string, message string) error {
	return streamTurn(context.Background(), chatID, message, os.Stdin, os.Stdout, os.Stderr)
}

func streamTurn(parent context.Context, chatID string, message string, in io.Reader, out, errOut interface {
	Write([]byte) (int, error)
}) error {
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

	return streamTurnWithClient(parent, client, chatID, message, bufio.NewReader(in), out, errOut)
}

func streamTurnWithClient(parent context.Context, client *api.Client, chatID string, message string, reader *bufio.Reader, out, errOut io.Writer) error {
	ctx, stop := signal.NotifyContext(parent, os.Interrupt)
	defer stop()

	err := client.StreamTurn(ctx, chatID, message, api.StreamTurnOptions{
		Out:             out,
		Renderer:        render.NewMarkdownRenderer(out),
		ProposalHandler: proposalHandler(client, reader, out),
	})
	if errors.Is(err, context.Canceled) {
		fmt.Fprintln(errOut, "Cancelling chat turn...")
		if stopErr := client.StopChat(context.Background(), chatID); stopErr != nil {
			return fmt.Errorf("cancel requested, but stop failed: %w", stopErr)
		}
		return nil
	}
	return err
}

func proposalHandler(client *api.Client, reader *bufio.Reader, out io.Writer) func(context.Context, api.ChatProposal) error {
	return func(ctx context.Context, proposal api.ChatProposal) error {
		return handleChatProposal(ctx, client, reader, out, proposal)
	}
}

func handleChatProposal(ctx context.Context, client *api.Client, reader *bufio.Reader, out io.Writer, proposal api.ChatProposal) error {
	renderProposal(out, proposal)
	fmt.Fprint(out, "[c]onfirm  [s]kip: ")
	line, err := reader.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return err
	}

	choice := strings.ToLower(strings.TrimSpace(line))
	switch choice {
	case "c", "confirm":
		if proposal.ConfirmPath == "" {
			return errors.New("proposal cannot be confirmed from the stream payload")
		}
		if err := client.ConfirmChatProposal(ctx, proposal.ConfirmPath); err != nil {
			return err
		}
		fmt.Fprintln(out, "Filed.")
	case "s", "skip":
		if err := skipChatProposal(ctx, client, proposal); err != nil {
			return err
		}
		fmt.Fprintln(out, "Skipped.")
	default:
		fmt.Fprintln(out, "Choose c to confirm or s to skip. Skipping.")
		if err := skipChatProposal(ctx, client, proposal); err != nil {
			return err
		}
		fmt.Fprintln(out, "Skipped.")
	}
	return nil
}

func skipChatProposal(ctx context.Context, client *api.Client, proposal api.ChatProposal) error {
	if proposal.RejectPath == "" {
		return errors.New("proposal cannot be skipped from the stream payload")
	}
	return client.RejectChatProposal(ctx, proposal.RejectPath)
}

func renderProposal(out io.Writer, proposal api.ChatProposal) {
	title := strings.TrimSpace(proposal.Title)
	if title == "" {
		title = strings.TrimSpace(proposal.Slug)
	}
	if title == "" {
		title = "Untitled proposal"
	}

	heading := "Proposed Job"
	if proposal.EpicBundle {
		heading = "Proposed Epic"
	}

	lines := []string{title}
	if proposal.EpicBundle {
		count := proposal.ActiveChildrenCount
		label := "child Jobs"
		if count == 1 {
			label = "child Job"
		}
		lines = append(lines, fmt.Sprintf("%d %s", count, label))
	} else if proposal.ScopedRepository != "" {
		lines = append(lines, "Repository: "+proposal.ScopedRepository)
	}

	const width = 60
	topFill := width - len([]rune(heading)) - 4
	if topFill < 0 {
		topFill = 0
	}
	fmt.Fprintf(out, "╭─ %s %s╮\n", heading, strings.Repeat("─", topFill))
	for _, line := range lines {
		fmt.Fprintf(out, "│ %-*s │\n", width-4, truncateRunes(line, width-4))
	}
	fmt.Fprintf(out, "╰%s╯\n", strings.Repeat("─", width-2))
}

func truncateRunes(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	if limit <= 3 {
		return string(runes[:limit])
	}
	return string(runes[:limit-3]) + "..."
}
