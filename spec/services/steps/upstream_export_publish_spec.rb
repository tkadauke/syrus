require "rails_helper"
require "ostruct"

RSpec.describe Steps::UpstreamExportPublish do
  let(:user) { Factories.user }
  let(:canonical) { Factories.repository(user: user, owner: "acme-canonical", default_branch: "main") }
  let(:repository) { Factories.repository(user: user, owner: "forker", default_branch: "main", upstream_repository: canonical) }
  let(:job) { Factories.job_record(user: user, repository: repository, issue_number: 9, state: "approved", branch_name: "syrus/issue-9") }
  let(:workflow) { Workflows::UpstreamExport.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "upstream_export_publish") }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "upstream_export") }
  let(:handler) { described_class.new(run) }
  let(:client) { instance_double(GithubClient) }

  def stub_policy(target_branch:)
    allow(DeliveryPolicy).to receive(:for).with(repository: repository, job: job).and_return(
      instance_double(DeliveryPolicy, upstream_export_target_branch: target_branch)
    )
  end

  before do
    allow(GithubClient).to receive(:for).with(repository: canonical, user: user).and_return(client)
  end

  it "raises StepFailed when the repository has no in-instance upstream_repository" do
    repository.update!(upstream_repository: nil)
    stub_policy(target_branch: "main")

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /has no in-instance upstream_repository/)
  end

  it "raises StepFailed when the resolved target branch is blank" do
    stub_policy(target_branch: nil)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /could not resolve/)
  end

  context "opening a new PR (canonical has a configured intake/development branch)" do
    before do
      stub_policy(target_branch: "develop")
      allow(client).to receive(:open_pull_request_for_head).and_return(nil)
      allow(client).to receive(:create_pull_request).and_return(OpenStruct.new(number: 900))
    end

    it "opens a cross-repo PR from the job's own branch (head_repository) to canonical's resolved target branch" do
      handler.call

      expect(client).to have_received(:create_pull_request).with(
        canonical.slug,
        base: "develop",
        head: "#{repository.owner}:syrus/issue-9",
        title: kind_of(String),
        body: kind_of(String)
      )
    end

    it "records a JobPrLink with role upstream_export carrying the resolved refs" do
      handler.call

      link = job.pr_links.find_by!(role: JobPrLink::ROLE_UPSTREAM_EXPORT)
      expect(link.source_repository_id).to eq(repository.id)
      expect(link.source_ref).to eq("syrus/issue-9")
      expect(link.target_repository_id).to eq(canonical.id)
      expect(link.target_ref).to eq("develop")
      expect(link.pr_number).to eq(900)
      expect(link.metadata).to eq("pr_state" => "open")
    end

    it "uses a fallback title/body when no succeeded workflow has recorded pr_title/pr_body" do
      handler.call

      expect(client).to have_received(:create_pull_request).with(
        canonical.slug, base: "develop", head: anything,
        title: "[syrus] #{repository.slug}##{job.issue_number}",
        body: a_string_including("Opened by Syrus following local approval")
      )
    end

    it "stamps a syrus_job_export provenance marker in the PR body" do
      handler.call

      expect(client).to have_received(:create_pull_request).with(
        canonical.slug, base: "develop", head: anything, title: anything,
        body: a_string_including(PrProvenanceMarker.stamp(kind: "syrus_job_export", job: job))
      )
    end

    it "reuses pr_title/pr_body from the job's most recent succeeded workflow" do
      Workflow.create!(
        job: job, trigger_kind: "initial", state: "succeeded",
        artifacts: { "pr_title" => "Add widgets", "pr_body" => "Adds widget support." }
      )

      handler.call

      expect(client).to have_received(:create_pull_request).with(
        canonical.slug, base: "develop", head: anything,
        title: "Add widgets",
        body: a_string_including("Adds widget support.")
      )
    end
  end

  context "when canonical uses strict main (no configured development track)" do
    it "opens the PR against the branch DeliveryPolicy resolved" do
      stub_policy(target_branch: "main")
      allow(client).to receive(:open_pull_request_for_head).and_return(nil)
      allow(client).to receive(:create_pull_request).and_return(OpenStruct.new(number: 901))

      handler.call

      expect(client).to have_received(:create_pull_request).with(canonical.slug, base: "main", head: anything, title: anything, body: anything)
    end
  end

  context "open/update idempotency" do
    it "reuses an already-recorded upstream_export PR instead of opening a duplicate" do
      stub_policy(target_branch: "develop")
      JobPrLink.record!(
        job: job, role: JobPrLink::ROLE_UPSTREAM_EXPORT,
        source_repository_id: repository.id, source_ref: "syrus/issue-9",
        target_repository_id: canonical.id, target_ref: "develop",
        pr_number: 900, metadata: { "pr_state" => "open" }
      )
      allow(client).to receive(:create_pull_request)

      handler.call

      expect(client).not_to have_received(:create_pull_request)
      expect(job.pr_links.find_by!(role: JobPrLink::ROLE_UPSTREAM_EXPORT).pr_number).to eq(900)
    end
  end
end
