require "rails_helper"
require "ostruct"

RSpec.describe PollExternalOpenPrsJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets",
                         external_pr_ingestion_enabled: true)
  end
  let(:slug) { "acme/widgets" }

  def pr(number:, head_ref: "feature/cool-thing", head_repo: "acme/widgets",
         base_repo: "acme/widgets", author: "contributor", title: "Some feature")
    OpenStruct.new(
      number: number,
      title: title,
      head: OpenStruct.new(
        ref: head_ref,
        repo: OpenStruct.new(full_name: head_repo)
      ),
      base: OpenStruct.new(
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
