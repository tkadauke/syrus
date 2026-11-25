require "rails_helper"

# Negative security fixtures for the build network: what a build must never be
# able to reach, even when an administrator's allowlist is permissive. Each
# fixture is a destination a hostile Dockerfile might try; the contract is that
# the policy refuses it, or the resolver refuses every address it resolves to.
RSpec.describe "build network negative fixtures" do
  let(:policy_class) { RuntimeImages::BuildNetwork::Policy }
  let(:resolver_class) { RuntimeImages::BuildNetwork::Resolver }

  def rule(source_class, host, port: 443, ecosystem: "", required: false)
    policy_class::Rule.new(source_class: source_class, host: host, port: port, path_prefix: "", ecosystem: ecosystem, required: required)
  end

  def resolver_for(answers) = resolver_class.new(lookup: ->(host) { answers.fetch(host) })

  describe "destinations nobody declared" do
    {
      "cloud metadata name (GCP)" => "metadata.google.internal",
      "cloud metadata name (generic)" => "instance-data",
      "cloud metadata literal" => "169.254.169.254",
      "alibaba metadata literal" => "100.100.100.200",
      "kubernetes API service" => "kubernetes.default.svc.cluster.local",
      "application service in the cluster" => "syrus-web.syrus.svc.cluster.local",
      "database host" => "mysql.syrus.svc",
      "registry control host" => "registry.syrus.svc",
      "localhost" => "localhost",
      "loopback literal" => "127.0.0.1",
      "private literal (application network)" => "10.42.0.12",
      "ipv6 loopback" => "::1",
      "unrelated internet host" => "attacker.example.net"
    }.each do |label, host|
      it "denies #{label} under an empty allowlist" do
        expect(policy_class.new([]).decide(host: host, port: 80)).not_to be_allowed
        expect(policy_class.new([]).decide(host: host, port: 443)).not_to be_allowed
      end

      it "denies #{label} under a typical allowlist" do
        typical = policy_class.new([ rule("os_mirror", "deb.debian.org", ecosystem: "debian"), rule("source_host", "github.com"),
                                     rule("language_registry", "registry.npmjs.org", ecosystem: "npm") ])
        expect(typical.decide(host: host, port: 443)).not_to be_allowed
      end
    end
  end

  describe "declared destinations that resolve somewhere forbidden" do
    {
      "cloud metadata" => "169.254.169.254",
      "alibaba metadata" => "100.100.100.200",
      "ipv6 metadata" => "fd00:ec2::254",
      "link-local" => "169.254.10.10",
      "loopback" => "127.0.0.1",
      "ipv6 loopback" => "::1",
      "unspecified" => "0.0.0.0",
      "IPv4-mapped metadata" => "::ffff:169.254.169.254",
      "NAT64 metadata" => "64:ff9b::a9fe:a9fe"
    }.each do |label, address|
      it "refuses a name that resolves to #{label} even when declared and even behind an internal mirror" do
        resolver = resolver_for("declared.example" => [ address ])
        expect { resolver.resolve("declared.example") }.to raise_error(resolver_class::Blocked)
        expect { resolver.resolve("declared.example", allow_private: true) }.to raise_error(resolver_class::Blocked)
      end
    end

    it "refuses the application network (private space) for every source class except a declared internal mirror" do
      resolver = resolver_for("app.example" => [ "10.42.0.12" ])
      expect { resolver.resolve("app.example") }.to raise_error(resolver_class::Blocked, /private/)
      expect(resolver.resolve("app.example", allow_private: true)).to eq([ "10.42.0.12" ])
      %w[os_mirror language_registry source_host artifact_registry exact_domain repository_namespace].each do |klass|
        expect(RuntimeImages::BuildNetwork::SourceClass.for(klass).allow_private?).to be(false), "#{klass} must never reach private space"
      end
    end

    it "refuses a mixed answer so a record set cannot be used to probe the network" do
      resolver = resolver_for("mixed.example" => [ "93.184.216.34", "169.254.169.254" ])
      expect { resolver.resolve("mixed.example") }.to raise_error(resolver_class::Blocked, /forbidden/)
    end

    it "refuses a name that does not resolve" do
      resolver = resolver_class.new(lookup: ->(_host) { [] })
      expect { resolver.resolve("nowhere.example") }.to raise_error(resolver_class::Blocked, /did not resolve/)
    end
  end

  describe "bypasses a hostile build might try" do
    let(:policy) { policy_class.new([ rule("exact_domain", "example.com") ]) }

    {
      "decimal literal" => "2130706433",
      "hex literal" => "0x7f000001",
      "octal literal" => "0177.0.0.1",
      "bracketed ipv6" => "[::1]",
      "userinfo trick" => "example.com@169.254.169.254",
      "suffix lookalike" => "example.com.attacker.net",
      "prefix lookalike" => "evil-example.com",
      "subdomain of a declared host" => "sub.example.com",
      "trailing-dot lookalike with port" => "example.com:8080"
    }.each do |label, host|
      it "denies a #{label}" do
        expect(policy.decide(host: host, port: 443)).not_to be_allowed
      end
    end

    it "denies the declared host on an undeclared port" do
      expect(policy.decide(host: "example.com", port: 22)).not_to be_allowed
      expect(policy.decide(host: "example.com", port: 443)).to be_allowed
    end
  end
end
