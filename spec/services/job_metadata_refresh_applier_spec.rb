require "rails_helper"

RSpec.describe JobMetadataRefreshApplier do
  let(:user) { Factories.user(github_token: "ghp_test", github_handle: "octavia") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Factories.job_record(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Pin provider creation",
      issue_body: "Pin chat provider at creation.",
      pr_number: 9
    )
  end
  let(:workflow) do
    Workflow.create!(
      job: job,
      trigger_kind: "chat_feedback",
      state: "running",
      agent_provider: "codex",
      artifacts: {
        "job_metadata" => {
          "changed" => true,
          "title" => "Preserve provider switching",
          "summary" => "The Job now preserves explicit provider switching.",
          "pr_body" => "Preserves explicit provider switching while keeping the selected provider pinned by default.",
          "test_plan" => {
            "steps" => [ "Run bin/rspec spec/services/chat_provider_spec.rb" ],
            "notes" => "Check the provider switch affordance."
          },
          "intent_revision_reason" => "Chat feedback changed the effective scope."
        }
      }
    )
  end
  let(:client) { instance_double(GithubClient) }

  it "updates a direct Job title, managed PR metadata, audit artifact, and search index" do
    allow(client).to receive(:pull_request)
      .with("acme/widgets", 9, bypass_cache: true)
      .and_return(Struct.new(:title, :body).new("Old PR title", "Old PR body"))
    allow(client).to receive(:update_pull_request_metadata)
    allow(IndexJobSearchJob).to receive(:perform_later)

    result = described_class.new(workflow, client: client).call

    expect(result).to eq("applied refreshed Job metadata")
    expect(job.reload.issue_title).to eq("Preserve provider switching")
    expect(client).to have_received(:update_pull_request_metadata) do |slug, pr_number, title:, body:|
      expect(slug).to eq("acme/widgets")
      expect(pr_number).to eq(9)
      expect(title).to eq("Preserve provider switching")
      expect(body).to include("Preserves explicit provider switching")
      expect(body).to include("## Test Plan")
      expect(body).to include("syrus checkout #{job.slug}")
      expect(body).to include("Triggered by @octavia")
      expect(body).to include(PrCostFooter::START_MARKER)
    end
    expect(workflow.reload.artifact("job_metadata_applied")).to include(
      "changed" => true,
      "before" => include("job_title" => "Pin provider creation", "pr_title" => "Old PR title"),
      "after" => include("title" => "Preserve provider switching")
    )
    expect(IndexJobSearchJob).to have_received(:perform_later).with(job.id).at_least(:once)
  end

  it "does not update canonical metadata when changed=false" do
    workflow.set_artifact!("job_metadata", {
      "changed" => false,
      "intent_revision_reason" => "Only fixed a spelling mistake."
    })
    allow(client).to receive(:pull_request).and_return(Struct.new(:title, :body).new("Old", "Body"))

    expect(client).not_to receive(:update_pull_request_metadata)
    expect(IndexJobSearchJob).not_to receive(:perform_later)

    result = described_class.new(workflow, client: client).call

    expect(result).to eq("metadata refresh made no canonical changes")
    expect(job.reload.issue_title).to eq("Pin provider creation")
    expect(workflow.reload.artifact("job_metadata_applied")).to include(
      "changed" => false,
      "reason" => "Only fixed a spelling mistake."
    )
  end

  it "leaves issue-backed Job titles untouched while updating the PR title" do
    job.update!(kind: "issue", issue_number: 42, issue_title: "Original issue title")
    allow(client).to receive(:pull_request).and_return(Struct.new(:title, :body).new("Old PR title", "Old PR body"))
    allow(client).to receive(:update_pull_request_metadata)
    allow(IndexJobSearchJob).to receive(:perform_later)

    described_class.new(workflow, client: client).call

    expect(job.reload.issue_title).to eq("Original issue title")
    expect(client).to have_received(:update_pull_request_metadata).with(
      "acme/widgets",
      9,
      title: "Preserve provider switching",
      body: kind_of(String)
    )
  end
end
