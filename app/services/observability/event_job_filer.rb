module Observability
  class EventJobFiler
    Result = Struct.new(:job, :issue_url, :error_code, :error_message, :mode, keyword_init: true) do
      def success? = error_code.nil? && error_message.nil?
    end

    SOURCES = {
      "browser_error" => {
        model: BrowserErrorEvent,
        payload: ->(event) { Observability::EventPayloads.browser_error(event) },
        title: ->(event) { "Fix browser error: #{event.message}" },
        description: ->(event, payload) do
          <<~MARKDOWN
            A browser error log entry was captured. Investigate the root cause and fix the application so this browser failure no longer occurs.

            Browser error event: ##{event.id}
            Path: #{event.path.presence || "-"}
            Route: #{event.route_id.presence || "-"}
            Revision: #{event.app_revision.presence || "-"}
            Fingerprint: #{event.fingerprint}

            Full browser error payload:
            ```json
            #{JSON.pretty_generate(payload)}
            ```
          MARKDOWN
        end
      },
      "backend_exception" => {
        model: BackendExceptionEvent,
        payload: ->(event) { Observability::EventPayloads.backend_exception(event) },
        title: ->(event) { "Fix backend exception: #{event.exception_class}: #{event.message}" },
        description: ->(event, payload) do
          context = event.source == "active_job" ? [ event.job_class, event.queue_name ].compact.join(" on ") : [ event.method, event.path ].compact.join(" ")
          <<~MARKDOWN
            A backend exception log entry was captured. Investigate the root cause and fix the application so this exception no longer occurs.

            Backend exception event: ##{event.id}
            Source: #{event.source}
            Context: #{context.presence || "-"}
            Revision: #{event.app_revision.presence || "-"}
            Fingerprint: #{event.fingerprint}

            Full backend exception payload:
            ```json
            #{JSON.pretty_generate(payload)}
            ```
          MARKDOWN
        end
      }
    }.freeze

    def self.actions_for(event_type)
      return [] unless SOURCES.key?(event_type.to_s)

      [ { id: "file_job", label: "File Job", event_type: event_type.to_s } ]
    end

    def initialize(user:, event_type:, event_id:)
      @user = user
      @event_type = event_type.to_s
      @event_id = event_id
    end

    def call
      source = source_config
      return failure("unsupported_event_type", "Unsupported event type") unless source

      event = source.fetch(:model).find_by(id: event_id)
      return failure("not_found", "Event not found") unless event
      return failure("forbidden", "You cannot file a job for this event") unless permitted?(event)

      payload = source.fetch(:payload).call(event)
      result = BugReports::Router.new(user: user).call(
        title: truncate_title(source.fetch(:title).call(event)),
        description: source.fetch(:description).call(event, payload),
        context: {
          source: "event_job_filer",
          event_type: event_type,
          event_id: event.id,
          event_payload: payload
        }
      )

      Result.new(
        job: result.job,
        issue_url: result.issue_url,
        error_code: result.error_code,
        error_message: result.error_message,
        mode: result.mode
      )
    end

    private

    attr_reader :user, :event_type, :event_id

    def source_config
      SOURCES[event_type]
    end

    def permitted?(event)
      return true if user&.admin?

      event.is_a?(BrowserErrorEvent) && event.user_id == user&.id
    end

    def truncate_title(title)
      title.to_s.squish.safe_byteslice(0, 200)
    end

    def failure(code, message)
      Result.new(error_code: code, error_message: message)
    end
  end
end
