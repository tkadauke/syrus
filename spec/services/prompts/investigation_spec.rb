require "rails_helper"

RSpec.describe Prompts::Investigation do
  let(:definition) { Skills::InvestigateAndReport.definition }

  def build(**overrides)
    described_class.new(definition: definition, request: "Why does /dashboard feel slow?", **overrides).to_s
  end

  it "includes the investigation request body" do
    expect(build).to include("Why does /dashboard feel slow?")
  end

  it "tells the agent no PR or code change is required" do
    text = build

    expect(text).to include("no pull request is\nexpected")
    expect(text).to match(/do not\s+manufacture changes just to produce a diff/)
  end

  it "instructs the agent to capture evidence via submit_artifact/submit_visual_artifact" do
    text = build

    expect(text).to include("submit_artifact")
    expect(text).to include("submit_visual_artifact")
    expect(text).to include("start_preview")
    expect(text).to include("stop_preview")
    expect(text).to match(/artifact `type`/)
  end

  it "instructs the agent not to call submit_report during this step" do
    text = build

    expect(text).to include("investigate")
    expect(text).to match(/DO NOT call `submit_report` here/)
  end

  it "includes epic context when present" do
    epic = Factories.epic(user: Factories.user)
    text = build(epic: epic)

    expect(text).to include("Epic context")
  end

  it "renders a repo-local override definition's instructions instead of the built-in text" do
    override = Skills::Definition.new(
      name: "investigate-and-report",
      description: "Repo-local override",
      parameters: Skills::ParameterSchema.normalize([ { "key" => "request", "type" => "text", "required" => true } ]),
      instructions: "Repo override answer for: {{request}}"
    )

    text = described_class.new(definition: override, request: "Why does /dashboard feel slow?").to_s

    expect(text).to include("Repo override answer for: Why does /dashboard feel slow?")
    expect(text).not_to include("submit_artifact")
  end
end
