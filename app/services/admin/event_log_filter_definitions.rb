module Admin
  module EventLogFilterDefinitions
    module_function

    def browser_errors
      @browser_errors ||= EventLogFilterDefinition.define(:browser_errors, model: BrowserErrorEvent) do
        field :query, label: "Search", bucket: :text, operators: %i[contains does_not_contain], column: :message, columns: %i[message name path stack fingerprint user_agent], placeholder: "message, name, or path"
        field :since, label: "Since", bucket: :date, operators: %i[within_last after more_than_ago before between], column: :occurred_at, default: { "n" => 24, "unit" => "hours" }, placeholder: "24h"
        field :until, label: "Until", bucket: :date, operators: %i[before after between within_last more_than_ago], column: :occurred_at, placeholder: "optional"
        field :id, label: "ID", bucket: :number, operators: %i[is is_not greater_than less_than between], input_mode: "numeric"
        field :fingerprint, label: "Fingerprint", bucket: :text, operators: %i[is is_not contains], placeholder: "sha..."
        field :path, label: "Path", bucket: :text, operators: %i[is is_not contains starts_with], placeholder: "/jobs/3188"
        field :app_revision, label: "Revision", bucket: :enum, operators: %i[is is_not is_set is_unset], placeholder: "commit sha"
        field :revision_scope, label: "Revision scope", bucket: :enum, operators: %i[is], column: :app_revision, values: revision_scope_values, default: "current" do |scope, _op, value|
          value.to_s == "current" ? scope.where(app_revision: SyrusVersion.current) : scope
        end
        field :per_page, label: "Per page", bucket: :enum, operators: %i[is], column: :id, values: per_page_values, default: "50" do |scope, _op, _value|
          scope
        end
      end
    end

    def backend_exceptions
      @backend_exceptions ||= EventLogFilterDefinition.define(:backend_exceptions, model: BackendExceptionEvent) do
        field :query, label: "Search", bucket: :text, operators: %i[contains does_not_contain], column: :message, columns: %i[message exception_class path backtrace request_id], placeholder: "message, class, or path"
        field :since, label: "Since", bucket: :date, operators: %i[within_last after more_than_ago before between], column: :occurred_at, default: { "n" => 24, "unit" => "hours" }, placeholder: "24h"
        field :until, label: "Until", bucket: :date, operators: %i[before after between within_last more_than_ago], column: :occurred_at, placeholder: "optional"
        field :source, label: "Source", bucket: :text, operators: %i[is is_not contains]
        field :exception_class, label: "Exception class", bucket: :text, operators: %i[is is_not contains]
        field :path, label: "Path", bucket: :text, operators: %i[is is_not contains starts_with]
        field :fingerprint, label: "Fingerprint", bucket: :text, operators: %i[is is_not contains]
        field :job_id, label: "Job ID", bucket: :number, operators: %i[is is_not greater_than less_than], input_mode: "numeric"
        field :workflow_id, label: "Workflow ID", bucket: :number, operators: %i[is is_not greater_than less_than], input_mode: "numeric"
        field :run_id, label: "Run ID", bucket: :number, operators: %i[is is_not greater_than less_than], input_mode: "numeric"
        field :revision_scope, label: "Revision scope", bucket: :enum, operators: %i[is], column: :app_revision, values: revision_scope_values, default: "current" do |scope, _op, value|
          value.to_s == "current" ? scope.where(app_revision: SyrusVersion.current) : scope
        end
        field :per_page, label: "Per page", bucket: :enum, operators: %i[is], column: :id, values: per_page_values, default: "50" do |scope, _op, _value|
          scope
        end
      end
    end

    def workflow_activity
      @workflow_activity ||= EventLogFilterDefinition.define(:workflow_activity, model: WorkflowActivityEvent) do
        field :event_type, label: "Event type", bucket: :enum, operators: %i[is is_not is_one_of is_none_of], values: option_values(WorkflowActivityEvent::EVENT_TYPES)
        field :trigger_kind, label: "Trigger kind", bucket: :enum, operators: %i[is is_not is_one_of is_none_of], values: option_values(Workflow::TRIGGER_KINDS)
        field :reason_key, label: "Reason", bucket: :text, operators: %i[is is_not contains]
        field :job_id, label: "Job ID", bucket: :number, operators: %i[is is_not greater_than less_than], input_mode: "numeric"
        field :workflow_id, label: "Workflow ID", bucket: :number, operators: %i[is is_not greater_than less_than], input_mode: "numeric"
        field :run_id, label: "Run ID", bucket: :number, operators: %i[is is_not greater_than less_than], input_mode: "numeric"
      end
    end

    def reconciler_activity
      @reconciler_activity ||= EventLogFilterDefinition.define(:reconciler_activity, model: WorkEngineReconcilerActivityEvent) do
        field :event_type, label: "Event type", bucket: :enum, operators: %i[is is_not is_one_of is_none_of], values: option_values(WorkEngineReconcilerActivityEvent::EVENT_TYPES)
        field :issue_kind, label: "Issue kind", bucket: :text, operators: %i[is is_not contains]
        field :repair_action, label: "Repair action", bucket: :text, operators: %i[is is_not contains]
        field :repair_status, label: "Repair status", bucket: :text, operators: %i[is is_not contains]
        field :job_id, label: "Job ID", bucket: :number, operators: %i[is is_not greater_than less_than], input_mode: "numeric"
        field :workflow_id, label: "Workflow ID", bucket: :number, operators: %i[is is_not greater_than less_than], input_mode: "numeric"
        field :run_id, label: "Run ID", bucket: :number, operators: %i[is is_not greater_than less_than], input_mode: "numeric"
      end
    end

    def operational_logs
      @operational_logs ||= EventLogFilterDefinition.define(:operational_logs, model: nil) do
        field :query, label: "Search", bucket: :text, operators: %i[contains], placeholder: "message or context"
        field :since, label: "Since", bucket: :date, operators: %i[within_last after more_than_ago before between], column: :occurred_at, default: { "n" => 1, "unit" => "hours" }, placeholder: "1h"
        field :until, label: "Until", bucket: :date, operators: %i[before after between within_last more_than_ago], column: :occurred_at, placeholder: "optional"
        field :level, label: "Level", bucket: :enum, operators: %i[is is_not is_one_of is_none_of], values: option_values(OperationalLogEvent::LEVELS)
        field :role, label: "Role", bucket: :enum, operators: %i[is is_not is_one_of is_none_of], values: option_values(%w[web worker])
        field :hostname, label: "Hostname", bucket: :text, operators: %i[is is_not contains]
        field :revision_scope, label: "Revision scope", bucket: :enum, operators: %i[is], values: revision_scope_values, default: "current"
        field :per_page, label: "Per page", bucket: :enum, operators: %i[is], values: per_page_values, default: "50"
      end
    end

    def option_values(values)
      values.map { |value| { "value" => value.to_s, "label" => Filters::Schema.humanize_value(value) } }
    end

    def revision_scope_values
      [
        { "value" => "current", "label" => "Current SHA" },
        { "value" => "all", "label" => "All SHAs" }
      ]
    end

    def per_page_values
      [ 25, 50, 100 ].map { |value| { "value" => value.to_s, "label" => value.to_s } }
    end
  end
end
