require "rails_helper"

RSpec.describe TestCaseIdentity do
  it "uses the source file instead of formatter-specific suite names" do
    junit = { "suite_name" => "Widgets::Pricing", "name" => "calculates tax", "file_path" => "spec/models/widget_spec.rb" }
    json = { "suite_name" => "Widget pricing", "name" => "calculates tax", "file_path" => "./spec/models/widget_spec.rb" }

    expect(described_class.for(junit)).to eq(described_class.for(json))
    expect(described_class.for(junit)).to eq("spec/models/widget_spec.rb\0calculates tax")
  end

  it "normalizes missing suite labels without inventing distinct identities" do
    expect(described_class.for("suite_name" => "UNKNOWN", "name" => "fails"))
      .to eq("unknown\0fails")
  end
end
