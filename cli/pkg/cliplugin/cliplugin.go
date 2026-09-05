// Package cliplugin is the contract between the syrus CLI and the command
// sets bundled plugins contribute to it.
//
// A plugin's commands live in its own Go module under plugins/<name>/cli and
// are compiled into the one static binary (Go has no usable dynamic plugin
// loading for that shape). Being a separate module, a plugin cannot reach
// cli/internal/..., so everything a plugin command legitimately needs is
// exported here -- deliberately as a small, named surface rather than by
// promoting the CLI's internals wholesale.
//
// Keep this narrow. Anything added here is API that plugin modules may rely
// on; the CLI's own commands should keep using their unexported helpers,
// which delegate to these so there is a single implementation.
package cliplugin

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strings"

	"github.com/tkadauke/syrus/cli/internal/config"
	"github.com/tkadauke/syrus/cli/pkg/api"
)

// LoginMessage is what the CLI tells a user with no usable credentials.
// Exported so plugin commands fail the same way the built-in ones do.
const LoginMessage = "Run 'syrus login' to set up your Syrus instance URL and API token."

// DetectCurrentRepoSlug reports the owner/name of the checkout the command was
// run from, or "" when it cannot tell. It is a var so tests can stub it; see
// cliplugintest.WithRepoSlug.
var DetectCurrentRepoSlug = currentRepoSlug

func currentRepoSlug() string {
	out, err := exec.CommandContext(context.Background(), "git", "config", "--get", "remote.origin.url").Output()
	if err != nil {
		return ""
	}
	return parseGitHubSlug(strings.TrimSpace(string(out)))
}

func parseGitHubSlug(remote string) string {
	match := gitHubRemote.FindStringSubmatch(remote)
	if len(match) == 3 {
		return match[1] + "/" + match[2]
	}
	return ""
}

var gitHubRemote = regexp.MustCompile(`github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$`)

// Client returns an authenticated client for the configured instance.
func Client() (*api.Client, error) {
	creds, err := config.LoadDefaultCredentials()
	if err != nil {
		if errors.Is(err, config.ErrMissingCredentials) || errors.Is(err, config.ErrIncompleteCredentials) {
			return nil, errors.New(LoginMessage)
		}
		return nil, err
	}
	return api.NewClient(creds.URL, creds.Token)
}

// Prompt writes a label and reads one line of input.
func Prompt(reader *bufio.Reader, out io.Writer, label string) (string, error) {
	fmt.Fprint(out, label)
	line, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		return "", err
	}
	return strings.TrimSpace(line), nil
}

// Confirmed reports whether a prompt answer means yes.
func Confirmed(answer string) bool {
	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y", "yes":
		return true
	default:
		return false
	}
}

// JobSlug renders a Job identifier the way the rest of the CLI does.
func JobSlug(id any) string {
	return fmt.Sprintf("JOB-%v", id)
}

// RepositoryIDForSlug finds a repository by owner/name in a listing.
func RepositoryIDForSlug(repositories []api.RepositoryItem, slug string) (int64, bool) {
	for _, repository := range repositories {
		if repository.Slug == slug {
			return repository.ID, true
		}
	}
	return 0, false
}

// ReadMultiline reads lines until a blank one, the CLI's convention for
// free-form input such as a prompt body.
func ReadMultiline(reader *bufio.Reader) (string, error) {
	var lines []string
	for {
		line, err := reader.ReadString('\n')
		if err != nil && err != io.EOF {
			return "", err
		}
		line = strings.TrimSuffix(line, "\n")
		line = strings.TrimSuffix(line, "\r")
		if line == "" {
			return strings.Join(lines, "\n"), nil
		}
		lines = append(lines, line)
		if err == io.EOF {
			return strings.Join(lines, "\n"), nil
		}
	}
}
