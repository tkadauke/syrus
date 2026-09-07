// Package globalsearch is the CLI surface for the bundled global_search
// plugin.
//
// It is a thin, read-only client over the plugin's unified search endpoint
// (plugins/global_search/app/controllers/api/v1/app/search_controller.rb),
// which ranks results across Jobs, Epics, and chats in one call.
package globalsearch

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

func NewSearchCommand() *cobra.Command {
	var typesFlag string
	var limit int
	var jsonOutput bool
	cmd := &cobra.Command{
		Use:           "search <query>",
		Short:         "Search Jobs, Epics, and chats",
		Args:          cobra.ExactArgs(1),
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			query := strings.TrimSpace(args[0])
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			types, err := parseTypes(typesFlag)
			if err != nil {
				return err
			}
			result, err := Search(cmd.Context(), client, query, types, limit)
			if err != nil {
				return err
			}
			if jsonOutput {
				encoder := json.NewEncoder(cmd.OutOrStdout())
				return encoder.Encode(result)
			}
			renderResults(cmd.OutOrStdout(), result.Results)
			return nil
		},
	}
	cmd.Flags().StringVar(&typesFlag, "type", "", "comma-separated result types to search: job,epic,chat (default: all)")
	cmd.Flags().IntVar(&limit, "limit", 0, "maximum number of results (server default: 30, capped at 100)")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "print the raw JSON response")
	return cmd
}

var validSearchTypes = map[string]bool{"job": true, "epic": true, "chat": true}

func parseTypes(flag string) ([]string, error) {
	trimmed := strings.TrimSpace(flag)
	if trimmed == "" {
		return nil, nil
	}
	var types []string
	for _, part := range strings.Split(trimmed, ",") {
		t := strings.ToLower(strings.TrimSpace(part))
		if t == "" {
			continue
		}
		if !validSearchTypes[t] {
			return nil, fmt.Errorf("unknown --type %q; must be one of job, epic, chat", t)
		}
		types = append(types, t)
	}
	if len(types) == 0 {
		return nil, errors.New("--type must not be blank")
	}
	return types, nil
}

// renderResults prints a compact one-line-per-result table, grouped by
// type in the order each type first appears (the server already ranks
// results across types, so that order reflects overall relevance).
func renderResults(out io.Writer, results []Result) {
	if len(results) == 0 {
		fmt.Fprintln(out, "No results.")
		return
	}

	order, grouped := groupByType(results)
	for i, resultType := range order {
		if i > 0 {
			fmt.Fprintln(out)
		}
		items := grouped[resultType]
		fmt.Fprintf(out, "%s (%d)\n", strings.ToUpper(resultType), len(items))
		tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
		fmt.Fprintln(tw, "  ID\tSTATE\tTITLE\tREPO\tMATCH")
		for _, item := range items {
			fmt.Fprintf(tw, "  %s\t%s\t%s\t%s\t%s\n",
				resultIdentifier(item), valueOrDash(item.State), truncate(item.Title, 40), valueOrDash(item.RepositorySlug), truncate(stripMarkTags(item.Snippet), 60))
		}
		tw.Flush()
	}
}

func groupByType(results []Result) ([]string, map[string][]Result) {
	grouped := map[string][]Result{}
	var order []string
	for _, result := range results {
		if _, seen := grouped[result.Type]; !seen {
			order = append(order, result.Type)
		}
		grouped[result.Type] = append(grouped[result.Type], result)
	}
	return order, grouped
}

func resultIdentifier(result Result) string {
	if result.Slug != "" {
		return result.Slug
	}
	return "#" + strconv.FormatInt(result.ID, 10)
}

func stripMarkTags(value string) string {
	replacer := strings.NewReplacer("<mark>", "", "</mark>", "")
	return replacer.Replace(value)
}

func valueOrDash(value string) string {
	if strings.TrimSpace(value) == "" {
		return "-"
	}
	return value
}

func truncate(value string, width int) string {
	value = strings.TrimSpace(value)
	runes := []rune(value)
	if len(runes) <= width {
		return valueOrDash(value)
	}
	if width <= 1 {
		return string(runes[:width])
	}
	return string(runes[:width-1]) + "…"
}
