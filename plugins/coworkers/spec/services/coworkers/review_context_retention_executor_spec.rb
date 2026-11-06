require "rails_helper"

RSpec.describe Coworkers::ReviewContextRetentionExecutor do
  it "tombstones expired restricted text while preserving its manifest and lineage" do
    owner = Factories.user
    repository = Factories.repository(user: owner)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-retention", workspace_repo: repository.remote_url)
    job = Factories.job(user: owner, repository:)
    step = Step.create!(workflow: job.latest_workflow, kind: "coworker_review", position: 99)
    run = step.runs.create!(job:, trigger_kind: "initial", agent_provider: "codex", model: "test")
    evidence = ReviewEvidence.create!(run:, workflow: run.workflow, step:, reviewer: coworker, review_kind: "coworker",
      provider: "codex", model: "test", reviewed_base_sha: "a" * 40, reviewed_head_sha: "b" * 40,
      canonical_diff_sha256: "c" * 64, prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1")
    context = Coworkers::ReviewContext.create!(run:, review_evidence: evidence, coworker:,
      manifest: { "protected_prompt" => { "sha256" => "safe" } }, exact_context: { "protected_prompt" => "restricted" },
      workspace_path: "/recoverable/path", created_at: 31.days.ago)
    definition = instance_double(RetentionPolicyRegistry::Definition, retention_window: 30.days,
      model_class: Coworkers::ReviewContext, scope_name: :retention_candidates)

    result = described_class.new(definition).call

    expect(result.deleted_count).to eq(1)
    expect(context.reload).to have_attributes(persistence_state: "tombstoned", exact_context: "[tombstoned]",
      manifest: { "protected_prompt" => { "sha256" => "safe" } })
  end
end
