package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

const pluginTestImage = "ghcr.io/tkadauke/syrus-plugin-test"

var pluginCLIVersion = "development"

type pluginRunner interface {
	Run(context.Context, io.Writer, io.Writer, string, string, string, string, bool) error
}
type containerPluginRunner struct{}

var pluginLookPath = exec.LookPath
var pluginLocalCommand = exec.CommandContext

func (containerPluginRunner) Run(ctx context.Context, stdout, stderr io.Writer, mode, dir, version, checkout string, jsonOutput bool) error {
	var command *exec.Cmd
	if checkout != "" {
		command = pluginLocalCommand(ctx, filepath.Join(checkout, "bin/plugin-test"), mode, dir)
		jsonValue := "0"
		if jsonOutput {
			jsonValue = "1"
		}
		environment := command.Env
		if environment == nil {
			environment = os.Environ()
		}
		command.Env = append(environment, "SYRUS_PLUGIN_TEST_JSON="+jsonValue)
	} else {
		if _, err := pluginLookPath("docker"); err != nil {
			return errors.New("Docker is required to test plugins; install Docker or use --checkout PATH")
		}
		image := pluginTestImage + ":" + version
		pull := pluginLocalCommand(ctx, "docker", "pull", image)
		if jsonOutput {
			pull.Stdout, pull.Stderr = io.Discard, io.Discard
		} else {
			pull.Stdout, pull.Stderr = stdout, stderr
		}
		if err := pull.Run(); err != nil {
			return fmt.Errorf("could not pull plugin test image %s: %w", image, err)
		}
		jsonValue := "0"
		if jsonOutput {
			jsonValue = "1"
		}
		command = pluginLocalCommand(ctx, "docker", "run", "--rm", "-v", dir+":/plugin:ro", "-e", "SYRUS_PLUGIN_TEST_JSON="+jsonValue, image, mode, "/plugin")
	}
	command.Stdout, command.Stderr = stdout, stderr
	if err := command.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return cliplugin.ExitStatusError{Status: exitErr.ExitCode()}
		}
		return err
	}
	return nil
}

var localPluginRunner pluginRunner = containerPluginRunner{}
var pluginVersionHTTPClient = &http.Client{Timeout: 5 * time.Second}

type localPluginOptions struct {
	syrusVersion, checkout string
	json                   bool
}

func NewPluginCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "plugin", Short: "Validate and test external plugins"}
	cmd.AddCommand(newLocalPluginCommand("validate"), newLocalPluginCommand("test"))
	return cmd
}

func newLocalPluginCommand(mode string) *cobra.Command {
	opts := &localPluginOptions{}
	cmd := &cobra.Command{Use: mode + " [DIR]", Short: mode + " a plugin against a real Syrus host", Args: cobra.MaximumNArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		dir := "."
		if len(args) == 1 {
			dir = args[0]
		}
		absolute, err := filepath.Abs(dir)
		if err != nil {
			return err
		}
		info, err := os.Stat(absolute)
		if err != nil || !info.IsDir() {
			return fmt.Errorf("plugin directory not found: %s", dir)
		}
		version := opts.syrusVersion
		if version == "" {
			version = connectedSyrusVersion(cmd.Context())
		}
		if version == "" || version == "development" {
			version = "latest"
		}
		checkout := opts.checkout
		if checkout != "" {
			checkout, err = filepath.Abs(checkout)
			if err != nil {
				return err
			}
		}
		return localPluginRunner.Run(cmd.Context(), cmd.OutOrStdout(), cmd.ErrOrStderr(), mode, absolute, version, checkout, opts.json)
	}}
	cmd.Flags().StringVar(&opts.syrusVersion, "syrus-version", "", "Syrus release to test against")
	cmd.Flags().StringVar(&opts.checkout, "checkout", "", "run from a local Syrus checkout")
	cmd.Flags().BoolVar(&opts.json, "json", false, "print the machine-readable runner summary")
	return cmd
}

func connectedSyrusVersion(ctx context.Context) string {
	creds, err := config.LoadDefaultCredentials()
	if err != nil {
		return pluginCLIVersion
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, strings.TrimRight(creds.URL, "/")+"/", nil)
	if err != nil {
		return pluginCLIVersion
	}
	req.Header.Set("Authorization", "Bearer "+creds.Token)
	response, err := pluginVersionHTTPClient.Do(req)
	if err != nil {
		return pluginCLIVersion
	}
	defer response.Body.Close()
	if response.StatusCode >= 200 && response.StatusCode < 400 && response.Header.Get("X-Syrus-Version") != "" {
		return response.Header.Get("X-Syrus-Version")
	}
	return pluginCLIVersion
}
