module Admin
  class BrowserErrorEventsPayload
    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE = 100
    REVISION_SCOPES = %w[ current all ].freeze
    SORTS = {
      "time" => [ "browser_error_events.occurred_at", "browser_error_events.id" ],
      "path" => [ "browser_error_events.path", "browser_error_events.occurred_at", "browser_error_events.id" ],
      "error" => [ "browser_error_events.message", "browser_error_events.name", "browser_error_events.id" ],
      "user" => [ "users.email_address", "browser_error_events.user_id", "browser_error_events.id" ]
    }.freeze

    def initialize(params: {})
      @params = params
    end

    def as_json(*)
      rows = relation.limit(per_page + 1).to_a
      visible_rows = rows.first(per_page)

      {
        current_revision: current_revision,
        revision_scope: revision_scope,
        filter_schema: filter_definition.schema,
        filter: filter_tree,
        filters: filters_payload.merge(sort: sort_column, direction: sort_direction),
        timeline: Admin::EventTimeline.build(filtered_scope, since_time: since_time, until_time: until_time || Time.current),
        pagination: {
          page: page,
          per_page: per_page,
          has_next_page: rows.size > per_page,
          has_previous_page: page > 1,
          next_page: rows.size > per_page ? page + 1 : nil,
          previous_page: page > 1 ? page - 1 : nil
        },
        events: visible_rows.map { |event| event_payload(event) }
      }
    end

    private

    attr_reader :params

    def relation
      sorted_scope.includes(:user).offset((page - 1) * per_page)
    end

    def filtered_scope
      filter_definition.apply(BrowserErrorEvent.all, params)
    end

    def sorted_scope
      scope = filtered_scope
      scope = scope.left_joins(:user) if sort_column == "user"
      columns = SORTS.fetch(sort_column)
      orders = columns.map.with_index do |column, index|
        direction = index == columns.length - 1 ? tie_breaker_direction : sort_direction
        Arel.sql("#{column} #{direction.upcase}")
      end
      scope.reorder(*orders)
    end

    def event_payload(event)
      Observability::EventPayloads.browser_error(event).merge(
        actions: Observability::EventJobFiler.actions_for("browser_error")
      )
    end

    def since_time
      time_filter(:since, default: 24.hours.ago)
    end

    def until_time
      time_filter(:until, default: nil)
    end

    def time_filter(key, default:)
      value = filters_payload[key]
      return default if value.blank?
      return duration_value(value).ago if value.is_a?(Hash)

      Time.zone.parse(value.to_s) || default
    end

    def page
      [ Integer(params[:page], exception: false).to_i, 1 ].max
    end

    def per_page
      raw = Integer(filters_payload[:per_page].presence || params[:per], exception: false) || DEFAULT_PER_PAGE
      [[raw, 1].max, MAX_PER_PAGE].min
    end

    def sort_column
      value = utf8_param(:sort)
      SORTS.key?(value) ? value : "time"
    end

    def sort_direction
      utf8_param(:direction) == "asc" ? "asc" : "desc"
    end

    def tie_breaker_direction
      sort_column == "time" ? sort_direction : "asc"
    end

    def revision_scope
      value = filters_payload[:revision_scope].to_s
      REVISION_SCOPES.include?(value) ? value : "current"
    end

    def current_revision
      SyrusVersion.current
    end

    def filter_definition
      Admin::EventLogFilterDefinitions.browser_errors
    end

    def filter_tree
      @filter_tree ||= filter_definition.filter_tree(params)
    end

    def filters_payload
      @filters_payload ||= filter_definition.flat_filters(params).symbolize_keys
    end

    def duration_value(value)
      amount = Integer(value["n"] || value[:n] || 0)
      unit = (value["unit"] || value[:unit]).to_s
      amount.public_send(unit)
    end

    def utf8_param(key)
      Mcp::Tools.utf8(params[key]).strip
    end
  end
end
