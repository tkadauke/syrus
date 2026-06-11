package cmd

import (
	"context"
	"errors"
	"fmt"
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
			return streamTurn(cmd.Context(), args[0], strings.Join(args[1:], " "), cmd.OutOrStdout(), cmd.ErrOrStderr())
		},
	}
}

func StreamTurn(chatID string, message string) error {
	return streamTurn(context.Background(), chatID, message, os.Stdout, os.Stderr)
}

func streamTurn(parent context.Context, chatID string, message string, out, errOut interface {
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

	return streamTurnWithClient(parent, client, chatID, message, out, errOut)
}

func streamTurnWithClient(parent context.Context, client *api.Client, chatID string, message string, out, errOut interface {
	Write([]byte) (int, error)
}) error {
	ctx, stop := signal.NotifyContext(parent, os.Interrupt)
	defer stop()

	err := client.StreamTurn(ctx, chatID, message, api.StreamTurnOptions{
		Out:      out,
		Renderer: render.NewMarkdownRenderer(out),
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
