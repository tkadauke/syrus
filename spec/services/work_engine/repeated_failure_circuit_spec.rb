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

  # Builds exactly THRESHOLD consecutive identical failures, derived from the
  # constant rather than hardcoded, so the helper cannot drift away from the
  # threshold it is supposed to trip (it did, when THRESHOLD moved above the
  # auto-retry budget).
  def trip_circuit(app_revision:, finished_at:)
    latest_run = nil

    described_class::THRESHOLD.times do |index|
      minutes_ago = described_class::THRESHOLD - 1 - index
      latest_run = failed_attempt(finished_at: finished_at - minutes_ago.minutes, app_revision: app_revision)
    end

    described_class.new(run: latest_run).log_open_circuit!
  end

  it "opens only after the auto-retry budget has been spent" do
    # These two numbers were equal, which made the circuit open on the same
    # failure that would have scheduled the final retry. The budget's last
    # attempt became unreachable: the documented "up to three attempts with
    # 5m/20m/1h backoff" was really two, the 1-hour backoff was dead code, and
    # the budget never recorded exhaustion -- so the reconciler re-detected the
    # failure every tick and re-skipped a repair that could never apply.
    #
    # The circuit is meant to catch failures that survive retrying, so its
    # threshold has to sit above the retry budget, not on top of it.
    expect(described_class::THRESHOLD).to be > AutoRetryAttempt::MAX_ATTEMPTS
  end

  it "walks the failure history without selecting whole Workflow or Run rows" do
    # Workflows carry a 16MB artifacts column and Runs two 16MB agent diffs,
    # and neither ordering this class needs is served by an index, so whole-row
    # selects left the database sorting multi-megabyte rows in a sort buffer
    # sized in kilobytes. It refused with "Out of sort memory", and because
    # this runs inside every reconcile pass, one Job with a long failure
    # history stopped all repair work and turned the stuck-items watchlist that
    # shares the path into a 500. Nothing here reads those columns.
    now = Time.zone.parse("2026-11-10 06:00:00 UTC")
    latest_run = nil
    described_class::THRESHOLD.times do |index|
      latest_run = failed_attempt(
        finished_at: now - (described_class::THRESHOLD - 1 - index).minutes,
        app_revision: "wide-row-sha"
      )
    end
    latest_run.update!(agent_diff: "diff " * 256, step_agent_diff: "diff " * 256)

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end
    begin
      result = described_class.call(run: latest_run)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    expect(result.streak_count).to eq(described_class::THRESHOLD)
    expect(statements).not_to include(a_string_matching(/select\s+[`"]?(runs|workflows)[`"]?\.\*/i))
  end

  it "logs and returns the open circuit result without creating persisted alarms" do
    now = Time.zone.parse("2026-09-21 15:13:00 UTC")
    allow(Rails.logger).to receive(:warn)

    result = trip_circuit(app_revision: "pre-fix-sha", finished_at: now)

    expect(result).to be_open
    expect(result).to have_attributes(
      app_revision: "pre-fix-sha",
      streak_count: described_class::THRESHOLD
    )
    expect(Rails.logger).to have_received(:warn).with(
      a_string_matching(/automatic retries paused for #{job.slug}/)
    )
  end
end
