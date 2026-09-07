package cmd

import (
	"os"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
	designdocs "github.com/tkadauke/syrus/plugins/design_docs/cli"
	globalsearch "github.com/tkadauke/syrus/plugins/global_search/cli"
	k8scluster "github.com/tkadauke/syrus/plugins/k8s_cluster/cli"
	scheduledtasks "github.com/tkadauke/syrus/plugins/scheduled_tasks/cli"
	spendinginsights "github.com/tkadauke/syrus/plugins/spending_insights/cli"
)

const loginMessage = "Run 'syrus login' to set up your Syrus instance URL and API token."

var chatDebug bool

func Execute() error {
	return NewRootCommand().Execute()
}

func NewRootCommand() *cobra.Command {
	chatDebug = false
	// StringVar below resets this to "" on every build; the explicit clear
	// mirrors chatDebug and documents that the flag is command-scoped state.
	config.ProfileFlag = ""
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
	rootCmd.PersistentFlags().StringVar(&config.ProfileFlag, "profile", "",
		`credentials profile to target ("test" for a side-by-side test build; default is stable)`)

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
	// Contributed by a bundled plugin. Its commands live in the plugin's own
	// module (plugins/scheduled_tasks/cli) so they are deleted with it; Go has
	// no usable dynamic loading for a single static binary, so they are
	// compiled in here. No runtime gating: when the plugin is disabled the
	// instance already answers its routes with a "plugin_disabled" error.
	rootCmd.AddCommand(scheduledtasks.NewScheduleCommand())
	rootCmd.AddCommand(k8scluster.NewK8sCommand())
	rootCmd.AddCommand(globalsearch.NewSearchCommand())
	rootCmd.AddCommand(designdocs.NewDocsCommand())
	insightsCmd := NewInsightsCommand()
	insightsCmd.AddCommand(spendinginsights.NewSpendingCommand())
	rootCmd.AddCommand(insightsCmd)
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
