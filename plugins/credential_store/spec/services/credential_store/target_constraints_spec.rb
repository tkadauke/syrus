require "rails_helper"

RSpec.describe CredentialStore::Broker::TargetConstraint do
  describe CredentialStore::Broker::TargetConstraint::AllowedUrlPrefixes do
    subject(:constraint) { described_class.new(prefixes) }

    let(:prefixes) { [ "https://api.example.com/v1" ] }

    it "allows URLs on the same origin and within the configured path" do
      expect(constraint).to be_satisfied(url: "https://API.EXAMPLE.COM/v1/releases")
      expect(constraint).to be_satisfied(url: "https://api.example.com./v1")
    end

    it "denies host lookalikes and userinfo URLs" do
      expect(constraint).not_to be_satisfied(url: "https://api.example.com.attacker.net/v1")
      expect(constraint).not_to be_satisfied(url: "https://api.example.com@attacker.net/v1")
      expect(described_class.new([ "https://user@api.example.com/v1" ])).not_to be_satisfied(url: "https://api.example.com/v1")
    end

    it "requires schemes and effective ports to match" do
      expect(constraint).not_to be_satisfied(url: "http://api.example.com/v1")
      expect(constraint).not_to be_satisfied(url: "https://api.example.com:8443/v1")
      expect(described_class.new([ "https://api.example.com:443/v1" ])).to be_satisfied(url: "https://api.example.com/v1")
    end

    it "matches path prefixes only at a slash boundary" do
      expect(constraint).to be_satisfied(url: "https://api.example.com/v1")
      expect(constraint).not_to be_satisfied(url: "https://api.example.com/v10")
      expect(constraint).not_to be_satisfied(url: "https://api.example.com/v1evil")
    end

    it "denies malformed URLs and explicitly empty constraints" do
      expect(constraint).not_to be_satisfied(url: "not a URL")
      expect(described_class.new([ "https://api.example.com/v1?token=expected" ])).not_to be_satisfied(url: "https://api.example.com/v1?token=expected")
      expect(described_class.new([])).not_to be_satisfied(url: "https://api.example.com/v1")
      expect(described_class.new([ "" ])).not_to be_satisfied(url: "https://api.example.com/v1")
    end
  end

  describe "explicitly empty constraints" do
    {
      CredentialStore::Broker::TargetConstraint::AllowedHosts => :host,
      CredentialStore::Broker::TargetConstraint::AllowedKubeClusters => :kube_cluster,
      CredentialStore::Broker::TargetConstraint::AllowedKubeContexts => :kube_context,
      CredentialStore::Broker::TargetConstraint::AllowedKubeNamespaces => :kube_namespace
    }.each do |constraint_class, target_key|
      it "denies every target for #{constraint_class.name.demodulize}" do
        expect(constraint_class.new([])).not_to be_satisfied(target_key => "allowed-value")
        expect(constraint_class.new([ "" ])).not_to be_satisfied(target_key => "allowed-value")
      end
    end
  end
end
