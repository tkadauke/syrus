require "rails_helper"

RSpec.describe JobLogPruneJob do
  it "deletes only prunable logs and is idempotent" do
    run = Factories.run
    stale = JobLog.create!(run: run, chunk: "stale", sequence: 0, created_at: 31.days.ago)
    fresh = JobLog.create!(run: run, chunk: "fresh", sequence: 1)

    expect { described_class.perform_now }.to change(JobLog, :count).by(-1)
    expect(JobLog.exists?(stale.id)).to be(false)
    expect(JobLog.exists?(fresh.id)).to be(true)
    expect { described_class.perform_now }.not_to change(JobLog, :count)
  end
end
