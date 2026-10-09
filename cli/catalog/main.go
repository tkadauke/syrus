package main

import (
	"fmt"

	"github.com/tkadauke/syrus/cli/cmd"
)

func main() {
	fmt.Print(cmd.RenderCommandCatalog(cmd.NewRootCommand()))
}
