require "rails_helper"

RSpec.describe Job::ProviderSetting::Codex do
  it "resolves jobs to the Codex provider" do
    job = Factories.job(agent_provider: "claude")

    expect(described_class.new.resolve(job)).to eq("codex")
  end
end
