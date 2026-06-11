package cmd

import (
	"errors"
	"fmt"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
)

const configureMessage = "Run 'syrus configure' to set up your Syrus instance URL and API token."

func Execute() error {
	return NewRootCommand().Execute()
}

func NewRootCommand() *cobra.Command {
	rootCmd := &cobra.Command{
		Use:           "syrus",
		Short:         "Syrus command line client",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			creds, err := config.LoadDefaultCredentials()
			if err != nil {
				if errors.Is(err, config.ErrMissingCredentials) || errors.Is(err, config.ErrIncompleteCredentials) {
					return errors.New(configureMessage)
				}
				return err
			}

			fmt.Fprintf(cmd.OutOrStdout(), "Configured for %s\n", creds.URL)
			return nil
		},
	}

	rootCmd.AddCommand(NewConfigureCommand())
	return rootCmd
}
