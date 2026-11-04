require "rails_helper"

RSpec.describe "Unified permission cutover" do
  it "keeps every executable tool covered by a descriptor and canonical tool-set bundle" do
    registrations = Permissions::CapabilityRegistryValidator.for_application.registrations.reject(&:ungated)

    expect(registrations).not_to be_empty
    registrations.each do |registration|
      expect(registration.descriptor).to be_present,
        "#{registration.source} #{registration.surface} tool #{registration.tool_name.inspect} has no descriptor"
      expect(Permissions::ToolSetBundles::DEFINITIONS).to have_key(registration.descriptor.tool_set_bundle),
        "#{registration.tool_name.inspect} has no canonical tool-set bundle"
    end
  end

  it "has no observational shadow authority path" do
    expect(defined?(Permissions::ShadowEvaluator)).to be_nil
    expect(Rails.root.join("app/services/mcp_tool_registry.rb").read).not_to include("ShadowEvaluator")
  end
end
