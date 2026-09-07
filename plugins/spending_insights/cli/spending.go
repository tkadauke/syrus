// Package spendinginsights is the CLI surface for the bundled
// spending_insights plugin.
//
// It is a thin, read-only client over the plugin's existing app API
// (plugins/spending_insights/app/controllers/api/v1/app/insights/spending_controller.rb),
// which backs the web UI's /insights/spending page. That page also rolls up
// top runs, a cost trend, and a filter-schema-driven FilterBar; this v1 CLI
// deliberately only surfaces the headline totals plus one groupable
// breakdown at a time, matching the payload's own breakdowns (repository,
// user, epic, trigger kind -- there is no agent_provider breakdown, only an
// agent_provider filter, so it is not a --group-by option here).
package spendinginsights

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

func NewSpendingCommand() *cobra.Command {
	var since, until, groupBy string
	var jsonOutput bool
	cmd := &cobra.Command{
		Use:           "spending",
		Short:         "Summarize agent spend",
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := validateDate("--since", since); err != nil {
				return err
			}
			if err := validateDate("--until", until); err != nil {
				return err
			}
			group, err := parseGroupBy(groupBy)
			if err != nil {
				return err
			}
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			payload, err := GetSpending(cmd.Context(), client, since, until)
			if err != nil {
				return err
			}
			if jsonOutput {
				encoder := json.NewEncoder(cmd.OutOrStdout())
				return encoder.Encode(payload)
			}
			renderSpending(cmd.OutOrStdout(), payload, group)
			return nil
		},
	}
	cmd.Flags().StringVar(&since, "since", "", "start date (YYYY-MM-DD); server default is a 90-day window")
	cmd.Flags().StringVar(&until, "until", "", "end date (YYYY-MM-DD); server default is today")
	cmd.Flags().StringVar(&groupBy, "group-by", "repo", "breakdown to show: repo, user, epic, or trigger_kind")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "print the raw JSON response")
	return cmd
}

func validateDate(flag string, value string) error {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	if _, err := time.Parse("2006-01-02", value); err != nil {
		return fmt.Errorf("%s: invalid date %q, expected YYYY-MM-DD", flag, value)
	}
	return nil
}

type groupKind int

const (
	groupRepository groupKind = iota
	groupUser
	groupEpic
	groupTriggerKind
)

func parseGroupBy(value string) (groupKind, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "repo", "repository", "repositories":
		return groupRepository, nil
	case "user", "users":
		return groupUser, nil
	case "epic", "epics":
		return groupEpic, nil
	case "trigger_kind", "trigger-kind", "trigger_kinds":
		return groupTriggerKind, nil
	default:
		return 0, fmt.Errorf("unknown --group-by %q; must be one of repo, user, epic, trigger_kind", value)
	}
}

func renderSpending(out io.Writer, payload SpendingPayload, group groupKind) {
	scopeLabel := payload.Scope.Label
	if payload.Scope.Admin {
		scopeLabel = fmt.Sprintf("%s (instance-wide)", scopeLabel)
	}
	fmt.Fprintf(out, "Scope: %s\n", scopeLabel)
	fmt.Fprintf(out, "Window: %s to %s\n\n", payload.Filters.StartDate, payload.Filters.EndDate)

	totals := payload.Totals
	fmt.Fprintln(out, "Totals")
	fmt.Fprintf(out, "  This week:                  %s\n", formatUSD(totals.WeekUSD))
	fmt.Fprintf(out, "  This month:                 %s\n", formatUSD(totals.MonthUSD))
	fmt.Fprintf(out, "  Lifetime:                   %s (workflows: %s, chats: %s)\n",
		formatUSD(totals.LifetimeUSD), formatUSD(totals.WorkflowLifetimeUSD), formatUSD(totals.ChatLifetimeUSD))
	fmt.Fprintf(out, "  Avg cost / job (30d):       %s\n", formatUSD(totals.AverageJob30dUSD))
	fmt.Fprintf(out, "  Avg cost / merged PR (30d): %s\n\n", formatUSD(totals.AverageMergedPr30dUSD))

	switch group {
	case groupTriggerKind:
		renderTriggerKindBreakdown(out, payload.Breakdowns.TriggerKinds)
	case groupUser:
		renderBreakdown(out, "user", payload.Breakdowns.Users)
	case groupEpic:
		renderBreakdown(out, "epic", payload.Breakdowns.Epics)
	default:
		renderBreakdown(out, "repository", payload.Breakdowns.Repositories)
	}
}

func renderBreakdown(out io.Writer, label string, rows []BreakdownRow) {
	fmt.Fprintf(out, "By %s\n", label)
	if len(rows) == 0 {
		fmt.Fprintln(out, "  No spend in this window.")
		return
	}
	tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "  LABEL\tJOBS\tTOTAL\tAVG/JOB")
	for _, row := range rows {
		fmt.Fprintf(tw, "  %s\t%d\t%s\t%s\n", row.Label, row.JobsCount, formatUSD(row.TotalUSD), formatUSD(row.AverageJobUSD))
	}
	tw.Flush()
}

func renderTriggerKindBreakdown(out io.Writer, rows []TriggerKindRow) {
	fmt.Fprintln(out, "By trigger kind")
	if len(rows) == 0 {
		fmt.Fprintln(out, "  No spend in this window.")
		return
	}
	tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "  TRIGGER KIND\tJOBS\tRUNS\tTOTAL\tAVG/RUN")
	for _, row := range rows {
		fmt.Fprintf(tw, "  %s\t%d\t%d\t%s\t%s\n", row.TriggerKind, row.JobsCount, row.RunsCount, formatUSD(row.TotalUSD), formatUSD(row.AverageUSD))
	}
	tw.Flush()
}

func formatUSD(value float64) string {
	return fmt.Sprintf("$%.2f", value)
}
