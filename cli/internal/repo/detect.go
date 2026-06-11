package repo

import (
	"errors"
	"net/url"
	"os/exec"
	"regexp"
	"strings"
)

var ErrNoRepository = errors.New("no git repository detected")

func DetectSlug() (string, error) {
	cmd := exec.Command("git", "config", "--get", "remote.origin.url")
	output, err := cmd.Output()
	if err != nil {
		return "", ErrNoRepository
	}
	slug, ok := ParseRemoteURL(strings.TrimSpace(string(output)))
	if !ok {
		return "", ErrNoRepository
	}
	return slug, nil
}

func ParseRemoteURL(remote string) (string, bool) {
	remote = strings.TrimSpace(remote)
	if remote == "" {
		return "", false
	}

	if strings.HasPrefix(remote, "git@") {
		return parseSCPRemote(remote)
	}

	parsed, err := url.Parse(remote)
	if err != nil || parsed.Host == "" {
		return "", false
	}
	if !strings.EqualFold(strings.TrimPrefix(parsed.Host, "www."), "github.com") {
		return "", false
	}
	return normalizeSlug(parsed.Path)
}

func parseSCPRemote(remote string) (string, bool) {
	match := regexp.MustCompile(`^git@github\.com:(.+)$`).FindStringSubmatch(remote)
	if len(match) != 2 {
		return "", false
	}
	return normalizeSlug(match[1])
}

func normalizeSlug(path string) (string, bool) {
	path = strings.Trim(path, "/")
	path = strings.TrimSuffix(path, ".git")
	parts := strings.Split(path, "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", false
	}
	return parts[0] + "/" + parts[1], true
}
