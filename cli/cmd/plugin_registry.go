package cmd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	gem "github.com/aquasecurity/go-gem-version"
)

const pluginRegistryTTL = 5 * time.Minute

var (
	pluginRegistryNow      = time.Now
	pluginRegistryCacheDir = os.UserCacheDir
	pluginRegistryCommand  = exec.CommandContext
	pluginRegistryHTTP     = &http.Client{Timeout: 30 * time.Second}
)

type pluginRegistryIndex struct {
	FormatVersion int      `json:"format_version"`
	TrustStore    string   `json:"trust_store"`
	Releases      []string `json:"releases"`
}

type pluginRegistryTrustStore struct {
	Publishers []struct {
		Fingerprint string `json:"fingerprint"`
		Label       string `json:"label"`
		Prefix      string `json:"prefix"`
	} `json:"publishers"`
	RevokedKeys     []string `json:"revoked_keys"`
	RevokedReleases []struct {
		Name    string `json:"name"`
		Version string `json:"version"`
		Digest  string `json:"digest"`
	} `json:"revoked_releases"`
}

type pluginRegistryRelease struct {
	Name                    string          `json:"name"`
	Version                 string          `json:"version"`
	Description             string          `json:"description"`
	Category                string          `json:"category"`
	Author                  string          `json:"author"`
	Homepage                string          `json:"homepage"`
	License                 string          `json:"license"`
	RequiresSyrus           string          `json:"requires_syrus"`
	PackageURL              string          `json:"package_url"`
	PackageDigest           string          `json:"package_digest"`
	SignatureURL            string          `json:"signature_url"`
	PublisherKeyFingerprint string          `json:"publisher_key_fingerprint"`
	TrustLabelInputs        json.RawMessage `json:"trust_label_inputs"`
	CapabilitySummary       json.RawMessage `json:"capability_summary"`
}

type pluginRegistryCache struct {
	ETag      string               `json:"etag"`
	FetchedAt time.Time            `json:"fetched_at"`
	Entries   []pluginCatalogEntry `json:"entries"`
}

type pluginRegistryClient struct {
	URL          string
	SyrusVersion string
	HTTPClient   *http.Client
}

func (client pluginRegistryClient) search(ctx context.Context, term string) ([]pluginCatalogEntry, error) {
	entries, err := client.load(ctx)
	if err != nil && len(entries) == 0 {
		return nil, err
	}
	query := strings.ToLower(strings.TrimSpace(term))
	result := make([]pluginCatalogEntry, 0, len(entries))
	for _, entry := range entries {
		if query == "" || strings.Contains(strings.ToLower(entry.Name+"\n"+entry.Description+"\n"+entry.Category), query) {
			result = append(result, entry)
		}
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Name == result[j].Name {
			return compareVersions(result[i].Version, result[j].Version) < 0
		}
		return result[i].Name < result[j].Name
	})
	return result, err
}

func (client pluginRegistryClient) load(ctx context.Context) ([]pluginCatalogEntry, error) {
	parsed, err := url.Parse(strings.TrimPrefix(client.URL, "git+"))
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return nil, errors.New("plugin registry URL must use HTTPS")
	}
	if strings.HasPrefix(client.URL, "git+") || strings.HasSuffix(parsed.Path, ".git") {
		return client.loadGit(ctx, parsed.String())
	}
	return client.loadHTTP(ctx, parsed)
}

func (client pluginRegistryClient) loadHTTP(ctx context.Context, base *url.URL) ([]pluginCatalogEntry, error) {
	cache, cachePath := readPluginRegistryCache(client.cacheKey())
	if cache != nil && pluginRegistryNow().Sub(cache.FetchedAt) < pluginRegistryTTL {
		return cache.Entries, nil
	}
	directoryBase := *base
	directoryBase.Path = strings.TrimRight(directoryBase.Path, "/") + "/"
	directoryBase.RawQuery = ""
	directoryBase.Fragment = ""
	requestURL := directoryBase.ResolveReference(&url.URL{Path: "index.json"})
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL.String(), nil)
	if err != nil {
		return staleRegistry(cache, err)
	}
	if cache != nil && cache.ETag != "" {
		request.Header.Set("If-None-Match", cache.ETag)
	}
	httpClient := client.HTTPClient
	if httpClient == nil {
		httpClient = pluginRegistryHTTP
	}
	response, err := httpClient.Do(request)
	if err != nil {
		return staleRegistry(cache, err)
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotModified && cache != nil {
		cache.FetchedAt = pluginRegistryNow()
		_ = writePluginRegistryCache(cachePath, *cache)
		return cache.Entries, nil
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return staleRegistry(cache, fmt.Errorf("registry returned %s", response.Status))
	}
	var index pluginRegistryIndex
	if err := decodeRegistryJSON(response.Body, &index); err != nil {
		return staleRegistry(cache, fmt.Errorf("malformed plugin registry: %w", err))
	}
	read := func(path string, target any) error {
		relative, err := safeRegistryPath(path)
		if err != nil {
			return err
		}
		resource := directoryBase.ResolveReference(&url.URL{Path: relative})
		resourceRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, resource.String(), nil)
		if err != nil {
			return err
		}
		resourceResponse, err := httpClient.Do(resourceRequest)
		if err != nil {
			return err
		}
		defer resourceResponse.Body.Close()
		if resourceResponse.StatusCode < 200 || resourceResponse.StatusCode >= 300 {
			return fmt.Errorf("registry resource %s returned %s", relative, resourceResponse.Status)
		}
		return decodeRegistryJSON(resourceResponse.Body, target)
	}
	entries, err := parsePluginRegistry(index, read, client.SyrusVersion)
	if err != nil {
		return staleRegistry(cache, fmt.Errorf("malformed plugin registry: %w", err))
	}
	updated := pluginRegistryCache{ETag: response.Header.Get("ETag"), FetchedAt: pluginRegistryNow(), Entries: entries}
	_ = writePluginRegistryCache(cachePath, updated)
	return entries, nil
}

func (client pluginRegistryClient) loadGit(ctx context.Context, source string) ([]pluginCatalogEntry, error) {
	directory, err := registryCachePath(client.URL, "git")
	if err != nil {
		return nil, err
	}
	stamp, err := registryCachePath(client.URL, "git-refreshed-at")
	if err != nil {
		return nil, err
	}
	var refreshErr error
	if info, statErr := os.Stat(stamp); statErr != nil || pluginRegistryNow().Sub(info.ModTime()) >= pluginRegistryTTL {
		if _, statErr := os.Stat(filepath.Join(directory, ".git")); statErr == nil {
			err = pluginRegistryCommand(ctx, "git", "-C", directory, "pull", "--ff-only", "--quiet").Run()
		} else {
			_ = os.RemoveAll(directory)
			err = pluginRegistryCommand(ctx, "git", "clone", "--depth", "1", "--quiet", source, directory).Run()
		}
		if err != nil {
			if _, cacheErr := os.Stat(filepath.Join(directory, "index.json")); cacheErr != nil {
				return nil, fmt.Errorf("plugin registry git refresh failed: %w", err)
			}
			refreshErr = fmt.Errorf("plugin registry git refresh failed: %w", err)
		} else {
			_ = os.MkdirAll(filepath.Dir(stamp), 0700)
			_ = os.WriteFile(stamp, nil, 0600)
		}
	}
	payload, err := readRegistryFile(directory, "index.json")
	if err != nil {
		return nil, err
	}
	var index pluginRegistryIndex
	if err := json.Unmarshal(payload, &index); err != nil {
		return nil, fmt.Errorf("malformed plugin registry: %w", err)
	}
	read := func(path string, target any) error {
		payload, err := readRegistryFile(directory, path)
		if err != nil {
			return err
		}
		return json.Unmarshal(payload, target)
	}
	entries, err := parsePluginRegistry(index, read, client.SyrusVersion)
	if err != nil {
		return nil, err
	}
	return entries, refreshErr
}

func parsePluginRegistry(index pluginRegistryIndex, read func(string, any) error, syrusVersion string) ([]pluginCatalogEntry, error) {
	if index.FormatVersion != 1 || index.TrustStore == "" || index.Releases == nil {
		return nil, errors.New("unsupported or incomplete index format")
	}
	var trust pluginRegistryTrustStore
	if err := read(index.TrustStore, &trust); err != nil {
		return nil, err
	}
	labels := map[string]string{}
	for _, publisher := range trust.Publishers {
		labels[strings.ToLower(publisher.Fingerprint)] = publisher.Label
	}
	revokedKeys := map[string]bool{}
	for _, fingerprint := range trust.RevokedKeys {
		revokedKeys[strings.ToLower(fingerprint)] = true
	}
	entries := make([]pluginCatalogEntry, 0, len(index.Releases))
	for _, path := range index.Releases {
		var release pluginRegistryRelease
		if err := read(path, &release); err != nil {
			return nil, err
		}
		if err := validateRegistryRelease(path, release); err != nil {
			return nil, err
		}
		fingerprint := strings.ToLower(release.PublisherKeyFingerprint)
		revoked := revokedKeys[fingerprint]
		for _, candidate := range trust.RevokedReleases {
			if candidate.Name == release.Name && candidate.Version == release.Version && (candidate.Digest == "" || candidate.Digest == strings.TrimPrefix(release.PackageDigest, "sha256:")) {
				revoked = true
			}
		}
		compatible, err := versionRequirementSatisfied(release.RequiresSyrus, syrusVersion)
		if err != nil {
			return nil, err
		}
		if revoked || !compatible {
			continue
		}
		label := labels[fingerprint]
		if label == "" {
			label = "community"
		}
		entries = append(entries, pluginCatalogEntry{Name: release.Name, Version: release.Version, Description: release.Description, Category: release.Category, TrustLabel: label})
	}
	return entries, nil
}

func validateRegistryRelease(path string, release pluginRegistryRelease) error {
	if _, err := safeRegistryPath(path); err != nil {
		return err
	}
	if !regexp.MustCompile(`^[a-z][a-z0-9]*_[a-z][a-z0-9_]*$`).MatchString(release.Name) || path != release.Name+"/"+release.Version+".json" {
		return errors.New("registry entry path does not match a publisher-prefixed name and version")
	}
	if release.Description == "" || release.Category == "" || release.Author == "" || release.Homepage == "" || release.License == "" || release.RequiresSyrus == "" || release.PackageURL == "" || release.PackageDigest == "" || release.SignatureURL == "" || release.PublisherKeyFingerprint == "" || len(release.TrustLabelInputs) == 0 || len(release.CapabilitySummary) == 0 {
		return errors.New("registry entry is missing required metadata")
	}
	if _, err := gem.NewVersion(release.Version); err != nil {
		return fmt.Errorf("invalid registry release version %q: %w", release.Version, err)
	}
	return nil
}

func versionRequirementSatisfied(requirement, runningVersion string) (bool, error) {
	if strings.TrimSpace(runningVersion) == "" {
		return true, nil
	}
	if strings.Contains(requirement, "||") {
		return false, fmt.Errorf("invalid requires_syrus %q: alternatives are not supported by Gem::Requirement", requirement)
	}
	running, err := gem.NewVersion(strings.TrimPrefix(strings.TrimSpace(runningVersion), "v"))
	if err != nil {
		return false, fmt.Errorf("invalid Syrus version %q: %w", runningVersion, err)
	}
	constraints, err := gem.NewConstraints(requirement)
	if err != nil {
		return false, fmt.Errorf("invalid requires_syrus %q: %w", requirement, err)
	}
	return constraints.Check(running), nil
}

func compareVersions(left, right string) int {
	leftVersion, leftErr := gem.NewVersion(left)
	rightVersion, rightErr := gem.NewVersion(right)
	if leftErr != nil || rightErr != nil {
		return strings.Compare(left, right)
	}
	return leftVersion.Compare(rightVersion)
}

func safeRegistryPath(path string) (string, error) {
	clean := filepath.ToSlash(filepath.Clean(path))
	valid := clean != "." && clean != ".." && clean == path && !strings.HasPrefix(clean, "/") &&
		!strings.Contains(clean, "\\") && !slices.Contains(strings.Split(clean, "/"), "..")
	if !valid {
		return "", errors.New("invalid registry path")
	}
	return clean, nil
}

func readRegistryFile(root, path string) ([]byte, error) {
	relative, err := safeRegistryPath(path)
	if err != nil {
		return nil, err
	}
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, fmt.Errorf("invalid registry root: %w", err)
	}
	resolvedPath, err := filepath.EvalSymlinks(filepath.Join(root, filepath.FromSlash(relative)))
	if err != nil {
		return nil, fmt.Errorf("invalid registry file %q: %w", relative, err)
	}
	contained, err := filepath.Rel(resolvedRoot, resolvedPath)
	if err != nil || contained == ".." || strings.HasPrefix(contained, ".."+string(filepath.Separator)) {
		return nil, fmt.Errorf("registry file %q escapes the index root", relative)
	}
	info, err := os.Stat(resolvedPath)
	if err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("registry file %q is not a regular file", relative)
	}
	return os.ReadFile(resolvedPath)
}

func decodeRegistryJSON(reader io.Reader, target any) error {
	return json.NewDecoder(io.LimitReader(reader, 4<<20)).Decode(target)
}
func staleRegistry(cache *pluginRegistryCache, err error) ([]pluginCatalogEntry, error) {
	if cache != nil {
		return cache.Entries, fmt.Errorf("using cached plugin registry after refresh failed: %w", err)
	}
	return nil, err
}

func registryCachePath(source, suffix string) (string, error) {
	root, err := pluginRegistryCacheDir()
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256([]byte(source))
	return filepath.Join(root, "syrus", "plugin-registry-"+hex.EncodeToString(digest[:8])+"-"+suffix), nil
}

func (client pluginRegistryClient) cacheKey() string {
	return client.URL + "\x00" + client.SyrusVersion
}
func readPluginRegistryCache(source string) (*pluginRegistryCache, string) {
	path, err := registryCachePath(source, "catalog.json")
	if err != nil {
		return nil, ""
	}
	payload, err := os.ReadFile(path)
	if err != nil {
		return nil, path
	}
	var cache pluginRegistryCache
	if json.Unmarshal(payload, &cache) != nil {
		return nil, path
	}
	return &cache, path
}
func writePluginRegistryCache(path string, cache pluginRegistryCache) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	payload, err := json.Marshal(cache)
	if err != nil {
		return err
	}
	return os.WriteFile(path, payload, 0600)
}
