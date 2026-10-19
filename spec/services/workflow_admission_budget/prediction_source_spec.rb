require "rails_helper"

RSpec.describe WorkflowAdmissionBudget::PredictionSource do
  describe ".for" do
    it "delegates confidence to the command-attributed source" do
      source = described_class.for("command_attributed")

      expect(source).to be_a(described_class::CommandAttributed)
      expect(source.confidence).to eq("process_attributed")
    end

    it "delegates confidence to the host-correlated source" do
      source = described_class.for("host_correlated")

      expect(source).to be_a(described_class::HostCorrelated)
      expect(source.confidence).to eq("lower_confidence_fallback")
    end

    it "uses conservative defaults for missing and unknown sources" do
      expect(described_class.for("defaults_only").confidence).to eq("conservative_defaults")
      expect(described_class.for("future_source").confidence).to eq("conservative_defaults")
    end
  end
end
