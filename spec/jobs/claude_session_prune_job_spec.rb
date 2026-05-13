require "rails_helper"

RSpec.describe ClaudeSessionPruneJob do
  it "deletes ClaudeSessions for terminal Runs older than the retention window" do
    old_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }
    new_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }
    active_run = Factories.job.initial_run  # queued

    old_session    = ClaudeSession.create!(resumable: old_run,    session_id: "old",    transcript_jsonl: "x")
    new_session    = ClaudeSession.create!(resumable: new_run,    session_id: "new",    transcript_jsonl: "x")
    active_session = ClaudeSession.create!(resumable: active_run, session_id: "active", transcript_jsonl: "x")
    old_session.update_columns(updated_at: (ClaudeSession::RETAIN_AFTER_TERMINAL + 1.day).ago)
    active_session.update_columns(updated_at: 1.year.ago)  # old, but parent is active → keep

    expect {
      described_class.perform_now
    }.to change { ClaudeSession.count }.by(-1)

    expect(ClaudeSession.exists?(old_session.id)).to be false
    expect(ClaudeSession.exists?(new_session.id)).to be true
    expect(ClaudeSession.exists?(active_session.id)).to be true
  end

  it "clears transcript_jsonl for succeeded Runs within the retention window" do
    succeeded_run = Factories.job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
    session = ClaudeSession.create!(resumable: succeeded_run, session_id: "ok", transcript_jsonl: "payload")

    described_class.perform_now

    expect(session.reload.transcript_jsonl).to be_nil
    expect(ClaudeSession.exists?(session.id)).to be true  # row kept, just transcript cleared
  end

  it "does not clear transcript_jsonl for failed/cancelled Runs within the retention window" do
    failed_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }
    session = ClaudeSession.create!(resumable: failed_run, session_id: "fail", transcript_jsonl: "payload")

    described_class.perform_now

    expect(session.reload.transcript_jsonl).to eq("payload")
  end

  it "is a no-op when nothing is prunable" do
    expect { described_class.perform_now }.not_to change { ClaudeSession.count }
  end
end
