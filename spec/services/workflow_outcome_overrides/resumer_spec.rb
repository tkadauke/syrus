require "rails_helper"

RSpec.describe WorkflowOutcomeOverrides::Resumer do
  let(:user) { Factories.user }
  let(:job) { Factories.job(user:) }
  let(:workflow) { job.workflows.last }

  around do |example|
    previous_target = Syrus::LockOrder.target
    Syrus::LockOrder.target = :hierarchical
    example.run
  ensure
    Syrus::LockOrder.target = previous_target
  end

  it "reruns a failed grader collector through the registered grader strategy" do
    grader = Step.create!(workflow:, kind: "grader", position: 10, state: "failed",
      iteration: 1, loop_id: "grade-loop")
    collector = Step.create!(workflow:, kind: "grader_collect", position: 11, state: "failed",
      iteration: 1, loop_id: "grade-loop")
    override = instance_double(WorkflowOutcomeOverride, gate_kind: "implementation_grader", workflow:, step: grader)
    result = RetryFailedStepEnqueuer::Result.new(run: instance_double(Run), workflow:, step: collector, error: nil)
    allow(workflow).to receive(:failed?).and_return(true)
    allow(RetryFailedStepEnqueuer).to receive(:call).and_return(result)

    expect(described_class.call(override:)).to eq(result)
    expect(RetryFailedStepEnqueuer).to have_received(:call).with(
      workflow:, failed_step: collector, restart_grade_loop: false
    )
  end

  it "applies a panel member override and supersedes the queued repair iteration" do
    reviewed_sha = "a" * 40
    vote = panel_vote
    workflow.set_artifact!("security_review_iterations", [
      vote,
      { "iteration" => 1, "panel_id" => "panel", "aggregate" => true,
        "verdict" => "needs_work", "vote_breakdown" => {} }
    ])
    collect = Step.create!(workflow:, kind: "review_panel_collect", position: 10, state: "succeeded",
      iteration: 1, loop_id: "review-loop", details: {
        "panel_review_kind" => "security_review", "panel_id" => "panel",
        "reviewed_head_sha" => reviewed_sha, "consensus" => "unanimous", "min_members" => 1
      })
    repair = Step.create!(workflow:, kind: "implement", position: 11, iteration: 2, loop_id: "review-loop")
    continuation = Step.create!(workflow:, kind: "summarize", position: 12)
    collect.update!(next_step_id: repair.id)
    repair.update!(next_step_id: continuation.id)
    continuation.update!(depends_on_ids: [ repair.id ])
    override = record_review_override(step: collect, vote:, reviewed_sha:)

    expect(described_class.call(override:)).to eq(override)

    entries = workflow.reload.artifact("security_review_iterations")
    expect(entries.first).to include("verdict" => "needs_work", "effective_verdict" => "approved",
      "outcome_override_id" => override.id)
    expect(entries.last).to include("verdict" => "approved")
    expect(repair.reload.state).to eq("skipped")
    expect(collect.reload.next_step).to eq(continuation)
    expect(continuation.reload.depends_on_ids).to eq([ collect.id ])
    expect(continuation.runs.count).to eq(1)
    expect(override.reload).to be_consumed
  end

  it "applies a single-review override and skips its queued repair" do
    reviewed_sha = "b" * 40
    vote = panel_vote.except("panel_id").merge("step_id" => 44)
    workflow.set_artifact!("adversarial_review_iterations", [ vote ])
    review = Step.create!(workflow:, kind: "adversarial_review", position: 20, state: "succeeded",
      iteration: 1, loop_id: "single-review", details: { "reviewed_head_sha" => reviewed_sha })
    repair = Step.create!(workflow:, kind: "implement", position: 21, iteration: 2, loop_id: "single-review")
    continuation = Step.create!(workflow:, kind: "summarize", position: 22)
    review.update!(next_step_id: repair.id)
    repair.update!(next_step_id: continuation.id)
    override = record_review_override(step: review, vote:, reviewed_sha:, review_kind: "adversarial_review")

    described_class.call(override:)

    expect(workflow.reload.artifact("adversarial_review_iterations").sole)
      .to include("effective_verdict" => "approved", "outcome_override_id" => override.id)
    expect(repair.reload.state).to eq("skipped")
    expect(continuation.runs.count).to eq(1)
  end

  it "refuses and invalidates an override after review repair has started" do
    reviewed_sha = "c" * 40
    vote = panel_vote.except("panel_id").merge("step_id" => 45)
    workflow.set_artifact!("adversarial_review_iterations", [ vote ])
    review = Step.create!(workflow:, kind: "adversarial_review", position: 30, state: "succeeded",
      iteration: 1, loop_id: "started-review", details: { "reviewed_head_sha" => reviewed_sha })
    repair = Step.create!(workflow:, kind: "implement", position: 31, state: "running",
      iteration: 2, loop_id: "started-review")
    review.update!(next_step_id: repair.id)
    override = record_review_override(step: review, vote:, reviewed_sha:, review_kind: "adversarial_review")

    expect { described_class.call(override:) }
      .to raise_error(described_class::ResumeFailed, /repair already started/)
    expect(override.reload).to be_invalidated
    expect(override.invalidation_cause).to eq("resume_failed")
  end

  it "revalidates a queued repair after taking the workflow ancestry lock" do
    reviewed_sha = "d" * 40
    vote = panel_vote.except("panel_id").merge("step_id" => 46)
    workflow.set_artifact!("adversarial_review_iterations", [ vote ])
    review = Step.create!(workflow:, kind: "adversarial_review", position: 40, state: "succeeded",
      iteration: 1, loop_id: "claim-race", details: { "reviewed_head_sha" => reviewed_sha })
    repair = Step.create!(workflow:, kind: "implement", position: 41, state: "queued",
      iteration: 2, loop_id: "claim-race")
    run = Run.create!(job:, step: repair, trigger_kind: workflow.trigger_kind)
    review.update!(next_step_id: repair.id)
    override = record_review_override(step: review, vote:, reviewed_sha:, review_kind: "adversarial_review")
    allow(Lineage).to receive(:lock!).and_wrap_original do |original, record|
      result = original.call(record)
      run.update_columns(state: "running")
      result
    end

    expect { described_class.call(override:) }
      .to raise_error(described_class::ResumeFailed, /repair already started/)

    expect(workflow.reload.artifact("adversarial_review_iterations").sole).to eq(vote)
    expect(override.reload).to be_invalidated
  end

  it "rolls back override consumption and evidence when loop rewiring fails" do
    reviewed_sha = "e" * 40
    vote = panel_vote.except("panel_id").merge("step_id" => 47)
    workflow.set_artifact!("adversarial_review_iterations", [ vote ])
    review = Step.create!(workflow:, kind: "adversarial_review", position: 50, state: "succeeded",
      iteration: 1, loop_id: "atomic-review", details: { "reviewed_head_sha" => reviewed_sha })
    repair = Step.create!(workflow:, kind: "implement", position: 51, state: "queued",
      iteration: 2, loop_id: "atomic-review")
    continuation = Step.create!(workflow:, kind: "summarize", position: 52)
    review.update!(next_step_id: repair.id)
    repair.update!(next_step_id: continuation.id)
    continuation.update!(depends_on_ids: [ repair.id ])
    override = record_review_override(step: review, vote:, reviewed_sha:, review_kind: "adversarial_review")
    allow_any_instance_of(WorkflowOutcomeOverrides::Resumers::Review)
      .to receive(:rewire_continuation_dependencies!).and_raise("rewire failed")

    expect { described_class.call(override:) }.to raise_error("rewire failed")

    expect(override.reload).not_to be_consumed
    expect(workflow.reload.artifact("adversarial_review_iterations").sole).to eq(vote)
    expect(repair.reload.state).to eq("queued")
    expect(review.reload.next_step).to eq(repair)
    expect(continuation.reload.depends_on_ids).to eq([ repair.id ])
  end

  private

  def panel_vote
    { "iteration" => 1, "step_id" => 40, "run_id" => 41, "panel_id" => "panel",
      "provider" => "codex", "model" => "gpt-5", "verdict" => "needs_work",
      "critique" => "False positive." }
  end

  def record_review_override(step:, vote:, reviewed_sha:, review_kind: "security_review")
    identity = WorkflowOutcomeOverrides::ReviewVerdict.gate_identity(
      review_kind:, panel_id: vote["panel_id"], vote:
    )
    digest = WorkflowOutcomeOverrides::ReviewVerdict.evidence_digest(vote)
    WorkflowOutcomeOverride.record!(
      gate_failure: { outcome: "failed", technically_overridable: true, structural: false,
                      gate_identity: identity, evidence_digest: digest },
      job:, workflow:, step:, actor: user, gate_kind: "review", gate_identity: identity,
      candidate_head_sha: reviewed_sha, prompt_version: review_kind, evidence_digest: digest,
      channel: "ui", reason: "Confirmed false positive", permission_decision: { "policy" => "allow" }
    )
  end
end
