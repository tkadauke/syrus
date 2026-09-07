package cmd

import (
	"fmt"
	"strings"
)

// parseRef parses a raw job/epic identifier argument into the ref forwarded
// to the API (id) and the ref shown back to the user (display). A prefixed
// numeric ID (e.g. JOB-42) or a bare numeric ID (42) normalizes to
// <prefix><n> for display; a human-readable slug is forwarded to the API and
// displayed as-is. prefix (e.g. "JOB-", "EPIC-") is matched
// case-insensitively; label names the identifier in error messages (e.g.
// "job id", "epic id").
func parseRef(input string, prefix string, label string) (display string, id string, err error) {
	ref := strings.TrimSpace(input)
	if ref == "" {
		return "", "", fmt.Errorf("%s is required", label)
	}
	upper := strings.ToUpper(ref)
	if strings.HasPrefix(upper, strings.ToUpper(prefix)) {
		rest := strings.TrimSpace(ref[len(prefix):])
		if rest == "" {
			return "", "", fmt.Errorf("invalid %s %q", label, input)
		}
		return prefix + rest, rest, nil
	}
	return displayRef(ref, prefix), ref, nil
}

// displayRef formats an identifier for user-facing output: a numeric ID gets
// the given prefix (e.g. JOB-/EPIC-); a human-readable slug is shown as-is.
func displayRef(id string, prefix string) string {
	for _, r := range id {
		if r < '0' || r > '9' {
			return id
		}
	}
	return prefix + id
}
