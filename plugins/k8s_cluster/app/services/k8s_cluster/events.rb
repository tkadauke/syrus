module K8sCluster
  # List-only: an individual Event has no useful "describe" beyond what the
  # list row already shows, so this service has no #describe.
  class Events < ResourceService
    MAX_EVENTS = 500

    def list(namespace: nil, limit: nil, since: nil)
      validate_identifiers!(namespace: namespace)
      requested_limit = Integer(limit, exception: false).to_i
      requested_limit = MAX_EVENTS unless requested_limit.positive?
      requested_limit = requested_limit.clamp(1, MAX_EVENTS)
      with_client(api_client.core) do |client|
        items = client.get_events(namespace_scope(namespace)).fetch("items", [])
        sorted = items.sort_by { |item| timestamp(item) }.reverse
        filtered = since.present? ? sorted.select { |item| timestamp(item) > since } : sorted

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: filtered.length > requested_limit,
          events: filtered.first(requested_limit).map { |item| summary(item) },
          cursor: [ since, timestamp(sorted.first || {}) ].compact_blank.max.to_s
        }
      end
    end

    private

    def timestamp(item)
      item["lastTimestamp"] || item["eventTime"] || item["firstTimestamp"] || ""
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
