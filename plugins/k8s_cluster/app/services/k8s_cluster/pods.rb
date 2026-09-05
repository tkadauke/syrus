module K8sCluster
  # Namespace-scoped (omit `namespace` for an all-namespaces list, same as
  # `kubectl get pods -A`).
  class Pods < ResourceService
    MAX_PODS = 1_000

    def list(namespace: nil)
      with_client(api_client.core) do |client|
        items = client.get_pods(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_PODS,
          pods: items.first(MAX_PODS).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.core) do |client|
        { available: true, generated_at: Time.current.iso8601, pod: client.get_pod(name, namespace) }
      end
    end

    # Per-container log tail. `container` is required once a pod has more
    # than one container - Kubernetes itself returns a 400 in that case, so
    # we let that surface as Unavailable rather than guessing which one.
    def logs(name, namespace:, container: nil, tail_lines: 200, previous: false, timestamps: false)
      with_client(api_client.core) do |client|
        body = client.get_pod_log(
          name,
          namespace,
          container: container,
          tail_lines: tail_lines,
          previous: previous,
          timestamps: timestamps
        )

        { available: true, generated_at: Time.current.iso8601, pod: name, namespace: namespace, container: container, log: body.to_s }
      end
    end

    private

    def summary(item)
      statuses = item.dig("status", "containerStatuses") || []
      containers = item.dig("spec", "containers") || []
      container_count = containers.length || statuses.length

      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        status: item.dig("status", "phase"),
        pod_ip: item.dig("status", "podIP"),
        node_name: item.dig("spec", "nodeName"),
        ready: "#{statuses.count { |status| status['ready'] }}/#{container_count}",
        restart_count: statuses.sum { |status| integer(status["restartCount"]).to_i },
        container_names: containers.map { |container| container["name"] },
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end
  end
end
