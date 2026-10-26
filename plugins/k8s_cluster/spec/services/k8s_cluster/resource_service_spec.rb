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

  describe "condition summaries" do
    it "normalizes the three most recent conditions for resource subclasses" do
      service_class = Class.new(described_class) do
        def conditions_for(item)
          recent_conditions(item)
        end
      end
      conditions = 4.times.map do |index|
        {
          "type" => "Condition#{index}",
          "status" => index.even? ? "True" : "False",
          "reason" => "Reason#{index}",
          "lastTransitionTime" => "2026-01-0#{index + 1}T00:00:00Z"
        }
      end

      summaries = service_class.new(nil).conditions_for("status" => { "conditions" => conditions })

      expect(summaries).to eq(conditions.last(3).map do |condition|
        {
          type: condition["type"],
          status: condition["status"],
          reason: condition["reason"],
          last_transition_time: condition["lastTransitionTime"]
        }
      end)
    end
  end
end
