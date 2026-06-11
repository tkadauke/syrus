package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRootCommandReportsMissingCredentials(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	command := NewRootCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetErr(&bytes.Buffer{})
	command.SetArgs([]string{})

	err := command.Execute()
	if err == nil {
		t.Fatal("expected missing credentials error")
	}
	if err.Error() != configureMessage {
		t.Fatalf("error = %q", err.Error())
	}
}

func TestConfigureCommandWritesCredentials(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	input := strings.NewReader("https://syrus.example.com\nsecret-token\n")
	output := &bytes.Buffer{}
	command := NewConfigureCommand()
	command.SetIn(input)
	command.SetOut(output)

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	contents, err := os.ReadFile(filepath.Join(home, ".syrus", "credentials"))
	if err != nil {
		t.Fatal(err)
	}
	if got := string(contents); got != "url=https://syrus.example.com\ntoken=secret-token\n" {
		t.Fatalf("credentials file = %q", got)
	}
}
