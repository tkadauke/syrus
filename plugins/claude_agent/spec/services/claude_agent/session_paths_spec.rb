require "rails_helper"

RSpec.describe ClaudeAgent::SessionPaths do
  describe ".canonical_path_for" do
    it "encodes the cwd by replacing every / and . with -" do
      path = described_class.canonical_path_for(home: "/home/rails", cwd: "/syrus-home/.syrus/runs/40", session_id: "abc-123")
      # claude-code encodes both / and . to a single dash, so /.syrus
      # becomes --syrus (slash + dot → two dashes). Verified
      # empirically against a live worker — getting this wrong made
      # every session capture silently miss the JSONL on disk, which
      # broke --resume across the board.
      expect(path).to eq("/home/rails/.claude/projects/-syrus-home--syrus-runs-40/abc-123.jsonl")
    end

    it "handles a trailing slash on cwd" do
      path = described_class.canonical_path_for(home: "/h", cwd: "/a/b/", session_id: "id")
      expect(path).to eq("/h/.claude/projects/-a-b-/id.jsonl")
    end

    it "encodes dots in path segments (not just slashes)" do
      path = described_class.canonical_path_for(home: "/h", cwd: "/a/.foo/b", session_id: "id")
      expect(path).to eq("/h/.claude/projects/-a--foo-b/id.jsonl")
    end
  end

  describe ".canonical_transcript_jsonl" do
    it "reads the canonical transcript when the session id is safe" do
      Dir.mktmpdir("claude-paths-spec-") do |home|
        path = described_class.canonical_path_for(home: home, cwd: "/work/.syrus", session_id: "abc-123")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "jsonl")

        expect(described_class.canonical_transcript_jsonl(home: home, cwd: "/work/.syrus", session_id: "abc-123")).to eq("jsonl")
      end
    end

    it "rejects unsafe session ids" do
      expect(described_class.canonical_transcript_jsonl(home: "/h", cwd: "/w", session_id: "../secret")).to be_nil
    end
  end

  describe ".canonical_subagents_dir_for" do
    it "points at the subagents directory sibling to the session's own jsonl file" do
      dir = described_class.canonical_subagents_dir_for(home: "/home/rails", cwd: "/syrus-home/.syrus/runs/40", session_id: "abc-123")
      expect(dir).to eq("/home/rails/.claude/projects/-syrus-home--syrus-runs-40/abc-123/subagents")
    end
  end
end
