require "rails_helper"

RSpec.describe K8sCluster::ResourceService do
  describe ".validate_identifiers!" do
    it "accepts Kubernetes DNS-1123 identifiers" do
      expect {
        described_class.validate_identifiers!(name: "web-1.example", namespace: "default", container: "sidecar-2")
      }.not_to raise_error
    end

    it "rejects path and URL delimiters" do
      [ "/", "?", "#", "%" ].each do |delimiter|
        expect {
          described_class.validate_identifiers!(name: "web#{delimiter}proxy")
        }.to raise_error(described_class::InvalidArgument, /name/)
      end
    end

    it "rejects identifiers longer than 253 characters" do
      expect {
        described_class.validate_identifiers!(namespace: "a" * 254)
      }.to raise_error(described_class::InvalidArgument, /namespace/)
    end
  end
end
