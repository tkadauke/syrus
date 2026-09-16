require "rails_helper"

RSpec.describe RunHealthSnapshotPruneJob do
  let(:run) { Factories.run }

  def snapshot(created_at:)
    RunHealthSnapshot.create!(run: run, health_status: "healthy", run_state: "running", created_at: created_at)
  end

  it "deletes snapshots older than the retention window" do
    old = snapshot(created_at: (RunHealthSnapshot.retention_window + 1.day).ago)
    fresh = snapshot(created_at: 1.hour.ago)

    expect { described_class.perform_now }.to change { RunHealthSnapshot.count }.by(-1)
    expect(RunHealthSnapshot.exists?(old.id)).to be false
    expect(RunHealthSnapshot.exists?(fresh.id)).to be true
  end

  it "logs the number of deleted rows" do
    snapshot(created_at: 10.days.ago)
    allow(Rails.logger).to receive(:info).and_call_original

    described_class.perform_now

    expect(Rails.logger).to have_received(:info).with(a_string_matching(/deleted 1 run health snapshots/))
  end

  it "is a no-op when nothing is prunable" do
    snapshot(created_at: 1.hour.ago)

    expect { described_class.perform_now }.not_to change { RunHealthSnapshot.count }
  end

  it "is a no-op when retention is set to 0 (infinite)" do
    AppSetting.current.update!(run_health_snapshot_retention_days: 0)
    old = snapshot(created_at: 10.years.ago)

    expect { described_class.perform_now }.not_to change { RunHealthSnapshot.count }
    expect(RunHealthSnapshot.exists?(old.id)).to be true
  end
end
