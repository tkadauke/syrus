class BrowserErrorAutoReportJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform(browser_error_event_id)
    return unless Feature.browser_error_auto_reports_enabled?

    event = BrowserErrorEvent.find_by(id: browser_error_event_id)
    return unless event

    report = BrowserErrorAutoReport.claim_for!(event)
    return unless report

    result = Observability::EventJobFiler.new(user: event.user, event_type: "browser_error", event_id: event.id).call

    if result.success?
      report.update!(
        status: "reported",
        job: result.job,
        issue_url: result.issue_url
      )
    else
      report.update!(
        status: "failed",
        error_message: result.error_message || result.error_code || "unknown auto-report failure"
      )
    end
  end

  private

end
