require "rails_helper"

RSpec.describe Skills::Investigate do
  describe ".definition" do
    it "renders a read-only, question-answering skill definition" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("investigate")
      expect(definition.description).to match(/read-only/i)
      expect(definition.parameters.size).to eq(1)
      expect(definition.parameters.first.key).to eq("question")
      expect(definition.parameters.first.required).to eq(true)
    end

    it "renders instructions that forbid making changes and reference the question parameter" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/read-only/i)
      expect(instructions).to match(/do not edit, create, or delete/i)
      expect(instructions).to include("{{question}}")
    end
  end
end
