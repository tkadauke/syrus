module Admin
  class BrowserErrorEventsPayload < EventLogPayload
    SORTS = {
      "time" => [ "browser_error_events.occurred_at", "browser_error_events.id" ],
      "path" => [ "browser_error_events.path", "browser_error_events.occurred_at", "browser_error_events.id" ],
      "error" => [ "browser_error_events.message", "browser_error_events.name", "browser_error_events.id" ],
      "user" => [ "users.email_address", "browser_error_events.user_id", "browser_error_events.id" ]
    }.freeze

    private

    def model_class
      BrowserErrorEvent
    end

    def relation
      super.includes(:user)
    end

    def sortable_scope
      sort_column == "user" ? filtered_scope.left_joins(:user) : filtered_scope
    end

    def filter_definition
      Admin::EventLogFilterDefinitions.browser_errors
    end

    def event_payload(event, detail: false)
      Observability::EventPayloads.browser_error(event, detail: detail)
    end

    def event_type
      "browser_error"
    end

    def detail_association
      :user
    end
  end
end
