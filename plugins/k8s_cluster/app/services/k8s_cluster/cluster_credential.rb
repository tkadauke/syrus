require "yaml"

module K8sCluster
  class ClusterCredential
    CREDENTIAL_TYPE = "k8s_cluster.kubeconfig".freeze
    PURPOSE = "kubernetes cluster connection".freeze

    class DependencyDisabled < StandardError; end
    class MissingCredential < StandardError; end

    class << self
      def upsert!(cluster:, kubeconfig:, user:)
        raise DependencyDisabled, "credential_store plugin must be enabled to store Kubernetes cluster credentials" unless credential_store_enabled?

        parsed = KubeconfigParser.parse(kubeconfig)
        credential = credential_record_for(cluster) || CredentialStore::Credential.new(
          created_by: user,
          owner_user: user,
          scope_type: "instance"
        )
        credential.assign_attributes(
          name: credential_name_for(cluster),
          description: "Kubeconfig for Kubernetes cluster #{cluster.label}",
          credential_type: CREDENTIAL_TYPE,
          scope_type: "instance",
          scope_id: nil,
          payload: kubeconfig,
          safe_metadata: safe_metadata_for(parsed),
          target_constraints: {},
          allowed_surfaces: %w[admin workflow chat],
          allowed_tools: [],
          last_rotated_at: Time.current,
          revoked_at: nil
        )
        credential.save!
        cluster.credential_store_credential_id = credential.id
        cluster.api_server_url = parsed.api_server_url
        cluster.credential_kind = parsed.credential_kind
        cluster.credentials = {}
        parsed
      end

      def with_material(cluster, context: nil, tool_name: nil, purpose: PURPOSE)
        if cluster.credential_store_credential_id.present?
          with_brokered_material(cluster, context: context, tool_name: tool_name, purpose: purpose) { |material| yield material }
        else
          yield legacy_material_for(cluster)
        end
      end

      def build_kubeconfig(api_server_url:, credentials:)
        user = {}
        credentials = credentials.to_h
        if credentials["token"].present?
          user["token"] = credentials["token"]
        elsif credentials["client_cert"].present? && credentials["client_key"].present?
          user["client-certificate-data"] = credentials["client_cert"]
          user["client-key-data"] = credentials["client_key"]
        end

        cluster = { "server" => api_server_url }
        cluster["certificate-authority-data"] = credentials["ca_data"] if credentials["ca_data"].present?

        YAML.dump(
          "apiVersion" => "v1",
          "kind" => "Config",
          "current-context" => "default",
          "clusters" => [ { "name" => "default", "cluster" => cluster } ],
          "users" => [ { "name" => "default", "user" => user } ],
          "contexts" => [ { "name" => "default", "context" => { "cluster" => "default", "user" => "default" } } ]
        )
      end

      private

      def with_brokered_material(cluster, context:, tool_name:, purpose:)
        raise DependencyDisabled, "credential_store plugin must be enabled to read Kubernetes cluster credentials" unless credential_store_enabled?

        CredentialStore::Broker.with_credential_file(
          context: context || default_context,
          credential: cluster.credential_store_credential_id,
          type: CREDENTIAL_TYPE,
          purpose: purpose,
          tool_name: tool_name
        ) do |path, _metadata|
          yield KubeconfigParser.parse(File.read(path))
        end
      rescue CredentialStore::Broker::NotFound
        raise MissingCredential, "Kubernetes cluster credential not found"
      end

      def safe_metadata_for(parsed)
        {
          "cluster" => parsed.cluster_name,
          "context" => parsed.context_name,
          "host" => parsed.host
        }.compact
      end

      def legacy_material_for(cluster)
        credentials = cluster.credentials.to_h
        unless credentials["token"].present? || (credentials["client_cert"].present? && credentials["client_key"].present?)
          return KubeconfigParser::Result.new(api_server_url: cluster.api_server_url, credentials: credentials, context_name: nil, cluster_name: nil, host: nil)
        end

        KubeconfigParser.parse(build_kubeconfig(api_server_url: cluster.api_server_url, credentials: credentials))
      end

      def credential_record_for(cluster)
        CredentialStore::Credential.find_by(id: cluster.credential_store_credential_id)
      end

      def credential_name_for(cluster)
        "kubernetes-cluster-#{cluster.id}-kubeconfig"
      end

      def credential_store_enabled?
        defined?(CredentialStore) && CredentialStore.enabled?
      end

      def default_context
        McpToolContext.new(surface: :admin, role: nil, user: Current.user)
      end
    end
  end
end
