require "rails_helper"

RSpec.describe "Plugin family stability" do
  it "promotes only capabilities backed by independent implementations and contract tests" do
    violations = Syrus::Plugin::FamilyPromotion.new.violations
    expect(violations).to be_empty, violations.map(&:message).join("\n")
  end
end
