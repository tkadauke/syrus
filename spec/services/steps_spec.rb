require "rails_helper"

RSpec.describe Steps do
  describe ".handler_for" do
    it "returns the right class for every documented kind" do
      Step::KINDS.each do |kind|
        expect(described_class.handler_for(kind)).to be < Steps::Base
      end
    end

    it "matches each kind to a uniquely-named handler" do
      expect(described_class.handler_for("implement")).to eq(Steps::Implement)
      expect(described_class.handler_for("summarize")).to eq(Steps::Summarize)
      expect(described_class.handler_for("pr_open")).to eq(Steps::PrOpen)
      expect(described_class.handler_for("respond")).to eq(Steps::Respond)
      expect(described_class.handler_for("summarize_amend")).to eq(Steps::SummarizeAmend)
      expect(described_class.handler_for("push")).to eq(Steps::Push)
      expect(described_class.handler_for("push_agent_rebase")).to eq(Steps::PushAgentRebase)
      expect(described_class.handler_for("push_after_rebase")).to eq(Steps::PushAfterRebase)
      expect(described_class.handler_for("analyze_and_fix")).to eq(Steps::AnalyzeAndFix)
      expect(described_class.handler_for("auto_rebase")).to eq(Steps::AutoRebase)
      expect(described_class.handler_for("agent_rebase")).to eq(Steps::AgentRebase)
      expect(described_class.handler_for("force_push")).to eq(Steps::ForcePush)
      expect(described_class.handler_for("stack_auto_rebase")).to eq(Steps::StackAutoRebase)
      expect(described_class.handler_for("stack_agent_rebase")).to eq(Steps::StackAgentRebase)
      expect(described_class.handler_for("stack_force_push")).to eq(Steps::StackForcePush)
      expect(described_class.handler_for("grade")).to eq(Steps::Grade)
      expect(described_class.handler_for("auto_merge")).to eq(Steps::AutoMerge)
      expect(described_class.handler_for("merge_train_reconcile")).to eq(Steps::MergeTrainReconcile)
      expect(described_class.handler_for("manual")).to eq(Steps::Manual)
    end

    it "raises on unknown kind" do
      expect { described_class.handler_for("flop") }.to raise_error(ArgumentError, /step kind/)
    end

    it "every Step::KINDS entry has a registry mapping (no orphans)" do
      registered = Steps::REGISTRY.keys
      expect(Step::KINDS - registered).to be_empty
      expect(registered - Step::KINDS).to be_empty
    end
  end
end
