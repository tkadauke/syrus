require "rails_helper"

RSpec.describe PlannedExecutionParams do
  it "returns an empty hash when no planned execution params are present" do
    expect(described_class.from_params({ "title" => "x" })).to eq({})
  end

  it "reads prefixed top-level params" do
    attrs = described_class.from_params(
      planned_execution_target_label: "//web:app",
      planned_execution_capabilities: { "os" => [ "linux" ] }
    )

    expect(attrs[:planned_execution_target_label]).to eq("//web:app")
    expect(attrs[:planned_execution_capabilities]).to eq("os" => [ "linux" ])
    expect(attrs[:planned_execution_source]).to eq("operator")
  end

  it "reads a nested planned_execution hash and honors an explicit source" do
    attrs = described_class.from_params(
      "planned_execution" => { "capabilities" => { "os" => [ "macos" ] }, "source" => "explicit", "project_label" => "p" }
    )

    expect(attrs[:planned_execution_capabilities]).to eq("os" => [ "macos" ])
    expect(attrs[:planned_execution_source]).to eq("explicit")
    expect(attrs[:planned_execution_project_label]).to eq("p")
  end
end
