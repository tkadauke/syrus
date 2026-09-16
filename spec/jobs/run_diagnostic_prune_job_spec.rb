require "rails_helper"

RSpec.describe RunDiagnosticPruneJob do
  it "deletes RunDiagnostic rows older than the configured retention window" do
    old   = RunDiagnostic.create!(run: Factories.run, error_class: "X")
    fresh = RunDiagnostic.create!(run: Factories.run, error_class: "X")
    old.update_columns(created_at: (RunDiagnostic.retention_window + 1.day).ago)

    expect { described_class.perform_now }.to change { RunDiagnostic.count }.by(-1)
    expect(RunDiagnostic.exists?(old.id)).to be false
    expect(RunDiagnostic.exists?(fresh.id)).to be true
  end

  it "is a no-op when nothing is prunable" do
    RunDiagnostic.create!(run: Factories.run, error_class: "X")
    expect { described_class.perform_now }.not_to change { RunDiagnostic.count }
  end

  it "is a no-op when retention is set to 0 (infinite)" do
    AppSetting.current.update!(run_diagnostic_retention_days: 0)
    old = RunDiagnostic.create!(run: Factories.run, error_class: "X")
    old.update_columns(created_at: 10.years.ago)

    expect { described_class.perform_now }.not_to change { RunDiagnostic.count }
  end
end
