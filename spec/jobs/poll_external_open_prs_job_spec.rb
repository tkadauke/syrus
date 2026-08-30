require "rails_helper"
require "ostruct"
require "tmpdir"
require "fileutils"

RSpec.describe PollExternalOpenPrsJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets",
                         external_pr_ingestion_enabled: true)
  end
  let(:slug) { "acme/widgets" }

  def pr(number:, head_ref: "feature/cool-thing", head_repo: "acme/widgets",
         base_repo: "acme/widgets", author: "contributor", title: "Some feature", body: nil)
    OpenStruct.new(
      number: number,
      title: title,
      body: body,
      head: OpenStruct.new(
        ref: head_ref,
        repo: OpenStruct.new(full_name: head_repo)
      ),
      base: OpenStruct.new(
        ref: "main",
        repo: OpenStruct.new(full_name: base_repo)
      ),
      user: OpenStruct.new(login: author)
    )
  end

  before do
    allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([])
  end

  describe "ingestion" do
    it "creates external_pr Jobs for open PRs on the repo" do
      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 10, head_ref: "feature/add-widget", author: "alice", title: "Add widget")
      ])

      expect {
        described_class.perform_now(repository.id)
      }.to change(Job, :count).by(1)

      job = Job.find_by!(repository: repository, external_pr_number: 10)
      expect(job.kind).to eq("external_pr")
      expect(job.state).to eq("implemented")
      expect(job.external_pr_author).to eq("alice")
      expect(job.issue_title).to eq("Add widget")
    end

    it "stores the PR head branch as branch_name" do
      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 10, head_ref: "feature/add-widget")
      ])

      described_class.perform_now(repository.id)

      job = Job.find_by!(repository: repository, external_pr_number: 10)
      expect(job.branch_name).to eq("feature/add-widget")
    end

    it "marks same-repo PRs as not a fork" do
      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 10, head_repo: "acme/widgets", base_repo: "acme/widgets")
      ])

      described_class.perform_now(repository.id)

      job = Job.find_by!(repository: repository, external_pr_number: 10)
      expect(job.external_pr_fork).to eq(false)
    end

    it "marks fork PRs as a fork" do
      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 10, head_repo: "contributor/widgets", base_repo: "acme/widgets")
      ])

      described_class.perform_now(repository.id)

      job = Job.find_by!(repository: repository, external_pr_number: 10)
      expect(job.external_pr_fork).to eq(true)
    end

    it "dispatches an external_pr_ingest workflow on ingestion" do
      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 10)
      ])

      expect {
        described_class.perform_now(repository.id)
      }.to change(Workflow, :count).by(1)

      workflow = Workflow.last
      expect(workflow.trigger_kind).to eq("external_pr_ingest")
      expect(workflow.work_unit).to have_attributes(kind: "external_pr_ingest")
    end

    it "ingests multiple PRs in one pass" do
      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 11, title: "First"),
        pr(number: 12, title: "Second")
      ])

      expect {
        described_class.perform_now(repository.id)
      }.to change(Job, :count).by(2)
    end

    it "skips PRs whose head branch starts with 'syrus/'" do
      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 20, head_ref: "syrus/direct-99"),
        pr(number: 21, head_ref: "feature/human-work")
      ])

      expect {
        described_class.perform_now(repository.id)
      }.to change(Job, :count).by(1)

      expect(Job.find_by(repository: repository, external_pr_number: 20)).to be_nil
      expect(Job.find_by(repository: repository, external_pr_number: 21)).to be_present
    end

    it "does not skip a fork's 'syrus/'-prefixed branch — it's a different instance's export, not a same-repo Syrus PR" do
      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 22, head_ref: "syrus/direct-99", head_repo: "someone-else/widgets")
      ])

      expect {
        described_class.perform_now(repository.id)
      }.to change(Job, :count).by(1)

      expect(Job.find_by(repository: repository, external_pr_number: 22)).to be_present
    end

    it "skips PRs that already have a Job with that external_pr_number" do
      existing = Factories.job(repository: repository, issue_number: 99)
      existing.update!(external_pr_number: 30)

      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 30)
      ])

      expect {
        described_class.perform_now(repository.id)
      }.not_to change(Job, :count)
    end

    it "skips PRs that already have a Job with that pr_number" do
      existing = Factories.job_record(repository: repository, issue_number: 99, state: "approved", pr_number: 30)

      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: existing.pr_number, head_ref: "local-redo-chat-gutters")
      ])

      expect {
        described_class.perform_now(repository.id)
      }.not_to change(Job, :count)

      expect(Job.find_by(repository: repository, external_pr_number: existing.pr_number)).to be_nil
    end

    it "skips PRs that already have an external_pr kind Job" do
      Job.create!(user: user, repository: repository, kind: "external_pr",
                  state: "implemented", external_pr_number: 31)

      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 31)
      ])

      expect {
        described_class.perform_now(repository.id)
      }.not_to change(Job, :count)
    end
  end

  describe "provenance classification (external_prs.ingest.enabled: true)" do
    around do |example|
      @data_root = Pathname.new(Dir.mktmpdir("syrus-data"))
      previous_root = ENV["SYRUS_DATA_ROOT"]
      ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
      example.run
      ENV["SYRUS_DATA_ROOT"] = previous_root
      FileUtils.rm_rf(@data_root)
    end

    def write_bare_clone(repo, syrus_yml:)
      work_dir = Dir.mktmpdir("syrus-work")
      system("git", "init", "-q", "-b", "main", work_dir, exception: true)
      system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
      system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
      File.write(File.join(work_dir, ".syrus.yml"), syrus_yml)
      system("git", "-C", work_dir, "add", ".", exception: true)
      system("git", "-C", work_dir, "commit", "-q", "-m", "init", exception: true)

      clone_path = RepositoryBareClone.path_for(repo)
      FileUtils.mkdir_p(clone_path.dirname)
      system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
    ensure
      FileUtils.rm_rf(work_dir) if work_dir
    end

    it "attaches a per-job export from a registered fork to the existing Job instead of creating a new one" do
      write_bare_clone(repository, syrus_yml: "external_prs:\n  ingest:\n    enabled: true\n")
      fork = Factories.repository(user: user, owner: "casey", upstream_repository: repository)
      source_job = Factories.job_record(user: user, repository: fork, issue_number: 7)

      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 40, head_ref: "syrus/direct-#{source_job.id}", head_repo: fork.slug)
      ])

      expect {
        described_class.perform_now(repository.id)
      }.not_to change(Job, :count)

      expect(source_job.pr_links.find_by(role: JobPrLink::ROLE_EXTERNAL_INGEST, pr_number: 40)).to be_present
    end

    it "creates an umbrella Epic for a whole-branch export from a registered fork" do
      write_bare_clone(repository, syrus_yml: "external_prs:\n  ingest:\n    enabled: true\n")
      fork = Factories.repository(user: user, owner: "bob", default_branch: "main", upstream_repository: repository)

      allow_any_instance_of(GithubClient).to receive(:list_open_pull_requests).and_return([
        pr(number: 41, head_ref: "main", head_repo: fork.slug)
      ])

      expect {
        described_class.perform_now(repository.id)
      }.to change(Job, :count).by(1).and change(Epic, :count).by(1)

      job = Job.find_by!(repository: repository, external_pr_number: 41)
      expect(job.epic_id).to eq(Epic.last.id)
    end
  end

  describe "guards" do
    it "no-ops when the repository does not exist" do
      expect_any_instance_of(GithubClient).not_to receive(:list_open_pull_requests)
      described_class.perform_now(-1)
    end

    it "no-ops when external_pr_ingestion_enabled is false" do
      repository.update!(external_pr_ingestion_enabled: false)
      expect_any_instance_of(GithubClient).not_to receive(:list_open_pull_requests)
      described_class.perform_now(repository.id)
    end

    it "no-ops when the repository is archived" do
      repository.update!(archived_at: Time.current)
      expect_any_instance_of(GithubClient).not_to receive(:list_open_pull_requests)
      described_class.perform_now(repository.id)
    end
  end
end
