require "rails_helper"

RSpec.describe DataRootDiskUsageRefreshJob, type: :job do
  it "refreshes the shared data-root disk usage snapshot" do
    expect(DataRootDiskUsage).to receive(:refresh!)

    described_class.perform_now
  end
end
