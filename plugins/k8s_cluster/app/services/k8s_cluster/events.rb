module K8sCluster
  # List-only: an individual Event has no useful "describe" beyond what the
  # list row already shows, so this service has no #describe.
  class Events < ResourceService
    MAX_EVENTS = 500
    DEFAULT_EVENTS = 500

    def list(namespace: nil, limit: nil, since: nil)
      validate_identifiers!(namespace: namespace)
      requested_limit = Integer(limit || DEFAULT_EVENTS, exception: false)
      raise InvalidArgument, "limit must be a positive integer" unless requested_limit&.positive?
      since_time = Time.iso8601(since) if since
      cursor = Time.current.iso8601(6)
      with_client(api_client.core) do |client|
        items = client.get_events(namespace_scope(namespace)).fetch("items", [])
        sorted = items.sort_by { |item| timestamp(item) }.reverse
        sorted.select! { |item| newer_than?(item, since_time) } if since_time
        bounded_limit = [ requested_limit, MAX_EVENTS ].min

        {
          available: true,
          generated_at: Time.current.iso8601,
          cursor: cursor,
          truncated: sorted.length > bounded_limit,
          events: sorted.first(bounded_limit).map { |item| summary(item) }
        }
      end
    rescue ArgumentError
      raise InvalidArgument, "since must be an ISO 8601 timestamp"
    end

    private

    def timestamp(item)
      item["lastTimestamp"] || item["eventTime"] || item["firstTimestamp"] || ""
    end

    def newer_than?(item, since_time)
      Time.iso8601(timestamp(item)) > since_time
    rescue ArgumentError
      false
    end

    def summary(item)
      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        type: item["type"],
        reason: item["reason"],
        message: item["message"],
        involved_object: {
          kind: item.dig("involvedObject", "kind"),
          name: item.dig("involvedObject", "name")
        },
        count: integer(item["count"]),
        first_timestamp: item["firstTimestamp"],
        last_timestamp: item["lastTimestamp"]
      }
    end
  end
end
