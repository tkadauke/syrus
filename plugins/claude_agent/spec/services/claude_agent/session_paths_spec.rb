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

    # Regression: on macOS /var is a symlink to /private/var. Claude Code
    # stores a session for a workspace under /var/... in the project named
    # after the resolved /private/var/... path, so encoding the path as given
    # put resume transcripts where Claude never looked.
    it "encodes the cwd with symlinks resolved, the way Claude Code reports it" do
      Dir.mktmpdir("claude-paths-spec-") do |dir|
        real = File.join(File.realpath(dir), "real", "workflows", "7")
        FileUtils.mkdir_p(real)
        File.symlink(File.join(File.realpath(dir), "real"), File.join(dir, "link"))
        linked_cwd = File.join(dir, "link", "workflows", "7")

        path = described_class.canonical_path_for(home: "/h", cwd: linked_cwd, session_id: "id")
        subagents = described_class.canonical_subagents_dir_for(home: "/h", cwd: linked_cwd, session_id: "id")

        expected_project = real.gsub(%r{[/.]}, "-")
        expect(path).to eq("/h/.claude/projects/#{expected_project}/id.jsonl")
        expect(subagents).to eq("/h/.claude/projects/#{expected_project}/id/subagents")
      end
    end

    it "resolves symlinks the same way before the workspace directory exists" do
      Dir.mktmpdir("claude-paths-spec-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "real"))
        File.symlink(File.join(File.realpath(dir), "real"), File.join(dir, "link"))
        not_yet_created = File.join(dir, "link", "workflows", "8")

        before = described_class.canonical_path_for(home: "/h", cwd: not_yet_created, session_id: "id")
        FileUtils.mkdir_p(not_yet_created)
        after = described_class.canonical_path_for(home: "/h", cwd: not_yet_created, session_id: "id")

        expect(before).to eq(after)
        expect(before).to include(File.join(File.realpath(dir), "real", "workflows", "8").gsub(%r{[/.]}, "-"))
      end
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
