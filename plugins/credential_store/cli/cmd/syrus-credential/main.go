package main

import (
	"fmt"
	"os"

	credentialstore "github.com/tkadauke/syrus/plugins/credential_store/cli"
)

func main() {
	command := credentialstore.NewCredentialStoreCommand()
	command.SetArgs(os.Args[1:])
	if err := command.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
