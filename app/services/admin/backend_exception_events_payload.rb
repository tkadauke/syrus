module Admin
  class BackendExceptionEventsPayload
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
          source: source,
          exception_class: exception_class,
          path: path
        },
        timeline: Admin::EventTimeline.build(filtered_scope, since_time: since_time, until_time: until_time || Time.current),
        sources: BackendExceptionEvent.distinct.order(:source).pluck(:source),
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
      filtered_scope.recent_first.offset((page - 1) * per_page)
    end

    def filtered_scope
      scope = BackendExceptionEvent.all
      scope = scope.where(app_revision: current_revision) if revision_scope == "current"
      scope = scope.where(occurred_at: since_time..) if since_time
      scope = scope.where(occurred_at: ..until_time) if until_time
      scope = scope.where(fingerprint: fingerprint) if fingerprint.present?
      scope = scope.where(source: source) if source.present?
      scope = scope.where(exception_class: exception_class) if exception_class.present?
      scope = scope.where(path: path) if path.present?
      if query.present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
        scope = scope.where(
          "backend_exception_events.message LIKE ? OR backend_exception_events.exception_class LIKE ? OR backend_exception_events.path LIKE ? OR backend_exception_events.backtrace LIKE ? OR backend_exception_events.request_id LIKE ?",
          pattern, pattern, pattern, pattern, pattern
        )
      end
      scope
    end

    def event_payload(event)
      Observability::EventPayloads.backend_exception(event).merge(
        actions: Observability::EventJobFiler.actions_for("backend_exception")
      )
    end

    def query
      utf8_param(:query).safe_byteslice(0, 500).presence
    end

    def fingerprint
      utf8_param(:fingerprint).safe_byteslice(0, 500).presence
    end

    def source
      utf8_param(:source).safe_byteslice(0, 500).presence
    end

    def exception_class
      utf8_param(:exception_class).safe_byteslice(0, 500).presence
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
