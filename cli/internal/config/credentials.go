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
	ErrMissingCredentials    = errors.New("credentials file is missing")
	ErrIncompleteCredentials = errors.New("credentials are incomplete")
)

type Credentials struct {
	URL   string
	Token string
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
	return filepath.Join(home, ".syrus", "credentials"), nil
}

func LoadDefaultCredentials() (Credentials, error) {
	path, err := DefaultCredentialsPath()
	if err != nil {
		return Credentials{}, err
	}
	return LoadCredentials(path)
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
	return os.WriteFile(path, []byte(contents), 0600)
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
