require "rails_helper"
require "tmpdir"

RSpec.describe LandingAgenticRebase do
  describe ".touched_files" do
    around do |example|
      Dir.mktmpdir("landing-agentic-rebase") do |dir|
        @dir = dir
        example.run
      end
    end

    def git(*args)
      out, status = Open3.capture2e("git", *args, chdir: @dir)
      raise "git #{args.join(' ')} failed: #{out}" unless status.success?

      out.strip
    end

    def commit_file(path, content, message)
      full = File.join(@dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      git("add", path)
      git("commit", "-q", "-m", message)
    end

    before do
      git("init", "-q", "-b", "main")
      git("config", "user.email", "t@example.com")
      git("config", "user.name", "T")
      commit_file("shared.txt", "one\ntwo\nthree\n", "base")
      commit_file("docs/readme.md", "docs\n", "docs")
      git("checkout", "-q", "-b", "feature")
      commit_file("shared.txt", "one\nfeature\nthree\n", "feature edits shared")
      commit_file("app/feature.rb", "feature\n", "feature adds app file")
      @pre_head = git("rev-parse", "HEAD")
      git("checkout", "-q", "main")
      commit_file("shared.txt", "one\nmain\nthree\n", "main edits shared")
      commit_file("lib/unrelated.rb", "main\n", "main adds lib file")
      @base = git("rev-parse", "HEAD")
      git("checkout", "-q", "feature")
    end

    def resolve_rebase(extra_files: {})
      expect { git("rebase", @base) }.to raise_error(/failed/)
      File.write(File.join(@dir, "shared.txt"), "one\nresolved\nthree\n")
      extra_files.each do |path, content|
        FileUtils.mkdir_p(File.dirname(File.join(@dir, path)))
        File.write(File.join(@dir, path), content)
      end
      git("add", "-A")
      Open3.capture2e({ "GIT_EDITOR" => "true" }, "git", "rebase", "--continue", chdir: @dir)
    end

    it "names only the conflicted file the agent had to resolve" do
      resolve_rebase

      touched = described_class.touched_files(git: GitRunner.new, chdir: @dir, base_sha: @base, pre_head_sha: @pre_head)

      expect(touched).to eq([ "shared.txt" ])
    end

    it "also names files the agent edited beyond the conflict" do
      resolve_rebase(extra_files: { "docs/readme.md" => "docs changed by agent\n" })

      touched = described_class.touched_files(git: GitRunner.new, chdir: @dir, base_sha: @base, pre_head_sha: @pre_head)

      expect(touched).to eq([ "docs/readme.md", "shared.txt" ])
    end

    it "is nil when the pre-rebase head is unknown" do
      expect(described_class.touched_files(git: GitRunner.new, chdir: @dir, base_sha: @base, pre_head_sha: nil)).to be_nil
    end

    it "is nil when git cannot find the commits" do
      resolve_rebase

      expect(described_class.touched_files(git: GitRunner.new, chdir: @dir, base_sha: "f" * 40, pre_head_sha: @pre_head)).to be_nil
    end
  end

  describe ".recorded_for" do
    let(:job) { Factories.job }
    let(:workflow) { job.workflows.last }

    it "returns the record for exactly this head and ignores any other head" do
      described_class.record!(workflow: workflow, head_sha: "head1", base_sha: "base1", base_ref: "main", pre_head_sha: "pre1", touched_files: %w[b.rb a.rb])

      record = described_class.recorded_for(workflow: Workflow.new, job: job, head_sha: "head1")

      expect(record).to include("pre_head_sha" => "pre1", "base_ref" => "main", "touched_files" => %w[a.rb b.rb])
      expect(described_class.recorded_for(workflow: Workflow.new, job: job, head_sha: "head2")).to be_nil
      expect(described_class.recorded_for(workflow: Workflow.new, job: job, head_sha: nil)).to be_nil
    end
  end

  describe ".partition" do
    let(:grader_struct) { Struct.new(:name, :required, :metadata) }
    let(:graph) { instance_double(TargetGraph) }
    let(:fingerprints) { { "command_fingerprint" => "cmd", "environment_fingerprint" => "env" } }
    let(:rspec) { grader_struct.new("rspec", true, {}) }
    let(:manifest) do
      {
        "targets" => [
          { "target_label" => "//:grade/rspec", "outcome" => GraderOutcome::PASSED, "has_evidence" => true, "command_fingerprint" => "cmd", "environment_fingerprint" => "env" },
          { "target_label" => "//:grade/lint", "outcome" => GraderOutcome::TEST_FAILED, "has_evidence" => true, "command_fingerprint" => "cmd", "environment_fingerprint" => "env" }
        ]
      }
    end

    def partition(graders, touched, manifest: self.manifest, fingerprints: self.fingerprints)
      described_class.partition(
        graders: graders,
        touched_files: touched,
        manifest: manifest,
        target_graph: graph,
        label_for: ->(grader) { "//:grade/#{grader.name}" },
        fingerprints_for: ->(_grader) { fingerprints }
      )
    end

    def selection(affected, reason = "reason")
      TargetGraph::Selection.new(target: nil, affected: affected, reason: reason)
    end

    it "carries a grader whose scope no touched file reaches" do
      allow(graph).to receive(:affected).with("//:grade/rspec", changed_files: [ "docs/a.md" ]).and_return(selection(false))

      result = partition([ rspec ], [ "docs/a.md" ])

      expect(result.rerun).to be_empty
      expect(result.carried.map(&:first)).to eq([ rspec ])
      expect(result.carried.first.last).to include("none inside //:grade/rspec's scope")
    end

    it "re-runs a grader whose scope covers a touched file" do
      allow(graph).to receive(:affected).and_return(selection(true, "repo-wide (no source scope declared)"))

      result = partition([ rspec ], [ "app/a.rb" ])

      expect(result.carried).to be_empty
      expect(result.rerun.first.last).to include("agent-touched files reach //:grade/rspec")
    end

    it "carries everything when the agent changed nothing beyond the mechanical rebase" do
      result = partition([ rspec ], [])

      expect(result.carried.map(&:first)).to eq([ rspec ])
    end

    it "re-runs graders the prior validation did not conclusively pass" do
      lint = grader_struct.new("lint", true, {})
      other = grader_struct.new("other", true, {})

      result = partition([ lint, other ], [])

      expect(result.carried).to be_empty
      expect(result.rerun.map { |grader, _| grader.name }).to eq(%w[lint other])
    end

    it "re-runs a grader whose command fingerprint changed, is optional, or sets always_rerun" do
      expect(partition([ rspec ], [], fingerprints: fingerprints.merge("command_fingerprint" => "new")).carried).to be_empty
      expect(partition([ grader_struct.new("rspec", false, {}) ], []).carried).to be_empty
      expect(partition([ grader_struct.new("rspec", true, { "always_rerun" => true }) ], []).carried).to be_empty
    end
  end
end
