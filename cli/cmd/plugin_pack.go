package cmd

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

type packageFile struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}
type packageManifest struct {
	FormatVersion   int               `json:"format_version"`
	Name            string            `json:"name"`
	Version         string            `json:"version"`
	RequiresSyrus   string            `json:"requires_syrus"`
	Roles           []string          `json:"roles"`
	ExtensionPoints []string          `json:"extension_points"`
	Routes          []string          `json:"routes"`
	CredentialTypes []string          `json:"credential_types"`
	CLICommands     []string          `json:"cli_commands"`
	Frontend        map[string]string `json:"frontend"`
	Locales         []string          `json:"locales"`
	PublicHostAPIs  []string          `json:"public_host_apis"`
	Files           []packageFile     `json:"files"`
}

var packageField = func(field string) *regexp.Regexp {
	return regexp.MustCompile(`(?m)spec\.` + field + `\s*=\s*["']([^"']+)["']`)
}

func newPluginPackCommand() *cobra.Command {
	var output, version, checkout string
	command := &cobra.Command{Use: "pack [DIR]", Short: "Validate and build a deterministic plugin package", Args: cobra.MaximumNArgs(1), RunE: func(command *cobra.Command, args []string) error {
		directory := "."
		if len(args) == 1 {
			directory = args[0]
		}
		absolute, err := filepath.Abs(directory)
		if err != nil {
			return err
		}
		if err := runPluginValidation(command, absolute, version, checkout); err != nil {
			return fmt.Errorf("refusing to pack because validation failed: %w", err)
		}
		if _, err := os.Stat(filepath.Join(absolute, "frontend", "entry.tsx")); err == nil {
			if _, err := os.Stat(filepath.Join(absolute, "dist", "frontend", "plugin.js")); os.IsNotExist(err) {
				if err := runFrontendBuild(command, absolute, version, checkout); err != nil {
					return err
				}
			}
		}
		manifest, files, err := inspectPluginPackage(absolute)
		if err != nil {
			return err
		}
		if output == "" {
			output = filepath.Join(filepath.Dir(absolute), manifest.Name+"-"+manifest.Version+".syrus-plugin.tar.gz")
		}
		if err := writePluginPackage(output, manifest, files); err != nil {
			return err
		}
		fmt.Fprintln(command.OutOrStdout(), output)
		return nil
	}}
	command.Flags().StringVarP(&output, "output", "o", "", "package output path")
	command.Flags().StringVar(&version, "syrus-version", "", "Syrus release to validate against")
	command.Flags().StringVar(&checkout, "checkout", "", "run validation and frontend build from a local Syrus checkout")
	return command
}

func runPluginValidation(command *cobra.Command, directory, version, checkout string) error {
	runner := pluginRunner(checkoutPluginRunner{})
	request := pluginRunRequest{Mode: "validate", Directory: directory, Checkout: checkout}
	if checkout == "" {
		runner = newDockerPluginRunner()
		if err := runner.Available(); err != nil {
			return err
		}
		request.Image = pluginTestImage + ":" + selectedPluginVersion(command.Context(), version)
		if err := runner.Pull(command.Context(), request.Image, command.OutOrStdout(), command.ErrOrStderr()); err != nil {
			return err
		}
	}
	return runner.Run(command.Context(), request, command.InOrStdin(), command.OutOrStdout(), command.ErrOrStderr())
}

func runFrontendBuild(command *cobra.Command, directory, version, checkout string) error {
	runner := pluginRunner(checkoutPluginRunner{})
	request := pluginRunRequest{Mode: "build", Directory: directory, Checkout: checkout}
	if checkout == "" {
		runner = newDockerPluginRunner()
		request.Image = pluginTestImage + ":" + selectedPluginVersion(command.Context(), version)
	}
	return runner.Run(command.Context(), request, command.InOrStdin(), command.OutOrStdout(), command.ErrOrStderr())
}

func inspectPluginPackage(root string) (packageManifest, map[string][]byte, error) {
	files := map[string][]byte{}
	var gemspec []byte
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		if rel == "." {
			return nil
		}
		if d.IsDir() {
			if d.Name() == ".git" || d.Name() == "node_modules" || d.Name() == "tmp" {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("plugin contains symlink: %s", rel)
		}
		data, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		key := "plugin/" + filepath.ToSlash(rel)
		files[key] = data
		if strings.HasSuffix(rel, ".gemspec") {
			gemspec = data
		}
		return nil
	})
	if err != nil {
		return packageManifest{}, nil, err
	}
	if gemspec == nil {
		return packageManifest{}, nil, fmt.Errorf("plugin must contain one gemspec")
	}
	get := func(field string) string {
		m := packageField(field).FindSubmatch(gemspec)
		if len(m) > 1 {
			return string(m[1])
		}
		return ""
	}
	req := regexp.MustCompile(`requires_syrus["']\]\s*=\s*["']([^"']+)`).FindSubmatch(gemspec)
	requires := ""
	if len(req) > 1 {
		requires = string(req[1])
	}
	m := packageManifest{FormatVersion: 1, Name: get("name"), Version: get("version"), RequiresSyrus: requires, Roles: []string{}, ExtensionPoints: []string{}, Routes: []string{}, CredentialTypes: []string{}, CLICommands: []string{}, Frontend: map[string]string{}, Locales: []string{}, PublicHostAPIs: []string{}}
	for path, data := range files {
		sum := sha256.Sum256(data)
		m.Files = append(m.Files, packageFile{path, hex.EncodeToString(sum[:])})
		if strings.HasSuffix(path, ".rb") {
			for _, hit := range regexp.MustCompile(`provides\s+([a-z_]+):`).FindAllSubmatch(data, -1) {
				m.ExtensionPoints = append(m.ExtensionPoints, string(hit[1]))
			}
			for _, hit := range regexp.MustCompile(`route\s+:[a-z]+,\s*["']([^"']+)`).FindAllSubmatch(data, -1) {
				m.Routes = append(m.Routes, string(hit[1]))
			}
			for _, hit := range regexp.MustCompile(`credential_type_names?\s+["']([^"']+)`).FindAllSubmatch(data, -1) {
				m.CredentialTypes = append(m.CredentialTypes, string(hit[1]))
			}
			for _, hit := range regexp.MustCompile(`path:\s*%w\[([^\]]+)\]`).FindAllSubmatch(data, -1) {
				m.CLICommands = append(m.CLICommands, strings.Join(strings.Fields(string(hit[1])), " "))
			}
			for _, hit := range regexp.MustCompile(`Syrus::Host(?:::[A-Z][A-Za-z0-9_]*)+`).FindAll(data, -1) {
				m.PublicHostAPIs = append(m.PublicHostAPIs, string(hit))
			}
		}
		if strings.Contains(path, "/dist/frontend/plugin.js") {
			m.Frontend["entry"] = path
		}
		if strings.Contains(path, "/dist/frontend/plugin.css") {
			m.Frontend["css"] = path
		}
		if strings.Contains(path, "/i18n/locales/") && strings.HasSuffix(path, ".json") {
			m.Locales = append(m.Locales, path)
		}
	}
	sort.Slice(m.Files, func(i, j int) bool { return m.Files[i].Path < m.Files[j].Path })
	sort.Strings(m.Locales)
	sort.Strings(m.ExtensionPoints)
	m.ExtensionPoints = unique(m.ExtensionPoints)
	sort.Strings(m.Routes)
	m.Routes = unique(m.Routes)
	sort.Strings(m.CredentialTypes)
	m.CredentialTypes = unique(m.CredentialTypes)
	sort.Strings(m.CLICommands)
	m.CLICommands = unique(m.CLICommands)
	sort.Strings(m.PublicHostAPIs)
	m.PublicHostAPIs = unique(m.PublicHostAPIs)
	return m, files, nil
}
func unique(v []string) []string {
	if len(v) == 0 {
		return v
	}
	out := v[:1]
	for _, x := range v[1:] {
		if x != out[len(out)-1] {
			out = append(out, x)
		}
	}
	return out
}

func writePluginPackage(output string, manifest packageManifest, files map[string][]byte) error {
	manifestBytes, _ := json.MarshalIndent(manifest, "", "  ")
	manifestBytes = append(manifestBytes, '\n')
	all := map[string][]byte{"package.json": manifestBytes}
	for k, v := range files {
		all[k] = v
	}
	names := make([]string, 0, len(all))
	for k := range all {
		names = append(names, k)
	}
	sort.Strings(names)
	var checks strings.Builder
	for _, n := range names {
		s := sha256.Sum256(all[n])
		fmt.Fprintf(&checks, "%x  %s\n", s, n)
	}
	all["CHECKSUMS.sha256"] = []byte(checks.String())
	names = append(names, "CHECKSUMS.sha256")
	sort.Strings(names)
	f, err := os.Create(output)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, _ := gzip.NewWriterLevel(f, gzip.BestCompression)
	gz.Header.ModTime = time.Unix(0, 0)
	gz.Header.OS = 255
	tw := tar.NewWriter(gz)
	for _, n := range names {
		data := all[n]
		h := &tar.Header{Name: n, Mode: 0644, Size: int64(len(data)), ModTime: time.Unix(0, 0), Typeflag: tar.TypeReg, Format: tar.FormatUSTAR}
		if err := tw.WriteHeader(h); err != nil {
			return err
		}
		if _, err := io.Copy(tw, strings.NewReader(string(data))); err != nil {
			return err
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	return gz.Close()
}
