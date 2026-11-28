require "rails_helper"

RSpec.describe Coworkers::EnvironmentPublicationRisk do
  def snapshot(**attributes)
    described_class::Snapshot.new(**{
      source_digest: "source-a", base_digest: "base-a", dependency_digest: "deps-a",
      sbom_digest: "sbom-a", vulnerabilities: { high: 1 }, secret_findings: 0,
      network_sources: [ "rubygems.org" ], network_policy_digest: "network-a",
      policy_digest: "policy-a", policy_result: "passed", image_size: 10
    }.merge(attributes))
  end

  it "computes every material publication delta and a safe summary" do
    risk = described_class.call(
      active: snapshot,
      candidate: snapshot(source_digest: "source-b", dependency_digest: "deps-b", sbom_digest: "sbom-b",
        vulnerabilities: { high: 2, critical: 1 }, secret_findings: 1,
        network_sources: [ "rubygems.org", "npmjs.org" ], policy_digest: "policy-b")
    )

    expect(risk.deltas).to include("source", "base", "dependencies", "sbom", "vulnerabilities", "secrets", "network", "policy")
    expect(risk.deltas.dig("vulnerabilities", "high", "added")).to eq(1)
    expect(risk.deltas.dig("network", "added")).to eq([ "npmjs.org" ])
    expect(risk.summary).to eq(
      "changed_material" => %w[source dependencies sbom], "vulnerabilities_added" => 2,
      "secret_findings" => 1, "network_sources_added" => 1, "policy_result" => "passed"
    )
  end

  it "treats the first publication as a delta from no active environment" do
    risk = described_class.call(candidate: snapshot)

    expect(risk.deltas.dig("source", "changed")).to be(true)
    expect(risk.deltas.dig("vulnerabilities", "high", "added")).to eq(1)
  end
end
