package cmd

import "github.com/spf13/cobra"

// NewInsightsCommand is the shared "syrus insights" parent that
// insights-family plugins attach their own subcommands to (spending today;
// test_insights/throughput/worker_timeline/agent_insights are potential
// future siblings, each still owning its own subcommand and API calls from
// its own plugin module).
func NewInsightsCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "insights",
		Short: "Inspect operational insights",
	}
}
