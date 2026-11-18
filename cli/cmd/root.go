package cmd

import (
	"context"
	"os"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
)

const loginMessage = "Run 'syrus login' to set up your Syrus instance URL and API token."
const invocationContextMessage = "Syrus internal CLI authentication is enabled, but SYRUS_CLI_URL or SYRUS_CLI_INVOCATION_CONTEXT is missing. Check the worker runtime configuration."

var chatDebug bool

func Execute() error {
	root := NewRootCommand()
	args := os.Args[1:]
	if handled, err := resolvePluginCommand(context.Background(), root, args); handled || err != nil {
		return err
	}
	return root.Execute()
}

func NewRootCommand() *cobra.Command {
	chatDebug = false
	// StringVar below resets this to "" on every build; the explicit clear
	// mirrors chatDebug and documents that the flag is command-scoped state.
	config.ProfileFlag = ""
	rootCmd := &cobra.Command{
		Use:           "syrus",
		Short:         "Syrus command line client",
		Long:          "Syrus command line client. Commands may also be discovered from the configured instance or from syrus-<name> executables on PATH.",
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runInteractiveChat(cmd)
		},
	}

	rootCmd.PersistentFlags().BoolVar(&chatDebug, "debug", false, "show raw chat stream diagnostics")
	rootCmd.PersistentFlags().StringVar(&config.ProfileFlag, "profile", "",
		`credentials profile to target ("test" for a side-by-side test build; default is stable)`)

	rootCmd.AddCommand(NewLoginCommand())
	rootCmd.AddCommand(NewChatCommand())
	rootCmd.AddCommand(NewCheckoutCommand())
	rootCmd.AddCommand(NewTestPlanCommand())
	rootCmd.AddCommand(NewApproveCommand())
	rootCmd.AddCommand(NewReviewCommand())
	rootCmd.AddCommand(NewJobsCommand())
	rootCmd.AddCommand(NewStatusCommand())
	rootCmd.AddCommand(NewInboxCommand())
	rootCmd.AddCommand(NewJobCommand())
	rootCmd.AddCommand(NewEpicCommand())
	rootCmd.AddCommand(NewRepoCommand())
	rootCmd.AddCommand(NewWhoamiCommand())
	rootCmd.AddCommand(NewInsightsCommand())
	rootCmd.AddCommand(NewSkillCommand())
	rootCmd.AddCommand(NewLocalCommand())
	rootCmd.AddCommand(NewPluginCommand())
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
