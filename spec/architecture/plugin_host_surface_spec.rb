require "rails_helper"

RSpec.describe "Built-in plugin host surface", :ci_only do
  def member_exists?(constant, name)
    return true if constant.respond_to?(name) || constant.method_defined?(name)
    return true if constant.is_a?(Class) && constant.allocate.respond_to?(name)

    constant.const_defined?(:ClassMethods, false) && constant.const_get(:ClassMethods, false).method_defined?(name)
  rescue TypeError
    false
  end

  it "contains every core constant referenced by a built-in plugin and stays minimal" do
    findings = Admin::PluginHostSurfaceAudit.new.findings

    expect(findings).to eq([]), findings.join("\n")
    expect(Syrus::PluginHostSurface.new.lookup("Syrus::PluginApi")).to be_present
    expect(Syrus::PluginHostSurface.new.lookup("Syrus::Plugin::Callbacks")).to be_present
  end

  it "keeps every public contract documented and resolvable" do
    expect(Syrus::Host.apis.size).to be_between(25, 45)
    expect(Syrus::Host.apis.map(&:name)).to all(start_with("Syrus::Host::"))

    failures = Syrus::Host.apis.flat_map do |api|
      constant = api.name.safe_constantize
      next [ "#{api.name} does not resolve" ] unless constant
      next [ "#{api.name} has no summary" ] if api.summary.blank?
      next [ "#{api.name} has invalid since #{api.since.inspect}" ] unless Gem::Version.correct?(api.since)

      api.members.filter_map do |member|
        "#{api.name} is missing #{member}" unless member_exists?(constant, member)
      end
    end

    expect(failures).to eq([]), failures.join("\n")
  end
end
