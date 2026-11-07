require "rails_helper"

RSpec.describe Mcp::Tools::SubmitSecurityReviewTool do
  let(:run) do
    job = Factories.job
    workflow = job.latest_workflow
    step = Step.create!(workflow: workflow, kind: "security_review", position: 99)
    step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
  end

  it "persists findings and records a security finding event" do
    expect(ReviewFindingEvents).to receive(:record).with(hash_including(review_kind: "security", verdict: "needs_work"))

    response = described_class.call(
      critique: "Authorization is missing.", verdict: "needs_work", server_context: { run: run }
    )

    expect(response).not_to be_error
    expect(run.workflow.reload.artifact("security_review_iterations")).to include(
      hash_including("critique" => "Authorization is missing.", "verdict" => "needs_work")
    )
  end

  it "rejects invalid verdicts" do
    response = described_class.call(critique: "Maybe", verdict: "unknown", server_context: { run: run })
    expect(response).to be_error
  end

  it "persists coworker memory from the security critique without creating human approval" do
    run.update!(agent_provider: "codex", model: "gpt-test")
    reviewer = Coworkers::Coworker.create!(owner_user: run.job.owner_user || run.job.user, name: "Monica",
      handle: "monica-security", state: "active", workspace_repo: "https://github.com/example/reviewer-home.git")
    evidence = ReviewEvidence.create!(
      run: run, workflow: run.workflow, step: run.step, reviewer: reviewer, review_kind: "security",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1"
    )
    context = Coworkers::ReviewContext.create!(run: run, review_evidence: evidence, coworker: reviewer,
      manifest: { "protected_prompt" => { "sha256" => "safe" } },
      exact_context: { "protected_prompt" => "protected" }, workspace_path: "/tmp/reviewer-home")
    allow(ReviewEvidence::CanonicalDiff).to receive(:snapshot).and_return(head_sha: "b" * 40, sha256: "c" * 64)
    expect_any_instance_of(Coworkers::Coworker).to receive(:finalize_review_memory!).with(
      run: an_instance_of(Run), key_learning: "Authorization is sound.", verdict: "approved"
    ) do
      context.update!(persistence_state: "persisted", persisted_commit_sha: "e" * 40, persisted_at: Time.current)
    end
    expect {
      response = described_class.call(
        critique: "Authorization is sound.", verdict: "approved", server_context: { run: run }
      )
      expect(response).not_to be_error
    }.not_to change(JobApproval, :count)

    expect(run.workflow.reload.artifact("security_review_iterations").last).to include(
      "reviewer" => include("label" => "Monica · Codex"),
      "memory_persistence" => include("state" => "persisted"),
      "verdict" => "approved"
    )
  end

  it "rejects a verdict when the frozen source changed" do
    evidence = ReviewEvidence.create!(
      run: run, workflow: run.workflow, step: run.step, review_kind: "security",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1"
    )
    allow(ReviewEvidence::CanonicalDiff).to receive(:snapshot)
      .and_return(head_sha: "e" * 40, sha256: "f" * 64)

    response = described_class.call(
      critique: "Looks clean.", verdict: "approved", server_context: { run: run }
    )

    expect(response).to be_error
    expect(run.workflow.reload.artifact("security_review_iterations")).to be_nil
    expect(evidence.reload).to have_attributes(
      state: "stale", terminal_failure_code: "review_evidence_mismatch"
    )
  end
end
