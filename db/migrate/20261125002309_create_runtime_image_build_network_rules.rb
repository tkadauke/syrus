class CreateRuntimeImageBuildNetworkRules < ActiveRecord::Migration[8.1]
  def change
    create_table :runtime_image_build_network_rules, if_not_exists: true do |t|
      t.string :source_class, null: false, limit: 32
      t.string :host, null: false, limit: 253
      t.integer :port, null: false, default: 443
      # Empty string (not NULL) when unused so the unique index is effective on MySQL.
      t.string :path_prefix, null: false, limit: 255, default: ""
      t.string :ecosystem, null: false, limit: 32, default: ""
      t.boolean :required, null: false, default: false
      t.boolean :enabled, null: false, default: true
      t.string :note, limit: 500
      t.string :actor, limit: 191
      t.timestamps
    end
    unless index_exists?(:runtime_image_build_network_rules, %i[source_class host port path_prefix], name: "idx_ri_build_net_rules_identity")
      add_index :runtime_image_build_network_rules, %i[source_class host port path_prefix], unique: true, name: "idx_ri_build_net_rules_identity"
    end
  end
end
