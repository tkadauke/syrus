require "rails_helper"

RSpec.describe "Built-in plugin host surface", :ci_only do
  it "contains every core constant referenced by a built-in plugin and stays minimal" do
    findings = Admin::PluginHostSurfaceAudit.new.findings

    expect(findings).to eq([]), findings.join("\n")
  end
end
