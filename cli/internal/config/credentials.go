package config

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

var (
	ErrMissingCredentials       = errors.New("credentials file is missing")
	ErrIncompleteCredentials    = errors.New("credentials are incomplete")
	ErrMissingInvocationContext = errors.New("Syrus invocation context is missing")
)

type Credentials struct {
	URL      string
	Token    string
	Internal bool
}

func (c Credentials) Validate() error {
	if strings.TrimSpace(c.URL) == "" || strings.TrimSpace(c.Token) == "" {
		return ErrIncompleteCredentials
	}
	return nil
}

func DefaultCredentialsPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	// The channel/profile picks the file basename: `credentials` for the
	// default channel, `credentials.test` for a `syrus-test` build. See
	// profile.go for how the profile is resolved.
	return filepath.Join(home, ".syrus", credentialsFilename(Profile())), nil
}

func LoadDefaultCredentials() (Credentials, error) {
	if creds, ok, err := LoadInvocationCredentialsFromEnv(); ok || err != nil {
		return creds, err
	}

	path, err := DefaultCredentialsPath()
	if err != nil {
		return Credentials{}, err
	}
	return LoadCredentials(path)
}

func LoadInvocationCredentialsFromEnv() (Credentials, bool, error) {
	url := strings.TrimSpace(os.Getenv("SYRUS_CLI_URL"))
	token := strings.TrimSpace(os.Getenv("SYRUS_CLI_INVOCATION_CONTEXT"))
	runtime := truthy(os.Getenv("SYRUS_CLI_INTERNAL"))
	if url == "" && token == "" && !runtime {
		return Credentials{}, false, nil
	}
	if url == "" || token == "" {
		return Credentials{}, true, ErrMissingInvocationContext
	}
	creds := Credentials{URL: url, Token: token, Internal: true}
	if err := creds.Validate(); err != nil {
		return Credentials{}, true, ErrMissingInvocationContext
	}
	return creds, true, nil
}

func SaveDefaultCredentials(creds Credentials) error {
	path, err := DefaultCredentialsPath()
	if err != nil {
		return err
	}
	return SaveCredentials(path, creds)
}

func LoadCredentials(path string) (Credentials, error) {
	file, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Credentials{}, ErrMissingCredentials
		}
		return Credentials{}, err
	}
	defer file.Close()

	creds, err := ParseCredentials(file)
	if err != nil {
		return Credentials{}, err
	}
	if err := creds.Validate(); err != nil {
		return Credentials{}, err
	}
	return creds, nil
}

func SaveCredentials(path string, creds Credentials) error {
	if err := creds.Validate(); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	contents := fmt.Sprintf("url=%s\ntoken=%s\n", strings.TrimSpace(creds.URL), strings.TrimSpace(creds.Token))
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		return err
	}
	// os.WriteFile only applies the mode bits when creating a new file; if the
	// file already existed with weaker permissions, WriteFile truncates and
	// rewrites without changing them. Chmod explicitly so a pre-existing
	// world/group-readable credentials file is always corrected.
	return os.Chmod(path, 0600)
}

func ParseCredentials(r io.Reader) (Credentials, error) {
	var creds Credentials
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return Credentials{}, fmt.Errorf("invalid credentials line: %q", line)
		}
		key = strings.TrimSpace(key)
		value = strings.Trim(strings.TrimSpace(value), `"'`)

		switch key {
		case "url":
			creds.URL = value
		case "token":
			creds.Token = value
		}
	}
	if err := scanner.Err(); err != nil {
		return Credentials{}, err
	}
	return creds, nil
}

func truthy(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
