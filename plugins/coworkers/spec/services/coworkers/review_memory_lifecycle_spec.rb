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
      manifest: { "protected_prompt" => { "sha256" => "safe" } }, exact_context: { "protected_prompt" => "secret" },
      workspace_path: @directory.to_s)
  end

  it "bounds curated updates to approved non-symlink memory paths" do
    record = context
    expect(described_class.update!(coworker:, run:, path: "memory/preferences.md", content: "Keep it terse."))
      .to eq("memory/preferences.md")
    expect(@directory.join("memory/preferences.md").read).to eq("Keep it terse.")
    expect { described_class.update!(coworker:, run:, path: "../credentials", content: "bad") }
      .to raise_error(ArgumentError, /memory/)
    expect(record.reload.exact_context).to eq("protected_prompt" => "secret")
  end

  it "requests only explicitly selected memories through the memory provider boundary" do
    step.update!(details: { "review_memory_ids" => [ "12", 12, "invalid" ] })
    selected = [ { id: 12, revision: "2026-11-06T10:00:00Z", content: "Use the repository policy." } ]
    allow(Syrus::Memory).to receive(:selected_review_memories).and_return(selected)

    expect(described_class.send(:eligible_memories, coworker, run)).to eq(selected)
    expect(Syrus::Memory).to have_received(:selected_review_memories)
      .with(user: owner, repository_id: repository.id, ids: [ 12 ])
  end

  it "writes one deterministic journal and makes persistence retry-idempotent" do
    record = context
    allow(described_class).to receive(:persist_checkout!) do
      record.update!(persistence_state: "persisted", persisted_commit_sha: "e" * 40, persisted_at: Time.current)
    end

    2.times { described_class.persist!(coworker:, run:, key_learning: "Check authorization boundaries.", verdict: "approved") }

    journal = @directory.join("reviews/journal/evidence-#{evidence.id}.md").read
    expect(journal).to include("Reviewed SHA: #{evidence.reviewed_head_sha}", "Key learning: Check authorization boundaries.")
    expect(described_class).to have_received(:persist_checkout!).once
  end

  it "tombstones raw context while preserving the safe manifest and lineage" do
    record = context
    record.tombstone!
    expect(record.reload).to have_attributes(exact_context: "[tombstoned]", persistence_state: "tombstoned",
      manifest: { "protected_prompt" => { "sha256" => "safe" } }, run_id: run.id)
  end

  it "purges plugin-owned context and its isolated workspace without deleting generic evidence" do
    record = context
    allow(Coworkers::ReviewWorkspace).to receive(:remove!).with(record)

    coworker.destroy!

    expect(Coworkers::ReviewWorkspace).to have_received(:remove!).with(record)
    expect(Coworkers::ReviewContext.where(id: record.id)).to be_empty
    expect(ReviewEvidence.where(id: evidence.id)).to exist
  end

  it "serializes persistence for the coworker home branch" do
    record = context
    allow(Coworkers::OperationLock).to receive(:with).with(coworker, wait: 30).and_yield
    allow(described_class).to receive(:persist_checkout!) { record.update!(persistence_state: "persisted") }

    described_class.persist!(coworker:, run:, key_learning: "Keep boundaries narrow.", verdict: "approved")

    expect(Coworkers::OperationLock).to have_received(:with).with(coworker, wait: 30)
  end

  it "records only redacted persistence failure details" do
    record = context
    error = GitRunner::GitError.new([ "push" ], 1, "https://x-access-token:secret@github.com failed")
    allow(described_class).to receive(:persist_checkout!).and_raise(error)

    expect { described_class.persist!(coworker:, run:, key_learning: "No secrets.", verdict: "needs_work") }
      .to raise_error(described_class::PersistenceError, "coworker memory persistence failed")
    expect(record.reload.persistence_error_details.to_json).not_to include("secret", "github.com")
  end

  it "keeps Git credentials out of command arguments and removes the askpass helper" do
    allow(GithubAuthenticatedGit).to receive(:run).and_yield("https://x-access-token:top-secret@github.com/acme/home.git")
    captured = nil

    described_class.send(:with_git_auth, workspace_repository, run, operation_type: "review_test") do |url, env|
      captured = [ url, env.fetch("GIT_ASKPASS") ]
      expect(url).to eq("https://github.com/acme/home.git")
      expect(File.read(env.fetch("GIT_ASKPASS"))).to include("top-secret")
    end

    expect(captured.first).not_to include("top-secret", "x-access-token")
    expect(File).not_to exist(captured.last)
  end
end
