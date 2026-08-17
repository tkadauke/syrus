module Admin
  class BrowserErrorEventsPayload
    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE = 100
    REVISION_SCOPES = %w[ current all ].freeze

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
          fingerprint: fingerprint,
          path: path
        },
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
      scope = BrowserErrorEvent.includes(:user).recent_first
      scope = scope.where(app_revision: current_revision) if revision_scope == "current"
      scope = scope.where(occurred_at: since_time..) if since_time
      scope = scope.where(occurred_at: ..until_time) if until_time
      scope = scope.where(fingerprint: fingerprint) if fingerprint.present?
      scope = scope.where(path: path) if path.present?
      if query.present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
        scope = scope.where("browser_error_events.message LIKE ? OR browser_error_events.name LIKE ? OR browser_error_events.path LIKE ?", pattern, pattern, pattern)
      end
      scope.offset((page - 1) * per_page)
    end

    def event_payload(event)
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

    def query
      utf8_param(:query).safe_byteslice(0, 500).presence
    end

    def fingerprint
      utf8_param(:fingerprint).safe_byteslice(0, 500).presence
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
