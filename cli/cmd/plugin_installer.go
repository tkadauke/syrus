package cmd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/internal/config"
)

type pluginInstallerChange struct {
	ID                 int                 `json:"id"`
	Name               string              `json:"name"`
	Action             string              `json:"action"`
	Version            string              `json:"version"`
	Source             string              `json:"source"`
	TrustLabel         string              `json:"trust_label"`
	CapabilityManifest map[string][]string `json:"capability_manifest"`
}

type pluginInstallerPayload struct {
	Installations []struct {
		Name       string `json:"name"`
		Version    string `json:"version"`
		Source     string `json:"source"`
		TrustLabel string `json:"trust_label"`
		Health     string `json:"health"`
	} `json:"installations"`
}

func newPluginInstallCommand() *cobra.Command {
	var yes bool
	command := &cobra.Command{Use: "install <archive|name[@version]>", Short: "Stage and confirm a plugin installation", Args: cobra.ExactArgs(1), RunE: func(command *cobra.Command, args []string) error {
		path, err := filepath.Abs(args[0])
		if err != nil {
			return err
		}
		var change pluginInstallerChange
		if _, statErr := os.Stat(path); statErr == nil {
			change, err = uploadPluginArchive(command, path)
		} else {
			change, err = stageStoredPluginRelease(command, args[0])
		}
		if err != nil {
			return err
		}
		printPluginChange(command.OutOrStdout(), change)
		if !yes {
			fmt.Fprint(command.OutOrStdout(), "Install this plugin? [y/N] ")
			answer := ""
			_, _ = fmt.Fscanln(command.InOrStdin(), &answer)
			if !confirmed(answer) {
				return fmt.Errorf("installation was not confirmed")
			}
		}
		return confirmPluginChange(command, change.ID)
	}}
	command.Flags().BoolVar(&yes, "yes", false, "Confirm without prompting")
	return command
}

func stageStoredPluginRelease(command *cobra.Command, reference string) (pluginInstallerChange, error) {
	creds, err := loadCredentials()
	if err != nil {
		return pluginInstallerChange{}, err
	}
	name, version, _ := strings.Cut(reference, "@")
	body, _ := json.Marshal(map[string]string{"name": name, "version": version})
	var change pluginInstallerChange
	err = pluginInstallerJSON(command, http.MethodPost, creds, "/api/v1/app/admin/plugin_installer/stage_release", bytes.NewReader(body), "application/json", &change)
	return change, err
}

func newPluginListCommand() *cobra.Command {
	return &cobra.Command{Use: "list", Short: "List installed external plugins", Args: cobra.NoArgs, RunE: func(command *cobra.Command, _ []string) error {
		creds, err := loadCredentials()
		if err != nil {
			return err
		}
		var payload pluginInstallerPayload
		if err := pluginInstallerJSON(command, http.MethodGet, creds, "/api/v1/app/admin/plugin_installer", nil, "", &payload); err != nil {
			return err
		}
		fmt.Fprintln(command.OutOrStdout(), "NAME\tVERSION\tTRUST\tSOURCE\tHEALTH")
		for _, item := range payload.Installations {
			fmt.Fprintf(command.OutOrStdout(), "%s\t%s\t%s\t%s\t%s\n", item.Name, item.Version, item.TrustLabel, item.Source, item.Health)
		}
		return nil
	}}
}

func newPluginRemoveCommand() *cobra.Command {
	var yes bool
	command := &cobra.Command{Use: "remove <name>", Short: "Stage and confirm a plugin removal", Args: cobra.ExactArgs(1), RunE: func(command *cobra.Command, args []string) error {
		creds, err := loadCredentials()
		if err != nil {
			return err
		}
		body, _ := json.Marshal(map[string]string{"name": args[0]})
		var change pluginInstallerChange
		if err := pluginInstallerJSON(command, http.MethodPost, creds, "/api/v1/app/admin/plugin_installer/stage_remove", bytes.NewReader(body), "application/json", &change); err != nil {
			return err
		}
		printPluginChange(command.OutOrStdout(), change)
		if !yes {
			fmt.Fprint(command.OutOrStdout(), "Remove this plugin? [y/N] ")
			answer := ""
			_, _ = fmt.Fscanln(command.InOrStdin(), &answer)
			if !confirmed(answer) {
				return fmt.Errorf("removal was not confirmed")
			}
		}
		return confirmPluginChange(command, change.ID)
	}}
	command.Flags().BoolVar(&yes, "yes", false, "Confirm without prompting")
	return command
}

func uploadPluginArchive(command *cobra.Command, path string) (pluginInstallerChange, error) {
	creds, err := loadCredentials()
	if err != nil {
		return pluginInstallerChange{}, err
	}
	file, err := os.Open(path)
	if err != nil {
		return pluginInstallerChange{}, err
	}
	defer file.Close()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("archive", filepath.Base(path))
	if err != nil {
		return pluginInstallerChange{}, err
	}
	if _, err := io.Copy(part, file); err != nil {
		return pluginInstallerChange{}, err
	}
	_ = writer.Close()
	var change pluginInstallerChange
	err = pluginInstallerJSON(command, http.MethodPost, creds, "/api/v1/app/admin/plugin_installer/stage", &body, writer.FormDataContentType(), &change)
	return change, err
}

func confirmPluginChange(command *cobra.Command, id int) error {
	creds, err := loadCredentials()
	if err != nil {
		return err
	}
	var result map[string]any
	if err := pluginInstallerJSON(command, http.MethodPost, creds, fmt.Sprintf("/api/v1/app/admin/plugin_installer/changes/%d/confirm", id), strings.NewReader("{}"), "application/json", &result); err != nil {
		return err
	}
	fmt.Fprintln(command.OutOrStdout(), "Desired plugin state updated. Apply changes to restart the fleet.")
	return nil
}

func printPluginChange(out io.Writer, change pluginInstallerChange) {
	action := change.Action
	if action != "" {
		action = strings.ToUpper(action[:1]) + action[1:]
	}
	fmt.Fprintf(out, "%s %s %s (%s, %s)\n", action, change.Name, change.Version, change.Source, change.TrustLabel)
	fmt.Fprintln(out, "Capability manifest (disclosure, not enforcement):")
	for key, values := range change.CapabilityManifest {
		fmt.Fprintf(out, "  %s: %s\n", key, strings.Join(values, ", "))
	}
}

func pluginInstallerJSON(command *cobra.Command, method string, creds config.Credentials, path string, body io.Reader, contentType string, target any) error {
	request, err := http.NewRequestWithContext(command.Context(), method, strings.TrimRight(creds.URL, "/")+path, body)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+creds.Token)
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		message, _ := io.ReadAll(response.Body)
		return fmt.Errorf("plugin installer failed (%s): %s", response.Status, strings.TrimSpace(string(message)))
	}
	return json.NewDecoder(response.Body).Decode(target)
}
