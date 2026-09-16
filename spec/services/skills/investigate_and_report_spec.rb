require "rails_helper"

RSpec.describe Skills::InvestigateAndReport do
  describe ".definition" do
    it "renders a read-only investigate-and-report skill definition" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("investigate-and-report")
      expect(definition.description).to match(/read-only/i)
      expect(definition.parameters.size).to eq(1)
      expect(definition.parameters.first.key).to eq("request")
      expect(definition.parameters.first.required).to eq(true)
    end

    it "renders instructions that forbid making changes, name evidence tools, and reference the request parameter" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/read-only/i)
      expect(instructions).to match(/do not edit, create, or\s+delete/i)
      expect(instructions).to include("start_preview")
      expect(instructions).to include("submit_artifact")
      expect(instructions).to include("submit_visual_artifact")
      expect(instructions).to include("{{request}}")
    end
  end
end
