package cmd

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/plugintrust"
)

var pluginIndexCheckHTTP = http.DefaultClient
var pluginIndexCheckURLValidator = validateIndexResourceURL

func newPluginIndexCheckCommand() *cobra.Command {
	var trustPath, checkout string
	command := &cobra.Command{Use: "index-check ENTRY", Short: "Validate a plugin registry submission", Args: cobra.ExactArgs(1), RunE: func(command *cobra.Command, args []string) error {
		result := map[string]any{"version": 1, "entry": args[0], "status": "failed"}
		fail := func(err error) error {
			result["error"] = err.Error()
			bytes, _ := json.Marshal(result)
			fmt.Fprintln(command.OutOrStdout(), string(bytes))
			return err
		}
		entryBytes, err := os.ReadFile(args[0])
		if err != nil {
			return fail(err)
		}
		var entry pluginRegistryRelease
		if err = json.Unmarshal(entryBytes, &entry); err != nil {
			return fail(fmt.Errorf("invalid index format: %w", err))
		}
		entryPath := filepath.ToSlash(filepath.Join(filepath.Base(filepath.Dir(args[0])), filepath.Base(args[0])))
		if err = validateRegistryRelease(entryPath, entry); err != nil {
			return fail(err)
		}
		publisher := strings.Split(entry.Name, "_")[0]
		if publisher == "" {
			return fail(errors.New("plugin name prefix does not identify a publisher"))
		}
		declaredPublisher := regexp.MustCompile(`[^a-z0-9]+`).ReplaceAllString(strings.ToLower(entry.Author), "")
		if declaredPublisher == "" || publisher != declaredPublisher {
			return fail(errors.New("plugin name prefix does not match the publisher"))
		}
		minimum := minimumSyrusVersion(entry.RequiresSyrus)
		if minimum == "" {
			return fail(errors.New("requires_syrus must declare a plausible minimum version"))
		}
		compatible, requirementErr := versionRequirementSatisfied(entry.RequiresSyrus, minimum)
		if requirementErr != nil || !compatible {
			return fail(errors.New("requires_syrus must declare a plausible minimum version"))
		}
		if trustPath == "" {
			trustPath = filepath.Join(filepath.Dir(args[0]), "..", "trust-store.json")
		}
		trustBytes, err := os.ReadFile(trustPath)
		if err != nil {
			return fail(err)
		}
		var trust plugintrust.TrustStore
		if err = json.Unmarshal(trustBytes, &trust); err != nil {
			return fail(fmt.Errorf("invalid trust store: %w", err))
		}
		publisherKeyMatches := false
		for _, trustedPublisher := range trust.Publishers {
			if strings.EqualFold(trustedPublisher.Fingerprint, entry.PublisherKeyFingerprint) && trustedPublisher.Prefix == publisher {
				publisherKeyMatches = true
				break
			}
		}
		if !publisherKeyMatches {
			return fail(errors.New("publisher key is not listed for the plugin name prefix"))
		}
		packageBytes, err := downloadIndexResource(command, entry.PackageURL)
		if err != nil {
			return fail(err)
		}
		sum := sha256.Sum256(packageBytes)
		if entry.PackageDigest != "sha256:"+hex.EncodeToString(sum[:]) {
			return fail(errors.New("package digest mismatch"))
		}
		signatureBytes, err := downloadIndexResource(command, entry.SignatureURL)
		if err != nil {
			return fail(err)
		}
		var signature plugintrust.Signature
		if err = json.Unmarshal(signatureBytes, &signature); err != nil {
			return fail(fmt.Errorf("invalid signature: %w", err))
		}
		if !strings.EqualFold(signature.Fingerprint, entry.PublisherKeyFingerprint) {
			return fail(errors.New("signature publisher does not match index entry"))
		}
		temporary, err := os.MkdirTemp("", "syrus-plugin-index-check-")
		if err != nil {
			return fail(err)
		}
		defer os.RemoveAll(temporary)
		archive := filepath.Join(temporary, "package.tar.gz")
		if err = os.WriteFile(archive, packageBytes, 0600); err != nil {
			return fail(err)
		}
		if _, err = plugintrust.VerifyRelease(archive, signature, trust, false, entry.Name, entry.Version); err != nil {
			return fail(err)
		}
		if err = runSubmittedPackageValidation(command, archive, minimum, checkout); err != nil {
			return fail(fmt.Errorf("package validator failed: %w", err))
		}
		pluginRoot := filepath.Join(temporary, "plugin")
		manifest, err := extractSubmittedPackage(archive, temporary)
		if err != nil {
			return fail(fmt.Errorf("invalid package: %w", err))
		}
		if manifest.Name != entry.Name || manifest.Version != entry.Version || manifest.RequiresSyrus != entry.RequiresSyrus {
			return fail(errors.New("package manifest is inconsistent with index entry"))
		}
		var declaredCapabilities any
		var packagedCapabilities any
		manifestBytes, _ := json.Marshal(manifest)
		if json.Unmarshal(entry.CapabilitySummary, &declaredCapabilities) != nil || json.Unmarshal(manifestBytes, &packagedCapabilities) != nil || !reflect.DeepEqual(declaredCapabilities, packagedCapabilities) {
			return fail(errors.New("capability summary is inconsistent with package manifest"))
		}
		runner := pluginRunner(checkoutPluginRunner{})
		request := pluginRunRequest{Mode: "test", Directory: pluginRoot, Checkout: checkout, JSON: true}
		if checkout == "" {
			runner = newDockerPluginRunner()
			if err = runner.Available(); err != nil {
				return fail(err)
			}
			request.Image = pluginTestImage + ":" + minimum
			if err = runner.Pull(command.Context(), request.Image, io.Discard, io.Discard); err != nil {
				return fail(err)
			}
		}
		if err = runner.Run(command.Context(), request, command.InOrStdin(), io.Discard, command.ErrOrStderr()); err != nil {
			return fail(fmt.Errorf("plugin contract tests failed against Syrus %s: %w", minimum, err))
		}
		result["status"] = "passed"
		result["plugin"] = entry.Name
		result["version_tested"] = minimum
		bytes, _ := json.Marshal(result)
		fmt.Fprintln(command.OutOrStdout(), string(bytes))
		return nil
	}}
	command.Flags().StringVar(&trustPath, "trust-store", "", "publisher trust store (defaults relative to entry)")
	command.Flags().StringVar(&checkout, "checkout", "", "local Syrus checkout used by the plugin test runner")
	return command
}

func runSubmittedPackageValidation(command *cobra.Command, archive, version, checkout string) error {
	runner := pluginRunner(checkoutPluginRunner{})
	request := pluginRunRequest{Mode: "package-validate", Directory: archive, Checkout: checkout, JSON: true}
	if checkout == "" {
		runner = newDockerPluginRunner()
		if err := runner.Available(); err != nil {
			return err
		}
		request.Image = pluginTestImage + ":" + version
		if err := runner.Pull(command.Context(), request.Image, io.Discard, io.Discard); err != nil {
			return err
		}
	}
	return runner.Run(command.Context(), request, command.InOrStdin(), io.Discard, command.ErrOrStderr())
}

func downloadIndexResource(command *cobra.Command, raw string) ([]byte, error) {
	if err := pluginIndexCheckURLValidator(command.Context(), raw); err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(command.Context(), http.MethodGet, raw, nil)
	if err != nil {
		return nil, err
	}
	client := *pluginIndexCheckHTTP
	previousRedirectCheck := client.CheckRedirect
	client.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if err := pluginIndexCheckURLValidator(request.Context(), request.URL.String()); err != nil {
			return err
		}
		if previousRedirectCheck != nil {
			return previousRedirectCheck(request, via)
		}
		if len(via) >= 10 {
			return errors.New("stopped after 10 redirects")
		}
		return nil
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("download returned %s", response.Status)
	}
	return io.ReadAll(io.LimitReader(response.Body, 256<<20))
}

func validateIndexResourceURL(ctx context.Context, raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.Hostname() == "" || parsed.User != nil {
		return errors.New("package and signature URLs must use HTTPS without credentials")
	}
	if strings.Contains(parsed.Hostname(), "%") {
		return errors.New("package and signature URLs must not use scoped IP addresses")
	}
	addresses, err := net.DefaultResolver.LookupIPAddr(ctx, parsed.Hostname())
	if err != nil {
		return fmt.Errorf("resolve download host: %w", err)
	}
	if len(addresses) == 0 {
		return errors.New("download host did not resolve")
	}
	for _, address := range addresses {
		ip, ok := netip.AddrFromSlice(address.IP)
		if !ok || unsafeIndexResourceAddress(ip.Unmap()) {
			return fmt.Errorf("download host resolves to a private or reserved address: %s", address.IP)
		}
	}
	return nil
}

func unsafeIndexResourceAddress(address netip.Addr) bool {
	if !address.IsValid() || !address.IsGlobalUnicast() || address.IsPrivate() || address.IsLoopback() || address.IsLinkLocalUnicast() {
		return true
	}
	reserved := []netip.Prefix{
		netip.MustParsePrefix("0.0.0.0/8"),
		netip.MustParsePrefix("100.64.0.0/10"),
		netip.MustParsePrefix("192.0.0.0/24"),
		netip.MustParsePrefix("192.0.2.0/24"),
		netip.MustParsePrefix("198.18.0.0/15"),
		netip.MustParsePrefix("198.51.100.0/24"),
		netip.MustParsePrefix("203.0.113.0/24"),
		netip.MustParsePrefix("240.0.0.0/4"),
		netip.MustParsePrefix("2001:db8::/32"),
	}
	for _, prefix := range reserved {
		if prefix.Contains(address) {
			return true
		}
	}
	return false
}

func minimumSyrusVersion(requirement string) string {
	match := regexp.MustCompile(`(?:>=|~>)\s*v?([0-9]+(?:\.[0-9]+){1,2})`).FindStringSubmatch(requirement)
	if len(match) == 2 {
		return match[1]
	}
	return ""
}

func extractSubmittedPackage(path, root string) (packageManifest, error) {
	file, err := os.Open(path)
	if err != nil {
		return packageManifest{}, err
	}
	defer file.Close()
	gz, err := gzip.NewReader(file)
	if err != nil {
		return packageManifest{}, err
	}
	defer gz.Close()
	reader := tar.NewReader(gz)
	var manifest packageManifest
	extractedFiles := map[string]string{}
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return manifest, err
		}
		entryName := strings.TrimSuffix(header.Name, "/")
		clean := filepath.ToSlash(filepath.Clean(entryName))
		if entryName == "" || clean != entryName || strings.HasPrefix(clean, "../") {
			return manifest, errors.New("unsafe package entry")
		}
		if header.Typeflag == tar.TypeDir {
			if strings.HasPrefix(entryName, "plugin/") || entryName == "plugin" {
				if err = os.MkdirAll(filepath.Join(root, filepath.FromSlash(entryName)), 0755); err != nil {
					return manifest, err
				}
			}
			continue
		}
		if header.Typeflag != tar.TypeReg {
			return manifest, errors.New("unsafe package entry")
		}
		if header.Name == "package.json" {
			if err = json.NewDecoder(reader).Decode(&manifest); err != nil {
				return manifest, err
			}
			continue
		}
		if !strings.HasPrefix(header.Name, "plugin/") {
			continue
		}
		destination := filepath.Join(root, filepath.FromSlash(header.Name))
		if err = os.MkdirAll(filepath.Dir(destination), 0755); err != nil {
			return manifest, err
		}
		contents, err := io.ReadAll(reader)
		if err != nil {
			return manifest, err
		}
		if err = os.WriteFile(destination, contents, 0644); err != nil {
			return manifest, err
		}
		digest := sha256.Sum256(contents)
		extractedFiles[header.Name] = hex.EncodeToString(digest[:])
	}
	if manifest.Name == "" {
		return manifest, errors.New("package manifest is missing")
	}
	if len(extractedFiles) != len(manifest.Files) {
		return manifest, errors.New("package files do not match manifest")
	}
	for _, file := range manifest.Files {
		if extractedFiles[file.Path] != file.SHA256 {
			return manifest, fmt.Errorf("package file %s does not match manifest", file.Path)
		}
	}
	return manifest, nil
}
