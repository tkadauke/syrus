package cmd

import (
	"os"
	"strings"

	"github.com/spf13/cobra"
)

const loginMessage = "Run 'syrus login' to set up your Syrus instance URL and API token."

var chatDebug bool

func Execute() error {
	return NewRootCommand().Execute()
}

func NewRootCommand() *cobra.Command {
	chatDebug = false
	rootCmd := &cobra.Command{
		Use:           "syrus",
		Short:         "Syrus command line client",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runInteractiveChat(cmd)
		},
	}

	rootCmd.PersistentFlags().BoolVar(&chatDebug, "debug", false, "show raw chat stream diagnostics")

	rootCmd.AddCommand(NewLoginCommand())
	rootCmd.AddCommand(NewChatCommand())
	rootCmd.AddCommand(NewCheckoutCommand())
	rootCmd.AddCommand(NewTestPlanCommand())
	rootCmd.AddCommand(NewApproveCommand())
	rootCmd.AddCommand(NewJobsCommand())
	rootCmd.AddCommand(NewStatusCommand())
	rootCmd.AddCommand(NewInboxCommand())
	rootCmd.AddCommand(NewJobCommand())
	rootCmd.AddCommand(NewEpicCommand())
	rootCmd.AddCommand(NewRepoCommand())
	rootCmd.AddCommand(NewWhoamiCommand())
	rootCmd.AddCommand(NewScheduleCommand())
	rootCmd.AddCommand(NewSkillCommand())
	rootCmd.AddCommand(NewLocalCommand())
	return rootCmd
}

func chatDebugEnabled() bool {
	if chatDebug {
		return true
	}
	switch strings.ToLower(strings.TrimSpace(os.Getenv("SYRUS_CHAT_DEBUG"))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
