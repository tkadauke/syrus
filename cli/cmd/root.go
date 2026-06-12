package cmd

import "github.com/spf13/cobra"

const loginMessage = "Run 'syrus login' to set up your Syrus instance URL and API token."

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
			return runInteractiveChat(cmd)
		},
	}

	rootCmd.AddCommand(NewLoginCommand())
	rootCmd.AddCommand(NewChatCommand())
	rootCmd.AddCommand(NewCheckoutCommand())
	rootCmd.AddCommand(NewTestPlanCommand())
	rootCmd.AddCommand(NewApproveCommand())
	rootCmd.AddCommand(NewStatusCommand())
	rootCmd.AddCommand(NewJobCommand())
	rootCmd.AddCommand(NewEpicCommand())
	rootCmd.AddCommand(NewRepoCommand())
	rootCmd.AddCommand(NewWhoamiCommand())
	rootCmd.AddCommand(NewScheduleCommand())
	return rootCmd
}
