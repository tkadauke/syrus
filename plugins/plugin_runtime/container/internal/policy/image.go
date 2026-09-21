package policy

import (
	"fmt"
	"strings"
)

// ImageRef is a parsed, normalized image reference. Normalizing matters for
// the allowlist: "traefik/whoami:v1" and "docker.io/traefik/whoami:v1" are the
// same image, and a prefix check against the raw string would treat them as
// different -- in one direction, that is a bypass.
type ImageRef struct {
	Repository string // e.g. "ghcr.io/tkadauke/syrus-git-mirror"
	Tag        string // e.g. "abc123"; empty when pinned by digest
	Digest     string // e.g. "sha256:..."; empty when tagged
}

// ParseImage parses and normalizes an image reference. It requires an explicit
// tag or digest: an untagged reference means "whatever latest is today", and
// the manager replaces a container when its spec changes, so the image has to
// be something a spec can actually pin.
func ParseImage(ref string) (ImageRef, error) {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return ImageRef{}, fmt.Errorf("image is required")
	}
	if strings.ContainsAny(ref, " \t\n\r") {
		return ImageRef{}, fmt.Errorf("image %q contains whitespace", ref)
	}
	if ref != strings.ToLower(ref) {
		// Docker repository names are lowercase. Refusing uppercase keeps
		// normalization and the allowlist unambiguous.
		return ImageRef{}, fmt.Errorf("image %q must be lowercase", ref)
	}

	name := ref
	var parsed ImageRef
	if at := strings.Index(ref, "@"); at >= 0 {
		name, parsed.Digest = ref[:at], ref[at+1:]
		if !strings.HasPrefix(parsed.Digest, "sha256:") || len(parsed.Digest) != len("sha256:")+64 {
			return ImageRef{}, fmt.Errorf("image %q has a malformed digest", ref)
		}
	} else if colon := strings.LastIndex(ref, ":"); colon > strings.LastIndex(ref, "/") {
		name, parsed.Tag = ref[:colon], ref[colon+1:]
	}

	if parsed.Tag == "" && parsed.Digest == "" {
		return ImageRef{}, fmt.Errorf("image %q must specify a tag or digest", ref)
	}
	if name == "" {
		return ImageRef{}, fmt.Errorf("image %q has no repository", ref)
	}

	parsed.Repository = normalizeRepository(name)
	return parsed, nil
}

// String renders the normalized reference.
func (r ImageRef) String() string {
	if r.Digest != "" {
		return r.Repository + "@" + r.Digest
	}
	return r.Repository + ":" + r.Tag
}

// PullParams returns the fromImage/tag pair the Docker Engine API expects.
func (r ImageRef) PullParams() (fromImage, tag string) {
	if r.Digest != "" {
		return r.Repository + "@" + r.Digest, ""
	}
	return r.Repository, r.Tag
}

// normalizeRepository makes the registry host explicit: Docker Hub images get
// "docker.io/", and official single-segment images get "docker.io/library/".
func normalizeRepository(name string) string {
	parts := strings.SplitN(name, "/", 2)
	if len(parts) == 1 {
		return "docker.io/library/" + name
	}
	if !looksLikeHost(parts[0]) {
		return "docker.io/" + name
	}
	return name
}

// looksLikeHost is Docker's own rule for whether the first path segment names
// a registry: it has a dot or a port, or is literally "localhost".
func looksLikeHost(segment string) bool {
	return strings.ContainsAny(segment, ".:") || segment == "localhost"
}

// normalizePrefix normalizes an allowlist entry. A trailing slash marks a
// namespace ("ghcr.io/acme/"); anything else is one exact repository
// ("docker.io/traefik/whoami").
//
// Namespaces cannot reuse normalizeRepository. That function reads a single
// segment as an official Docker Hub image, which would turn the registry
// "localhost:5000/" into "docker.io/library/localhost:5000/" and the Hub org
// "traefik/" into "docker.io/library/traefik/" -- neither of which matches
// anything the operator meant.
func normalizePrefix(prefix string) string {
	prefix = strings.ToLower(strings.TrimSpace(prefix))
	if prefix == "" {
		return ""
	}
	if !strings.HasSuffix(prefix, "/") {
		return normalizeRepository(prefix)
	}
	namespace := strings.TrimSuffix(prefix, "/")
	if looksLikeHost(strings.SplitN(namespace, "/", 2)[0]) {
		return namespace + "/"
	}
	return "docker.io/" + namespace + "/"
}
