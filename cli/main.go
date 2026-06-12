package main

import (
	"os"

	"github.com/tkadauke/syrus/cli/cmd"
)

func main() {
	os.Exit(cmd.Execute(os.Args[1:]))
}
