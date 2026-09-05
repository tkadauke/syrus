package cmd

import (
	"bufio"
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

func NewLoginCommand() *cobra.Command {
	var urlFlag string
	var tokenFlag string

	loginCmd := &cobra.Command{
		Use:           "login",
		Short:         "Log in to a Syrus instance",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			// The Syrus desktop app keeps ~/.syrus/credentials current on its
			// own; login mainly exists for clone-based setups and for
			// refreshing a stale token. Existing values prefill the prompts so
			// a refresh is just Enter + paste-new-token.
			existing, _ := config.LoadDefaultCredentials()

			creds, err := promptCredentials(cmd.InOrStdin(), cmd.OutOrStdout(), existing, urlFlag, tokenFlag)
			if err != nil {
				return err
			}
			if err := config.SaveDefaultCredentials(creds); err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), "Syrus credentials saved.")
			return nil
		},
	}

	loginCmd.Flags().StringVar(&urlFlag, "url", "", "Syrus instance URL (skips the prompt)")
	loginCmd.Flags().StringVar(&tokenFlag, "token", "", "API token (skips the prompt)")
	return loginCmd
}

func promptCredentials(in io.Reader, out io.Writer, existing config.Credentials, urlFlag string, tokenFlag string) (config.Credentials, error) {
	reader := bufio.NewReader(in)

	url := strings.TrimSpace(urlFlag)
	if url == "" {
		label := "Syrus instance URL: "
		if existing.URL != "" {
			label = fmt.Sprintf("Syrus instance URL [%s]: ", existing.URL)
		}
		answer, err := prompt(reader, out, label)
		if err != nil {
			return config.Credentials{}, err
		}
		url = answer
		if url == "" {
			url = existing.URL
		}
	}

	token := strings.TrimSpace(tokenFlag)
	if token == "" {
		label := "API token: "
		if existing.Token != "" {
			label = fmt.Sprintf("API token [keep %s]: ", maskToken(existing.Token))
		}
		answer, err := prompt(reader, out, label)
		if err != nil {
			return config.Credentials{}, err
		}
		token = answer
		if token == "" {
			token = existing.Token
		}
	}

	creds := config.Credentials{URL: url, Token: token}
	if err := creds.Validate(); err != nil {
		return config.Credentials{}, err
	}
	return creds, nil
}

func maskToken(token string) string {
	trimmed := strings.TrimSpace(token)
	if len(trimmed) <= 4 {
		return "current token"
	}
	return "…" + trimmed[len(trimmed)-4:]
}

func prompt(reader *bufio.Reader, out io.Writer, label string) (string, error) {
	return cliplugin.Prompt(reader, out, label)
}
