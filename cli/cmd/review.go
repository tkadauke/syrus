package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/api"
)

func NewReviewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "review",
		Short: "Review job diffs from scripts",
	}
	cmd.AddCommand(
		newReviewListCommand(),
		newReviewAddCommand(),
		newReviewSubmitCommand(),
		newReviewResolveCommand(),
		newReviewReplyCommand(),
	)
	return cmd
}

func newReviewListCommand() *cobra.Command {
	var jsonOut bool
	var versionID int64
	var allVersions bool
	var state string
	var path string
	var surface string
	cmd := &cobra.Command{
		Use:   "list JOB-ID",
		Short: "List diff review comments for a job",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			jobID, err := normalizeJobID(args[0])
			if err != nil {
				return err
			}
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			filters := url.Values{}
			if versionID != 0 {
				filters.Set("diff_review_version_id", strconv.FormatInt(versionID, 10))
			}
			if allVersions {
				filters.Set("all_versions", "true")
			}
			if strings.TrimSpace(state) != "" {
				filters.Set("state", strings.TrimSpace(state))
			}
			if strings.TrimSpace(path) != "" {
				filters.Set("path", strings.TrimSpace(path))
			}
			if strings.TrimSpace(surface) != "" {
				filters.Set("surface", strings.TrimSpace(surface))
			}
			comments, err := client.ListDiffReviewComments(cmd.Context(), jobID, filters)
			if err != nil {
				return err
			}
			if jsonOut {
				return json.NewEncoder(cmd.OutOrStdout()).Encode(comments)
			}
			renderReviewComments(cmd.OutOrStdout(), comments.Comments)
			return nil
		},
	}
	cmd.Flags().BoolVar(&jsonOut, "json", false, "Print comments as JSON")
	cmd.Flags().Int64Var(&versionID, "version", 0, "diff review version ID")
	cmd.Flags().BoolVar(&allVersions, "all-versions", false, "include comments from all diff review versions")
	cmd.Flags().StringVar(&state, "state", "", "filter by comment state")
	cmd.Flags().StringVar(&path, "path", "", "filter by file path")
	cmd.Flags().StringVar(&surface, "surface", "", "filter by review surface")
	return cmd
}

func newReviewAddCommand() *cobra.Command {
	var opts reviewAddOptions
	cmd := &cobra.Command{
		Use:   "add JOB-ID",
		Short: "Add a diff review comment",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runReviewAdd(cmd, args[0], opts)
		},
	}
	cmd.Flags().StringVar(&opts.path, "path", "", "file path for the comment")
	cmd.Flags().Int64Var(&opts.line, "line", 0, "line number for the selected side")
	cmd.Flags().Int64Var(&opts.oldLine, "old-line", 0, "old-file line number for left-side comments")
	cmd.Flags().Int64Var(&opts.newLine, "new-line", 0, "new-file line number for right-side comments")
	cmd.Flags().StringVar(&opts.side, "side", "right", "diff side: right or left")
	cmd.Flags().StringVar(&opts.body, "body", "", "comment body")
	cmd.Flags().StringVar(&opts.surface, "surface", "job_source_diff", "review surface")
	cmd.Flags().StringVar(&opts.state, "state", "draft", "initial comment state")
	cmd.Flags().Int64Var(&opts.versionID, "version", 0, "diff review version ID")
	cmd.Flags().StringVar(&opts.diffHunk, "diff-hunk", "", "diff hunk snapshot")
	cmd.Flags().Int64Var(&opts.workflowID, "workflow-id", 0, "workflow ID for artifact comments")
	cmd.Flags().Int64Var(&opts.runID, "run-id", 0, "run ID for artifact comments")
	return cmd
}

type reviewAddOptions struct {
	path       string
	line       int64
	oldLine    int64
	newLine    int64
	side       string
	body       string
	surface    string
	state      string
	versionID  int64
	diffHunk   string
	workflowID int64
	runID      int64
}

func runReviewAdd(cmd *cobra.Command, rawJobID string, opts reviewAddOptions) error {
	jobID, err := normalizeJobID(rawJobID)
	if err != nil {
		return err
	}
	input, err := reviewCommentInput(opts)
	if err != nil {
		return err
	}
	client, _, err := apiClient()
	if err != nil {
		return err
	}
	comments, err := client.CreateDiffReviewComment(cmd.Context(), jobID, input)
	if err != nil {
		return err
	}
	if len(comments.Comments) == 0 {
		fmt.Fprintf(cmd.OutOrStdout(), "Added review comment to %s.\n", displayJobRef(jobID))
		return nil
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Added review comment %d to %s.\n", comments.Comments[0].ID, displayJobRef(jobID))
	return nil
}

func newReviewSubmitCommand() *cobra.Command {
	var commentIDs []int64
	var versionID int64
	cmd := &cobra.Command{
		Use:   "submit JOB-ID",
		Short: "Submit pending diff review comments as job feedback",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			jobID, err := normalizeJobID(args[0])
			if err != nil {
				return err
			}
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			result, err := client.SubmitDiffReviewComments(cmd.Context(), jobID, commentIDs, versionID)
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Submitted %d review comment(s) for %s.\n", len(result.Comments), displayJobRef(jobID))
			return nil
		},
	}
	cmd.Flags().Int64SliceVar(&commentIDs, "comment-id", nil, "comment ID to submit; repeatable")
	cmd.Flags().Int64Var(&versionID, "version", 0, "diff review version ID")
	return cmd
}

func newReviewResolveCommand() *cobra.Command {
	var versionID int64
	cmd := &cobra.Command{
		Use:   "resolve JOB-ID COMMENT-ID",
		Short: "Resolve a diff review comment thread",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			jobID, err := normalizeJobID(args[0])
			if err != nil {
				return err
			}
			commentID, err := parseReviewCommentID(args[1])
			if err != nil {
				return err
			}
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			if _, err := client.ResolveDiffReviewComment(cmd.Context(), jobID, commentID, versionID); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Resolved review comment %d on %s.\n", commentID, displayJobRef(jobID))
			return nil
		},
	}
	cmd.Flags().Int64Var(&versionID, "version", 0, "diff review version ID")
	return cmd
}

func newReviewReplyCommand() *cobra.Command {
	var body string
	var versionID int64
	cmd := &cobra.Command{
		Use:   "reply JOB-ID COMMENT-ID",
		Short: "Reply to a diff review comment thread",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			jobID, err := normalizeJobID(args[0])
			if err != nil {
				return err
			}
			commentID, err := parseReviewCommentID(args[1])
			if err != nil {
				return err
			}
			if strings.TrimSpace(body) == "" {
				return errors.New("--body is required")
			}
			client, _, err := apiClient()
			if err != nil {
				return err
			}
			comments, err := client.ReplyToDiffReviewComment(cmd.Context(), jobID, commentID, strings.TrimSpace(body), versionID)
			if err != nil {
				return err
			}
			if len(comments.Comments) == 0 {
				fmt.Fprintf(cmd.OutOrStdout(), "Replied to review comment %d on %s.\n", commentID, displayJobRef(jobID))
				return nil
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Replied to review comment %d on %s with comment %d.\n", commentID, displayJobRef(jobID), comments.Comments[0].ID)
			return nil
		},
	}
	cmd.Flags().StringVar(&body, "body", "", "reply body")
	cmd.Flags().Int64Var(&versionID, "version", 0, "diff review version ID")
	return cmd
}

func reviewCommentInput(opts reviewAddOptions) (api.DiffReviewCommentInput, error) {
	if strings.TrimSpace(opts.path) == "" {
		return api.DiffReviewCommentInput{}, errors.New("--path is required")
	}
	if strings.TrimSpace(opts.body) == "" {
		return api.DiffReviewCommentInput{}, errors.New("--body is required")
	}
	side := strings.TrimSpace(opts.side)
	if side != "left" && side != "right" {
		return api.DiffReviewCommentInput{}, fmt.Errorf("invalid --side %q: must be left or right", opts.side)
	}
	oldLine := opts.oldLine
	newLine := opts.newLine
	if opts.line != 0 {
		if side == "left" {
			oldLine = opts.line
		} else {
			newLine = opts.line
		}
	}
	if side == "left" && oldLine == 0 {
		return api.DiffReviewCommentInput{}, errors.New("--old-line or --line is required for left-side comments")
	}
	if side == "right" && newLine == 0 {
		return api.DiffReviewCommentInput{}, errors.New("--new-line or --line is required for right-side comments")
	}
	return api.DiffReviewCommentInput{
		Surface:             strings.TrimSpace(opts.surface),
		DiffReviewVersionID: opts.versionID,
		AnchorKind:          "line",
		Path:                strings.TrimSpace(opts.path),
		Side:                side,
		OldLine:             oldLine,
		NewLine:             newLine,
		DiffHunk:            opts.diffHunk,
		Body:                strings.TrimSpace(opts.body),
		State:               strings.TrimSpace(opts.state),
		WorkflowID:          opts.workflowID,
		RunID:               opts.runID,
	}, nil
}

func parseReviewCommentID(raw string) (int64, error) {
	commentID, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || commentID <= 0 {
		return 0, fmt.Errorf("invalid comment ID %q", raw)
	}
	return commentID, nil
}

func renderReviewComments(out io.Writer, comments []api.DiffReviewComment) {
	if len(comments) == 0 {
		fmt.Fprintln(out, "No review comments.")
		return
	}
	writer := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(writer, "ID\tSTATE\tANCHOR\tBODY")
	for _, comment := range comments {
		fmt.Fprintf(writer, "%d\t%s\t%s\t%s\n", comment.ID, comment.State, reviewAnchor(comment), firstReviewLine(comment.Body))
	}
	writer.Flush()
}

func reviewAnchor(comment api.DiffReviewComment) string {
	if comment.AnchorKind == "review" || comment.Path == "" {
		return "review"
	}
	line := comment.NewLine
	if comment.Side == "left" {
		line = comment.OldLine
	}
	if line == nil {
		return comment.Path
	}
	return fmt.Sprintf("%s:%d", comment.Path, *line)
}

func firstReviewLine(body string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(body), "\n")
	return line
}
