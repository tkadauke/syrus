require "rails_helper"

RSpec.describe RuntimeImages::BuildNetwork::Policy do
  def rule(source_class, host, port: 443, path_prefix: "", ecosystem: "", required: false)
    described_class::Rule.new(source_class: source_class, host: host, port: port, path_prefix: path_prefix, ecosystem: ecosystem, required: required)
  end

  def decide(rules, host, port = 443, path: nil) = described_class.new(rules).decide(host: host, port: port, path: path)

  it "denies everything with no rules" do
    expect(decide([], "github.com").reason).to eq("not_allowlisted")
    expect(described_class.new([])).to be_empty
  end

  {
    "os_mirror" => [ "deb.debian.org", { ecosystem: "debian" } ],
    "language_registry" => [ "registry.npmjs.org", { ecosystem: "npm" } ],
    "source_host" => [ "github.com", {} ],
    "artifact_registry" => [ "ghcr.io", {} ],
    "exact_domain" => [ "example.com", {} ],
    "internal_mirror" => [ "mirror.corp.example", {} ]
  }.each do |klass, (host, opts)|
    it "allows a declared #{klass} host and port only" do
      rules = [ rule(klass, host, **opts) ]
      expect(decide(rules, host)).to be_allowed
      expect(decide(rules, host.upcase)).to be_allowed
      expect(decide(rules, host, 80)).not_to be_allowed
      expect(decide(rules, "sub.#{host}").reason).to eq("not_allowlisted")
      expect(decide(rules, "evil-#{host}").reason).to eq("not_allowlisted")
    end
  end

  it "names undeclared package registries" do
    rules = [ rule("language_registry", "pypi.org", ecosystem: "pypi") ]
    expect(decide(rules, "pypi.org")).to be_allowed
    expect(decide(rules, "registry.npmjs.org").reason).to eq("undeclared_package_registry")
    expect(decide(rules, "rubygems.org").reason).to eq("undeclared_package_registry")
  end

  it "forbids literal IPs in every notation, even when a rule names the same address" do
    rules = [ rule("exact_domain", "example.com") ]
    %w[1.2.3.4 2130706433 0x7f000001 [::1] 169.254.169.254].each do |literal|
      expect(decide(rules, literal).reason).to eq("literal_ip_forbidden"), literal
    end
  end

  it "rejects invalid hosts and ports" do
    expect(decide([], "localhost").reason).to eq("invalid_host")
    expect(decide([], "example.com", 0).reason).to eq("invalid_port")
    expect(decide([], "example.com", 70_000).reason).to eq("invalid_port")
  end

  describe "repository namespaces" do
    let(:rules) { [ rule("repository_namespace", "github.com", port: 80, path_prefix: "/acme/") ] }

    it "matches only inside the path prefix" do
      expect(decide(rules, "github.com", 80, path: "/acme/widgets.git/info/refs")).to be_allowed
      expect(decide(rules, "github.com", 80, path: "/other/widgets.git").reason).to eq("not_allowlisted")
      expect(decide(rules, "github.com", 80, path: "/acme-evil/x").reason).to eq("not_allowlisted")
    end

    it "refuses traversal and encoded separators out of the namespace" do
      ["/acme/../other/x", "/acme/%2e%2e/other", "/acme/%2F../x", "/acme//x", "/acme/..\\x"].each do |path|
        expect(decide(rules, "github.com", 80, path: path)).not_to be_allowed, path
      end
    end

    it "never admits a tunnel whose path it cannot see" do
      tunnel = [ rule("repository_namespace", "github.com", path_prefix: "/acme/") ]
      expect(decide(tunnel, "github.com", 443, path: nil).reason).to eq("path_not_inspectable")
    end
  end

  describe "required internal mirrors" do
    let(:rules) do
      [ rule("language_registry", "registry.npmjs.org", ecosystem: "npm"), rule("language_registry", "pypi.org", ecosystem: "pypi"),
        rule("os_mirror", "deb.debian.org", ecosystem: "debian"), rule("source_host", "github.com"),
        rule("internal_mirror", "npm.corp.example", ecosystem: "npm", required: true) ]
    end

    it "displaces the public sources of the mirror's ecosystem only" do
      expect(decide(rules, "registry.npmjs.org").reason).to eq("internal_mirror_required")
      expect(decide(rules, "npm.corp.example")).to be_allowed
      expect(decide(rules, "pypi.org")).to be_allowed
      expect(decide(rules, "github.com")).to be_allowed
    end

    it "displaces every OS mirror and language registry when the required mirror names no ecosystem" do
      all = rules + [ rule("internal_mirror", "all.corp.example", required: true) ]
      expect(decide(all, "pypi.org").reason).to eq("internal_mirror_required")
      expect(decide(all, "deb.debian.org").reason).to eq("internal_mirror_required")
      expect(decide(all, "github.com")).to be_allowed
    end

    it "does not displace anything for an optional mirror" do
      optional = [ rule("language_registry", "pypi.org", ecosystem: "pypi"), rule("internal_mirror", "m.corp.example", ecosystem: "pypi") ]
      expect(decide(optional, "pypi.org")).to be_allowed
    end
  end

  it "only internal mirrors may resolve into private space" do
    rules = [ rule("internal_mirror", "m.corp.example"), rule("exact_domain", "example.com") ]
    expect(decide(rules, "m.corp.example").allow_private).to be(true)
    expect(decide(rules, "example.com").allow_private).to be(false)
  end

  it "snapshots the enabled rules and digests them stably" do
    RuntimeImageBuildNetworkRule.create!(source_class: "source_host", host: "github.com")
    RuntimeImageBuildNetworkRule.create!(source_class: "exact_domain", host: "off.example.com", enabled: false)
    policy = described_class.current
    expect(policy.rules.map(&:host)).to eq([ "github.com" ])
    expect(policy.digest).to eq(described_class.current.digest)
    RuntimeImageBuildNetworkRule.create!(source_class: "artifact_registry", host: "ghcr.io")
    expect(described_class.current.digest).not_to eq(policy.digest)
    expect(policy.decide(host: "ghcr.io", port: 443)).not_to be_allowed
  end
end
