require "rails_helper"

RSpec.describe RefreshTestRuntimeSummariesJob do
  it "refreshes the requested identities for the grader" do
    allow(TestInsights::RuntimeSummary).to receive(:refresh_many!)

    described_class.perform_now([ 3, 3, 7 ], "rspec")

    expect(TestInsights::RuntimeSummary).to have_received(:refresh_many!)
      .with([ 3, 7 ], grader_names: [ "rspec" ])
  end

  it "does nothing without identities" do
    allow(TestInsights::RuntimeSummary).to receive(:refresh_many!)

    described_class.perform_now([], "rspec")

    expect(TestInsights::RuntimeSummary).not_to have_received(:refresh_many!)
  end
end
