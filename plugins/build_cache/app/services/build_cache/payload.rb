module BuildCache
  # Read side for the build-cache admin page: bucket footprint stats plus
  # the current pending clear request (if any) and recent request history,
  # so the operator can see what's about to happen and what already
  # happened without leaving the page.
  class Payload
    RECENT_REQUESTS_LIMIT = 20

    def initialize(params: {})
      @params = params
    end

    def show(include_stats: true)
      {
        configured: Client.configured?,
        filter: filter_tree,
        filter_schema: filter_schema,
        stats: include_stats ? stats_payload : nil,
        stats_error: @stats_error,
        pending_request: pending_request_payload,
        recent_requests: recent_requests_payload
      }
    end

    def stats
      {
        configured: Client.configured?,
        stats: stats_payload,
        stats_error: @stats_error
      }
    end

    private

    attr_reader :params

    def stats_payload
      return nil unless Client.configured?

      stats = Client.new.stats
      {
        object_count: stats.object_count,
        total_size_bytes: stats.total_size_bytes,
        oldest_object: object_summary_payload(stats.oldest_object),
        newest_object: object_summary_payload(stats.newest_object),
        truncated: stats.truncated
      }
    rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => e
      @stats_error = "#{e.class}: #{e.message}"
      nil
    end

    def object_summary_payload(object)
      return nil unless object

      { key: object.key, size: object.size, last_modified: object.last_modified&.iso8601 }
    end

    def pending_request_payload
      request_payload(BuildCache::ClearRequest.pending.order(created_at: :desc).first)
    end

    def recent_requests_payload
      filtered_requests
        .order(created_at: :desc)
        .limit(RECENT_REQUESTS_LIMIT)
        .includes(:user)
        .map { |request| request_payload(request) }
    end

    def filtered_requests
      scope = BuildCache::ClearRequest.all
      scope = scope.where(state: state) if state.present?
      scope = scope.where(scope: request_scope) if request_scope.present?
      scope = scope.where(older_than_days: older_than_days) if older_than_days
      scope = scope.where(user_id: user_id) if user_id
      scope = scope.where("reason LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(reason)}%") if reason.present?
      scope = scope.where(confirmed_at: parse_time(params[:confirmed_since])..) if parse_time(params[:confirmed_since])
      scope = scope.where(cancelled_at: parse_time(params[:cancelled_since])..) if parse_time(params[:cancelled_since])
      scope = scope.where(created_at: parse_time(params[:created_since])..) if parse_time(params[:created_since])
      scope = scope.where(updated_at: parse_time(params[:updated_since])..) if parse_time(params[:updated_since])
      scope = filter_by_result_status(scope)
      scope
    end

    def request_payload(request)
      return nil unless request

      {
        id: request.id,
        scope: request.scope,
        older_than_days: request.older_than_days,
        reason: request.reason,
        state: request.state,
        result: request.result,
        result_status: result_status(request),
        requested_by: request.user&.display_name || request.user&.email_address,
        created_at: request.created_at.iso8601,
        confirmed_at: request.confirmed_at&.iso8601,
        cancelled_at: request.cancelled_at&.iso8601,
        updated_at: request.updated_at.iso8601
      }
    end

    def filter_tree
      chips = []
      %i[state scope older_than_days user_id reason confirmed_since cancelled_since created_since updated_since].each do |field|
        value = params[field]
        chips << { field: field.to_s, op: "is", value: value.to_s } if value.present?
      end
      chips << { field: "result_status", op: "is", value: result_status_filter } if result_status_filter.present?
      { and: chips }
    end

    def filter_schema
      [
        { field: "state", label: "State", bucket: "enum", operators: [ "is" ], values: BuildCache::ClearRequest::STATES.map { |value| { label: value.humanize, value: value } } },
        { field: "scope", label: "Scope", bucket: "enum", operators: [ "is" ], values: BuildCache::ClearRequest::SCOPES.map { |value| { label: value.humanize, value: value } } },
        { field: "older_than_days", label: "Older than days", bucket: "number", operators: [ "is" ] },
        { field: "reason", label: "Reason", bucket: "text", operators: [ "is" ] },
        { field: "user_id", label: "User ID", bucket: "number", operators: [ "is" ] },
        { field: "confirmed_since", label: "Confirmed since", bucket: "text", operators: [ "is" ] },
        { field: "cancelled_since", label: "Cancelled since", bucket: "text", operators: [ "is" ] },
        { field: "created_since", label: "Created since", bucket: "text", operators: [ "is" ] },
        { field: "updated_since", label: "Updated since", bucket: "text", operators: [ "is" ] },
        { field: "result_status", label: "Result", bucket: "enum", operators: [ "is" ], values: [ { label: "Present", value: "present" }, { label: "Empty", value: "empty" }, { label: "Truncated", value: "truncated" } ] }
      ]
    end

    def state
      value = params[:state].to_s
      BuildCache::ClearRequest::STATES.include?(value) ? value : nil
    end

    def request_scope
      value = params[:scope].to_s
      BuildCache::ClearRequest::SCOPES.include?(value) ? value : nil
    end

    def older_than_days = Integer(params[:older_than_days], exception: false)
    def user_id = Integer(params[:user_id], exception: false)
    def reason = params[:reason].to_s.strip.presence
    def result_status_filter = params[:result_status].to_s.presence

    def result_status(request)
      return "empty" unless request.result.present?
      return "truncated" if request.result["truncated"]

      "present"
    end

    def filter_by_result_status(scope)
      case result_status_filter
      when "present"
        scope.where.not(result: [ nil, {} ])
      when "empty"
        scope.where(result: [ nil, {} ])
      when "truncated"
        scope.where("json_extract(result, '$.truncated') = ?", true)
      else
        scope
      end
    end

    def parse_time(value)
      return if value.blank?

      text = value.to_s.strip
      if (match = text.match(/\A(\d+)(m|h|d)\z/i))
        amount = match[1].to_i
        return amount.minutes.ago if match[2].downcase == "m"
        return amount.hours.ago if match[2].downcase == "h"
        return amount.days.ago
      end
      Time.zone.parse(text)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
