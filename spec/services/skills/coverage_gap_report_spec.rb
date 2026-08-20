require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Skills::CoverageGapReport do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  describe ".definition" do
    it "declares an optional lookback_days integer parameter" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("coverage-gap-report")
      expect(definition.description).to match(/read-only/i)
      expect(definition.parameters.size).to eq(1)

      lookback = definition.parameters.first
      expect(lookback.key).to eq("lookback_days")
      expect(lookback.type).to eq("integer")
      expect(lookback.required).to eq(false)
      expect(lookback.default).to eq(90)
    end

    it "renders the {{lookback_days}} placeholder for Skills::Renderer to substitute" do
      expect(described_class.definition.instructions).to include("{{lookback_days}}")
    end

    it "instructs the agent to write a report and make no changes" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/report, not an implementation task/i)
      expect(instructions).to match(/make no\s+commit|do not\s+commit anything/i)
      expect(instructions).to match(/no diff/i)
    end

    it "does not report a pre-computed ranking without a repository and workspace_path" do
      expect(described_class.definition.instructions).not_to include("Automated pre-computed ranking")
    end
  end

  describe ".definition(repository:, workspace_path:)" do
    around do |ex|
      Dir.mktmpdir("syrus-coverage-gap-report") { |dir| @dir = dir; ex.run }
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

    def commit(file, days_ago:)
      path = File.join(@dir, file)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, SecureRandom.hex(4))
      sh("git", "add", file)
      date = days_ago.days.ago.utc.iso8601
      sh("git", "commit", "-q", "-m", "update #{file}", env: { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date })
    end

    def definition_for(**opts)
      described_class.definition(workspace_path: @dir, repository: repository, **opts)
    end

    it "does not report a pre-computed ranking without a repository" do
      instructions = described_class.definition(workspace_path: @dir).instructions
      expect(instructions).not_to include("Automated pre-computed ranking")
    end

    it "does not report a pre-computed ranking without a workspace_path" do
      instructions = described_class.definition(repository: repository).instructions
      expect(instructions).not_to include("Automated pre-computed ranking")
    end

    it "reports coverage data as unavailable when no CoverageSnapshot exists yet" do
      init_repo

      instructions = definition_for.instructions

      expect(instructions).to include("Automated pre-computed ranking")
      expect(instructions).to match(/no coverage data is available/i)
    end

    context "with a recorded CoverageSnapshot on the default branch" do
      before do
        init_repo
        # Committed oldest-first, like real history — git log --since stops
        # walking once it hits a commit older than the cutoff, so a fixture
        # with commit dates out of chronological order would break the
        # traversal rather than exercise the intended filtering.
        commit("app/stable_file.rb", days_ago: 200)
        commit("app/hot_path.rb", days_ago: 10)
        commit("app/hot_path.rb", days_ago: 5)
        commit("app/hot_path.rb", days_ago: 1)

        job = Factories.job(repository: repository)
        Factories.coverage_snapshot(
          repository: repository,
          job: job,
          branch: "main",
          lines_pct: 40.0,
          data: {
            "app/hot_path.rb"    => { "lines_pct" => 20.0, "branches_pct" => 10.0 },
            "app/stable_file.rb" => { "lines_pct" => 20.0, "branches_pct" => 10.0 },
            "app/well_tested.rb" => { "lines_pct" => 99.0, "branches_pct" => 95.0 }
          }
        )
      end

      it "ranks the frequently-changed low-coverage file above the equally-low but stable one" do
        instructions = definition_for.instructions

        hot_index = instructions.index("app/hot_path.rb")
        stable_index = instructions.index("app/stable_file.rb")
        expect(hot_index).not_to be_nil
        expect(stable_index).not_to be_nil
        expect(hot_index).to be < stable_index
      end

      it "includes the coverage percentage and change count in the rendered table" do
        instructions = definition_for.instructions

        expect(instructions).to match(%r{`app/hot_path\.rb`\s*\|\s*20\.0%\s*\|\s*3\s*\|})
      end

      it "reflects a shorter lookback_days arg in the reported window and excludes older commits" do
        instructions = definition_for(args: { "lookback_days" => 3 }).instructions

        expect(instructions).to match(%r{`app/hot_path\.rb`\s*\|\s*20\.0%\s*\|\s*1\s*\|})
      end

      it "does not leak a CoverageSnapshot belonging to a different repository" do
        other_repository = Factories.repository(user: user, owner: "acme", name: "other")
        other_job = Factories.job(repository: other_repository)
        Factories.coverage_snapshot(
          repository: other_repository, job: other_job, branch: "main",
          data: { "other/file.rb" => { "lines_pct" => 0.0, "branches_pct" => 0.0 } }
        )

        instructions = definition_for.instructions

        expect(instructions).not_to include("other/file.rb")
      end
    end
  end
end
