require "rails_helper"

RSpec.describe MainHealthChangedService do
  let(:repository) { Factories.repository }

  describe ".on_health_change!" do
    it "logs a warning with the repository slug and health states" do
      repository.update!(ci_health: "broken")

      expect(Rails.logger).to receive(:warn).with(
        include("MainHealthChangedService", repository.slug, "main_health=broken", "ci_health=broken")
      )

      described_class.on_health_change!(repository)
    end

    it "does not raise" do
      expect { described_class.on_health_change!(repository) }.not_to raise_error
    end
  end
end
