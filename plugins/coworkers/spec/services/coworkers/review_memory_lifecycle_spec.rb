require "rails_helper"
require "tmpdir"

RSpec.describe Coworkers::ReviewMemoryLifecycle do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:workspace_repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", state: "active",
      workspace_repo: workspace_repository.remote_url)
  end
  let(:job) { Factories.job(user: owner, repository: repository) }
  let(:step) { Step.create!(workflow: job.latest_workflow, kind: "coworker_review", position: 99) }
  let(:run) { step.runs.create!(job: job, trigger_kind: "initial", agent_provider: "codex", model: "test") }
  let(:evidence) do
    ReviewEvidence.create!(run:, workflow: run.workflow, step:, reviewer: coworker, review_kind: "coworker",
      provider: "codex", model: "test", reviewed_base_sha: "a" * 40, reviewed_head_sha: "b" * 40,
      canonical_diff_sha256: "c" * 64, prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1")
  end

  around do |example|
    Dir.mktmpdir("coworker-review-spec") do |directory|
      @directory = Pathname(directory)
      example.run
    end
  end

  def context
    Coworkers::ReviewContext.create!(run:, review_evidence: evidence, coworker:,
      manifest: { "identity" => { "sha256" => "safe" } }, exact_context: { "identity" => "secret" },
      workspace_path: @directory.to_s)
  end

  it "bounds curated updates to approved non-symlink memory paths" do
    record = context
    expect(described_class.update!(coworker:, run:, path: "memory/preferences.md", content: "Keep it terse."))
      .to eq("memory/preferences.md")
    expect(@directory.join("memory/preferences.md").read).to eq("Keep it terse.")
    expect { described_class.update!(coworker:, run:, path: "../credentials", content: "bad") }
      .to raise_error(ArgumentError, /memory/)
    expect(record.reload.exact_context).to eq("identity" => "secret")
  end

  it "writes one deterministic journal and makes persistence retry-idempotent" do
    record = context
    allow(described_class).to receive(:persist_checkout!) do
      record.update!(persistence_state: "persisted", persisted_commit_sha: "e" * 40, persisted_at: Time.current)
    end

    2.times { described_class.persist!(coworker:, run:, key_learning: "Check authorization boundaries.", verdict: "approved") }

    journal = @directory.join("reviews/journal/run-#{run.id}.md").read
    expect(journal).to include("Reviewed SHA: #{evidence.reviewed_head_sha}", "Key learning: Check authorization boundaries.")
    expect(described_class).to have_received(:persist_checkout!).once
  end

  it "tombstones raw context while preserving the safe manifest and lineage" do
    record = context
    record.tombstone!
    expect(record.reload).to have_attributes(exact_context: "[tombstoned]", persistence_state: "tombstoned",
      manifest: { "identity" => { "sha256" => "safe" } }, run_id: run.id)
  end
end
