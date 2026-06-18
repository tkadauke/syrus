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
    end
  end

  it "gives newer workflow triggers deliberate product copy" do
    expect(described_class.label_for("auto_merge")).to eq("Auto-merge")
    expect(described_class.style_for("auto_merge")).to eq("bg-green-100 text-green-700")
    expect(described_class.label_for("chat_feedback")).to eq("Chat feedback")
    expect(described_class.style_for("chat_feedback")).to eq("bg-indigo-100 text-indigo-700")
    expect(described_class.label_for("local_dev")).to eq("Local dev")
    expect(described_class.style_for("local_dev")).to eq("bg-blue-100 text-blue-700")
  end
end
