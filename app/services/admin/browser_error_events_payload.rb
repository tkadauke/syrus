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
        filters: {
          query: query,
          since: since_time.iso8601,
          until: until_time&.iso8601,
          id: id,
          fingerprint: fingerprint,
          path: path,
          sort: sort_column,
          direction: sort_direction
        },
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
      scope = BrowserErrorEvent.all
      scope = scope.where(app_revision: current_revision) if revision_scope == "current"
      scope = scope.where(occurred_at: since_time..) if since_time
      scope = scope.where(occurred_at: ..until_time) if until_time
      scope = scope.where(id: id) if id.present?
      scope = scope.where(fingerprint: fingerprint) if fingerprint.present?
      scope = scope.where(path: path) if path.present?
      if query.present?
        ids = indexed_query_ids
        if ids
          scope = scope.where(id: ids)
        else
          pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
          scope = scope.where("browser_error_events.message LIKE ? OR browser_error_events.name LIKE ? OR browser_error_events.path LIKE ? OR browser_error_events.stack LIKE ? OR browser_error_events.fingerprint LIKE ? OR browser_error_events.user_agent LIKE ?", pattern, pattern, pattern, pattern, pattern, pattern)
        end
      end
      scope
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

    def indexed_query_ids
      return unless BrowserErrorIndex.available?

      BrowserErrorIndex.search(
        query: query,
        since: since_time,
        until_time: until_time,
        app_revision: revision_scope == "current" ? current_revision : nil,
        limit: [ (page * per_page) + per_page, BrowserErrorIndex::MAX_LIMIT ].min
      )
    end

    def event_payload(event)
      Observability::EventPayloads.browser_error(event).merge(
        actions: Observability::EventJobFiler.actions_for("browser_error")
      )
    end

    def query
      utf8_param(:query).safe_byteslice(0, 500).presence
    end

    def fingerprint
      utf8_param(:fingerprint).safe_byteslice(0, 500).presence
    end

    def id
      Integer(params[:id], exception: false)
    end

    def path
      utf8_param(:path).safe_byteslice(0, 500).presence
    end

    def since_time
      parsed_time(:since, default: 24.hours.ago)
    end

    def until_time
      parsed_time(:until, default: nil)
    end

    def parsed_time(key, default:)
      value = utf8_param(key)
      parsed = if value.blank?
        default
      elsif (match = value.match(/\A(\d+)([mhd])\z/i))
        amount = match[1].to_i
        amount.public_send({ "m" => :minutes, "h" => :hours, "d" => :days }.fetch(match[2].downcase)).ago
      else
        Time.zone.parse(value)
      end
      return nil if parsed.nil? && default.nil?
      raise ArgumentError, "#{key} must be an ISO8601 timestamp or relative duration like 30m, 2h, or 1d" unless parsed

      parsed
    end

    def page
      [ Integer(params[:page], exception: false).to_i, 1 ].max
    end

    def per_page
      raw = Integer(params[:per_page].presence || params[:per], exception: false) || DEFAULT_PER_PAGE
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
      value = utf8_param(:revision_scope)
      REVISION_SCOPES.include?(value) ? value : "current"
    end

    def current_revision
      SyrusVersion.current
    end

    def utf8_param(key)
      Mcp::Tools.utf8(params[key]).strip
    end
  end
end
