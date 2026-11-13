module Observability
  module EventPayloads
    module_function

    def browser_error(event, detail: false)
      {
        id: event.id,
        occurred_at: event.occurred_at&.iso8601,
        app_revision: event.app_revision,
        fingerprint: event.fingerprint,
        name: event.name,
        message: event.message,
        path: event.path,
        route_id: event.route_id,
        trace_id: event.trace_id,
        user: {
          id: event.user_id,
          display_name: event.user&.display_name,
          email_address: event.user&.email_address
        }
      }.tap do |payload|
        payload.merge!(
          stack: event.stack,
          component_stack: event.component_stack,
          recent_api_requests: event.recent_api_requests || [],
          recent_errors: event.recent_errors || [],
          feature_flags: event.feature_flags || {},
          viewport: event.viewport || {},
          metadata: event.metadata || {},
          route_params: event.route_params || {},
          url: event.url,
          user_agent: event.user_agent
        ) if detail
      end
    end

    def backend_exception(event, detail: false)
      {
        id: event.id,
        occurred_at: event.occurred_at&.iso8601,
        app_revision: event.app_revision,
        fingerprint: event.fingerprint,
        source: event.source,
        role: event.role,
        request_id: event.request_id,
        exception_class: event.exception_class,
        message: event.message,
        method: event.method,
        path: event.path,
        status: event.status,
        job_class: event.job_class,
        queue_name: event.queue_name,
        job_id: event.job_id,
        job_slug: event.job&.slug
      }.tap do |payload|
        payload.merge!(
          backtrace: event.backtrace,
          metadata: event.metadata || {},
          request_context: {
            controller: event.controller, action: event.action, method: event.method,
            path: event.path, status: event.status, request_id: event.request_id
          },
          job_context: {
            job_class: event.job_class, active_job_id: event.active_job_id,
            queue_name: event.queue_name, executions: event.executions, job_id: event.job_id,
            job_slug: event.job&.slug, workflow_id: event.workflow_id, run_id: event.run_id
          },
          hostname: event.hostname,
          pid: event.pid
        ) if detail
      end
    end
  end
end
