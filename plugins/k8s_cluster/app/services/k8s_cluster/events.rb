module K8sCluster
  # List-only: an individual Event has no useful "describe" beyond what the
  # list row already shows, so this service has no #describe.
  class Events < ResourceService
    MAX_EVENTS = 500

    def list(namespace: nil)
      with_client(api_client.core) do |client|
        items = client.get_events(namespace_scope(namespace)).fetch("items", [])
        sorted = items.sort_by { |item| timestamp(item) }.reverse

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: sorted.length > MAX_EVENTS,
          events: sorted.first(MAX_EVENTS).map { |item| summary(item) }
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
