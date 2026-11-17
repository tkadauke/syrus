// Package designdocs is the CLI surface for the bundled design_docs plugin.
//
// It is a thin, read-only client over the plugin's existing app API
// (plugins/design_docs/app/controllers/api/v1/app/design_docs_controller.rb):
// list docs (optionally scoped to a repository) and show one doc's rendered
// body. The plugin's propose/comment/suggest tools are chat/proposal-flow
// features, not a good fit for a one-shot CLI command, so this module
// deliberately does not expose write commands.
package designdocs

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/api"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

func NewDocsCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "docs", Short: "Inspect Design Docs"}
	cmd.AddCommand(newDocsListCommand(), newDocsShowCommand())
	return cmd
}

func newDocsListCommand() *cobra.Command {
	var repoFlag string
	cmd := &cobra.Command{
		Use:   "list",
		Short: "List design docs",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			list, err := designDocsForRepo(cmd, client, repoFlag)
			if err != nil {
				return err
			}
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "DOC\tTITLE\tSTATE\tVISIBILITY\tOWNER\tREPOS\tUPDATED")
			for _, doc := range list.DesignDocs {
				fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", doc.DisplayID, doc.Title, doc.State, doc.Visibility, ownerName(doc.Owner), repoSlugs(doc.Repositories), doc.UpdatedAt)
			}
			return tw.Flush()
		},
	}
	cmd.Flags().StringVar(&repoFlag, "repo", "", "restrict to one repository (owner/name); auto-detected from the current checkout otherwise")
	return cmd
}

func newDocsShowCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "show DOC-ID",
		Short: "Show a design doc",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseDesignDocRef(args[0])
			if err != nil {
				return err
			}
			client, err := cliplugin.Client()
			if err != nil {
				return err
			}
			payload, err := GetDesignDoc(cmd.Context(), client, id)
			if err != nil {
				return err
			}
			return page(cmd, renderDesignDoc(payload.DesignDoc))
		},
	}
}

// designDocsForRepo scopes the list to a repository when possible: an
// explicit --repo that Syrus doesn't recognize is an error, but a
// checkout-detected slug that doesn't resolve quietly falls back to the
// unscoped list rather than failing a command the caller didn't pin.
func designDocsForRepo(cmd *cobra.Command, client *api.Client, repoFlag string) (DesignDocList, error) {
	explicit := strings.TrimSpace(repoFlag) != ""
	repo := strings.TrimSpace(repoFlag)
	if repo == "" {
		repo = cliplugin.DetectCurrentRepoSlug()
	}
	if repo == "" {
		return ListDesignDocs(cmd.Context(), client)
	}

	repositories, err := client.ListRepositories(cmd.Context())
	if err != nil {
		return DesignDocList{}, err
	}
	repositoryID, ok := cliplugin.RepositoryIDForSlug(repositories.AvailableRepositories(), repo)
	if !ok {
		if explicit {
			return DesignDocList{}, fmt.Errorf("repository %s is not configured in Syrus", repo)
		}
		return ListDesignDocs(cmd.Context(), client)
	}
	return ListRepositoryDesignDocs(cmd.Context(), client, repositoryID)
}

// parseDesignDocRef follows the same JOB-<id>/EPIC-<id> convention used
// elsewhere in the CLI: an optional case-insensitive "DOC-" prefix, and the
// bare id otherwise.
func parseDesignDocRef(input string) (string, error) {
	ref := strings.TrimSpace(input)
	if ref == "" {
		return "", errors.New("design doc id is required")
	}
	if strings.HasPrefix(strings.ToUpper(ref), "DOC-") {
		id := strings.TrimSpace(ref[4:])
		if id == "" {
			return "", fmt.Errorf("invalid design doc id %q", input)
		}
		return id, nil
	}
	return ref, nil
}

func renderDesignDoc(doc DesignDocDetail) string {
	var body strings.Builder
	fmt.Fprintf(&body, "%s · %s\n", doc.DisplayID, doc.Title)
	fmt.Fprintf(&body, "State: %s\nVisibility: %s\nOwner: %s\n", doc.State, doc.Visibility, ownerName(doc.Owner))
	if repos := repoSlugs(doc.Repositories); repos != "-" {
		fmt.Fprintf(&body, "Repositories: %s\n", repos)
	}
	fmt.Fprintf(&body, "Updated: %s\n\n", doc.UpdatedAt)
	body.WriteString(doc.RenderedMarkdown)
	return body.String()
}

func ownerName(owner *DesignDocOwner) string {
	if owner == nil || strings.TrimSpace(owner.Name) == "" {
		return "-"
	}
	return owner.Name
}

func repoSlugs(repositories []DesignDocRepository) string {
	if len(repositories) == 0 {
		return "-"
	}
	slugs := make([]string, 0, len(repositories))
	for _, repository := range repositories {
		slugs = append(slugs, repository.Slug)
	}
	return strings.Join(slugs, ",")
}

// page mirrors cli/cmd/inspect.go's job-log pager: stream to $PAGER when
// set, otherwise print directly. Kept local rather than promoted to
// cliplugin since only this command needs it so far.
func page(cmd *cobra.Command, text string) error {
	pager := strings.TrimSpace(os.Getenv("PAGER"))
	if pager == "" {
		fmt.Fprint(cmd.OutOrStdout(), text)
		if !strings.HasSuffix(text, "\n") {
			fmt.Fprintln(cmd.OutOrStdout())
		}
		return nil
	}
	parts := strings.Fields(pager)
	process := exec.Command(parts[0], parts[1:]...)
	process.Stdin = strings.NewReader(text)
	process.Stdout = cmd.OutOrStdout()
	process.Stderr = cmd.ErrOrStderr()
	return process.Run()
}
