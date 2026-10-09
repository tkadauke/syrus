package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/spf13/cobra"
)

func TestSkillInstallWritesTheClaudeSkill(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	output := &bytes.Buffer{}
	command := NewSkillCommand()
	command.SetOut(output)
	command.SetArgs([]string{"install"})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	target := filepath.Join(home, ".claude", "skills", "syrus", "SKILL.md")
	contents, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}

	skill := string(contents)
	if !strings.HasPrefix(skill, "---\nname: syrus\n") {
		t.Fatalf("skill missing frontmatter: %q", skill[:80])
	}
	for _, fragment := range []string{
		"syrus inbox",
		"syrus checkout JOB-<id>",
		"syrus approve",
		"Only approve when the user",
		"syrus login",
	} {
		if !strings.Contains(skill, fragment) {
			t.Fatalf("skill missing %q", fragment)
		}
	}

	if !strings.Contains(output.String(), target) {
		t.Fatalf("output should name the target path, got %q", output.String())
	}
}

// Every `syrus <verb> [<subverb>]` the skill documents must resolve in the
// real command tree. The skill once taught `syrus job view` while the
// actual verb was `job show` — an agent following it ran a nonexistent
// command, which is the exact failure mode a skill exists to prevent.
func TestSkillDocumentsOnlyRealCommands(t *testing.T) {
	registered := map[string]bool{}
	hasChildren := map[string]bool{}
	var walk func(prefix string, c *cobra.Command)
	walk = func(prefix string, c *cobra.Command) {
		for _, sub := range c.Commands() {
			name := strings.Fields(sub.Use)[0]
			full := strings.TrimSpace(prefix + " " + name)
			registered[full] = true
			hasChildren[full] = len(sub.Commands()) > 0
			walk(full, sub)
		}
	}
	walk("", NewRootCommand())

	// `syrus verb` or `syrus verb subverb` mentions; ALL-CAPS and
	// bracketed/placeholder tokens are arguments, not subcommands.
	mention := regexp.MustCompile("`syrus ([a-z][a-z0-9-]*)( [a-z][a-z0-9-]*)?")
	for _, match := range mention.FindAllStringSubmatch(skillContents(), -1) {
		full := match[1] + match[2]
		if registered[full] {
			continue
		}
		// A trailing lowercase word after a LEAF command is an argument
		// (`syrus chat my-chat ...`). After a PARENT command it must be a
		// real subcommand — that's exactly how `job view` slipped in.
		if match[2] != "" && registered[match[1]] && !hasChildren[match[1]] {
			continue
		}
		t.Errorf("skill documents `syrus %s`, which is not a registered command", full)
	}
}

func TestSkillDocumentedJSONSupportMatchesRegisteredFlags(t *testing.T) {
	catalog := RenderCommandCatalog(NewRootCommand())
	for _, entry := range CommandCatalog(NewRootCommand()) {
		rowPrefix := "| `" + markdownCell(entry.Use) + "` |"
		rowStart := strings.Index(catalog, rowPrefix)
		if rowStart == -1 {
			t.Fatalf("generated catalog missing %s", entry.Use)
		}
		rowEnd := strings.Index(catalog[rowStart:], "\n")
		row := catalog[rowStart:]
		if rowEnd >= 0 {
			row = catalog[rowStart : rowStart+rowEnd]
		}
		documented := strings.HasSuffix(row, " | yes |")
		if documented != entry.JSONSupport {
			t.Errorf("%s JSON support documented=%v registered=%v", entry.Path, documented, entry.JSONSupport)
		}
	}
}

func TestSkillInstallHonorsDirFlagAndOverwrites(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "syrus", "SKILL.md")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}

	command := NewSkillCommand()
	command.SetOut(&bytes.Buffer{})
	command.SetArgs([]string{"install", "--dir", dir})

	if err := command.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	contents, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) == "stale" {
		t.Fatal("install should overwrite an existing skill file")
	}
}
