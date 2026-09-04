require "rails_helper"

# workflow-engine-v3 primitive E. WorkUnit already models members and locks
# honestly, but the graph ran over a representative Job -- so a merge train's
# real shape lived inside Steps::MergeTrainBuild and needed its own retry
# policy, failure handler, and repair semantics. These node types are what let
# that shape live in a template.
RSpec.describe "Unit-scoped workflow nodes" do
  describe Workflows::ForEachMember do
    it "declares the step it fans out over its unit's members" do
      node = described_class.new("merge_train_build")

      expect(node).to be_for_each_member
      expect(node.step_kinds).to eq([ "merge_train_build" ])
      expect(node.to_chain_template).to include("type" => "for_each_member", "step" => "merge_train_build")
    end

    # "What happens if this is preempted mid-train" gets a declared per-node
    # answer, not only a per-definition one.
    it "attaches a preemption policy to the node" do
      expect(described_class.new("x", preemption: "rebuild").to_chain_template["preemption"]).to eq("rebuild")
      expect(described_class.new("x").to_chain_template["preemption"]).to eq("checkpoint")
    end

    it "refuses a preemption policy that is not one of the three that exist" do
      expect { described_class.new("x", preemption: "improvise") }
        .to raise_error(ArgumentError, /unknown preemption/)
    end
  end

  describe Workflows::Barrier do
    it "declares the step that waits for the fan-out" do
      node = described_class.new("merge_train_reconcile")

      expect(node).to be_barrier
      expect(node.to_chain_template).to include("type" => "barrier", "step" => "merge_train_reconcile")
    end
  end

  describe "materialization" do
    let(:job) { Factories.job }

    def instantiate(nodes)
      klass = Class.new(Workflows::Base) do
        def self.trigger_kind = "initial"
      end
      klass.define_singleton_method(:step_kinds) { nodes }
      klass.instantiate(job: job)
    end

    # Members are only known at run time, so the fan-out materializes as one
    # Step and inserts the rest when it runs -- the shape GraderFanout uses.
    it "materializes a fan-out as a single step carrying its declaration" do
      workflow = instantiate([ Workflows::ForEachMember.new("merge_train_build", preemption: "rebuild"), "summarize" ])
      step = workflow.steps.order(:position).first

      expect(step.kind).to eq("merge_train_build")
      expect(step.details).to include("type" => "for_each_member", "preemption" => "rebuild")
    end

    it "records the node types in the persisted template" do
      workflow = instantiate([ Workflows::Barrier.new("summarize") ])

      expect(workflow.chain_template.first).to include("type" => "barrier")
    end
  end
end
