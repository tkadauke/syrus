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
    run = stale.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", started_at: 1.minute.ago)
    tail = Step.create!(workflow: workflow, kind: "format", position: 2, state: "queued")
    stale.update!(next_step: tail)

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
    # The stale review is graph maintenance, not an operator stop: the work
    # after it must stay runnable.
    expect(tail.reload).to be_queued
  end

  it "rematerializes an in-flight stale gate after the repair transaction commits without cancelling its chain" do
    stale = Step.create!(workflow: workflow, kind: "security_review", position: 1, state: "running",
      loop_id: "security-loop", details: { "panel_member" => true, "reviewed_head_sha" => "head-a" })
    stale.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", started_at: 1.minute.ago)
    repair = Step.create!(workflow: workflow, kind: "implement", position: 2, state: "succeeded",
      loop_id: "security-loop")
    repair.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "succeeded", head_sha: "head-c")
    sibling = Step.create!(workflow: workflow, kind: "adversarial_review", position: 3,
      details: { "panel_review_kind" => "adversarial_review", "panel_member" => true })
    collect_step = Step.create!(workflow: workflow, kind: "review_panel_collect", position: 4,
      details: { "panel_review_kind" => "adversarial_review" })
    format = Step.create!(workflow: workflow, kind: "format", position: 5)
    grader = Step.create!(workflow: workflow, kind: "grader", position: 6)
    pr_open = Step.create!(workflow: workflow, kind: "pr_open", position: 7)
    repair.update!(next_step: sibling)
    sibling.update!(next_step: collect_step)
    collect_step.update!(next_step: format)
    format.update!(next_step: grader)
    grader.update!(next_step: pr_open)

    StepDispatcher.advance_from(repair)
    created = workflow.steps.select { |step| step.details.to_h["review_barrier_rematerialized"] }

    expect(stale.reload).to be_cancelled
    expect(created.map(&:kind)).to include("security_review")
    expect(created.detect { |step| step.kind == "security_review" }.details)
      .to include("reviewed_head_sha" => "head-c")
    expect([ sibling, collect_step, format, grader, pr_open ].map { |step| step.reload.state }).to all(eq("queued"))

    replacement = created.detect { |step| step.kind == "security_review" }
    expect(replacement.runs.active).to exist

    replacement.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
    sibling.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
    collect_step.update_columns(
      state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current,
      details: collect_step.details.to_h.merge("reviewed_head_sha" => "head-c")
    )
    workflow.set_artifact!("security_review_iterations", [
      { "reviewed_head_sha" => "head-c", "verdict" => "approved" }
    ])
    workflow.set_artifact!("adversarial_review_iterations", [
      { "aggregate" => true, "reviewed_head_sha" => "head-c", "verdict" => "approved" }
    ])

    expect(StepDispatcher.create_run_and_enqueue(format.reload, workflow)).to be_present
    format.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
    expect(StepDispatcher.create_run_and_enqueue(grader.reload, workflow)).to be_present
    grader.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
    expect(StepDispatcher.create_run_and_enqueue(pr_open.reload, workflow)).to be_present
  end

  # Regression: a required review gate still waiting to run had been stamped
  # with the HEAD of the time. A repair changed HEAD, invalidation cancelled
  # that never-run gate as "stale evidence" -- and the cancellation took the
  # rest of the chain (format, graders, pr_open) with it. The rematerialized
  # loop then pointed at the cancelled gate, and the workflow stalled running
  # with nothing left to run.
  it "re-stamps a review gate that has not started yet instead of cancelling it and its tail" do
    adversarial = collect(kind: "adversarial_review", position: 1, sha: "head-a")
    adversarial.update!(loop_id: "adversarial-loop")
    repair = Step.create!(workflow: workflow, kind: "implement", position: 2, state: "succeeded",
      loop_id: "adversarial-loop")
    repair.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "succeeded", head_sha: "head-c")
    waiting_gate = Step.create!(workflow: workflow, kind: "security_review", position: 3, state: "queued",
      details: { "reviewed_head_sha" => "head-a", "required" => true })
    format = Step.create!(workflow: workflow, kind: "format", position: 4, state: "queued")
    pr_open = Step.create!(workflow: workflow, kind: "pr_open", position: 5, state: "queued")
    repair.update!(next_step: waiting_gate)
    waiting_gate.update!(next_step: format)
    format.update!(next_step: pr_open)

    created = described_class.refresh_required_reviews!(workflow, repair)

    expect(waiting_gate.reload).to be_queued
    expect(waiting_gate.details).to include("reviewed_head_sha" => "head-c")
    expect(waiting_gate.details).not_to include("review_evidence_superseded")
    expect(format.reload).to be_queued
    expect(pr_open.reload).to be_queued
    expect(adversarial.reload.details).to include("review_evidence_superseded" => true)
    expect(created.map(&:kind)).to eq([ "adversarial_review" ])
    expect(created.first.next_step).to eq(waiting_gate)
  end

  it "moves the continuation's dependency edge onto a rematerialized review" do
    adversarial = collect(kind: "adversarial_review", position: 1, sha: "head-a")
    adversarial.update!(loop_id: "adversarial-loop")
    repair = Step.create!(workflow: workflow, kind: "implement", position: 2, state: "succeeded",
      loop_id: "adversarial-loop")
    repair.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "succeeded", head_sha: "head-c")
    tail = Step.create!(workflow: workflow, kind: "format", position: 3, depends_on_ids: [ repair.id ])
    repair.update!(next_step: tail)

    created = described_class.refresh_required_reviews!(workflow, repair)

    expect(created.map(&:kind)).to eq([ "adversarial_review" ])
    expect(created.first.depends_on_step_ids).to eq([ repair.id ])
    expect(tail.reload.depends_on_step_ids).to eq([ created.first.id ])
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

  it "keeps current evidence after a final repair leaves HEAD unchanged without warning or another review" do
    adversarial = collect(kind: "adversarial_review", position: 1, sha: "head-b", verdict: "needs_work")
    adversarial.update!(loop_id: "adversarial-loop")
    security = collect(kind: "security_review", position: 2, sha: "head-b")
    repair = Step.create!(workflow: workflow, kind: "implement", position: 3, state: "succeeded",
      loop_id: "adversarial-loop")
    repair.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "succeeded", head_sha: "head-b")
    tail = Step.create!(workflow: workflow, kind: "format", position: 4)
    repair.update!(next_step: tail)

    expect(described_class.refresh_required_reviews!(workflow, repair)).to be_empty
    expect(described_class.satisfied_for?(tail)).to be(true)
    expect(adversarial.reload.details).not_to include("review_evidence_superseded")
    expect(workflow.artifact("review_budget_exhaustions")).to be_nil
    expect(workflow.workflow_warnings.where(kind: "required_review_budget_exhausted")).to be_empty
    expect(security.reload.details).not_to include("review_evidence_superseded")
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
