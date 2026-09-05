class CreateKubernetesClusters < ActiveRecord::Migration[8.1]
  def change
    create_table :kubernetes_clusters, if_not_exists: true do |t|
      t.string :label, null: false
      t.string :api_server_url, null: false
      t.text :credentials
      t.boolean :agentic_access_enabled, null: false, default: false
      t.boolean :allow_writes, null: false, default: false
      t.boolean :insecure_skip_tls_verify, null: false, default: false

      t.timestamps
    end
  end
end
