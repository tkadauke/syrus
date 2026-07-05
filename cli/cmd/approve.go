package cmd

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
	"github.com/tkadauke/syrus/cli/internal/config"
)

func NewApproveCommand() *cobra.Command {
	return &cobra.Command{
		Use:           "approve JOB-ID",
		Short:         "Approve a Syrus job for landing",
		Args:          cobra.ExactArgs(1),
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			jobID, err := normalizeJobID(args[0])
			if err != nil {
				return err
			}

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
			if err := client.ApproveJob(context.Background(), jobID); err != nil {
				return err
			}

			fmt.Fprintf(cmd.OutOrStdout(), "Approved %s. Landing will begin shortly.\n", displayJobRef(jobID))
			return nil
		},
	}
}

func normalizeJobID(value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return "", errors.New("job ID is required")
	}
	upper := strings.ToUpper(trimmed)
	if strings.HasPrefix(upper, "JOB-") {
		rest := strings.TrimSpace(trimmed[4:])
		if rest == "" {
			return "", fmt.Errorf("invalid job ID %q", value)
		}
		return rest, nil
	}
	return trimmed, nil
}
