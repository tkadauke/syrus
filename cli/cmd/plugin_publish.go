package cmd

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/plugintrust"
)

type pluginPublisher interface {
	Upload(context.Context, string, string, string, []byte) (string, error)
	Submit(context.Context, string, string, []byte) (string, error)
}

var newPluginPublisher = func(token string) pluginPublisher {
	return &githubPluginPublisher{token: token, client: http.DefaultClient}
}

var githubAPIBase = "https://api.github.com"

type githubPluginPublisher struct {
	token  string
	client *http.Client
}

func (p *githubPluginPublisher) request(ctx context.Context, method, endpoint string, body []byte, contentType string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+p.token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", contentType)
	res, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		defer res.Body.Close()
		message, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
		return nil, fmt.Errorf("GitHub returned %s: %s", res.Status, strings.TrimSpace(string(message)))
	}
	return res, nil
}

func (p *githubPluginPublisher) Upload(ctx context.Context, repository, tag, name string, contents []byte) (string, error) {
	api := githubAPIBase + "/repos/" + repository
	payload, _ := json.Marshal(map[string]any{"tag_name": tag, "name": tag})
	res, err := p.request(ctx, http.MethodPost, api+"/releases", payload, "application/json")
	if err != nil { // An existing release is the normal retry path.
		res, err = p.request(ctx, http.MethodGet, api+"/releases/tags/"+url.PathEscape(tag), nil, "application/json")
		if err != nil {
			return "", err
		}
	}
	defer res.Body.Close()
	var release struct {
		UploadURL string `json:"upload_url"`
	}
	if err := json.NewDecoder(res.Body).Decode(&release); err != nil {
		return "", err
	}
	upload := strings.Split(release.UploadURL, "{")[0] + "?name=" + url.QueryEscape(name)
	res, err = p.request(ctx, http.MethodPost, upload, contents, "application/octet-stream")
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	var asset struct {
		URL string `json:"browser_download_url"`
	}
	if err := json.NewDecoder(res.Body).Decode(&asset); err != nil {
		return "", err
	}
	return asset.URL, nil
}

func (p *githubPluginPublisher) Submit(ctx context.Context, repository, path string, contents []byte) (string, error) {
	branchName := strings.TrimSuffix(filepath.ToSlash(path), ".json")
	branch := "plugin-submission-" + strings.NewReplacer("/", "-", ".", "-").Replace(branchName)
	api := githubAPIBase + "/repos/" + repository
	res, err := p.request(ctx, http.MethodGet, api, nil, "application/json")
	if err != nil {
		return "", err
	}
	var repositoryDetails struct {
		DefaultBranch string `json:"default_branch"`
		Name          string `json:"name"`
		Owner         struct {
			Login string `json:"login"`
		} `json:"owner"`
		Permissions struct {
			Push bool `json:"push"`
		} `json:"permissions"`
	}
	if err := json.NewDecoder(res.Body).Decode(&repositoryDetails); err != nil {
		res.Body.Close()
		return "", err
	}
	res.Body.Close()
	if repositoryDetails.DefaultBranch == "" {
		return "", errors.New("GitHub repository did not report a default branch")
	}
	baseBranch := repositoryDetails.DefaultBranch
	if repositoryDetails.Name == "" {
		repositoryDetails.Name = strings.Split(repository, "/")[1]
	}
	if repositoryDetails.Owner.Login == "" {
		repositoryDetails.Owner.Login = strings.Split(repository, "/")[0]
	}
	res, err = p.request(ctx, http.MethodGet, api+"/git/ref/heads/"+url.PathEscape(baseBranch), nil, "application/json")
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	var ref struct {
		Object struct {
			SHA string `json:"sha"`
		} `json:"object"`
	}
	if err := json.NewDecoder(res.Body).Decode(&ref); err != nil {
		return "", err
	}
	res.Body.Close()
	indexBytes, indexSHA, err := p.readRepositoryFile(ctx, repository, "index.json", baseBranch)
	if err != nil {
		return "", err
	}
	var index pluginRegistryIndex
	if err := json.Unmarshal(indexBytes, &index); err != nil {
		return "", fmt.Errorf("invalid index.json: %w", err)
	}
	if index.FormatVersion != 1 || index.Releases == nil {
		return "", errors.New("index.json has an unsupported or incomplete format")
	}
	for _, release := range index.Releases {
		if release == path {
			return "", fmt.Errorf("index.json already lists %s", path)
		}
	}
	index.Releases = append(index.Releases, path)
	sort.Strings(index.Releases)
	updatedIndex, _ := json.MarshalIndent(index, "", "  ")
	updatedIndex = append(updatedIndex, '\n')
	writableRepository, headOwner, err := p.submissionRepository(ctx, repository, repositoryDetails.Name, repositoryDetails.Owner.Login, repositoryDetails.Permissions.Push)
	if err != nil {
		return "", err
	}
	if !strings.EqualFold(writableRepository, repository) {
		if err := p.waitForRepositoryRef(ctx, writableRepository, baseBranch); err != nil {
			return "", err
		}
	}
	writableAPI := githubAPIBase + "/repos/" + writableRepository
	branchBody, _ := json.Marshal(map[string]string{"ref": "refs/heads/" + branch, "sha": ref.Object.SHA})
	if res, err = p.request(ctx, http.MethodPost, writableAPI+"/git/refs", branchBody, "application/json"); err != nil {
		return "", err
	}
	res.Body.Close()
	fileBody, _ := json.Marshal(map[string]string{"message": "Add " + path, "content": base64.StdEncoding.EncodeToString(contents), "branch": branch})
	if res, err = p.request(ctx, http.MethodPut, writableAPI+"/contents/"+path, fileBody, "application/json"); err != nil {
		return "", err
	}
	res.Body.Close()
	indexBody, _ := json.Marshal(map[string]string{"message": "List " + path, "content": base64.StdEncoding.EncodeToString(updatedIndex), "branch": branch, "sha": indexSHA})
	if res, err = p.request(ctx, http.MethodPut, writableAPI+"/contents/index.json", indexBody, "application/json"); err != nil {
		return "", err
	}
	res.Body.Close()
	prBody, _ := json.Marshal(map[string]string{"title": "Add " + path, "head": headOwner + ":" + branch, "base": baseBranch, "body": "Automated plugin registry submission."})
	if res, err = p.request(ctx, http.MethodPost, api+"/pulls", prBody, "application/json"); err != nil {
		return "", err
	}
	defer res.Body.Close()
	var pr struct {
		URL string `json:"html_url"`
	}
	if err := json.NewDecoder(res.Body).Decode(&pr); err != nil {
		return "", err
	}
	return pr.URL, nil
}

func (p *githubPluginPublisher) waitForRepositoryRef(ctx context.Context, repository, branch string) error {
	endpoint := githubAPIBase + "/repos/" + repository + "/git/ref/heads/" + url.PathEscape(branch)
	for attempt := 0; attempt < 30; attempt++ {
		if res, err := p.request(ctx, http.MethodGet, endpoint, nil, "application/json"); err == nil {
			res.Body.Close()
			return nil
		}
		timer := time.NewTimer(time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
	return fmt.Errorf("GitHub fork %s was not ready after 30 seconds", repository)
}

func (p *githubPluginPublisher) readRepositoryFile(ctx context.Context, repository, path, ref string) ([]byte, string, error) {
	endpoint := githubAPIBase + "/repos/" + repository + "/contents/" + path + "?ref=" + url.QueryEscape(ref)
	res, err := p.request(ctx, http.MethodGet, endpoint, nil, "application/json")
	if err != nil {
		return nil, "", err
	}
	defer res.Body.Close()
	var file struct {
		Content string `json:"content"`
		SHA     string `json:"sha"`
	}
	if err := json.NewDecoder(res.Body).Decode(&file); err != nil {
		return nil, "", err
	}
	contents, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(file.Content, "\n", ""))
	if err != nil {
		return nil, "", fmt.Errorf("invalid GitHub file content: %w", err)
	}
	return contents, file.SHA, nil
}

func (p *githubPluginPublisher) submissionRepository(ctx context.Context, upstream, name, upstreamOwner string, canPush bool) (string, string, error) {
	if canPush {
		return upstream, upstreamOwner, nil
	}
	res, err := p.request(ctx, http.MethodGet, githubAPIBase+"/user", nil, "application/json")
	if err != nil {
		return "", "", err
	}
	var user struct {
		Login string `json:"login"`
	}
	if err := json.NewDecoder(res.Body).Decode(&user); err != nil {
		res.Body.Close()
		return "", "", err
	}
	res.Body.Close()
	if user.Login == "" {
		return "", "", errors.New("GitHub did not report the authenticated user")
	}
	fork := user.Login + "/" + name
	if existing, existingErr := p.request(ctx, http.MethodGet, githubAPIBase+"/repos/"+fork, nil, "application/json"); existingErr == nil {
		var repositoryDetails struct {
			Parent struct {
				FullName string `json:"full_name"`
			} `json:"parent"`
		}
		if err := json.NewDecoder(existing.Body).Decode(&repositoryDetails); err != nil {
			existing.Body.Close()
			return "", "", err
		}
		existing.Body.Close()
		if !strings.EqualFold(repositoryDetails.Parent.FullName, upstream) {
			return "", "", fmt.Errorf("GitHub repository %s exists but is not a fork of %s", fork, upstream)
		}
		return fork, user.Login, nil
	}
	res, err = p.request(ctx, http.MethodPost, githubAPIBase+"/repos/"+upstream+"/forks", []byte(`{}`), "application/json")
	if err != nil {
		return "", "", err
	}
	var created struct {
		FullName string `json:"full_name"`
	}
	if err := json.NewDecoder(res.Body).Decode(&created); err != nil {
		res.Body.Close()
		return "", "", err
	}
	res.Body.Close()
	if created.FullName != "" {
		fork = created.FullName
	}
	return fork, strings.Split(fork, "/")[0], nil
}

func newPluginPublishCommand() *cobra.Command {
	var keyPath, repository, indexRepository, registry, version, checkout, description, category, license string
	var submit bool
	command := &cobra.Command{Use: "publish [DIR]", Short: "Pack, sign, and publish a plugin release", Args: cobra.MaximumNArgs(1), RunE: func(command *cobra.Command, args []string) error {
		if keyPath == "" || repository == "" {
			return errors.New("--key and --repository are required")
		}
		if submit {
			var err error
			indexRepository, err = resolveSubmissionRepository(command.Context(), indexRepository, registry)
			if err != nil {
				return err
			}
		}
		token := os.Getenv("GITHUB_TOKEN")
		if token == "" {
			return errors.New("GITHUB_TOKEN is required")
		}
		directory := "."
		if len(args) == 1 {
			directory = args[0]
		}
		root, err := filepath.Abs(directory)
		if err != nil {
			return err
		}
		if err = runPluginValidation(command, root, version, checkout); err != nil {
			return fmt.Errorf("refusing to publish because validation failed: %w", err)
		}
		if _, err := os.Stat(filepath.Join(root, "frontend", "entry.tsx")); err == nil {
			if _, err := os.Stat(filepath.Join(root, "dist", "frontend", "plugin.js")); os.IsNotExist(err) {
				if err := runFrontendBuild(command, root, version, checkout); err != nil {
					return err
				}
			}
		}
		manifest, files, err := inspectPluginPackage(root)
		if err != nil {
			return err
		}
		if description == "" || license == "" {
			inferredDescription, inferredLicense := pluginPublicationMetadata(files)
			if description == "" {
				description = inferredDescription
			}
			if license == "" {
				license = inferredLicense
			}
		}
		if description == "" || license == "" {
			return errors.New("plugin description and license must be set in the gemspec or with --description and --license")
		}
		temp, err := os.MkdirTemp("", "syrus-plugin-publish-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(temp)
		packagePath := filepath.Join(temp, manifest.Name+"-"+manifest.Version+".syrus-plugin.tar.gz")
		if err = writePluginPackage(packagePath, manifest, files); err != nil {
			return err
		}
		keyBytes, err := os.ReadFile(keyPath)
		if err != nil {
			return err
		}
		var key plugintrust.KeyFile
		if err = json.Unmarshal(keyBytes, &key); err != nil {
			return err
		}
		signature, err := plugintrust.Sign(packagePath, key)
		if err != nil {
			return err
		}
		signatureBytes, _ := json.MarshalIndent(signature, "", "  ")
		signatureBytes = append(signatureBytes, '\n')
		publisher := newPluginPublisher(token)
		tag := "v" + manifest.Version
		packageBytes, _ := os.ReadFile(packagePath)
		packageURL, err := publisher.Upload(command.Context(), repository, tag, filepath.Base(packagePath), packageBytes)
		if err != nil {
			return err
		}
		signatureURL, err := publisher.Upload(command.Context(), repository, tag, filepath.Base(packagePath)+".sig", signatureBytes)
		if err != nil {
			return err
		}
		digest := sha256.Sum256(packageBytes)
		entry := pluginRegistryRelease{Name: manifest.Name, Version: manifest.Version, Description: description, Category: category, Author: strings.Split(manifest.Name, "_")[0], Homepage: "https://github.com/" + repository, License: license, RequiresSyrus: manifest.RequiresSyrus, PackageURL: packageURL, PackageDigest: "sha256:" + hex.EncodeToString(digest[:]), SignatureURL: signatureURL, PublisherKeyFingerprint: key.Fingerprint, TrustLabelInputs: json.RawMessage(`{}`), CapabilitySummary: mustJSON(manifest)}
		entryBytes, _ := json.MarshalIndent(entry, "", "  ")
		entryBytes = append(entryBytes, '\n')
		path := manifest.Name + "/" + manifest.Version + ".json"
		if submit {
			pr, err := publisher.Submit(command.Context(), indexRepository, path, entryBytes)
			if err != nil {
				return err
			}
			fmt.Fprintln(command.OutOrStdout(), pr)
			return nil
		}
		fmt.Fprintln(command.OutOrStdout(), string(entryBytes))
		fmt.Fprintf(command.OutOrStdout(), "Save as %s in the index repository, add it to index.json, and open a pull request.\n", path)
		return nil
	}}
	command.Flags().StringVar(&keyPath, "key", "", "publisher private key file")
	command.Flags().StringVar(&repository, "repository", "", "GitHub release repository (OWNER/REPO)")
	command.Flags().StringVar(&indexRepository, "index-repository", "", "GitHub index repository (OWNER/REPO)")
	command.Flags().StringVar(&registry, "registry", "", "Configured registry to submit to (defaults to canonical)")
	command.Flags().BoolVar(&submit, "submit", false, "open an index pull request (explicit consent)")
	command.Flags().StringVar(&version, "syrus-version", "", "Syrus release to validate against")
	command.Flags().StringVar(&checkout, "checkout", "", "run validation from a local Syrus checkout")
	command.Flags().StringVar(&description, "description", "", "registry description (defaults to the gemspec summary or description)")
	command.Flags().StringVar(&category, "category", "other", "registry category")
	command.Flags().StringVar(&license, "license", "", "registry license (defaults to the gemspec license)")
	return command
}

func resolveSubmissionRepository(ctx context.Context, override, registry string) (string, error) {
	if override != "" {
		return override, nil
	}
	if registry == "" {
		registry = "canonical"
	}
	_, source, err := findConfiguredRegistry(ctx, registry)
	if err != nil {
		return "", fmt.Errorf("cannot select submission registry: %w", err)
	}
	return githubRepositoryForRegistry(source)
}

func pluginPublicationMetadata(files map[string][]byte) (string, string) {
	for path, contents := range files {
		if !strings.HasSuffix(path, ".gemspec") {
			continue
		}
		read := func(field string) string {
			match := packageField(field).FindSubmatch(contents)
			if len(match) > 1 {
				return string(match[1])
			}
			return ""
		}
		description := read("summary")
		if description == "" {
			description = read("description")
		}
		return description, read("license")
	}
	return "", ""
}

func mustJSON(value any) json.RawMessage { bytes, _ := json.Marshal(value); return bytes }
