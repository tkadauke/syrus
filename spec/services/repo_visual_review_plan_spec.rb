require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RepoVisualReviewPlan do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:job) { Factories.job_record(user: user, repository: repository, branch_name: "feature") }

  around do |example|
    @data_root = Pathname.new(Dir.mktmpdir("syrus-repo-visual-review-plan-data"))
    previous_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
    example.run
    ENV["SYRUS_DATA_ROOT"] = previous_root
    FileUtils.rm_rf(@data_root)
  end

  def loaded(config: nil, source: "none", note: nil)
    RepoDefaultBranchSyrusYml::Result.new(config: config, source: source, note: note)
  end

  def parse(yaml)
    SyrusYml.new(yaml).parse
  end

  def write_bare_clone(files:)
    work_dir = Dir.mktmpdir("syrus-repo-visual-review-plan-work")
    system("git", "init", "-q", "-b", "main", work_dir, exception: true)
    system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
    files.each do |path, content|
      full_path = File.join(work_dir, path)
      FileUtils.mkdir_p(File.dirname(full_path))
      File.write(full_path, content)
    end
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "main", exception: true)

    clone_path = RepositoryBareClone.path_for(repository)
    FileUtils.mkdir_p(clone_path.dirname)
    system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  describe ".from_syrus_yml" do
    it "falls back to the instance default when the shared loader has no config" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(true)

      result = described_class.from_syrus_yml(loaded(note: "no GitHub credentials"))

      expect(result).to be_enabled
      expect(result.note).to eq("no GitHub credentials")
    end

    it "enables from the parsed config, overriding the instance default" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(false)
      config = parse(<<~YAML)
        visual_review:
          enabled: true
          rounds: 2
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).to be_enabled
      expect(result.rounds).to eq(2)
      expect(result.source).to eq(".syrus.yml")
    end

    it "defers to the instance default when the block is present but enabled is omitted" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      config = parse(<<~YAML)
        visual_review:
          rounds: 3
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).to be_enabled
      expect(result.rounds).to eq(3)
      expect(result.source).to eq(".syrus.yml")
    end

    it "disables via explicit repository opt-out, overriding an enabled instance default" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      config = parse(<<~YAML)
        visual_review:
          enabled: false
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).not_to be_enabled
      expect(result.source).to eq(".syrus.yml")
    end

    it "falls back to the instance-wide default when visual_review is not configured" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(false)
      config = parse("prepare: []\n")

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).not_to be_enabled
      expect(result.note).to eq("no visual_review configured")
    end
  end

  describe ".for_job" do
    it "resolves through RepoDefaultBranchSyrusYml.for_job" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(false)
      fallback_job = instance_double(Job)
      allow(RepoDefaultBranchSyrusYml).to receive(:for_job).with(fallback_job).and_return(loaded(note: "GitHub client unavailable"))

      result = described_class.for_job(fallback_job)

      expect(result).not_to be_enabled
      expect(result.note).to eq("GitHub client unavailable")
    end

    it "enables visual review when a nested preview project opts in and the root/global plan is disabled" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(false)
      write_bare_clone(
        files: {
          ".syrus.yml" => "prepare: []\n",
          "apps/web/.syrus.yml" => <<~YAML
            project:
              id: web
            preview:
              start: npm run dev
            visual_review:
              enabled: true
              rounds: 3
          YAML
        }
      )
      allow(RepoDefaultBranchSyrusYml).to receive(:for_job).with(job).and_return(
        loaded(config: parse("prepare: []\n"), source: ".syrus.yml")
      )

      result = described_class.for_job(job)

      expect(result).to be_enabled
      expect(result.rounds).to eq(3)
      expect(result.source).to include(".syrus.yml", "project .syrus.yml")
    end
  end
end
