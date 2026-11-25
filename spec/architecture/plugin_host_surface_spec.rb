require "rails_helper"

RSpec.describe "Built-in plugin host surface", :ci_only do
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

      []
    end

    expect(failures).to eq([]), failures.join("\n")
  end
end
