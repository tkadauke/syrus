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

  it "does not archive before deleting when archive_before_delete is off (default, matches JOB-5025 behavior)" do
    old = RunDiagnostic.create!(run: Factories.run, error_class: "X")
    old.update_columns(created_at: (RunDiagnostic.retention_window + 1.day).ago)

    expect { described_class.perform_now }.not_to change { RetentionArchive.count }
    expect(RunDiagnostic.exists?(old.id)).to be false
  end

  it "archives before deleting when archive_before_delete is on" do
    AppSetting.current.update!(run_diagnostic_archive_before_delete: true)
    old = RunDiagnostic.create!(run: Factories.run, error_class: "X")
    old.update_columns(created_at: (RunDiagnostic.retention_window + 1.day).ago)

    expect { described_class.perform_now }.to change { RetentionArchive.count }.by(1)

    archive = RetentionArchive.last
    expect(archive.retention_key).to eq("run_diagnostic")
    expect(archive.row_count).to eq(1)
    expect(RunDiagnostic.exists?(old.id)).to be false
  end
end
