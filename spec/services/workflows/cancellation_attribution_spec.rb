require "rails_helper"

RSpec.describe Workflows::CancellationAttribution do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:root_job) { Factories.job_record(user: user, repository: repository) }
  let(:child_job) { Factories.job_record(user: user, repository: repository) }

  def workflow_with_active_step(job, state:, step_state:, run_state: nil)
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: state)
    step = Step.create!(workflow: workflow, kind: "implement", position: 0, state: step_state)
    run = Run.create!(job: job, step: step, trigger_kind: "initial", state: run_state) if run_state
    [ workflow, step, run ]
  end

  # Stacked-job cascade: a running root workflow is cancelled by an operator,
  # a queued descendant on the child job is cancelled as a consequence, and a
  # replacement workflow takes over.
  describe "stacked cascade" do
    let!(:root) { workflow_with_active_step(root_job, state: "running", step_state: "running", run_state: "running") }
    let!(:descendant) { workflow_with_active_step(child_job, state: "queued", step_state: "queued", run_state: "queued") }
    let!(:replacement) { Workflow.create!(job: root_job, trigger_kind: "initial", state: "queued") }

    def cancel_root!
      WorkUnits::WorkflowCancellation.cancel!(
        root[0].tap(&:reload),
        reason: "operator_cancelled",
        cause: {
          kind: "operator_cancellation", initiator_class: "User", initiator_id: user.id,
          control_path: "pending_action#cancel", reason: "token=ghp_abcdefghijklmnop123 stop it",
          source: { "pending_action_id" => 7, "replacement_workflow_id" => replacement.id,
                    "authorization_header" => "Bearer secret", "note" => { "x" => 1 } }
        }
      )
    end

    # Drives the descendant cancellation from inside the root's terminal
    # propagation (as a dependent-job hook does), with NO parent passed in:
    # the parent must come from the ambient propagation context.
    def cancel_root_and_descendant!
      child = descendant[0]
      root_id = root[0].id
      allow_any_instance_of(Workflows::LifecyclePropagation).to receive(:dispatch_hook).and_wrap_original do |m, name|
        m.call(name)
        if name == :after_cancel && m.receiver.send(:workflow).id == root_id
          WorkUnits::WorkflowCancellation.cancel!(child.reload, reason: "job_closed")
        end
      end
      cancel_root!
    end

    it "records a redacted root event before cleanup and propagates it to steps and runs" do
      cancel_root!
      event = root[0].reload.artifacts["cancellation"]

      expect(event).to include(
        "root_workflow_id" => root[0].id, "kind" => "operator_cancellation", "initiator_class" => "User",
        "initiator_id" => user.id.to_s, "control_path" => "pending_action#cancel", "attributed" => true
      )
      expect(event["event_id"]).to be_present
      expect(event["cascade_id"]).to be_present
      expect(event["reason"]).not_to include("ghp_abcdefghijklmnop123")
      expect(event["source"]).to eq("pending_action_id" => 7, "replacement_workflow_id" => replacement.id)

      step_ref = root[1].reload.details["cancellation_attribution"]
      expect(step_ref).to include("event_id" => event["event_id"], "cascade_id" => event["cascade_id"],
                                  "root_workflow_id" => root[0].id, "parent" => { "type" => "workflow", "id" => root[0].id })
      expect(root[1].details["cancelled_by"]).to eq("terminal_workflow_cleanup")
      expect(described_class.run_payload(root[2].reload)).to include("event_id" => event["event_id"], "attribution_available" => true)
    end

    it "links descendants to the same root event and exposes the chain and replacement" do
      cancel_root_and_descendant!
      root_event = root[0].reload.artifacts["cancellation"]
      child_event = descendant[0].reload.artifacts["cancellation"]

      expect(child_event).to include(
        "root_event_id" => root_event["event_id"], "parent_event_id" => root_event["event_id"],
        "cascade_id" => root_event["cascade_id"], "root_workflow_id" => root[0].id,
        "parent_workflow_id" => root[0].id, "kind" => "dependency_invalidation", "attributed" => true
      )
      expect(child_event["event_id"]).not_to eq(root_event["event_id"])
      expect(descendant[1].reload.details["cancellation_attribution"]).to include("root_workflow_id" => root[0].id)

      payload = described_class.payload_for(root[0])
      expect(payload["descendants"].map { |d| d["workflow_id"] }).to eq([ descendant[0].id ])
      expect(payload["replacement_workflow_ids"]).to eq([ replacement.id ])
      expect(described_class.payload_for(descendant[0])).to include("root" => false, "attribution_available" => true)
    end

    it "keeps the original cause across repeated cleanup" do
      cancel_root!
      before = root[0].reload.artifacts["cancellation"]
      step_before = root[1].reload.details["cancellation_attribution"]

      root[0].reload.cancel_active_descendants!(reason: "cancel_terminal_workflow_active_descendants")
      cancel_root!
      described_class.record!(root[0].reload, reason: "later_cleanup", cause: { kind: "direct_cancellation" })

      expect(root[0].reload.artifacts["cancellation"]).to eq(before)
      expect(root[1].reload.details["cancellation_attribution"]).to eq(step_before)
    end

    it "links a replacement created after the cancellation" do
      later = Factories.job_record(user: user, repository: repository)
      WorkUnits::WorkflowCancellation.cancel!(
        root[0].reload, reason: "superseded_by_newer_workflow",
        cause: { kind: "supersession", initiator_class: "system", control_path: "spec" }
      )
      newer = Workflow.create!(job: root_job, trigger_kind: "initial", state: "queued")

      expect(root[0].reload.artifacts.dig("cancellation", "source", "replacement_workflow_id")).to eq(newer.id)
      expect(root[0].workflow_artifact_values.find_by!(key: "cancellation")).to be_present
      expect(described_class.payload_for(root[0])["replacement_workflow_ids"]).to eq([ newer.id ])
      expect(later).to be_present
    end

    it "reports a Run's immediate parent as its Step" do
      cancel_root!
      expect(described_class.run_payload(root[2].reload)["parent"]).to eq("type" => "step", "id" => root[1].id)
    end

    it "drops nested or secret-bearing array source values" do
      WorkUnits::WorkflowCancellation.cancel!(
        root[0].reload, reason: "operator_cancelled",
        cause: { kind: "operator_cancellation", initiator_class: "User",
                 source: { "job_ids" => [ 1, "token=ghp_abcdefghijklmnop123", { "a" => 1 } ] } }
      )
      expect(root[0].reload.artifacts.dig("cancellation", "source", "job_ids")).to eq([ 1, "token=[REDACTED]" ])
    end

    it "serializes through the read_workflow tool" do
      cancel_root_and_descendant!
      workflow = root[0].reload
      tool = Mcp::Tools::ReadWorkflowTool
      payload = tool.send(:workflow_detail_payload, workflow)

      expect(payload[:cancellation]).to include("kind" => "operator_cancellation", "attribution_available" => true)
      expect(payload[:cancellation]["descendants"].size).to eq(1)
      expect(payload[:steps].first[:runs].first[:cancellation]).to include("attribution_available" => true)
    end
  end

  describe "unattributed and legacy records" do
    it "flags a direct cancel! with no cause as an invariant violation" do
      workflow, = workflow_with_active_step(root_job, state: "running", step_state: "running")
      allow(Rails.logger).to receive(:error)

      workflow.cancel!

      expect(Syrus::Metrics.render).to match(/syrus_workflow_cancellations_unattributed_total\{kind="unattributed"\} [1-9]/)

      event = workflow.reload.artifacts["cancellation"]
      expect(event).to include("attributed" => false, "kind" => "unattributed", "initiator_class" => "unknown")
      expect(Rails.logger).to have_received(:error).with(/unattributed_workflow_cancellation workflow_id=#{workflow.id}/)
    end

    it "renders legacy cancelled records as attribution unavailable" do
      workflow, step, run = workflow_with_active_step(root_job, state: "cancelled", step_state: "cancelled", run_state: "cancelled")

      expect(described_class.payload_for(workflow)).to eq("attribution_available" => false)
      expect(described_class.run_payload(run)).to eq("attribution_available" => false)
      expect(described_class.step_payload(step)).to be_nil
    end

    it "returns no cancellation payload for non-cancelled workflows" do
      workflow, = workflow_with_active_step(root_job, state: "running", step_state: "running")
      expect(described_class.payload_for(workflow)).to be_nil
    end
  end

  it "classifies reasons into cause kinds" do
    expect(described_class.kind_for("superseded_by_newer_workflow")).to eq("supersession")
    expect(described_class.kind_for("superseded_by_rebase")).to eq("stack_topology_repair")
    expect(described_class.kind_for("operator_cancelled")).to eq("operator_cancellation")
    expect(described_class.kind_for("something_else")).to eq("direct_cancellation")
  end
end
