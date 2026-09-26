require "rails_helper"

RSpec.describe WorkEngine::RepeatedFailureCircuit do
  let(:job) { Factories.job_record(state: "failed") }

  def failed_attempt(finished_at:, app_revision:, error_message: "undefined method 'id' for an instance of Hash")
    workflow = Workflow.create!(
      job: job,
      user: job.user,
      trigger_kind: "retry",
      agent_provider: job.agent_provider,
      state: "failed",
      finished_at: finished_at,
      cleaned_up_at: nil
    )
    step = workflow.steps.create!(kind: "grader_fanout", position: 0, state: "failed", finished_at: finished_at)
    run = step.runs.create!(
      job: job,
      user: job.user,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      state: "failed",
      finished_at: finished_at
    )
    RunDiagnostic.create!(
      run: run,
      error_class: "NoMethodError",
      error_message: error_message,
      error_backtrace: [
        "app/services/target_health_reuse.rb:42:in `block in health_records'",
        "app/services/steps/grader_fanout.rb:100:in `perform'"
      ].join("\n"),
      environment_snapshot: { "GIT_SHA" => app_revision }
    )

    run
  end

  def trip_circuit(app_revision:, finished_at:)
    failed_attempt(finished_at: finished_at - 2.minutes, app_revision: app_revision)
    failed_attempt(finished_at: finished_at - 1.minute, app_revision: app_revision)
    latest_run = failed_attempt(finished_at: finished_at, app_revision: app_revision)

    described_class.new(run: latest_run).open_attention_item!
  end

  it "keeps one open attention item across retry workflows and app revisions" do
    now = Time.zone.parse("2026-09-21 15:13:00 UTC")

    first = trip_circuit(app_revision: "pre-fix-sha", finished_at: now - 10.minutes).decision
    second = trip_circuit(app_revision: "post-fix-sha", finished_at: now).decision

    expect(second).to eq(first)
    expect(AttentionItem.open_decisions.where(problem_code: "application_error", job: job)).to contain_exactly(first)
    expect(first.reload.evidence).to include(
      "app_revision" => "post-fix-sha",
      "streak_count" => described_class::THRESHOLD,
      "workflow_id" => job.workflows.order(:finished_at).last.id,
      "circuit" => described_class::CIRCUIT
    )
  end

  it "supersedes older open repeated-failure rows with volatile signatures" do
    now = Time.zone.parse("2026-09-21 15:13:00 UTC")
    stale = AttentionItem.create!(
      problem_code: "application_error",
      signature: "application_error:old-revision-specific-signature",
      title: "Repeated automatic repair failure on #{job.slug}",
      repository: job.repository,
      job: job,
      state: "open",
      urgency: "urgent",
      evidence: {
        "fingerprint" => "old-fingerprint",
        "app_revision" => "old-sha",
        "streak_count" => described_class::THRESHOLD,
        "threshold" => described_class::THRESHOLD,
        "job_id" => job.id
      },
      actions: []
    )

    result = trip_circuit(app_revision: "current-sha", finished_at: now)

    expect(result.decision).to be_open
    expect(stale.reload.state).to eq("superseded")
    open_repeated_failures = AttentionItem.open_decisions.where(problem_code: "application_error", job: job)
    expect(open_repeated_failures).to contain_exactly(result.decision)
    expect(result.decision.evidence).to include("app_revision" => "current-sha")
  end
end
