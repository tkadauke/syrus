require "rails_helper"
require "tmpdir"

RSpec.describe CoverageAnalysis::ChangeFrequency do
  around do |ex|
    Dir.mktmpdir("syrus-change-frequency") { |dir| @dir = dir; ex.run }
  end

  def sh(*args, env: {})
    ok = system(env, *args, chdir: @dir, out: File::NULL, err: File::NULL)
    raise "command failed: #{args.join(' ')}" unless ok
  end

  def init_repo
    sh("git", "init", "-q", "-b", "main")
    sh("git", "config", "user.email", "test@example.com")
    sh("git", "config", "user.name", "Test")
  end

  def commit(file, content, days_ago:, message: "update #{file}")
    File.write(File.join(@dir, file), content)
    sh("git", "add", file)
    date = days_ago.days.ago.utc.iso8601
    sh("git", "commit", "-q", "-m", message, env: { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date })
  end

  describe ".for" do
    it "counts commits per file within the lookback window, excluding older commits" do
      init_repo
      # Committed oldest-first, like real history — git log --since stops
      # walking once it hits a commit older than the cutoff, so a fixture
      # with commit dates out of chronological order would break the
      # traversal rather than exercise the intended filtering.
      commit("cold.rb", "v1", days_ago: 200)
      commit("hot.rb", "v1", days_ago: 60)
      commit("hot.rb", "v2", days_ago: 10)
      commit("hot.rb", "v3", days_ago: 1)

      counts = described_class.for(@dir, lookback_days: 90)

      expect(counts["hot.rb"]).to eq(3)
      expect(counts).not_to have_key("cold.rb")
    end

    it "defaults to a 90-day lookback window" do
      init_repo
      commit("old.rb", "v1", days_ago: 200)
      commit("recent.rb", "v1", days_ago: 5)

      counts = described_class.for(@dir)

      expect(counts["recent.rb"]).to eq(1)
      expect(counts).not_to have_key("old.rb")
    end

    it "counts a single commit touching multiple files against each file" do
      init_repo
      File.write(File.join(@dir, "a.rb"), "a")
      File.write(File.join(@dir, "b.rb"), "b")
      sh("git", "add", "a.rb", "b.rb")
      date = 1.day.ago.utc.iso8601
      sh("git", "commit", "-q", "-m", "add both", env: { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date })

      counts = described_class.for(@dir, lookback_days: 90)

      expect(counts["a.rb"]).to eq(1)
      expect(counts["b.rb"]).to eq(1)
    end

    it "returns an empty hash instead of raising when the path has no git history" do
      expect(described_class.for(@dir, lookback_days: 90)).to eq({})
    end
  end
end
