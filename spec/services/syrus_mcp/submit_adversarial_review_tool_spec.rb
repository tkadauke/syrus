require "rails_helper"

RSpec.describe Mcp::Tools::SubmitAdversarialReviewTool do
  # submit_adversarial_review is role-gated to WORKFLOW_ADVERSARIAL_REVIEWER,
  # which is assigned when the step.kind is "adversarial_review". Using
  # initial_run would produce WORKFLOW_IMPLEMENT and trigger the capability guard.
  let(:run) do
    job = Factories.job
    workflow = job.latest_workflow
    step = Step.create!(workflow: workflow, kind: "adversarial_review", position: 99)
    step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
  end

  def call(critique: "The implementation needs a missing edge-case test.", verdict: "needs_work")
    described_class.call(critique: critique, verdict: verdict, server_context: { run: run })
  end

  def grant_review_access(coworker)
    coworker.grants.create!(capability: "code.read", approval_policy: "auto", scope: [ run.job.repository_id ])
    coworker.permission_rules.update!(
      capability: "code.read", approval_policy: "auto", scope: [ run.job.repository_id ],
      actor: coworker.owner_user
    )
  end

  it "accepts a run_id-only sidecar context" do
    expect(ReviewFindingEvents).to receive(:record).with(
      workflow: run.workflow,
      step: run.step,
      run: run,
      review_kind: "adversarial",
      iteration: run.step.iteration,
      verdict: "approved",
      critique: "No blocking issues found."
    )

    described_class.call(
      critique: "No blocking issues found.",
      verdict: "approved",
      server_context: { run_id: run.id }
    )

    expect(run.workflow.reload.artifact("adversarial_review_iterations")).to eq([
      {
        "iteration" => run.step.iteration,
        "step_id" => run.step_id,
        "run_id" => run.id,
        "critique" => "No blocking issues found.",
        "verdict" => "approved"
      }
    ])
  end

  it "appends each review to the workflow artifact" do
    run.workflow.set_artifact!("adversarial_review_iterations", [
      { "iteration" => 1, "critique" => "First pass.", "verdict" => "needs_work" }
    ])

    call(critique: "Second pass is clean.", verdict: "approved")

    expect(run.workflow.reload.artifact("adversarial_review_iterations")).to eq([
      { "iteration" => 1, "critique" => "First pass.", "verdict" => "needs_work" },
      { "iteration" => run.step.iteration, "step_id" => run.step_id, "run_id" => run.id, "critique" => "Second pass is clean.", "verdict" => "approved" }
    ])
  end

  it "normalizes binary-tagged UTF-8 and strips whitespace" do
    call(critique: "  Check ● paths.  ".b, verdict: " approved ".b)

    artifact = run.workflow.reload.artifact("adversarial_review_iterations").last
    expect(artifact).to include("critique" => "Check ● paths.", "verdict" => "approved")
    expect(artifact["critique"].encoding).to eq(Encoding::UTF_8)
  end

  it "rejects empty critique" do
    response = call(critique: " ")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("critique is required")
    expect(run.workflow.reload.artifact("adversarial_review_iterations")).to be_nil
  end

  it "rejects unsupported verdicts" do
    response = call(verdict: "maybe")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("verdict must be one of")
    expect(run.workflow.reload.artifact("adversarial_review_iterations")).to be_nil
  end

  it "writes a JobLog audit line" do
    expect { call(verdict: "approved") }.to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] submit_adversarial_review received: approved")
  end

  it "links a matching frozen evidence record to the authoritative verdict artifact" do
    evidence = ReviewEvidence.create!(
      run: run, workflow: run.workflow, step: run.step, review_kind: "adversarial",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1"
    )
    allow(ReviewEvidence::CanonicalDiff).to receive(:snapshot)
      .and_return(head_sha: "b" * 40, sha256: "c" * 64)

    response = call(verdict: "approved")

    expect(response).not_to be_error
    expect(run.workflow.reload.artifact("adversarial_review_iterations").last)
      .to include("review_evidence_id" => evidence.id, "verdict" => "approved")
    expect(evidence.reload).to have_attributes(state: "submitted", submitted_at: be_present)
  end

  it "persists and records independent coworker reviewer provenance" do
    owner = run.job.owner_user || run.job.user
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Monica", handle: "monica-review",
      state: "active", workspace_repo: "https://github.com/example/reviewer-home.git")
    grant_review_access(coworker)
    run.update!(agent_provider: "codex", model: "gpt-test")
    run.step.update!(details: { "reviewer_target" => {
      "type" => "coworker", "reference" => coworker.id.to_s, "display" => { "name" => "Monica" }
    } })
    evidence = ReviewEvidence.create!(
      run: run, workflow: run.workflow, step: run.step, reviewer: coworker, review_kind: "adversarial",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1"
    )
    context = Coworkers::ReviewContext.create!(run:, review_evidence: evidence, coworker:,
      manifest: { "protected_prompt" => { "sha256" => "safe" } },
      exact_context: { "protected_prompt" => "protected" }, workspace_path: "/tmp/reviewer-home")
    allow(ReviewEvidence::CanonicalDiff).to receive(:snapshot).and_return(head_sha: "b" * 40, sha256: "c" * 64)
    persistence_calls = 0
    allow_any_instance_of(Coworkers::Coworker).to receive(:finalize_review_memory!) do
      persistence_calls += 1
      context.update!(persistence_state: "persisted", persisted_commit_sha: "e" * 40, persisted_at: Time.current)
    end

    response = nil
    expect { response = call(critique: "The authorization boundary is sound.", verdict: "approved") }
      .not_to change(JobApproval, :count)

    expect(response).not_to be_error
    entry = run.workflow.reload.artifact("adversarial_review_iterations").last
    expect(entry).to include(
      "review_evidence_id" => evidence.id,
      "reviewer" => include("label" => "Monica · Codex", "provider" => "codex", "model" => "gpt-test"),
      "memory_persistence" => include("state" => "persisted", "persisted_commit_sha" => "e" * 40),
      "verdict" => "approved"
    )

    duplicate = call(critique: "The authorization boundary is sound.", verdict: "approved")
    expect(duplicate).not_to be_error
    expect(persistence_calls).to eq(1)
    expect(run.workflow.reload.artifact("adversarial_review_iterations").count).to eq(1)
  end

  it "fails without recording a verdict when coworker memory cannot be persisted" do
    reviewer = Coworkers::Coworker.create!(owner_user: run.job.owner_user || run.job.user, name: "Monica",
      handle: "monica-failure", state: "active", workspace_repo: "https://github.com/example/reviewer-home.git")
    grant_review_access(reviewer)
    evidence = ReviewEvidence.create!(
      run: run, workflow: run.workflow, step: run.step, reviewer: reviewer, review_kind: "adversarial",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1"
    )
    allow(ReviewEvidence::CanonicalDiff).to receive(:snapshot).and_return(head_sha: "b" * 40, sha256: "c" * 64)
    allow_any_instance_of(Coworkers::Coworker).to receive(:finalize_review_memory!)
      .and_raise(Steps::AdversarialReview::MemoryPersistenceFailed, "memory failed")

    expect {
      call(critique: "A finding that must be remembered.", verdict: "needs_work")
    }.to raise_error(Steps::AdversarialReview::MemoryPersistenceFailed, /memory failed/)
    expect(run.workflow.reload.artifact("adversarial_review_iterations")).to be_nil
  end

  it "rejects a verdict for a changed head and permanently stales its evidence" do
    evidence = ReviewEvidence.create!(
      run: run, workflow: run.workflow, step: run.step, review_kind: "adversarial",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1"
    )
    allow(ReviewEvidence::CanonicalDiff).to receive(:snapshot)
      .and_return(head_sha: "e" * 40, sha256: "f" * 64)

    response = call(verdict: "approved")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("Review evidence mismatch")
    expect(run.workflow.reload.artifact("adversarial_review_iterations")).to be_nil
    expect(evidence.reload).to have_attributes(
      state: "stale", terminal_failure_code: "review_evidence_mismatch"
    )
  end

  it "rolls the verdict artifact back when evidence submission fails" do
    evidence = ReviewEvidence.create!(
      run: run, workflow: run.workflow, step: run.step, review_kind: "adversarial",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1"
    )
    allow(ReviewEvidence::CanonicalDiff).to receive(:snapshot)
      .and_return(head_sha: "b" * 40, sha256: "c" * 64)
    allow_any_instance_of(ReviewEvidence)
      .to receive(:mark_submitted!).and_raise(ActiveRecord::RecordInvalid.new(evidence))

    response = call(verdict: "approved")

    expect(response).to be_error
    expect(run.workflow.reload.artifact("adversarial_review_iterations")).to be_nil
    expect(evidence.reload.state).to eq("pending")
  end

  it "exposes the expected tool name and required schema" do
    expect(described_class.tool_name).to eq("submit_adversarial_review")
    expect(described_class.input_schema_value.to_h[:required]).to match_array(%w[critique verdict])
  end

  it "returns not_authorized when called from an implement-role step" do
    implement_run = Factories.job.initial_run
    response = described_class.call(
      critique: "Looks fine.", verdict: "approved",
      server_context: { run: implement_run }
    )

    expect(response).to be_error
    payload = JSON.parse(response.content.first[:text], symbolize_names: true)
    expect(payload).to eq(error: "not_authorized")
  end
end
