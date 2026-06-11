package render

import (
	"io"

	"github.com/charmbracelet/glamour"
	"golang.org/x/term"
)

type MarkdownRenderer struct {
	width int
}

func NewMarkdownRenderer(output io.Writer) MarkdownRenderer {
	width := 100
	if file, ok := output.(interface{ Fd() uintptr }); ok && term.IsTerminal(int(file.Fd())) {
		if terminalWidth, _, err := term.GetSize(int(file.Fd())); err == nil && terminalWidth > 20 {
			width = terminalWidth
		}
	}
	return MarkdownRenderer{width: width}
}

func (r MarkdownRenderer) Render(markdown string) (string, error) {
	renderer, err := glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(r.width),
	)
	if err != nil {
		return "", err
	}
	return renderer.Render(markdown)
}
