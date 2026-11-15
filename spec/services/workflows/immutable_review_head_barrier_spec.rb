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
end
