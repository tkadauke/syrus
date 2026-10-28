require "rails_helper"

RSpec.describe "retention policy executors" do
  def create_test_insight_run(job, grader_name:)
    TestInsights::TestRun.create!(
      run: job.initial_run, repository: job.repository, grader_name:,
      total_count: 1, passed_count: 1, failed_count: 0, skipped_count: 0, error_count: 0
    )
  end

  def create_test_insight_case(test_run, name:)
    TestInsights::TestCase.create!(
      test_run:, repository: test_run.repository, suite_name: "Spec", name:, status: "passed"
    )
  end

  def create_isolated_repro_attempt(repository, name:)
    TestInsights::IsolatedReproAttempt.create!(
      repository:, grader_name: "rspec", suite_name: "Spec", name:,
      sha: "c" * 40, reproduced: false, command: "bin/rspec", output: "ok"
    )
  end

  it "prunes the operational index and database rows under logging suppression" do
    event = OperationalLogEvent.create!(
      occurred_at: 7.hours.ago, level: "info", role: "worker", hostname: "host-a",
      source: "spec", message: "expired event", context: {}
    )
    index = Class.new do
      def self.prune_before(*) = nil
    end
    stub_const("OperationalLogIndex", index)
    allow(OperationalLogging).to receive(:configured_for_instance?).and_return(true)
    expect(OperationalLogging).to receive(:suppress).and_call_original
    expect(index).to receive(:prune_before).with(be_within(2.seconds).of(6.hours.ago))

    RetentionPolicyPruneJob.perform_now("operational_log_event")

    expect(OperationalLogEvent.exists?(event.id)).to be(false)
  end

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

  it "deletes expired cases before empty parents and continues a capped backlog safely" do
    stub_const("RetentionPruner::DEFAULT_BATCH_SIZE", 1)
    stub_const("RetentionPruner::DEFAULT_MAX_BATCHES", 1)
    job = Factories.job
    first_run = create_test_insight_run(job, grader_name: "rspec-first")
    second_run = create_test_insight_run(job, grader_name: "rspec-second")
    first_case = create_test_insight_case(first_run, name: "first")
    second_case = create_test_insight_case(second_run, name: "second")
    old_time = 91.days.ago
    [ first_run, second_run, first_case, second_case ].each { |record| record.update_columns(created_at: old_time) }

    expect { RetentionPolicyPruneJob.perform_now("test_insight_case") }
      .to have_enqueued_job(RetentionPolicyPruneJob).with("test_insight_case").once

    expect(TestInsights::TestCase.exists?(first_case.id)).to be(false)
    expect(TestInsights::TestRun.exists?(first_run.id)).to be(false)
    expect(TestInsights::TestCase.exists?(second_case.id)).to be(true)
    expect(TestInsights::TestRun.exists?(second_run.id)).to be(true)
  end

  it "keeps case history at infinite retention while pruning isolated reproductions on their fixed window" do
    set_retention(:test_insight_case, 0)
    job = Factories.job
    test_run = create_test_insight_run(job, grader_name: "rspec")
    test_case = create_test_insight_case(test_run, name: "history")
    attempt = create_isolated_repro_attempt(job.repository, name: "isolated")
    [ test_run, test_case ].each { |record| record.update_columns(created_at: 1.year.ago) }
    attempt.update_columns(created_at: 31.days.ago)

    RetentionPolicyPruneJob.perform_now("test_insight_case")

    expect(TestInsights::TestCase.exists?(test_case.id)).to be(true)
    expect(TestInsights::TestRun.exists?(test_run.id)).to be(true)
    expect(TestInsights::IsolatedReproAttempt.exists?(attempt.id)).to be(false)
  end
end
