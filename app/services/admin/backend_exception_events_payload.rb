module Admin
  class BackendExceptionEventsPayload < EventLogPayload
    SORTS = {
      "time" => [ "backend_exception_events.occurred_at", "backend_exception_events.id" ],
      "context" => [ "backend_exception_events.source", "backend_exception_events.path", "backend_exception_events.job_class", "backend_exception_events.id" ],
      "error" => [ "backend_exception_events.message", "backend_exception_events.exception_class", "backend_exception_events.id" ],
      "runtime" => [ "backend_exception_events.role", "backend_exception_events.hostname", "backend_exception_events.pid", "backend_exception_events.id" ]
    }.freeze

    private

    def model_class
      BackendExceptionEvent
    end

    def relation
      super.includes(:job)
    end

    def filter_definition
      Admin::EventLogFilterDefinitions.backend_exceptions
    end

    def event_payload(event, detail: false)
      Observability::EventPayloads.backend_exception(event, detail: detail)
    end

    def event_type
      "backend_exception"
    end

    def detail_association
      :job
    end

    def extra_controls
      { sources: Rails.cache.fetch("admin/backend_exception_sources", expires_in: 5.minutes) { BackendExceptionEvent.distinct.order(:source).pluck(:source) } }
    end
  end
end
