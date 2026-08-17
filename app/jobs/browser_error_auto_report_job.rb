class BrowserErrorAutoReportJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform(browser_error_event_id)
    return unless Feature.browser_error_auto_reports_enabled?

    event = BrowserErrorEvent.find_by(id: browser_error_event_id)
    return unless event

    report = BrowserErrorAutoReport.claim_for!(event)
    return unless report

    result = BugReports::Router.new(user: event.user).call(
      title: title_for(event),
      description: description_for(event),
      context: context_for(event)
    )

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

  def title_for(event)
    "Browser error: #{event.message}".safe_byteslice(0, 200)
  end

  def description_for(event)
    <<~MARKDOWN
      A browser error was captured automatically.

      Browser error event: ##{event.id}
      Path: #{event.path.presence || "-"}
      Route: #{event.route_id.presence || "-"}
      Revision: #{event.app_revision.presence || "-"}
      Fingerprint: #{event.fingerprint}

      Error:
      #{event.name.presence || "Error"}: #{event.message}

      Stack:
      ```
      #{event.stack.presence || "-"}
      ```

      Component stack:
      ```
      #{event.component_stack.presence || "-"}
      ```
    MARKDOWN
  end

  def context_for(event)
    {
      source: "browser_error_auto_report",
      browser_error_event_id: event.id,
      app_revision: event.app_revision,
      fingerprint: event.fingerprint,
      route_id: event.route_id,
      route_params: event.route_params,
      url: event.url,
      path: event.path,
      user_agent: event.user_agent,
      viewport: event.viewport,
      feature_flags: event.feature_flags,
      recent_api_requests: event.recent_api_requests,
      recent_errors: event.recent_errors,
      metadata: event.metadata
    }.compact
  end
end
