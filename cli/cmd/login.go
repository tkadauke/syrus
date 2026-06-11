package cmd

import (
	"bufio"
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
)

func NewLoginCommand() *cobra.Command {
	return &cobra.Command{
		Use:           "login",
		Short:         "Log in to a Syrus instance",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			creds, err := promptCredentials(cmd.InOrStdin(), cmd.OutOrStdout())
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
}

func promptCredentials(in io.Reader, out io.Writer) (config.Credentials, error) {
	reader := bufio.NewReader(in)

	url, err := prompt(reader, out, "Syrus instance URL: ")
	if err != nil {
		return config.Credentials{}, err
	}
	token, err := prompt(reader, out, "API token: ")
	if err != nil {
		return config.Credentials{}, err
	}

	creds := config.Credentials{URL: url, Token: token}
	if err := creds.Validate(); err != nil {
		return config.Credentials{}, err
	}
	return creds, nil
}

func prompt(reader *bufio.Reader, out io.Writer, label string) (string, error) {
	fmt.Fprint(out, label)
	value, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		return "", err
	}
	return strings.TrimSpace(value), nil
}
