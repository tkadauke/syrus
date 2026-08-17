require "rails_helper"

RSpec.describe Prompts::ChatSkillInvocation do
  let(:definition) do
    Skills::Definition.new(
      name: "investigate",
      description: "Investigate something.",
      parameters: [
        Skills::ParameterSchema::Field.new(key: "question", type: "string", required: true, label: "Question", options: nil, default: nil, depends_on: nil)
      ],
      instructions: "Look into: {{question}}"
    )
  end
  let(:resolution) { Skills::Resolution.new(source: :built_in, path: nil, klass: Skills::Investigate, definition: definition) }

  subject(:prompt) { described_class.new(resolution: resolution, args: { "question" => "why is CI red?" }).to_s }

  it "names the invoked skill" do
    expect(prompt).to include("/investigate")
  end

  it "renders the skill's instructions with the submitted args substituted" do
    expect(prompt).to include("Look into: why is CI red?")
  end

  it "tells the agent a diff still needs the normal Coding Mode handoff confirmation" do
    expect(prompt).to include("complete_implement_step")
    expect(prompt).to include("submit_coding_changes")
    expect(prompt).to include("requiring operator confirmation")
  end

  it "tells the agent a no-diff result is a complete, successful outcome" do
    expect(prompt).to include("no diff")
    expect(prompt).to include("complete, successful")
    expect(prompt).to include("nothing")
  end
end
