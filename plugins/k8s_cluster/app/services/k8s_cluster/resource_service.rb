require "kubeclient"

module K8sCluster
  # Shared shape for the one-service-per-resource-kind split: every resource
  # service (Namespaces, Pods, Deployments, ...) wraps a cluster's ApiClient
  # and maps Kubeclient's exceptions - and the lower-level connection
  # failures Kubeclient doesn't itself normalize (timeouts, TLS failures,
  # DNS/connection errors) - onto the same two outcomes SchemaInspector uses
  # for MysqlDbBrowser: Unavailable (the cluster/API couldn't be reached) and
  # NotFound (the cluster was reached, but the named resource doesn't exist).
  class ResourceService
    class Unavailable < StandardError; end
    class NotFound < StandardError; end
    class InvalidArgument < StandardError; end

    CONNECTION_ERRORS = [
      RestClient::Exceptions::Timeout,
      RestClient::ServerBrokeConnection,
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      SocketError,
      OpenSSL::SSL::SSLError
    ].freeze

    KUBERNETES_IDENTIFIER_PATTERN = /\A[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?\z/
    KUBERNETES_IDENTIFIER_MAX_LENGTH = 253

    def self.validate_identifiers!(name: nil, namespace: nil, container: nil)
      { name: name, namespace: namespace, container: container }.each do |field, value|
        next if value.nil?
        next if value.is_a?(String) && value.length <= KUBERNETES_IDENTIFIER_MAX_LENGTH && value.match?(KUBERNETES_IDENTIFIER_PATTERN)

        raise InvalidArgument, "#{field} must be a valid Kubernetes DNS-1123 identifier"
      end
    end

    def initialize(cluster, context: nil, tool_name: nil)
      @cluster = cluster
      @context = context || Thread.current[:k8s_cluster_mcp_context]
      @tool_name = tool_name || Thread.current[:k8s_cluster_mcp_tool_name]
    end

    private

    attr_reader :cluster, :context, :tool_name

    def api_client
      @api_client ||= ApiClient.new(cluster, context: context, tool_name: tool_name)
    end

    def with_client(client)
      yield client
    rescue ClusterCredential::DependencyDisabled, ClusterCredential::MissingCredential, CredentialStore::Broker::Error => e
      raise Unavailable, e.message
    rescue Kubeclient::ResourceNotFoundError => e
      raise NotFound, e.message
    rescue Kubeclient::HttpError => e
      raise Unavailable, e.message
    rescue *CONNECTION_ERRORS => e
      raise Unavailable, e.message
    end

    def namespace_scope(namespace)
      validate_identifiers!(namespace: namespace)
      namespace.presence ? { namespace: namespace } : {}
    end

    def validate_identifiers!(name: nil, namespace: nil, container: nil)
      self.class.validate_identifiers!(name: name, namespace: namespace, container: container)
    end

    def integer(value)
      Integer(value, exception: false) if value
    end
  end
end
