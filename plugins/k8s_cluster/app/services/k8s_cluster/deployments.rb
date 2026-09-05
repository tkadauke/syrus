module K8sCluster
  class Deployments < ResourceService
    MAX_DEPLOYMENTS = 1_000
    RESTART_ANNOTATION = "kubectl.kubernetes.io/restartedAt"

    def list(namespace: nil)
      with_client(api_client.apps) do |client|
        items = client.get_deployments(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_DEPLOYMENTS,
          deployments: items.first(MAX_DEPLOYMENTS).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.apps) do |client|
        { available: true, generated_at: Time.current.iso8601, deployment: client.get_deployment(name, namespace) }
      end
    end

    # Mirrors `kubectl rollout restart deployment/<name>`: a strategic-merge
    # patch that stamps the pod template with a restart annotation, which
    # causes the deployment controller to roll every pod even though no
    # actual spec content changed.
    def restart_rollout(name, namespace:)
      with_client(api_client.apps) do |client|
        before = client.get_deployment(name, namespace)
        patch = { spec: { template: { metadata: { annotations: { RESTART_ANNOTATION => Time.current.iso8601 } } } } }
        after = client.patch_deployment(name, patch, namespace)

        {
          available: true,
          generated_at: Time.current.iso8601,
          deployment: name,
          namespace: namespace,
          before: { restarted_at: restarted_at(before) },
          after: { restarted_at: restarted_at(after) }
        }
      end
    end

    def scale(name, namespace:, replicas:)
      raise ResourceService::InvalidArgument, "replicas must be a non-negative integer" unless valid_replicas?(replicas)

      with_client(api_client.apps) do |client|
        before = client.get_deployment(name, namespace)
        after = client.patch_deployment(name, { spec: { replicas: replicas } }, namespace)

        {
          available: true,
          generated_at: Time.current.iso8601,
          deployment: name,
          namespace: namespace,
          before: { replicas: integer(before.dig("spec", "replicas")) },
          after: { replicas: integer(after.dig("spec", "replicas")) }
        }
      end
    end

    private

    def restarted_at(item)
      item.dig("spec", "template", "metadata", "annotations", RESTART_ANNOTATION)
    end

    def valid_replicas?(replicas)
      replicas.is_a?(Integer) && replicas >= 0
    end

    def summary(item)
      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        replicas: integer(item.dig("spec", "replicas")),
        ready_replicas: integer(item.dig("status", "readyReplicas")).to_i,
        available_replicas: integer(item.dig("status", "availableReplicas")).to_i,
        updated_replicas: integer(item.dig("status", "updatedReplicas")).to_i,
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end
  end
end
