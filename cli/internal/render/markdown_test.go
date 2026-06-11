package render

import (
	"bytes"
	"strings"
	"testing"
)

func TestMarkdownRendererRendersCommonChatMarkdown(t *testing.T) {
	renderer := NewMarkdownRenderer(&bytes.Buffer{})

	out, err := renderer.Render("# Plan\n\nUse **bold** text.\n\n```ruby\nputs :ok\n```\n")
	if err != nil {
		t.Fatalf("Render returned error: %v", err)
	}
	if !strings.Contains(out, "Plan") {
		t.Fatalf("rendered markdown did not include header text: %q", out)
	}
	if !strings.Contains(out, "bold") {
		t.Fatalf("rendered markdown did not include bold text: %q", out)
	}
	if !strings.Contains(out, "puts") {
		t.Fatalf("rendered markdown did not include code block: %q", out)
	}
}
