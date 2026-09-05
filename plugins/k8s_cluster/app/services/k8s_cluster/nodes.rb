module K8sCluster
  # Cluster-scoped.
  class Nodes < ResourceService
    MAX_NODES = 1_000
    ROLE_LABEL_PREFIX = "node-role.kubernetes.io/"

    def list
      with_client(api_client.core) do |client|
        items = client.get_nodes.fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_NODES,
          nodes: items.first(MAX_NODES).map { |item| summary(item) }
        }
      end
    end

    def describe(name)
      with_client(api_client.core) do |client|
        { available: true, generated_at: Time.current.iso8601, node: client.get_node(name) }
      end
    end

    # Mirrors `kubectl cordon`/`kubectl uncordon <node>`: a strategic-merge
    # patch on `spec.unschedulable`. Cordoning does not evict or move
    # already-running pods - it only stops the scheduler from placing new
    # ones there.
    def set_cordon(name, cordoned:)
      with_client(api_client.core) do |client|
        before = client.get_node(name)
        after = client.patch_node(name, { spec: { unschedulable: cordoned } })

        {
          available: true,
          generated_at: Time.current.iso8601,
          node: name,
          before: { unschedulable: unschedulable?(before) },
          after: { unschedulable: unschedulable?(after) }
        }
      end
    end

    private

    def unschedulable?(item)
      !!item.dig("spec", "unschedulable")
    end

    def summary(item)
      conditions = item.dig("status", "conditions") || []
      ready_condition = conditions.find { |condition| condition["type"] == "Ready" }

      {
        name: item.dig("metadata", "name"),
        ready: ready_condition&.dig("status") == "True",
        roles: roles(item),
        kubelet_version: item.dig("status", "nodeInfo", "kubeletVersion"),
        internal_ip: internal_ip(item),
        capacity_cpu: item.dig("status", "capacity", "cpu"),
        capacity_memory: item.dig("status", "capacity", "memory"),
        allocatable_cpu: item.dig("status", "allocatable", "cpu"),
        allocatable_memory: item.dig("status", "allocatable", "memory"),
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end

    def roles(item)
      labels = item.dig("metadata", "labels") || {}
      found = labels.keys.filter_map { |key| key.delete_prefix(ROLE_LABEL_PREFIX) if key.start_with?(ROLE_LABEL_PREFIX) }
      found.presence || [ "<none>" ]
    end

    def internal_ip(item)
      addresses = item.dig("status", "addresses") || []
      addresses.find { |address| address["type"] == "InternalIP" }&.dig("address")
    end
  end
end
