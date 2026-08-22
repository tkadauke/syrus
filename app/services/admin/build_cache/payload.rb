module Admin
  module BuildCache
    # Read side for the build-cache admin page: bucket footprint stats plus
    # the current pending clear request (if any) and recent request history,
    # so the operator can see what's about to happen and what already
    # happened without leaving the page.
    class Payload
      RECENT_REQUESTS_LIMIT = 20

      def show
        {
          configured: Client.configured?,
          stats: stats_payload,
          stats_error: @stats_error,
          pending_request: pending_request_payload,
          recent_requests: recent_requests_payload
        }
      end

      private

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
        request_payload(AdminBuildCacheClearRequest.pending.order(created_at: :desc).first)
      end

      def recent_requests_payload
        AdminBuildCacheClearRequest
          .where.not(state: "pending")
          .order(created_at: :desc)
          .limit(RECENT_REQUESTS_LIMIT)
          .includes(:user)
          .map { |request| request_payload(request) }
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
          requested_by: request.user&.display_name || request.user&.email_address,
          created_at: request.created_at.iso8601,
          confirmed_at: request.confirmed_at&.iso8601,
          cancelled_at: request.cancelled_at&.iso8601
        }
      end
    end
  end
end
