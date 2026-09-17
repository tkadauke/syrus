require "rails_helper"

RSpec.describe ProviderSessionPruneJob do
  it "deletes ProviderSessions for terminal Runs older than the retention window" do
    old_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }
    new_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }
    active_run = Factories.job.initial_run  # queued

    old_session    = ProviderSession.create!(resumable: old_run,    session_id: "old",    transcript_jsonl: "x")
    new_session    = ProviderSession.create!(resumable: new_run,    session_id: "new",    transcript_jsonl: "x")
    active_session = ProviderSession.create!(resumable: active_run, session_id: "active", transcript_jsonl: "x")
    old_session.update_columns(updated_at: (ProviderSession.retention_window + 1.day).ago)
    active_session.update_columns(updated_at: 1.year.ago)  # old, but parent is active → keep

    expect {
      described_class.perform_now
    }.to change { ProviderSession.count }.by(-1)

    expect(ProviderSession.exists?(old_session.id)).to be false
    expect(ProviderSession.exists?(new_session.id)).to be true
    expect(ProviderSession.exists?(active_session.id)).to be true
  end

  it "keeps transcript_jsonl for succeeded Runs within the retention window" do
    succeeded_run = Factories.job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
    session = ProviderSession.create!(resumable: succeeded_run, session_id: "ok", transcript_jsonl: "payload")

    described_class.perform_now

    expect(session.reload.transcript_jsonl).to eq("payload")
    expect(ProviderSession.exists?(session.id)).to be true
  end

  it "does not clear transcript_jsonl for failed/cancelled Runs within the retention window" do
    failed_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }
    session = ProviderSession.create!(resumable: failed_run, session_id: "fail", transcript_jsonl: "payload")

    described_class.perform_now

    expect(session.reload.transcript_jsonl).to eq("payload")
  end

  it "is a no-op when nothing is prunable" do
    expect { described_class.perform_now }.not_to change { ProviderSession.count }
  end

  it "is a no-op when retention is set to 0 (infinite)" do
    AppSetting.current.update!(provider_session_retention_days: 0)
    old_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }
    old_session = ProviderSession.create!(resumable: old_run, session_id: "old", transcript_jsonl: "x")
    old_session.update_columns(updated_at: 10.years.ago)

    expect { described_class.perform_now }.not_to change { ProviderSession.count }
  end

  it "does not archive before deleting when archive_before_delete is off (default, matches JOB-5025 behavior)" do
    old_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }
    old_session = ProviderSession.create!(resumable: old_run, session_id: "old", transcript_jsonl: "x")
    old_session.update_columns(updated_at: (ProviderSession.retention_window + 1.day).ago)

    expect { described_class.perform_now }.not_to change { RetentionArchive.count }
    expect(ProviderSession.exists?(old_session.id)).to be false
  end

  it "archives before deleting when archive_before_delete is on" do
    AppSetting.current.update!(provider_session_archive_before_delete: true)
    old_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }
    old_session = ProviderSession.create!(resumable: old_run, session_id: "old", transcript_jsonl: "x")
    old_session.update_columns(updated_at: (ProviderSession.retention_window + 1.day).ago)

    expect { described_class.perform_now }.to change { RetentionArchive.count }.by(1)

    archive = RetentionArchive.last
    expect(archive.retention_key).to eq("provider_session")
    expect(archive.row_count).to eq(1)
    expect(ProviderSession.exists?(old_session.id)).to be false
  end
end
