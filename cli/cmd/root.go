package cmd

import (
	"fmt"
	"io"
	"net/http"
	"os"
)

type runner struct {
	stdout io.Writer
	stderr io.Writer
	getenv func(string) string
	client httpClient
}

type httpClient interface {
	Do(*http.Request) (*http.Response, error)
}

func Execute(args []string) int {
	return execute(args, os.Stdout, os.Stderr, os.Getenv, http.DefaultClient)
}

func execute(args []string, stdout io.Writer, stderr io.Writer, getenv func(string) string, client httpClient) int {
	r := runner{
		stdout: stdout,
		stderr: stderr,
		getenv: getenv,
		client: client,
	}

	if len(args) == 0 {
		fmt.Fprintln(stderr, "Usage: syrus <test-plan> ...")
		return 1
	}

	switch args[0] {
	case "test-plan":
		if err := r.runTestPlan(args[1:]); err != nil {
			fmt.Fprintf(stderr, "syrus test-plan failed: %v\n", err)
			return 1
		}
		return 0
	default:
		fmt.Fprintln(stderr, "Usage: syrus <test-plan> ...")
		return 1
	}
}
