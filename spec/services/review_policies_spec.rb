require "rails_helper"

RSpec.describe ReviewPolicies do
  describe ".for" do
    it "returns SelfPolicy for 'self'" do
      expect(described_class.for("self")).to eq(ReviewPolicies::SelfPolicy)
    end

    it "returns TwoPersonPolicy for 'two_person'" do
      expect(described_class.for("two_person")).to eq(ReviewPolicies::TwoPersonPolicy)
    end

    it "returns FinalSayPolicy for 'final_say'" do
      expect(described_class.for("final_say")).to eq(ReviewPolicies::FinalSayPolicy)
    end

    it "raises ConfigurationError for unknown policies" do
      expect { described_class.for("dictator") }
        .to raise_error(ReviewPolicies::ConfigurationError, /Unknown review policy/)
    end
  end
end
