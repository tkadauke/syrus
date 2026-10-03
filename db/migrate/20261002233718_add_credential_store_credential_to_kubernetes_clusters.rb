require "uri"

class AddCredentialStoreCredentialToKubernetesClusters < ActiveRecord::Migration[8.1]
  class MigrationKubernetesCluster < ActiveRecord::Base
    self.table_name = "kubernetes_clusters"

    attribute :credentials, :json
    encrypts :credentials
  end

  def up
    return unless table_exists?(:kubernetes_clusters)

    unless column_exists?(:kubernetes_clusters, :credential_store_credential_id)
      add_column :kubernetes_clusters, :credential_store_credential_id, :bigint
    end
    unless column_exists?(:kubernetes_clusters, :credential_kind)
      add_column :kubernetes_clusters, :credential_kind, :string
    end
    unless index_exists?(:kubernetes_clusters, :credential_store_credential_id, name: "idx_kubernetes_clusters_credential_store_credential")
      add_index :kubernetes_clusters, :credential_store_credential_id, name: "idx_kubernetes_clusters_credential_store_credential"
    end

    backfill_credential_store_records if table_exists?(:credential_store_credentials)
  end

  def down
    return unless table_exists?(:kubernetes_clusters)

    remove_index :kubernetes_clusters, name: "idx_kubernetes_clusters_credential_store_credential" if index_exists?(:kubernetes_clusters, :credential_store_credential_id, name: "idx_kubernetes_clusters_credential_store_credential")
    remove_column :kubernetes_clusters, :credential_kind if column_exists?(:kubernetes_clusters, :credential_kind)
    remove_column :kubernetes_clusters, :credential_store_credential_id if column_exists?(:kubernetes_clusters, :credential_store_credential_id)
  end

  private

  def backfill_credential_store_records
    created_by = User.admin.order(:id).first || User.order(:id).first
    return unless created_by

    MigrationKubernetesCluster.reset_column_information
    MigrationKubernetesCluster.where(credential_store_credential_id: nil).find_each do |cluster|
      credentials = cluster.credentials.to_h
      next if credentials.blank?

      credential_kind = credential_kind_for(credentials)
      credential = CredentialStore::Credential.find_or_initialize_by(name: credential_name_for(cluster))
      credential.assign_attributes(
        description: "Kubeconfig for Kubernetes cluster #{cluster.label}",
        credential_type: K8sCluster::ClusterCredential::CREDENTIAL_TYPE,
        scope_type: "instance",
        scope_id: nil,
        created_by: created_by,
        owner_user: created_by,
        payload: K8sCluster::ClusterCredential.build_kubeconfig(api_server_url: cluster.api_server_url, credentials: credentials),
        safe_metadata: {
          "cluster" => "default",
          "context" => "default",
          "host" => host_for(cluster.api_server_url)
        }.compact,
        target_constraints: {},
        allowed_surfaces: %w[admin workflow chat],
        allowed_tools: [],
        last_rotated_at: cluster.updated_at || Time.current,
        revoked_at: nil
      )
      credential.save!
      cluster.update!(credential_store_credential_id: credential.id, credential_kind: credential_kind, credentials: {})
    end
  end

  def credential_kind_for(credentials)
    return "token" if credentials["token"].present?
    return "client_cert" if credentials["client_cert"].present?

    nil
  end

  def credential_name_for(cluster)
    "kubernetes-cluster-#{cluster.id}-kubeconfig"
  end

  def host_for(api_server_url)
    URI.parse(api_server_url).host
  rescue URI::InvalidURIError
    nil
  end
end
