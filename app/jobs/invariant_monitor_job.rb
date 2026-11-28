# The periodic invariant sweep: evaluates every Invariants check over the
# whole instance, records the result as InvariantViolation episodes, and logs
# what changed. Open episodes surface to admins as a system alert banner and
# through GET /api/v1/admin/invariants.
class InvariantMonitorJob < ApplicationJob
  include SkipIfPending

  queue_as :low_priority_maintenance

  limits_concurrency to: 1, key: "invariant_monitor", duration: 15.minutes, on_conflict: :discard

  def perform(now: Time.current)
    report = Invariants.evaluate(now: now)
    outcome = Invariants::Recorder.record!(report)

    I18n.with_locale(I18n.default_locale) do
      outcome.opened.each do |record|
        Rails.logger.warn("[InvariantMonitorJob] violation opened #{record.fingerprint} (#{record.severity}): #{record.message}")
      end
      outcome.resolved.each do |record|
        Rails.logger.info("[InvariantMonitorJob] violation resolved #{record.fingerprint}")
      end
    end
    report.errors.each do |result|
      Rails.logger.error("[InvariantMonitorJob] #{result.key} raised #{result.error.class}: #{result.error.message}")
    end
    Rails.logger.info(
      "[InvariantMonitorJob] #{report.violations.size} violations " \
      "(#{outcome.opened.size} opened, #{outcome.resolved.size} resolved, #{report.errors.size} invariant errors)"
    )
    outcome
  end
end
