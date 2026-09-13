module App
  class MaintenanceTasksPayload
    EVENT_LOG_PER_PAGE = 100

    FILTER_FIELDS = [
      { name: "state", label: "State" },
      { name: "recurrence", label: "Type" },
      { name: "category", label: "Category" },
      { name: "definition_key", label: "Definition" },
      { name: "trigger_kind", label: "Trigger" },
      { name: "query", label: "Search" }
    ].freeze

    def self.sidebar
      {
        tasks: MaintenanceTask.visible_in_sidebar.limit(5).map { |task| serialize_task(task, include_documentation: false) }
      }
    end

    def self.index(params:)
      scope = MaintenanceTask.includes(:requested_by_user).order(updated_at: :desc, id: :desc)
      filter_tree = self.filter_tree(params)
      filters = flat_filters(filter_tree)
      states = Array(filters["state"])
      scope = scope.where(state: states) if states.present?
      scope = scope.where(recurrence: filters["recurrence"]) if filters["recurrence"].present?
      scope = scope.where(category: filters["category"]) if filters["category"].present?
      scope = scope.where(definition_key: filters["definition_key"]) if filters["definition_key"].present?
      scope = scope.where(trigger_kind: filters["trigger_kind"]) if filters["trigger_kind"].present?
      if filters["query"].present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(filters["query"].to_s)}%"
        scope = scope.where("title LIKE :q OR summary LIKE :q OR task_key LIKE :q", q: pattern)
      end

      {
        tasks: scope.limit(200).map { |task| serialize_task(task, include_documentation: false) },
        definitions: MaintenanceTasks::Registry.all.map { |definition| serialize_definition(definition) },
        filter: filter_tree,
        filter_schema: FILTER_FIELDS.map { |field| filter_schema_field(field) },
        filters: filters
      }
    end

    def self.show(task, params: {})
      page = normalized_event_log_page(params)
      events_scope = task.events.order(created_at: :desc, id: :desc)
      total_events = events_scope.count
      total_pages = [ (total_events.to_f / EVENT_LOG_PER_PAGE).ceil, 1 ].max
      page = total_pages if page > total_pages
      offset = (page - 1) * EVENT_LOG_PER_PAGE

      serialize_task(task, include_documentation: true).merge(
        events: events_scope.offset(offset).limit(EVENT_LOG_PER_PAGE).map { |event| serialize_event(event) },
        events_pagination: {
          page: page,
          per_page: EVENT_LOG_PER_PAGE,
          total_events: total_events,
          total_pages: total_pages,
          first_item: total_events.zero? ? 0 : offset + 1,
          last_item: [ offset + EVENT_LOG_PER_PAGE, total_events ].min,
          previous_page: page > 1 ? page - 1 : nil,
          next_page: page < total_pages ? page + 1 : nil,
          has_previous_page: page > 1,
          has_next_page: page < total_pages
        }
      )
    end

    def self.serialize_task(task, include_documentation:)
      definition = task.definition
      {
        id: task.id,
        definition_key: task.definition_key,
        task_key: task.task_key,
        state: task.state,
        recurrence: task.recurrence,
        category: task.category,
        title: task.title,
        summary: task.summary,
        trigger_kind: task.trigger_kind,
        trigger_key: task.trigger_key,
        required_role: task.required_role,
        current_step_key: task.current_step_key,
        current_step_title: task.current_step_title,
        total_units: task.total_units,
        completed_units: task.completed_units,
        failed_units: task.failed_units,
        progress_percent: task.progress_percent,
        eta_seconds: task.eta_seconds,
        started_at: task.started_at,
        finished_at: task.finished_at,
        paused_at: task.paused_at,
        cancelled_at: task.cancelled_at,
        dismissed_at: task.dismissed_at,
        last_error: task.last_error,
        pending_reason: task.metadata["pending_reason"],
        documentation: include_documentation ? definition.documentation : nil,
        steps: definition.steps.map { |step| { key: step.key, title: step.title, description: step.description } },
        requested_by: task.requested_by_user && {
          id: task.requested_by_user.id,
          display_name: task.requested_by_user.display_name
        },
        paths: {
          admin: "/admin/maintenance_tasks/#{task.id}",
          api: "/api/v1/app/admin/maintenance_tasks/#{task.id}"
        }
      }
    end

    def self.serialize_definition(definition)
      {
        key: definition.key,
        title: definition.title,
        summary: definition.summary,
        category: definition.category,
        recurrence: definition.recurrence,
        required_role: definition.required_role
      }
    end

    def self.serialize_event(event)
      {
        id: event.id,
        level: event.level,
        step_key: event.step_key,
        step_title: event.step_title,
        message: event.message,
        units_done: event.units_done,
        units_total: event.units_total,
        metadata: event.metadata,
        created_at: event.created_at
      }
    end

    def self.filter_tree(params)
      decoded = Filters::QueryParam.decode(params[:q] || params["q"]) if (params[:q] || params["q"]).present?
      return Filters::Ast.serialize(Filters::Ast.parse(decoded)) if decoded

      chips = FILTER_FIELDS.filter_map do |field|
        name = field.fetch(:name)
        value = params[name] || params[name.to_sym]
        value = %w[pending running failed paused] if name == "state" && value.blank?
        next if value.blank?

        { "field" => name, "op" => "is", "value" => value }
      end
      { "and" => chips }
    rescue ArgumentError
      { "and" => [] }
    end

    def self.flat_filters(tree)
      chips = []
      collect_chips(Filters::Ast.parse(tree), chips)
      chips.to_h { |chip| [ chip.field, chip.value ] }
    end

    def self.collect_chips(node, chips)
      case node
      when Filters::Ast::Chip
        chips << node
      when Filters::Ast::AndNode, Filters::Ast::OrNode
        node.children.each { |child| collect_chips(child, chips) }
      when Filters::Ast::NotNode
        collect_chips(node.child, chips)
      end
      chips
    end

    def self.filter_schema_field(field)
      {
        bucket: "text",
        field: field.fetch(:name),
        label: field.fetch(:label),
        operators: [ "is" ]
      }
    end

    def self.normalized_event_log_page(params)
      raw_page = params[:log_page] || params["log_page"] || params[:page] || params["page"]
      page = raw_page.to_i
      page.positive? ? page : 1
    end
  end
end
