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
    result = patch(nodes: [ "adversarial_review" ], after_kind: "implement")

    expect(result).to be_applied
    kinds = WorkflowTemplates.step_kinds_in(workflow.reload.chain_template)
    expect(kinds.each_cons(2)).to include([ "implement", "adversarial_review" ])
  end

  it "appends when no anchor is named" do
    result = patch(nodes: [ "adversarial_review" ])

    expect(result).to be_applied
    expect(WorkflowTemplates.step_kinds_in(result.graph).last).to eq("adversarial_review")
  end

  it "records who patched, why, and what was added" do
    patch(nodes: [ "adversarial_review" ], reason: "UI change needs a reviewer")

    record = workflow.reload.artifact("workflow_patches").last
    expect(record).to include(
      "operation" => "insert_after", "author" => "agent",
      "added_kinds" => [ "adversarial_review" ], "reason" => "UI change needs a reviewer"
    )
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
