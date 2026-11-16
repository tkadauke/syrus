require "rails_helper"

RSpec.describe Workflows::ImmutableReviewHeadBarrier do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository, user: user, owner_user: user) }
  let(:workflow) { job.workflows.last }
  let(:snapshots) do
    %w[adversarial security].map do |name|
      {
        "step_kind" => "#{name}_review",
        "verdict_artifact" => "#{name}_review_iterations",
        "exit_verdicts" => %w[approved skipped],
        "required" => true
      }
    end
  end

  before do
    workflow.steps.delete_all
    workflow.set_artifact!("review_gate_contributions", snapshots)
    implement = Step.create!(workflow: workflow, kind: "implement", position: 0, state: "succeeded")
    implement.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "succeeded", head_sha: "head-b")
  end

  def collect(kind:, position:, sha:, state: "succeeded", verdict: "approved", required: true)
    step = Step.create!(
      workflow: workflow, kind: "review_panel_collect", position: position, state: state,
      details: { "panel_review_kind" => kind, "panel_id" => "#{kind}-panel", "reviewed_head_sha" => sha,
                 "required" => required }
    )
    artifact = Step::Kind.review_gate_for(kind).fetch(:artifact_key)
    workflow.set_artifact!(artifact, Array(workflow.artifact(artifact)) + [
      { "aggregate" => true, "panel_id" => "#{kind}-panel", "reviewed_head_sha" => sha, "verdict" => verdict }
    ])
    step
  end

  it "does not accept a fanout placeholder or evidence for an older implementation HEAD" do
    Step.create!(workflow: workflow, kind: "adversarial_review", position: 1, state: "succeeded",
      details: { "panel_fanout" => true, "reviewed_head_sha" => "head-b" })
    collect(kind: "adversarial_review", position: 2, sha: "head-a")
    collect(kind: "security_review", position: 3, sha: "head-b")
    tail = Step.create!(workflow: workflow, kind: "format", position: 4)

    expect(described_class.satisfied_for?(tail)).to be(false)
  end

  it "joins every required collect barrier on the same approved HEAD" do
    collect(kind: "adversarial_review", position: 1, sha: "head-b")
    collect(kind: "security_review", position: 2, sha: "head-b")
    tail = Step.create!(workflow: workflow, kind: "grader_fanout", position: 3)

    expect(described_class.satisfied_for?(tail)).to be(true)
  end

  it "blocks dispatcher Run creation until every required collect approves the current HEAD" do
    collect(kind: "adversarial_review", position: 1, sha: "head-b")
    tail = Step.create!(workflow: workflow, kind: "format", position: 3)

    expect(StepDispatcher.create_run_and_enqueue(tail, workflow)).to be_nil

    collect(kind: "security_review", position: 2, sha: "head-b")
    expect(StepDispatcher.create_run_and_enqueue(tail.reload, workflow)).to be_present
  end

  it "keeps failed fresh evidence closed and excludes explicitly optional gates" do
    collect(kind: "adversarial_review", position: 1, sha: "head-b", verdict: "needs_work")
    collect(kind: "security_review", position: 2, sha: "head-b")
    tail = Step.create!(workflow: workflow, kind: "pr_open", position: 3)

    expect(described_class.satisfied_for?(tail)).to be(false)

    workflow.set_artifact!("review_gate_contributions", [ snapshots.last, snapshots.first.merge("required" => false) ])
    expect(described_class.satisfied_for?(tail)).to be(true)
  end

  it "stamps panel control and collect steps with the immutable implementation HEAD" do
    control = Step.create!(workflow: workflow, kind: "security_review", position: 1)
    expect(described_class.stamp!(control, workflow)).to eq("head-b")
    expect(control.reload.details["reviewed_head_sha"]).to eq("head-b")
  end

  it "cancels in-flight stale review work without cascading workflow failure" do
    stale = Step.create!(workflow: workflow, kind: "security_review", position: 1, state: "running",
      details: { "panel_member" => true, "reviewed_head_sha" => "head-a" })
    run = stale.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running")

    expect(described_class.reviewed_head_sha(workflow)).to eq("head-b")
    expect(described_class.effective_review_kind(stale)).to eq("security_review")
    described_class.invalidate_stale_evidence!(workflow)

    expect(stale.reload).to be_cancelled
    expect(run.reload).to be_cancelled
    expect(stale.details).to include(
      "review_evidence_superseded" => true,
      "superseded_by_head_sha" => "head-b"
    )
    expect(workflow.reload).not_to be_failed
  end

  it "idempotently rematerializes every missing required review for a repaired HEAD" do
    adversarial = collect(kind: "adversarial_review", position: 1, sha: "head-a")
    security = collect(kind: "security_review", position: 2, sha: "head-a", state: "running")
    repair = Step.create!(workflow: workflow, kind: "implement", position: 3, state: "succeeded",
      loop_id: adversarial.loop_id || "adversarial-loop")
    repair.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "succeeded", head_sha: "head-c")
    tail = Step.create!(workflow: workflow, kind: "format", position: 4)
    repair.update!(next_step: tail)
    adversarial.update!(loop_id: "adversarial-loop")
    security.update!(loop_id: "security-loop")

    described_class.invalidate_stale_evidence!(workflow)
    first = described_class.refresh_required_reviews!(workflow, repair)
    second = described_class.refresh_required_reviews!(workflow, repair)

    expect(first.map(&:kind)).to contain_exactly("adversarial_review", "security_review")
    expect(second).to be_empty
    expect(workflow.steps.select { |step| step.details.to_h["review_barrier_rematerialized"] }.map(&:kind))
      .to contain_exactly("adversarial_review", "security_review")
    expect(described_class.satisfied_for?(tail)).to be(false)
  end

  it "accepts only an explicit exhausted-gate exception for the repaired HEAD and rematerializes sibling gates" do
    adversarial = collect(kind: "adversarial_review", position: 1, sha: "head-a")
    security = collect(kind: "security_review", position: 2, sha: "head-a")
    adversarial.update!(loop_id: "adversarial-loop")
    security.update!(loop_id: "security-loop")
    repair = Step.create!(workflow: workflow, kind: "implement", position: 3, state: "succeeded",
      loop_id: "adversarial-loop")
    repair.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "succeeded", head_sha: "head-c")
    tail = Step.create!(workflow: workflow, kind: "format", position: 4)
    repair.update!(next_step: tail)

    described_class.invalidate_stale_evidence!(workflow)
    described_class.record_budget_exhaustion!(workflow, repair, "adversarial_review")
    created = described_class.refresh_required_reviews!(workflow, repair)
    workflow.reload

    expect(created.map(&:kind)).to eq([ "security_review" ])
    expect(described_class.exhausted_for_head?(workflow, "adversarial_review", "head-c")).to be(true)
    expect(described_class.exhausted_for_head?(workflow, "adversarial_review", "head-b")).to be(false)
    expect(described_class.satisfied_for?(tail)).to be(false)
    expect(workflow.workflow_warnings.where(kind: "required_review_budget_exhausted").count).to eq(1)

    described_class.record_budget_exhaustion!(workflow, repair, "adversarial_review")
    expect(workflow.workflow_warnings.where(kind: "required_review_budget_exhausted").count).to eq(1)
  end

  it "keeps the tail closed after a fresh required failure and releases it exactly once after all approve" do
    collect(kind: "adversarial_review", position: 1, sha: "head-b")
    collect(kind: "security_review", position: 2, sha: "head-b", verdict: "needs_work")
    tail = Step.create!(workflow: workflow, kind: "pr_open", position: 4)

    expect(StepDispatcher.create_run_and_enqueue(tail, workflow)).to be_nil
    expect(tail.runs.count).to eq(0)

    collect(kind: "security_review", position: 3, sha: "head-b")
    first = StepDispatcher.create_run_and_enqueue(tail.reload, workflow)
    second = StepDispatcher.create_run_and_enqueue(tail.reload, workflow)

    expect(first).to be_present
    expect(second).to be_nil
    expect(tail.runs.count).to eq(1)
  end

  it "cancels stale Runs without triggering operator-stop workflow cancellation" do
    step = Step.create!(workflow: workflow, kind: "security_review", position: 1, state: "running",
      details: { "panel_member" => true, "reviewed_head_sha" => "head-a" })
    run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running")

    described_class.invalidate_stale_evidence!(workflow)

    expect(run.reload).to be_cancelled
    expect(workflow.reload).not_to be_cancelled
  end

  it "treats a missing post-repair validation step as exhausted instead of dereferencing nil" do
    expect(described_class.effective_review_kind(nil)).to be_nil
  end
end
