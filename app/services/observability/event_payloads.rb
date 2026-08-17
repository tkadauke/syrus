module Observability
  module EventPayloads
    module_function

    def browser_error(event)
      {
        id: event.id,
        occurred_at: event.occurred_at&.iso8601,
        app_revision: event.app_revision,
        fingerprint: event.fingerprint,
        name: event.name,
        message: event.message,
        stack: event.stack,
        component_stack: event.component_stack,
        url: event.url,
        path: event.path,
        route_id: event.route_id,
        route_params: event.route_params || {},
        trace_id: event.trace_id,
        user_agent: event.user_agent,
        viewport: event.viewport || {},
        feature_flags: event.feature_flags || {},
        recent_api_requests: event.recent_api_requests || [],
        recent_errors: event.recent_errors || [],
        metadata: event.metadata || {},
        user: {
          id: event.user_id,
          display_name: event.user&.display_name,
          email_address: event.user&.email_address
        }
      }
    end

    def backend_exception(event)
      {
        id: event.id,
        occurred_at: event.occurred_at&.iso8601,
        app_revision: event.app_revision,
        fingerprint: event.fingerprint,
        source: event.source,
        role: event.role,
        hostname: event.hostname,
        pid: event.pid,
        request_id: event.request_id,
        exception_class: event.exception_class,
        message: event.message,
        backtrace: event.backtrace,
        controller: event.controller,
        action: event.action,
        method: event.method,
        path: event.path,
        status: event.status,
        job_class: event.job_class,
        active_job_id: event.active_job_id,
        queue_name: event.queue_name,
        executions: event.executions,
        job_id: event.job_id,
        workflow_id: event.workflow_id,
        run_id: event.run_id,
        metadata: event.metadata || {}
      }
    end
  end
end
