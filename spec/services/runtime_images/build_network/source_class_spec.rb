require "rails_helper"

RSpec.describe RuntimeImages::BuildNetwork::SourceClass do
  it "registers every source class by key" do
    expect(described_class.keys).to match_array(%w[os_mirror language_registry source_host artifact_registry exact_domain repository_namespace internal_mirror])
    expect { described_class.for("nope") }.to raise_error(KeyError)
  end

  it "describes ecosystem inputs without requiring callers to branch on source-class names" do
    expect(described_class.for("os_mirror")).to have_attributes(ecosystem_input_mode: "freeform", ecosystems: nil)
    expect(described_class.for("internal_mirror")).to have_attributes(ecosystem_input_mode: "freeform", ecosystems: nil)
    expect(described_class.for("language_registry")).to have_attributes(
      ecosystem_input_mode: "select", ecosystems: include("npm", "pypi")
    )
    expect(described_class.for("exact_domain")).to have_attributes(ecosystem_input_mode: "none", ecosystems: nil)
  end
end

RSpec.describe RuntimeImageBuildNetworkRule do
  def build_rule(**attrs) = described_class.new({ source_class: "source_host", host: "github.com" }.merge(attrs))

  it "is valid for a plain host and canonicalizes it" do
    rule = build_rule(host: " GitHub.COM. ")
    expect(rule).to be_valid
    expect(rule.host).to eq("github.com")
    expect(rule.port).to eq(443)
  end

  it "rejects literal IPs, unknown classes, and bad ports" do
    expect(build_rule(host: "10.0.0.1")).not_to be_valid
    expect(build_rule(host: "2130706433")).not_to be_valid
    expect(build_rule(source_class: "wildcard")).not_to be_valid
    expect(build_rule(port: 0)).not_to be_valid
  end

  it "requires an ecosystem for language registries, restricted to known ones" do
    expect(build_rule(source_class: "language_registry", host: "pypi.org")).not_to be_valid
    expect(build_rule(source_class: "language_registry", host: "pypi.org", ecosystem: "cobol")).not_to be_valid
    expect(build_rule(source_class: "language_registry", host: "pypi.org", ecosystem: "pypi")).to be_valid
  end

  it "requires a well-formed path prefix for repository namespaces and forbids it elsewhere" do
    expect(build_rule(source_class: "repository_namespace")).not_to be_valid
    expect(build_rule(source_class: "repository_namespace", path_prefix: "acme")).not_to be_valid
    expect(build_rule(source_class: "repository_namespace", path_prefix: "/acme/../x/")).not_to be_valid
    expect(build_rule(source_class: "repository_namespace", path_prefix: "/acme/")).to be_valid
    expect(build_rule(path_prefix: "/acme/")).not_to be_valid
  end

  it "allows required only on internal mirrors" do
    expect(build_rule(required: true)).not_to be_valid
    expect(build_rule(source_class: "internal_mirror", host: "m.corp.example", required: true)).to be_valid
  end

  it "keeps rules unique per class, host, port, and path" do
    build_rule.save!
    expect(build_rule).not_to be_valid
    expect(build_rule(port: 80)).to be_valid
  end
end
