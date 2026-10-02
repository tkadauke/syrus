require "kubeclient"
require "openssl"
require "base64"

module K8sCluster
  # Builds authenticated Kubeclient::Client instances for a KubernetesCluster,
  # one per Kubernetes API group, translating brokered credential-store
  # kubeconfig material (or a legacy encrypted cluster credential during
  # migration) into Kubeclient's ssl_options/auth_options shape.
  #
  # Every client is built with `as: :parsed` so entity calls (get_pods,
  # get_deployments, ...) return plain parsed JSON hashes/lists instead of
  # RecursiveOpenStruct wrappers - resource services just dig into hashes,
  # same as the rest of Syrus.
  class ApiClient
    CONNECT_TIMEOUT_SECONDS = 10

    CORE = { group_path: nil, version: "v1" }.freeze
    APPS = { group_path: "apis/apps", version: "v1" }.freeze
    BATCH = { group_path: "apis/batch", version: "v1" }.freeze
    NETWORKING = { group_path: "apis/networking.k8s.io", version: "v1" }.freeze
    METRICS = { group_path: "apis/metrics.k8s.io", version: "v1beta1" }.freeze

    class_attribute :client_factory, default: ->(uri, version, options) { Kubeclient::Client.new(uri, version, **options) }

    def initialize(cluster, context: nil, tool_name: nil)
      @cluster = cluster
      @context = context
      @tool_name = tool_name
      @clients = {}
    end

    def core = @clients[:core] ||= build(**CORE)
    def apps = @clients[:apps] ||= build(**APPS)
    def batch = @clients[:batch] ||= build(**BATCH)
    def networking = @clients[:networking] ||= build(**NETWORKING)
    def metrics = @clients[:metrics] ||= build(**METRICS)

    private

    attr_reader :cluster, :context, :tool_name

    def build(group_path:, version:)
      base = cluster.api_server_url.to_s.chomp("/")
      uri = group_path.present? ? "#{base}/#{group_path}" : base

      ClusterCredential.with_material(cluster, context: context, tool_name: tool_name) do |material|
        self.class.client_factory.call(
          uri,
          version,
          ssl_options: ssl_options(material),
          auth_options: auth_options(material),
          timeouts: { open: CONNECT_TIMEOUT_SECONDS, read: CONNECT_TIMEOUT_SECONDS },
          as: :parsed
        )
      end
    end

    def ssl_options(material)
      options = { verify_ssl: cluster.insecure_skip_tls_verify ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER }
      credentials = material.credentials.to_h

      if credentials["client_cert"].present? && credentials["client_key"].present?
        options[:client_cert] = OpenSSL::X509::Certificate.new(Base64.decode64(credentials["client_cert"]))
        options[:client_key] = OpenSSL::PKey.read(Base64.decode64(credentials["client_key"]))
      end

      options[:cert_store] = build_cert_store(credentials["ca_data"]) if credentials["ca_data"].present?

      options
    end

    def build_cert_store(ca_data)
      store = OpenSSL::X509::Store.new
      store.add_cert(OpenSSL::X509::Certificate.new(Base64.decode64(ca_data)))
      store
    end

    def auth_options(material)
      token = material.credentials.to_h["token"]
      token.present? ? { bearer_token: token } : {}
    end
  end
end
