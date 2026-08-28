require "rails_helper"
require Rails.root.join("evals/lib/evals")

RSpec.describe Evals::TranscriptRenderer do
  def jsonl(*lines)
    lines.map(&:to_json).join("\n") + "\n"
  end

  describe ".render" do
    it "returns a placeholder for a blank transcript" do
      expect(described_class.render(nil)).to eq("(no transcript captured)")
      expect(described_class.render("")).to eq("(no transcript captured)")
    end

    it "renders assistant text, tool_use, and tool_result events into a readable log" do
      input = jsonl(
        { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "Resolving the conflict." } ] } },
        { "type" => "assistant", "message" => { "content" => [
          { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "rm -rf .git && git init" }, "id" => "u1" }
        ] } },
        { "type" => "user", "message" => { "content" => [
          { "type" => "tool_result", "tool_use_id" => "u1", "content" => "Reinitialized existing Git repository" }
        ] } }
      )

      text = described_class.render(input)

      expect(text).to include("[assistant] Resolving the conflict.")
      expect(text).to include("[tool_use] Bash")
      expect(text).to include("rm -rf .git && git init")
      expect(text).to include("[tool_result] Reinitialized existing Git repository")
    end

    it "marks a failed tool_result distinctly and normalizes array-shaped content blocks" do
      input = jsonl(
        { "type" => "assistant", "message" => { "content" => [
          { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "bundle exec rspec" }, "id" => "u1" }
        ] } },
        { "type" => "user", "message" => { "content" => [
          { "type" => "tool_result", "tool_use_id" => "u1", "is_error" => true,
            "content" => [ { "type" => "text", "text" => "command not found: bundle" } ] }
        ] } }
      )

      text = described_class.render(input)

      expect(text).to include("[tool_result(error)] command not found: bundle")
    end

    it "truncates very long tool_result content" do
      long_output = "x" * 2000
      input = jsonl(
        { "type" => "assistant", "message" => { "content" => [
          { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "cat big.log" }, "id" => "u1" }
        ] } },
        { "type" => "user", "message" => { "content" => [
          { "type" => "tool_result", "tool_use_id" => "u1", "content" => long_output }
        ] } }
      )

      text = described_class.render(input)

      expect(text).to include("truncated, 2000 chars total")
      expect(text.scan("x").size).to be < 2000
    end

    it "degrades gracefully instead of raising on malformed JSONL" do
      expect(described_class.render("not json at all\n")).to eq("")
    end
  end
end
