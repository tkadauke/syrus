// Package gitremote parses and safely displays git remote URLs.
package gitremote

import (
	"net/url"
	"regexp"
	"strings"
)

var credentialedURL = regexp.MustCompile(`(?i)(?:https?|ssh|git)://[^\s]+`)

// GitHubSlug returns the owner/name portion of a GitHub remote URL.
func GitHubSlug(remote string) string {
	value := strings.TrimSpace(remote)
	if strings.HasPrefix(value, "git@github.com:") {
		return cleanSlug(strings.TrimPrefix(value, "git@github.com:"))
	}

	parsed, err := url.Parse(value)
	if err != nil || !strings.EqualFold(parsed.Hostname(), "github.com") {
		return ""
	}
	return cleanSlug(parsed.Path)
}

// Redact removes URL userinfo so credentials cannot reach terminal output.
func Redact(value string) string {
	return credentialedURL.ReplaceAllStringFunc(value, func(candidate string) string {
		parsed, err := url.Parse(candidate)
		if err != nil || parsed.User == nil {
			return candidate
		}
		parsed.User = nil
		return parsed.String()
	})
}

func cleanSlug(value string) string {
	value = strings.Trim(strings.TrimSpace(value), "/")
	value = strings.TrimSuffix(value, ".git")
	parts := strings.Split(value, "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return ""
	}
	return parts[0] + "/" + parts[1]
}
