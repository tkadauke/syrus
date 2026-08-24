require "rails_helper"

RSpec.describe AgentProviders::Base do
  describe ".refresh_stale_usage!" do
    it "no-ops by default, so providers without a usage probe stay inert" do
      user = Factories.user

      expect { described_class.refresh_stale_usage!(user: user) }.not_to raise_error
    end
  end
end
