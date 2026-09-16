require "rails_helper"

RSpec.describe Job::ProviderSetting::Agy do
  it "resolves jobs to the Agy provider" do
    job = Factories.job(agent_provider: "claude")

    expect(described_class.new.resolve(job)).to eq("agy")
  end
end
