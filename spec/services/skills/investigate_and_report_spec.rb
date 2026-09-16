require "rails_helper"

RSpec.describe Skills::InvestigateAndReport do
  describe ".definition" do
    it "renders the investigate-and-report skill definition" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("investigate-and-report")
      expect(definition.description).to match(/investigate-and-report/i)
      expect(definition.parameters.size).to eq(1)
      expect(definition.parameters.first.key).to eq("request")
      expect(definition.parameters.first.required).to eq(true)
    end

    it "renders instructions that forbid manufacturing a diff and reference the request parameter" do
      instructions = described_class.definition.instructions

      expect(instructions).to include("no pull request is")
      expect(instructions).to match(/do not\s+manufacture changes just to produce a diff/)
      expect(instructions).to include("{{request}}")
    end

    it "points the agent at evidence-capture and preview tools" do
      instructions = described_class.definition.instructions

      expect(instructions).to include("submit_artifact")
      expect(instructions).to include("submit_visual_artifact")
      expect(instructions).to include("start_preview")
      expect(instructions).to include("stop_preview")
    end
  end
end
