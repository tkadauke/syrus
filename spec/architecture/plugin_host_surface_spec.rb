require "rails_helper"

RSpec.describe "Built-in plugin host surface", :ci_only do
  def member_exists?(constant, name)
    return true if constant.respond_to?(name) || constant.method_defined?(name)
    return true if constant.respond_to?(:const_defined?) && name.match?(/\A[A-Z]/) && constant.const_defined?(name)
    return true if constant.is_a?(Class) && constant.allocate.respond_to?(name)

    constant.const_defined?(:ClassMethods, false) && constant.const_get(:ClassMethods, false).method_defined?(name)
  rescue TypeError
    false
  end

  it "allows built-in plugins to use only public APIs or explicit exceptions" do
    findings = Admin::PluginHostSurfaceAudit.new.findings

    expect(findings).to eq([]), findings.join("\n")
    expect(Admin::PluginHostSurfaceInventory.new.results.map(&:tier).uniq).to all(be_in(%w[public allowlisted]))
  end

  it "keeps every public contract documented and resolvable" do
    expect(Syrus::Host.apis.size).to be >= 25
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
