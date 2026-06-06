require "rails_helper"

RSpec.describe AgentEventAbbreviator do
  describe ".tool_use" do
    it "Bash → command on a single line" do
      out = described_class.tool_use("Bash", { "command" => "rg \"foo\" --type rb" })
      expect(out).to eq("● Bash(rg \"foo\" --type rb)")
    end

    it "Bash with multi-line command shows only the first line" do
      out = described_class.tool_use("Bash", { "command" => "set -euo pipefail\nrg foo\nrg bar" })
      expect(out).to eq("● Bash(set -euo pipefail)")
    end

    it "Read → file path" do
      expect(described_class.tool_use("Read", { "file_path" => "/syrus-home/foo.rb" }))
        .to eq("● Read(/syrus-home/foo.rb)")
    end

    it "shortens absolute paths under a supplied repository root" do
      root = "/syrus-home/.syrus/chat-workspaces/4/repositories/acme/widgets"

      expect(described_class.tool_use(
        "Read",
        { "file_path" => "#{root}/app/models/widget.rb" },
        path_roots: [ root ]
      ))
        .to eq("● Read(app/models/widget.rb)")

      expect(described_class.tool_use(
        "Bash",
        { "command" => "find #{root} -type f -name '*.rb'" },
        path_roots: [ root ]
      ))
        .to eq("● Bash(find . -type f -name '*.rb')")
    end

    it "shortens chat workspace repository paths to repository-relative paths" do
      root = "/syrus-home/.syrus/chat-workspaces/4"

      expect(described_class.tool_use(
        "Read",
        { "file_path" => "#{root}/repositories/acme/widgets/app/models/widget.rb" },
        path_roots: [ root ]
      ))
        .to eq("● Read(app/models/widget.rb)")
    end

    it "shortens workflow workspace paths to repository-relative paths" do
      root = "/syrus-home/.syrus/workflows/42"

      expect(described_class.tool_use(
        "Bash",
        { "command" => "rg queue_as #{root}/app/jobs" },
        path_roots: [ root ]
      ))
        .to eq("● Bash(rg queue_as app/jobs)")
    end

    it "leaves non-workspace paths intact" do
      expect(described_class.tool_use("Read", { "file_path" => "/tmp/syrus/app/models/widget.rb" }))
        .to eq("● Read(/tmp/syrus/app/models/widget.rb)")
    end

    it "Edit and Write → file path" do
      expect(described_class.tool_use("Edit", { "file_path" => "x.rb" })).to include("Edit(x.rb)")
      expect(described_class.tool_use("Write", { "file_path" => "x.rb" })).to include("Write(x.rb)")
    end

    it "Glob → pattern" do
      expect(described_class.tool_use("Glob", { "pattern" => "**/*.rb" })).to eq("● Glob(**/*.rb)")
    end

    it "Grep → pattern, optionally with path" do
      expect(described_class.tool_use("Grep", { "pattern" => "foo" })).to eq("● Grep(foo)")
      expect(described_class.tool_use("Grep", { "pattern" => "foo", "path" => "app/" }))
        .to eq("● Grep(foo in app/)")
    end

    it "WebFetch → url" do
      expect(described_class.tool_use("WebFetch", { "url" => "https://example.com" }))
        .to eq("● WebFetch(https://example.com)")
    end

    it "WebSearch → query" do
      expect(described_class.tool_use("WebSearch", { "query" => "claude code" }))
        .to eq("● WebSearch(claude code)")
    end

    it "TodoWrite → item count" do
      expect(described_class.tool_use("TodoWrite", { "todos" => [ {}, {}, {} ] }))
        .to eq("● TodoWrite(3 item(s))")
    end

    it "MCP tools strip the mcp__server__ prefix from the displayed name" do
      out = described_class.tool_use("mcp__syrus__submit_summary", { "pr_title" => "Add greeting helper" })
      expect(out).to start_with("● submit_summary(")
      expect(out).to include("Add greeting helper")
    end

    it "unknown tools fall through to a JSON-ish input dump" do
      out = described_class.tool_use("Frobnicate", { "x" => 1, "y" => 2 })
      expect(out).to start_with("● Frobnicate(")
    end

    it "truncates very long inputs with an ellipsis" do
      long = "x" * 500
      out = described_class.tool_use("Bash", { "command" => long })
      expect(out.length).to be <= 200
      expect(out).to end_with("…)")
    end
  end

  describe ".tool_result" do
    it "string content shows the first line" do
      expect(described_class.tool_result("hello\nworld")).to eq("  ⎿ hello")
    end

    it "marks errors with an explicit ✗" do
      expect(described_class.tool_result("not found", error: true)).to start_with("  ⎿ ✗ ")
    end

    it "array content with text blocks joins them" do
      content = [ { "type" => "text", "text" => "first chunk" } ]
      expect(described_class.tool_result(content)).to eq("  ⎿ first chunk")
    end

    it "array content with tool_reference renders the referenced tool name" do
      content = [ { "type" => "tool_reference", "tool_name" => "AskUserQuestion" } ]
      expect(described_class.tool_result(content)).to eq("  ⎿ → AskUserQuestion")
    end

    it "nil content renders as (empty)" do
      expect(described_class.tool_result(nil)).to eq("  ⎿ (empty)")
    end

    it "truncates very long output" do
      out = described_class.tool_result("x" * 1000)
      expect(out.length).to be <= 200
      expect(out).to end_with("…")
    end
  end
end
