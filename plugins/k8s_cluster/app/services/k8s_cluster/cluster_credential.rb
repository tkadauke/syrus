require "yaml"

module K8sCluster
  class ClusterCredential
    CREDENTIAL_TYPE = "k8s_cluster.kubeconfig".freeze
    PURPOSE = "kubernetes cluster connection".freeze
    ADMIN_TOOL_NAME = "k8s_cluster_admin".freeze
    ALLOWED_TOOLS = %w[
      k8s_cluster_admin
      k8s_cluster_namespaces
      k8s_cluster_nodes
      k8s_cluster_pods
      k8s_cluster_pod_logs
      k8s_cluster_deployments
      k8s_cluster_statefulsets
      k8s_cluster_daemonsets
      k8s_cluster_jobs
      k8s_cluster_services
      k8s_cluster_ingresses
      k8s_cluster_configmaps
      k8s_cluster_secrets
      k8s_cluster_events
      k8s_cluster_pvcs
      k8s_cluster_cronjobs
      k8s_cluster_overview
      k8s_cluster_restart_rollout
      k8s_cluster_scale_deployment
      k8s_cluster_delete_pod
      k8s_cluster_set_node_cordon
      k8s_cluster_kubectl
    ].freeze

    class DependencyDisabled < StandardError; end
    class MissingCredential < StandardError; end
    class ExpiredCredential < StandardError; end

    class << self
      def upsert!(cluster:, kubeconfig:, user:, scope_type: "instance", scope_id: nil)
        raise DependencyDisabled, "credential_store plugin must be enabled to store Kubernetes cluster credentials" unless credential_store_enabled?

        parsed = KubeconfigParser.parse(kubeconfig)
        raise ExpiredCredential, "kubeconfig credential is already expired" if parsed.expires_at && parsed.expires_at <= Time.current

        credential = credential_record_for(cluster)
        rotating = credential.present?
        credential ||= CredentialStore::Credential.new(
          created_by: user,
          owner_user: user,
          scope_type: scope_type
        )
        credential.assign_attributes(
          name: credential_name_for(cluster),
          description: "Kubeconfig for Kubernetes cluster #{cluster.label}",
          credential_type: CREDENTIAL_TYPE,
          scope_type: scope_type,
          scope_id: scope_type == "instance" ? nil : scope_id,
          payload: kubeconfig,
          safe_metadata: safe_metadata_for(parsed),
          target_constraints: {},
          allowed_surfaces: %w[admin workflow chat],
          allowed_tools: ALLOWED_TOOLS,
          expires_at: parsed.expires_at,
          last_rotated_at: Time.current,
          revoked_at: nil
        )
        credential.save!
        CredentialStore::CredentialAccessEvent.record!(
          credential: credential,
          user: user,
          surface: "admin",
          action: rotating ? "rotate" : "create",
          result: "allowed",
          purpose: PURPOSE,
          metadata: { payload_replaced: true, source: "k8s_cluster" }
        )
        cluster.credential_store_credential_id = credential.id
        cluster.api_server_url = parsed.api_server_url
        cluster.credential_kind = parsed.credential_kind
        cluster.credentials = {}
        cluster.credential_refresh_status = parsed.expires_at.present? ? "healthy" : "unknown"
        cluster.credential_refresh_error = nil
        cluster.credential_refresh_attempted_at = nil
        parsed
      end

      def with_material(cluster, context: nil, tool_name: nil, purpose: PURPOSE)
        if cluster.credential_store_credential_id.present?
          with_brokered_material(cluster, context: context, tool_name: tool_name, purpose: purpose) { |material| yield material }
        else
          yield legacy_material_for(cluster)
        end
      end

      def credential_for(cluster)
        credential_record_for(cluster)
      end

      def credentials_by_id_for(clusters)
        ids = clusters.filter_map(&:credential_store_credential_id).uniq
        return {} if ids.empty?

        CredentialStore::Credential.where(id: ids).index_by(&:id)
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
          "host" => parsed.host,
          "refreshable" => parsed.refreshable.to_s
        }.compact
      end

      def legacy_material_for(cluster)
        credentials = cluster.credentials.to_h
        unless credentials["token"].present? || (credentials["client_cert"].present? && credentials["client_key"].present?)
          return KubeconfigParser::Result.new(api_server_url: cluster.api_server_url, credentials: credentials, context_name: nil, cluster_name: nil, host: nil, expires_at: nil, refreshable: false)
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
