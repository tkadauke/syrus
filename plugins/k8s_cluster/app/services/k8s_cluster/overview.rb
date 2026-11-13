require "rest-client"
require "json"

module K8sCluster
  # Aggregate node/pod CPU and memory via the metrics.k8s.io API, which
  # requires metrics-server to be running in the target cluster. That is
  # exactly the kind of thing that is often just not there (a homelab k3s
  # box, a fresh cluster) - so this soft-fails to an explicit "metrics
  # unavailable" result instead of raising, mirroring the `prepare` step's
  # soft-fail posture for guessed commands (CLAUDE.md).
  #
  # metrics.k8s.io isn't in Kubeclient's usual list/get vocabulary (it's an
  # aggregated API with only "nodes"/"pods" resources, no create/update/etc),
  # so this bypasses entity-method discovery and hits the REST path directly
  # via the client's own (public) rest_client/get_headers.
  class Overview < ResourceService
    SOFT_FAIL_ERRORS = (CONNECTION_ERRORS + [ RestClient::Exception, JSON::ParserError ]).freeze

    def call(summary: false, namespace: nil)
      {
        generated_at: Time.current.iso8601,
        nodes: node_metrics(summary: summary),
        pods: pod_metrics(summary: summary, namespace: namespace)
      }
    end

    private

    def node_metrics(summary:)
      fetch("nodes") do |items|
        rows = items.map { |item| { name: item.dig("metadata", "name"), **usage(item.dig("usage")) } }
        aggregate(rows, summary: summary)
      end
    end

    def pod_metrics(summary:, namespace:)
      fetch("pods") do |items|
        rows = items.filter_map do |item|
          next if namespace.present? && item.dig("metadata", "namespace") != namespace

          pod_row(item)
        end
        aggregate(rows, summary: summary)
      end
    end

    def pod_row(item)
      containers = item["containers"] || []
      totals = containers.each_with_object({ cpu_millicores: 0, memory_bytes: 0 }) do |container, sums|
        usage = usage(container["usage"])
        sums[:cpu_millicores] += usage[:cpu_millicores]
        sums[:memory_bytes] += usage[:memory_bytes]
      end

      { name: item.dig("metadata", "name"), namespace: item.dig("metadata", "namespace") }.merge(totals)
    end

    def usage(raw_usage)
      raw_usage ||= {}
      { cpu_millicores: ResourceQuantity.cpu_millicores(raw_usage["cpu"]), memory_bytes: ResourceQuantity.memory_bytes(raw_usage["memory"]) }
    end

    def aggregate(rows, summary:)
      totals = {
        available: true,
        total_cpu_millicores: rows.sum { |row| row[:cpu_millicores] },
        total_memory_bytes: rows.sum { |row| row[:memory_bytes] }
      }
      summary ? totals : totals.merge(items: rows)
    end

    def fetch(resource)
      client = api_client.metrics
      response = client.rest_client[resource].get(client.get_headers)
      items = JSON.parse(response.body)["items"] || []
      yield items
    rescue *SOFT_FAIL_ERRORS => e
      { available: false, reason: "metrics_unavailable", message: e.message }
    end
  end
end
