require "rails_helper"

RSpec.describe RebaseRequestOrigin do
  describe ".for" do
    it "maps each known value to its origin class" do
      expect(described_class.for("system")).to be_a(RebaseRequestOrigin::System)
      expect(described_class.for("user")).to be_a(RebaseRequestOrigin::User)
      expect(described_class.for("chat_agent")).to be_a(RebaseRequestOrigin::ChatAgent)
    end

    it "accepts symbols" do
      expect(described_class.for(:system)).to be_a(RebaseRequestOrigin::System)
    end

    it "covers every declared value" do
      described_class::VALUES.each do |value|
        expect { described_class.for(value) }.not_to raise_error
      end
    end

    it "raises for unknown values" do
      expect { described_class.for("bogus") }.to raise_error(ArgumentError, /unknown rebase request origin: "bogus"/)
      expect { described_class.for(nil) }.to raise_error(ArgumentError)
    end
  end

  describe "#patient?" do
    it "is true only for system-originated requests" do
      expect(described_class.for("system")).to be_patient
      expect(described_class.for("user")).not_to be_patient
      expect(described_class.for("chat_agent")).not_to be_patient
    end
  end
end
