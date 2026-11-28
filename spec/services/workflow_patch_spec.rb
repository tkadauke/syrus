require "rails_helper"

# workflow-engine-v3 A7. An agent can add work to itself, never remove work,
# and never grant itself the ability to publish. All three are enforced here
# rather than trusted, which is why the plan sequences agent authoring last.
RSpec.describe WorkflowPatch do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }

  def patch(**overrides)
    described_class.apply!(**{ workflow: workflow, operation: "insert_after", author: "agent" }.merge(overrides))
  end

  it "inserts a step after a named anchor" do
    implement_step = workflow.steps.find_by!(kind: "implement")
    original_continuation = implement_step.next_step

    result = patch(nodes: [ "adversarial_review" ], after_kind: "implement")

    expect(result).to be_applied
    kinds = WorkflowTemplates.step_kinds_in(workflow.reload.chain_template)
    expect(kinds.each_cons(2)).to include([ "implement", "adversarial_review" ])

    inserted = workflow.steps.find_by!(kind: "adversarial_review")
    expect(implement_step.reload.next_step).to eq(inserted)
    expect(inserted.next_step).to eq(original_continuation)
    expect(inserted.depends_on_step_ids).to eq([ implement_step.id ])
    expect(original_continuation.reload.depends_on_step_ids).to eq([ inserted.id ])
  end

  it "appends when no anchor is named" do
    original_tail = workflow.steps.order(:position, :id).last

    result = patch(nodes: [ "adversarial_review" ])

    expect(result).to be_applied
    expect(WorkflowTemplates.step_kinds_in(result.graph).last).to eq("adversarial_review")

    inserted = workflow.steps.find_by!(kind: "adversarial_review")
    expect(original_tail.reload.next_step).to eq(inserted)
    expect(inserted.next_step).to be_nil
    expect(inserted.depends_on_step_ids).to eq([ original_tail.id ])
  end

  it "materializes multiple inserted steps as runnable live steps" do
    implement_step = workflow.steps.find_by!(kind: "implement")
    original_continuation = implement_step.next_step

    result = patch(nodes: [ "adversarial_review", "security_review" ], after_kind: "implement")

    expect(result).to be_applied
    inserted_positions = implement_step.reload.position + 1..implement_step.position + 2
    inserted = workflow.steps.where(position: inserted_positions).order(:position).to_a
    expect(inserted.map(&:kind)).to eq(%w[adversarial_review security_review])
    expect(implement_step.reload.next_step).to eq(inserted.first)
    expect(inserted.first.next_step).to eq(inserted.second)
    expect(inserted.second.next_step).to eq(original_continuation)
    expect(inserted.first.depends_on_step_ids).to eq([ implement_step.id ])
    expect(inserted.second.depends_on_step_ids).to eq([ inserted.first.id ])
    expect(original_continuation.reload.depends_on_step_ids).to eq([ inserted.second.id ])
  end

  it "starts the inserted step when the anchor already finished and the continuation has not started" do
    implement_step = workflow.steps.find_by!(kind: "implement")
    implement_step.update_columns(state: "succeeded")

    result = patch(nodes: [ "adversarial_review" ], after_kind: "implement")

    expect(result).to be_applied
    inserted = workflow.steps.find_by!(kind: "adversarial_review")
    expect(inserted.runs.count).to eq(1)
    expect(inserted.runs.last).to be_queued
  end

  it "reports not applied when inserting after a terminal anchor whose continuation already started" do
    implement_step = workflow.steps.find_by!(kind: "implement")
    original_continuation = implement_step.next_step
    implement_step.update_columns(state: "succeeded")
    original_continuation.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      iteration: original_continuation.iteration
    )

    result = patch(nodes: [ "adversarial_review" ], after_kind: "implement")

    expect(result).not_to be_applied
    expect(result.reason).to match(/continuation already started/)
    expect(workflow.steps.where(kind: "adversarial_review")).to be_empty
  end

  it "records who patched, why, and what was added" do
    patch(nodes: [ "adversarial_review" ], reason: "UI change needs a reviewer")

    record = workflow.reload.artifact("workflow_patches").last
    expect(record).to include(
      "operation" => "insert_after", "author" => "agent",
      "added_kinds" => [ "adversarial_review" ], "reason" => "UI change needs a reviewer"
    )
  end

  # The patch is computed from the Workflow it is handed, which another patch
  # may have changed since it was loaded. Taking the lock does not refresh the
  # in-memory graph, so the second writer must re-read under the lock.
  describe "against a Workflow loaded before another patch committed" do
    it "keeps the other patch's graph and history" do
      stale = Workflow.find(workflow.id)
      expect(described_class.apply!(workflow: Workflow.find(workflow.id), operation: "insert_after", author: "agent",
                                    nodes: [ "adversarial_review" ], after_kind: "implement")).to be_applied

      result = described_class.apply!(workflow: stale, operation: "insert_after", author: "agent", nodes: [ "security_review" ])

      expect(result).to be_applied
      kinds = WorkflowTemplates.step_kinds_in(workflow.reload.chain_template)
      expect(kinds).to include("adversarial_review", "security_review")
      expect(workflow.artifacts.fetch("workflow_patches").size).to eq(2)
    end

    it "refuses once the Workflow is no longer active" do
      stale = Workflow.find(workflow.id)
      Workflow.where(id: workflow.id).update_all(state: "cancelled")

      result = described_class.apply!(workflow: stale, operation: "insert_after", author: "agent", nodes: [ "security_review" ])

      expect(result).not_to be_applied
      expect(result.reason).to eq("workflow is not active")
      expect(workflow.steps.where(kind: "security_review")).not_to exist
    end
  end

  describe "guardrails" do
    # The checks a workflow exists to satisfy cannot be patched away by the
    # thing being checked.
    it "refuses to add a step that publishes" do
      result = patch(nodes: [ "auto_merge" ])

      expect(result).not_to be_applied
      expect(result.reason).to match(/may not add publication step/)
    end

    it "refuses a step kind that does not exist" do
      expect(patch(nodes: [ "summon_daemon" ]).reason).to match(/unknown step kind/)
    end

    it "refuses an unknown operation" do
      expect(patch(operation: "delete_step", nodes: [ "implement" ]).reason).to match(/unknown operation/)
    end

    it "reports not applied for operations that do not affect live steps" do
      result = described_class.apply!(workflow: workflow, operation: "mark_optional_done", author: "agent")

      expect(result).not_to be_applied
      expect(result.reason).to match(/does not change the live workflow graph/)
    end

    it "refuses an unattributed patch" do
      expect(patch(author: "anonymous", nodes: [ "implement" ]).reason).to match(/unknown author/)
    end

    it "refuses to insert after a step the workflow does not have" do
      expect(patch(nodes: [ "implement" ], after_kind: "nope").reason).to match(/no step "nope"/)
    end

    it "leaves the graph untouched when it refuses" do
      before_graph = workflow.chain_template

      patch(nodes: [ "auto_merge" ])

      expect(workflow.reload.chain_template).to eq(before_graph)
    end
  end
end
