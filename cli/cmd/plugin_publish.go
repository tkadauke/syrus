package cmd

import (
	"bytes"
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
	"path/filepath"
	"strings"

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
	api := "https://api.github.com/repos/" + repository
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
	owner := strings.Split(repository, "/")[0]
	branch := "plugin-submission-" + strings.ReplaceAll(strings.TrimSuffix(filepath.Base(path), ".json"), ".", "-")
	api := "https://api.github.com/repos/" + repository
	res, err := p.request(ctx, http.MethodGet, api+"/git/ref/heads/main", nil, "application/json")
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
	branchBody, _ := json.Marshal(map[string]string{"ref": "refs/heads/" + branch, "sha": ref.Object.SHA})
	if res, err = p.request(ctx, http.MethodPost, api+"/git/refs", branchBody, "application/json"); err != nil {
		return "", err
	}
	res.Body.Close()
	fileBody, _ := json.Marshal(map[string]string{"message": "Add " + path, "content": encodeBase64(contents), "branch": branch})
	if res, err = p.request(ctx, http.MethodPut, api+"/contents/"+path, fileBody, "application/json"); err != nil {
		return "", err
	}
	res.Body.Close()
	prBody, _ := json.Marshal(map[string]string{"title": "Add " + path, "head": owner + ":" + branch, "base": "main", "body": "Automated plugin registry submission."})
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

func encodeBase64(value []byte) string {
	const table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	var out strings.Builder
	for i := 0; i < len(value); i += 3 {
		var n uint32
		remain := len(value) - i
		n = uint32(value[i]) << 16
		if remain > 1 {
			n |= uint32(value[i+1]) << 8
		}
		if remain > 2 {
			n |= uint32(value[i+2])
		}
		out.WriteByte(table[(n>>18)&63])
		out.WriteByte(table[(n>>12)&63])
		if remain > 1 {
			out.WriteByte(table[(n>>6)&63])
		} else {
			out.WriteByte('=')
		}
		if remain > 2 {
			out.WriteByte(table[n&63])
		} else {
			out.WriteByte('=')
		}
	}
	return out.String()
}

func newPluginPublishCommand() *cobra.Command {
	var keyPath, repository, indexRepository, version, checkout string
	var submit bool
	command := &cobra.Command{Use: "publish [DIR]", Short: "Pack, sign, and publish a plugin release", Args: cobra.MaximumNArgs(1), RunE: func(command *cobra.Command, args []string) error {
		if keyPath == "" || repository == "" {
			return errors.New("--key and --repository are required")
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
		manifest, files, err := inspectPluginPackage(root)
		if err != nil {
			return err
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
		entry := pluginRegistryRelease{Name: manifest.Name, Version: manifest.Version, Description: manifest.Name, Category: "other", Author: strings.Split(manifest.Name, "_")[0], Homepage: "https://github.com/" + repository, License: "unknown", RequiresSyrus: manifest.RequiresSyrus, PackageURL: packageURL, PackageDigest: "sha256:" + hex.EncodeToString(digest[:]), SignatureURL: signatureURL, PublisherKeyFingerprint: key.Fingerprint, TrustLabelInputs: json.RawMessage(`{}`), CapabilitySummary: mustJSON(manifest)}
		entryBytes, _ := json.MarshalIndent(entry, "", "  ")
		entryBytes = append(entryBytes, '\n')
		path := manifest.Name + "/" + manifest.Version + ".json"
		if submit {
			if indexRepository == "" {
				return errors.New("--index-repository is required with --submit")
			}
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
	command.Flags().BoolVar(&submit, "submit", false, "open an index pull request (explicit consent)")
	command.Flags().StringVar(&version, "syrus-version", "", "Syrus release to validate against")
	command.Flags().StringVar(&checkout, "checkout", "", "run validation from a local Syrus checkout")
	return command
}

func mustJSON(value any) json.RawMessage { bytes, _ := json.Marshal(value); return bytes }
