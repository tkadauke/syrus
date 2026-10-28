require "rails_helper"

RSpec.describe "retention policy executors" do
  it "clears old provider payloads before generic row retention" do
    succeeded_run = Factories.job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }
    session = ProviderSession.create!(
      resumable: succeeded_run,
      session_id: "payload",
      transcript_jsonl: "large transcript",
      normalized_messages: [ { "role" => "assistant", "content" => "large payload" } ]
    )
    session.update_columns(updated_at: ProviderSession::PAYLOAD_RETENTION.ago - 1.second)

    RetentionPolicyPruneJob.perform_now("provider_session")

    expect(session.reload).to have_attributes(
      transcript_jsonl: nil,
      normalized_messages: nil,
      transcript_pruned: true
    )
  end

  it "preserves active provider sessions regardless of age" do
    active_run = Factories.job.initial_run
    session = ProviderSession.create!(resumable: active_run, session_id: "active", transcript_jsonl: "resume me")
    session.update_columns(updated_at: 1.year.ago)

    RetentionPolicyPruneJob.perform_now("provider_session")

    expect(session.reload.transcript_jsonl).to eq("resume me")
  end

  it "keeps provider payloads intact until an archive-enabled row is deleted" do
    set_retention_archive(:provider_session, true)
    succeeded_run = Factories.job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }
    session = ProviderSession.create!(resumable: succeeded_run, session_id: "archive", transcript_jsonl: "preserve me")
    session.update_columns(updated_at: ProviderSession::PAYLOAD_RETENTION.ago - 1.second)

    RetentionPolicyPruneJob.perform_now("provider_session")

    expect(session.reload.transcript_jsonl).to eq("preserve me")
  end

  it "archives the complete provider payload atomically with row deletion" do
    set_retention_archive(:provider_session, true)
    failed_run = Factories.job.initial_run.tap { |run| run.start!; run.fail!; run.save! }
    session = ProviderSession.create!(resumable: failed_run, session_id: "archive", transcript_jsonl: "preserve me")
    session.update_columns(updated_at: ProviderSession.retention_window.ago - 1.second)

    expect { RetentionPolicyPruneJob.perform_now("provider_session") }.to change(RetentionArchive, :count).by(1)

    archived_rows = Zlib::GzipReader.new(StringIO.new(RetentionArchive.last.archive_file.download))
      .read.lines.map { |line| JSON.parse(line) }
    expect(archived_rows).to contain_exactly(include("id" => session.id, "transcript_jsonl" => "preserve me"))
    expect(ProviderSession.exists?(session.id)).to be(false)
  end

  it "continues when capped provider payload cleanup leaves eligible rows" do
    stub_const("RetentionPolicyExecutors::ProviderSession::PAYLOAD_BATCH_SIZE", 1)
    stub_const("RetentionPolicyExecutors::ProviderSession::MAX_PAYLOAD_BATCHES", 1)
    sessions = 2.times.map do |index|
      run = Factories.job.initial_run.tap { |candidate| candidate.start!; candidate.succeed!; candidate.save! }
      ProviderSession.create!(resumable: run, session_id: "payload-#{index}", transcript_jsonl: "payload").tap do |session|
        session.update_columns(updated_at: ProviderSession::PAYLOAD_RETENTION.ago - 1.second)
      end
    end

    result = nil
    expect { result = RetentionPolicyPruneJob.perform_now("provider_session") }
      .to have_enqueued_job(RetentionPolicyPruneJob).with("provider_session").once

    expect(result).to eq(1)
    expect(sessions.count { |session| session.reload.transcript_jsonl.present? }).to eq(1)
  end

  it "detaches dependent command spans before deleting spawned processes" do
    process = SpawnedProcess.create!(
      kind: "agent", command: "agent", hostname: "host", started_at: 8.days.ago,
      finished_at: 8.days.ago, outcome: "succeeded", exit_status: 0
    )
    user = Factories.user
    repository = Factories.repository(user:)
    job = Factories.job_record(user:, repository:, state: "running")
    workflow = Workflow.create!(job:, user:, trigger_kind: "initial", state: "running")
    step = Step.create!(workflow:, kind: "grader", position: 1, state: "succeeded", details: { "name" => "rspec" })
    run = Run.create!(job:, user:, step:, trigger_kind: "initial", state: "succeeded")
    span = CommandSpan.create!(
      job:, workflow:, step:, run:, spawned_process: process, sequence: 1, name: "rspec",
      command_excerpt: "bin/rspec", hostname: "host", started_at: 8.days.ago, metadata: {}
    )

    RetentionPolicyPruneJob.perform_now("spawned_process")

    expect(SpawnedProcess.exists?(process.id)).to be(false)
    expect(span.reload.spawned_process_id).to be_nil
  end

  it "lets the plugin strategy clean dependent and fixed-window rows" do
    job = Factories.job
    test_run = TestInsights::TestRun.create!(
      run: job.initial_run, repository: job.repository, grader_name: "rspec",
      total_count: 0, passed_count: 0, failed_count: 0, skipped_count: 0, error_count: 0
    )
    test_run.update_columns(created_at: 91.days.ago)
    attempt = TestInsights::IsolatedReproAttempt.create!(
      repository: job.repository, grader_name: "rspec", suite_name: "Spec", name: "example",
      sha: "c" * 40, reproduced: false, command: "bin/rspec", output: "ok"
    )
    attempt.update_columns(created_at: 31.days.ago)

    RetentionPolicyPruneJob.perform_now("test_insight_case")

    expect(TestInsights::TestRun.exists?(test_run.id)).to be(false)
    expect(TestInsights::IsolatedReproAttempt.exists?(attempt.id)).to be(false)
  end
end
