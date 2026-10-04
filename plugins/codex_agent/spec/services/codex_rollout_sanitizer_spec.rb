require "rails_helper"

RSpec.describe CodexRolloutSanitizer do
  def line(obj) = JSON.generate(obj)

  describe ".native?" do
    it "recognizes a rollout Codex wrote itself" do
      jsonl = line(type: "session_meta", payload: { id: "019e" }) + "\n"

      expect(described_class.native?(jsonl)).to be(true)
    end

    # The transcript synthesized from ChatMessage rows uses Codex's stdout
    # event vocabulary. Codex cannot resume from it, which is the whole reason
    # this predicate exists.
    it "rejects a synthesized stdout-event transcript" do
      jsonl = line(type: "thread.started", thread_id: "019e") + "\n"

      expect(described_class.native?(jsonl)).to be(false)
    end

    it "rejects blank and unparseable content" do
      expect(described_class.native?(nil)).to be(false)
      expect(described_class.native?("")).to be(false)
      expect(described_class.native?("not json\n")).to be(false)
    end
  end

  describe ".call" do
    it "redacts invocation tokens wherever they appear in the JSON" do
      jsonl = [
        line(type: "session_meta", payload: { id: "019e" }),
        line(type: "event_msg", payload: { item: { stdout: "SYRUS_MCP_PROXY_INVOCATION_CONTEXT=tok-abc123 tail" } }),
        line(type: "event_msg", payload: { item: { command: [ "syrus-mcp-proxy", "--token", "tok-def456" ] } }),
        line(type: "response_item", payload: { content: [ { text: "X-Syrus-Invocation-Context: tok-ghi789" } ] })
      ].join("\n") + "\n"

      out = described_class.call(jsonl)

      expect(out).not_to include("tok-abc123")
      expect(out).not_to include("tok-def456")
      expect(out).not_to include("tok-ghi789")
      expect(out).to include("[redacted]")
    end

    it "preserves line order, line types and the trailing newline" do
      jsonl = [
        line(type: "session_meta", payload: { id: "019e" }),
        line(type: "event_msg", payload: { item: { stdout: "clean" } }),
        line(type: "response_item", payload: { output: "also clean" })
      ].join("\n") + "\n"

      out = described_class.call(jsonl)

      expect(out.lines.map { |l| JSON.parse(l)["type"] })
        .to eq(%w[session_meta event_msg response_item])
      expect(out).to end_with("\n")
    end

    it "keeps the rollout resumable after redaction" do
      jsonl = [
        line(type: "session_meta", payload: { id: "019e" }),
        line(type: "event_msg", payload: { item: { stdout: "SYRUS_MCP_PROXY_INVOCATION_CONTEXT=tok-abc123" } })
      ].join("\n") + "\n"

      expect(described_class.native?(described_class.call(jsonl))).to be(true)
    end

    # Dropping a line would silently truncate the transcript, which is worse
    # than leaving a line we could not parse.
    it "passes through lines that do not parse rather than dropping them" do
      jsonl = "not json\n" + line(type: "event_msg", payload: { item: { stdout: "ok" } }) + "\n"

      out = described_class.call(jsonl)

      expect(out.lines.size).to eq(2)
      expect(out.lines.first).to eq("not json\n")
    end

    it "returns blank input unchanged" do
      expect(described_class.call(nil)).to be_nil
      expect(described_class.call("")).to eq("")
    end
  end
end
