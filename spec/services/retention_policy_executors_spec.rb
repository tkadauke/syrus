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
