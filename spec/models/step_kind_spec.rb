require "rails_helper"

RSpec.describe StepKind do
  it "is the canonical source for Step validation values and handler registry" do
    expect(Step::KINDS).to eq(described_class.values)
    expect(Steps::REGISTRY).to eq(described_class.registry)
  end

  it "has a label, style, and loadable handler for every step kind" do
    described_class.values.each do |kind|
      entry = described_class.fetch(kind)

      expect(entry.label).to be_present, "expected #{kind} to have a label"
      expect(entry.style).to be_present, "expected #{kind} to have a style"
      expect(entry.handler_class).to be < Steps::Base
    end
  end

  it "gives newer non-agentic steps deliberate product copy" do
    expect(described_class.label_for("apply_suggestions")).to eq("Apply suggestions")
    expect(described_class.style_for("apply_suggestions")).to eq("bg-lime-100 text-lime-700")
    expect(described_class.label_for("auto_merge")).to eq("Auto-merge")
    expect(described_class.style_for("auto_merge")).to eq("bg-green-100 text-green-700")
  end
end
