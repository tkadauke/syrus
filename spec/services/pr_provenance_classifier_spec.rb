require "rails_helper"
require "ostruct"
require "tmpdir"
require "fileutils"

RSpec.describe PrProvenanceClassifier do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", default_branch: "main") }

  around do |example|
    @data_root = Pathname.new(Dir.mktmpdir("syrus-data"))
    previous_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
    example.run
    ENV["SYRUS_DATA_ROOT"] = previous_root
    FileUtils.rm_rf(@data_root)
  end

  def write_bare_clone(repo, syrus_yml: nil)
    work_dir = Dir.mktmpdir("syrus-work")
    system("git", "init", "-q", "-b", "main", work_dir, exception: true)
    system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
    File.write(File.join(work_dir, "README.md"), "hi") unless syrus_yml
    File.write(File.join(work_dir, ".syrus.yml"), syrus_yml) if syrus_yml
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "init", exception: true)

    clone_path = RepositoryBareClone.path_for(repo)
    FileUtils.mkdir_p(clone_path.dirname)
    system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  def pr(head_ref:, head_repo:, base_ref: "main", base_repo: nil, body: nil, number: 1)
    OpenStruct.new(
      number: number,
      body: body,
      head: OpenStruct.new(ref: head_ref, repo: OpenStruct.new(full_name: head_repo)),
      base: OpenStruct.new(ref: base_ref, repo: OpenStruct.new(full_name: base_repo || repository.slug))
    )
  end

  describe "when external_prs.ingest.enabled is not set" do
    it "always classifies external_unknown, even with a Syrus provenance marker present" do
      write_bare_clone(repository)
      marker = PrProvenanceMarker.stamp(kind: "syrus_promotion", job: Factories.job_record(user: user, repository: repository, issue_number: 1))

      classification = described_class.classify(
        repository: repository,
        pr: pr(head_ref: "syrus/promote-develop-main-1", head_repo: repository.slug, body: marker)
      )

      expect(classification).to eq("external_unknown")
    end
  end

  describe "with external_prs.ingest.enabled: true" do
    before { write_bare_clone(repository, syrus_yml: "external_prs:\n  ingest:\n    enabled: true\n") }

    it "classifies a hand-written PR from an unregistered fork as external_unknown (Story 10: Robin)" do
      classification = described_class.classify(
        repository: repository,
        pr: pr(head_ref: "fix-login", head_repo: "robin/widgets")
      )

      expect(classification).to eq("external_unknown")
    end

    it "classifies a per-job export branch from a registered fork as syrus_job_export (Story 10: Casey)" do
      fork = Factories.repository(user: user, owner: "casey", default_branch: "main", upstream_repository: repository)

      classification = described_class.classify(
        repository: repository,
        pr: pr(head_ref: "syrus/direct-123", head_repo: fork.slug)
      )

      expect(classification).to eq("syrus_job_export")
    end

    it "classifies a whole development-branch export from a registered fork as syrus_branch_export (Story 10: Bob)" do
      fork = Factories.repository(user: user, owner: "bob", default_branch: "main", upstream_repository: repository)
      write_bare_clone(fork)

      classification = described_class.classify(
        repository: repository,
        pr: pr(head_ref: "main", head_repo: fork.slug)
      )

      expect(classification).to eq("syrus_branch_export")
    end

    it "classifies a Syrus-branch-named PR from an unregistered fork as external_unknown" do
      classification = described_class.classify(
        repository: repository,
        pr: pr(head_ref: "syrus/direct-999", head_repo: "stranger/widgets")
      )

      expect(classification).to eq("external_unknown")
    end

    it "classifies a marker-stamped promotion PR as syrus_promotion regardless of heuristics" do
      job = Factories.job_record(user: user, repository: repository, issue_number: 1)
      marker = PrProvenanceMarker.stamp(kind: "syrus_promotion", job: job)

      classification = described_class.classify(
        repository: repository,
        pr: pr(head_ref: "syrus/promote-develop-main-#{job.id}", head_repo: repository.slug, body: marker)
      )

      expect(classification).to eq("syrus_promotion")
    end

    it "does not classify manual_hotfix when hotfix sync isn't configured" do
      classification = described_class.classify(
        repository: repository,
        pr: pr(head_ref: "hotfix/urgent-fix", head_repo: repository.slug, base_ref: "main")
      )

      expect(classification).to eq("external_unknown")
    end
  end

  describe "manual_hotfix (requires delivery.hotfix_sync configured alongside external_prs.ingest.enabled)" do
    before do
      write_bare_clone(repository, syrus_yml: <<~YAML)
        external_prs:
          ingest:
            enabled: true
        delivery:
          hotfix_sync:
            enabled: true
      YAML
    end

    it "classifies a same-repo PR landing directly on the release branch as manual_hotfix (Story 5/5A)" do
      classification = described_class.classify(
        repository: repository,
        pr: pr(head_ref: "hotfix/urgent-fix", head_repo: repository.slug, base_ref: "main")
      )

      expect(classification).to eq("manual_hotfix")
    end

    it "does not classify a same-repo Syrus branch as manual_hotfix" do
      classification = described_class.classify(
        repository: repository,
        pr: pr(head_ref: "syrus/hotfix-sync-main-develop-1", head_repo: repository.slug, base_ref: "main")
      )

      expect(classification).to eq("external_unknown")
    end
  end
end
