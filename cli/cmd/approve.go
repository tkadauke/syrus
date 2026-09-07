package cmd

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"
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

			client, _, err := apiClient()
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
	_, id, err := parseRef(value, "JOB-", "job ID")
	return id, err
}
