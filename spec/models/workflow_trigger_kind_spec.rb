require "rails_helper"

RSpec.describe Workflow::TriggerKind do
  it "is the canonical source for Workflow and Run trigger validation values" do
    expect(Workflow::TRIGGER_KINDS).to eq(described_class.values)
    expect(Run::TRIGGER_KINDS).to eq(described_class.values)
    expect(Workflows::REGISTRY).to eq(described_class.registry)
  end

  it "has a label, style, and loadable template for every trigger kind" do
    described_class.values.each do |kind|
      entry = described_class.fetch(kind)

      expect(entry.label).to be_present, "expected #{kind} to have a label"
      expect(entry.style).to be_present, "expected #{kind} to have a style"
      expect(entry.template_class).to be < Workflows::Base
      expect(described_class::RUNTIME_ROLES).to include(entry.runtime_role), "expected #{kind} to have a valid runtime role"
    end
  end

  it "classifies trigger kinds by runtime role deliberately" do
    expect(described_class.runtime_role_values("first_class")).to contain_exactly(
      "initial",
      "pr_comment",
      "chat_feedback",
      "ci_failure",
      "rebase",
      "stack_rebase",
      "promotion",
      "hotfix_sync",
      "upstream_export",
      "auto_merge",
      "external_pr_merge",
      "merge_train",
      "retry",
      "manual_visual_review",
      "manual",
      "resume",
      "coding_handoff",
      "local_mode_handoff",
      "main_branch_repair",
      "manual_agentic_run",
      "external_pr_ingest",
      "external_pr_feedback",
      "skill",
      "deploy"
    )
    expect(described_class.runtime_role_values("child")).to contain_exactly("landing_validation", "merge_train_validation")
    expect(described_class.runtime_role_values("infrastructure")).to contain_exactly("main_grader", "agent_insight")
    expect(described_class.runtime_role_values("legacy")).to contain_exactly("replay")
  end

  it "gives newer workflow triggers deliberate product copy" do
    expect(described_class.label_for("auto_merge")).to eq("Auto-merge")
    expect(described_class.style_for("auto_merge")).to eq("bg-green-100 text-green-700")
    expect(described_class.label_for("chat_feedback")).to eq("Chat feedback")
    expect(described_class.style_for("chat_feedback")).to eq("bg-indigo-100 text-indigo-700")
  end
end
