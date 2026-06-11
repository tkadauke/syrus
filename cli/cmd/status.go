package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"strconv"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/api"
	"github.com/tkadauke/syrus/cli/internal/config"
)

const defaultStatusWidth = 80

type statusOptions struct {
	repo   string
	closed bool
}

func NewStatusCommand() *cobra.Command {
	opts := &statusOptions{}
	cmd := &cobra.Command{
		Use:           "status",
		Short:         "Show Syrus jobs",
		Args:          cobra.NoArgs,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runStatus(cmd.Context(), cmd.OutOrStdout(), opts, supportsColor(cmd.OutOrStdout()))
		},
	}
	cmd.Flags().StringVar(&opts.repo, "repo", "", "Filter by repository owner/name")
	cmd.Flags().BoolVar(&opts.closed, "closed", false, "Show closed jobs instead of open jobs")
	return cmd
}

func runStatus(ctx context.Context, out io.Writer, opts *statusOptions, color bool) error {
	creds, err := config.LoadDefaultCredentials()
	if err != nil {
		if errors.Is(err, config.ErrMissingCredentials) || errors.Is(err, config.ErrIncompleteCredentials) {
			return errors.New(configureMessage)
		}
		return err
	}

	client, err := api.NewClient(creds.URL, creds.Token)
	if err != nil {
		return err
	}

	filters := url.Values{}
	if opts.closed {
		filters.Set("state", "closed")
	} else {
		filters.Set("state", "open")
	}
	if strings.TrimSpace(opts.repo) != "" {
		filters.Set("repo", strings.TrimSpace(opts.repo))
	}

	list, err := client.ListJobs(ctx, filters)
	if err != nil {
		return err
	}

	renderStatus(out, list.Jobs, defaultStatusWidth, color)
	return nil
}

func renderStatus(out io.Writer, jobs []api.Job, width int, color bool) {
	if width < 40 {
		width = defaultStatusWidth
	}

	idWidth := 7
	repoWidth := 21
	stateWidth := 12
	prWidth := maxPRWidth(jobs)
	titleWidth := width - idWidth - repoWidth - stateWidth - prWidth - 8
	if titleWidth < 10 {
		titleWidth = 10
	}

	fmt.Fprintf(out, "%-*s  %-*s  %-*s  %-*s  %s\n",
		idWidth, "ID",
		repoWidth, "REPO",
		titleWidth, "TITLE",
		stateWidth, "STATE",
		"PR")

	for _, job := range jobs {
		state := padRight(fit(job.State, stateWidth), stateWidth)
		if color {
			state = colorState(state, job.State)
		}
		fmt.Fprintf(out, "%-*s  %-*s  %-*s  %s  %*s\n",
			idWidth, "JOB-"+strconv.FormatInt(job.ID, 10),
			repoWidth, fit(job.Repository, repoWidth),
			titleWidth, fit(job.IssueTitle, titleWidth),
			state,
			prWidth, prLabel(job.PRNumber))
	}
}

func maxPRWidth(jobs []api.Job) int {
	width := len("PR")
	for _, job := range jobs {
		if labelWidth := len(prLabel(job.PRNumber)); labelWidth > width {
			width = labelWidth
		}
	}
	return width
}

func prLabel(number *int64) string {
	if number == nil {
		return "-"
	}
	return "#" + strconv.FormatInt(*number, 10)
}

func fit(value string, width int) string {
	value = strings.TrimSpace(value)
	runes := []rune(value)
	if len(runes) <= width {
		return value
	}
	if width <= 1 {
		return string(runes[:width])
	}
	return string(runes[:width-1]) + "."
}

func padRight(value string, width int) string {
	padding := width - len([]rune(value))
	if padding <= 0 {
		return value
	}
	return value + strings.Repeat(" ", padding)
}

func colorState(display string, state string) string {
	color := ""
	switch state {
	case "running":
		color = "\033[33m"
	case "implemented", "approved":
		color = "\033[32m"
	case "failed":
		color = "\033[31m"
	case "queued":
		color = "\033[90m"
	default:
		return display
	}
	return color + display + "\033[0m"
}

func supportsColor(out io.Writer) bool {
	if os.Getenv("NO_COLOR") != "" || os.Getenv("TERM") == "dumb" {
		return false
	}
	file, ok := out.(*os.File)
	if !ok {
		return false
	}
	info, err := file.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}
