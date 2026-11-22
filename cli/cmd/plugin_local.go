package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
	"github.com/tkadauke/syrus/cli/pkg/cliplugin"
)

const pluginTestImage = "ghcr.io/tkadauke/syrus-plugin-test"

var cliReleaseVersion = "latest"
var newDockerPluginRunner = func() pluginRunner { return dockerPluginRunner{} }
var resolveConnectedInstanceVersion = connectedInstanceVersion

type pluginRunner interface {
	Available() error
	Pull(context.Context, string, io.Writer, io.Writer) error
	Run(context.Context, pluginRunRequest, io.Reader, io.Writer, io.Writer) error
}

type pluginRunRequest struct {
	Mode, Directory, Image, Checkout string
	JSON                             bool
}

type dockerPluginRunner struct{}

func (dockerPluginRunner) Available() error {
	if _, err := exec.LookPath("docker"); err != nil {
		return errors.New("Docker is required for plugin validation; install Docker or use --checkout PATH")
	}
	return nil
}

func (dockerPluginRunner) Pull(ctx context.Context, image string, stdout, stderr io.Writer) error {
	command := exec.CommandContext(ctx, "docker", "pull", image)
	command.Stdout, command.Stderr = stdout, stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("could not pull plugin test image %s: %w", image, err)
	}
	return nil
}

func (dockerPluginRunner) Run(ctx context.Context, request pluginRunRequest, stdin io.Reader, stdout, stderr io.Writer) error {
	if request.Mode == "package-validate" {
		args := []string{"run", "--rm", "--entrypoint", "/rails/bin/plugin-package-validate", "-v", request.Directory + ":/plugins/package.tar.gz:ro", request.Image, "--json", "/plugins/package.tar.gz"}
		command := exec.CommandContext(ctx, "docker", args...)
		command.Stdin, command.Stdout, command.Stderr = stdin, stdout, stderr
		return exitStatus(command.Run())
	}
	args := []string{"run", "--rm", "-e", "SYRUS_PLUGIN_TEST_MODE=" + request.Mode}
	if request.JSON {
		args = append(args, "-e", "SYRUS_PLUGIN_TEST_JSON=1")
	}
	mountMode := "ro"
	if request.Mode == "build" {
		mountMode = "rw"
	}
	args = append(args, "-v", request.Directory+":/plugins/plugin:"+mountMode, request.Image, "/plugins/plugin")
	command := exec.CommandContext(ctx, "docker", args...)
	command.Stdin, command.Stdout, command.Stderr = stdin, stdout, stderr
	return exitStatus(command.Run())
}

type checkoutPluginRunner struct{}

func (checkoutPluginRunner) Available() error                                         { return nil }
func (checkoutPluginRunner) Pull(context.Context, string, io.Writer, io.Writer) error { return nil }
func (checkoutPluginRunner) Run(ctx context.Context, request pluginRunRequest, stdin io.Reader, stdout, stderr io.Writer) error {
	if request.Mode == "package-validate" {
		entrypoint := filepath.Join(request.Checkout, "bin", "plugin-package-validate")
		command := exec.CommandContext(ctx, entrypoint, "--json", request.Directory)
		command.Stdin, command.Stdout, command.Stderr = stdin, stdout, stderr
		return exitStatus(command.Run())
	}
	entrypoint := filepath.Join(request.Checkout, "bin", "plugin-test")
	command := exec.CommandContext(ctx, entrypoint, request.Directory)
	command.Stdin, command.Stdout, command.Stderr = stdin, stdout, stderr
	command.Env = append(os.Environ(), "SYRUS_PLUGIN_TEST_MODE="+request.Mode)
	if request.JSON {
		command.Env = append(command.Env, "SYRUS_PLUGIN_TEST_JSON=1")
	}
	return exitStatus(command.Run())
}

func exitStatus(err error) error {
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return cliplugin.ExitStatusError{Status: exitError.ExitCode()}
	}
	return err
}

func NewPluginCommand() *cobra.Command {
	command := &cobra.Command{Use: "plugin", Short: "Develop and inspect Syrus plugins"}
	command.AddCommand(newPluginNewCommand(), newPluginCapabilitiesCommand(), newPluginRegistryCommand(), newPluginSearchCommand(), newPluginInstallCommand(), newPluginListCommand(), newPluginRemoveCommand(), newLocalPluginCommand("validate"), newLocalPluginCommand("test"), newPluginPackCommand(), newPluginKeygenCommand(), newPluginSignCommand(), newPluginVerifyCommand(), newPluginPublishCommand(), newPluginIndexCheckCommand(), newPluginDevCommand())
	return command
}

func selectedPluginVersion(ctx context.Context, requested string) string {
	if requested != "" {
		return strings.TrimPrefix(requested, "v")
	}
	if connected := resolveConnectedInstanceVersion(ctx); connected != "" {
		return strings.TrimPrefix(connected, "v")
	}
	return strings.TrimPrefix(cliReleaseVersion, "v")
}

func newLocalPluginCommand(mode string) *cobra.Command {
	var version, checkout string
	var jsonOutput bool
	command := &cobra.Command{
		Use:   mode + " [DIR]",
		Short: map[string]string{"validate": "Validate a plugin against a Syrus release", "test": "Validate and test a plugin against a Syrus release"}[mode],
		Args:  cobra.MaximumNArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			directory := "."
			if len(args) == 1 {
				directory = args[0]
			}
			absolute, err := filepath.Abs(directory)
			if err != nil {
				return err
			}
			info, err := os.Stat(absolute)
			if err != nil || !info.IsDir() {
				return fmt.Errorf("plugin directory is not readable: %s", absolute)
			}

			request := pluginRunRequest{Mode: mode, Directory: absolute, Checkout: checkout, JSON: jsonOutput}
			var runner pluginRunner = checkoutPluginRunner{}
			if checkout == "" {
				runner = newDockerPluginRunner()
				if err := runner.Available(); err != nil {
					return err
				}
				request.Image = pluginTestImage + ":" + selectedPluginVersion(command.Context(), version)
				pullOut, pullErr := command.OutOrStdout(), command.ErrOrStderr()
				if jsonOutput {
					pullOut, pullErr = io.Discard, io.Discard
				}
				if err := runner.Pull(command.Context(), request.Image, pullOut, pullErr); err != nil {
					return err
				}
			}
			return runner.Run(command.Context(), request, command.InOrStdin(), command.OutOrStdout(), command.ErrOrStderr())
		},
	}
	command.Flags().StringVar(&version, "syrus-version", "", "Syrus release to test against")
	command.Flags().StringVar(&checkout, "checkout", "", "run from a local Syrus checkout instead of Docker")
	command.Flags().BoolVar(&jsonOutput, "json", false, "print only the machine-readable summary")
	return command
}

func connectedInstanceVersion(ctx context.Context) string {
	credentials, err := config.LoadDefaultCredentials()
	if err != nil {
		return ""
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(credentials.URL, "/")+"/api/v1/app/bootstrap", nil)
	if err != nil {
		return ""
	}
	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return ""
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return ""
	}
	var payload struct {
		App struct {
			Version string `json:"version"`
		} `json:"app"`
	}
	if json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&payload) != nil {
		return ""
	}
	return instanceVersionFromReported(payload.App.Version)
}

// instanceVersionFromReported keeps a version the instance reports only when
// it is a plain release version. The value becomes an image tag and is spliced
// into a generated gemspec's Ruby string literal, so anything else (a
// development describe like 1.2.3-4-gabcdef, or a string with quotes or
// spaces) falls back to the CLI's own release version.
func instanceVersionFromReported(reported string) string {
	version := strings.TrimPrefix(strings.TrimSpace(reported), "v")
	if strings.Contains(version, "-") && strings.Contains(version, "-g") {
		return ""
	}
	if !plainVersion(version) {
		return ""
	}
	return version
}

var plainVersionPattern = regexp.MustCompile(`^[0-9]+(\.[0-9A-Za-z]+)*(-[0-9A-Za-z.]+)?(\+[0-9A-Za-z.]+)?$`)

func plainVersion(version string) bool {
	return len(version) <= 64 && plainVersionPattern.MatchString(version)
}
