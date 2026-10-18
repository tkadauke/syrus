class AddCredentialHealthToKubernetesClusters < ActiveRecord::Migration[8.1]
  def up
    add_column :kubernetes_clusters, :credential_refresh_status, :string unless column_exists?(:kubernetes_clusters, :credential_refresh_status)
    add_column :kubernetes_clusters, :credential_refresh_error, :string unless column_exists?(:kubernetes_clusters, :credential_refresh_error)
    add_column :kubernetes_clusters, :credential_refresh_attempted_at, :datetime unless column_exists?(:kubernetes_clusters, :credential_refresh_attempted_at)
  end

  def down
    remove_column :kubernetes_clusters, :credential_refresh_attempted_at if column_exists?(:kubernetes_clusters, :credential_refresh_attempted_at)
    remove_column :kubernetes_clusters, :credential_refresh_error if column_exists?(:kubernetes_clusters, :credential_refresh_error)
    remove_column :kubernetes_clusters, :credential_refresh_status if column_exists?(:kubernetes_clusters, :credential_refresh_status)
  end
end
