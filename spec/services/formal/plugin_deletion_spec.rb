require "rails_helper"

RSpec.describe Formal::PluginDeletion do
  def violation(source:, target:, path:)
    Admin::PluginSourceBoundaryAudit::Violation.new(source:, target:, path:, line: 1, evidence: "Coworkers::Thing", reason: "constant")
  end

  let(:audit) { instance_double(Admin::PluginSourceBoundaryAudit, bundled_manifests: []) }

  before do
    allow(audit).to receive(:removed_plugin_names_for) { |name| name == "coworkers" ? %w[coworkers coworkers_extra] : [ name ] }
    allow(audit).to receive(:plugin_violations).and_return([])
  end

  it "calls a plugin safe to delete when nothing kept refers to it" do
    allow(audit).to receive(:core_violations).and_return([])

    expect(described_class.call("coworkers", audit: audit).verdict).to eq(:safe)
  end

  it "calls a plugin broken when core refers to it, naming the edge" do
    allow(audit).to receive(:core_violations).and_return([ violation(source: "core", target: "coworkers", path: "app/models/job.rb") ])

    result = described_class.call("coworkers", audit: audit)

    expect(result.verdict).to eq(:broken)
    expect(result.crossing.map(&:from)).to eq([ "app/models/job.rb" ])
  end

  it "calls a plugin broken when core refers to one of its dependents, which go with it" do
    allow(audit).to receive(:core_violations).and_return([ violation(source: "core", target: "coworkers_extra", path: "app/models/job.rb") ])

    expect(described_class.call("coworkers", audit: audit).verdict).to eq(:broken)
  end

  it "leaves an unrelated plugin safe when core refers to a different one" do
    allow(audit).to receive(:core_violations).and_return([ violation(source: "core", target: "coworkers", path: "app/models/job.rb") ])

    expect(described_class.call("calendar", audit: audit).verdict).to eq(:safe)
  end

  it "scans the source once for every plugin's verdict" do
    allow(audit).to receive(:core_violations).and_return([])
    checker = described_class.new(audit)

    %w[coworkers calendar mail].each { |plugin| checker.call(plugin) }

    expect(audit).to have_received(:core_violations).once
  end
end
