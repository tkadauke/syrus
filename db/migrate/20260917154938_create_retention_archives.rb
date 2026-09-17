class CreateRetentionArchives < ActiveRecord::Migration[8.1]
  def change
    create_table :retention_archives, if_not_exists: true do |t|
      t.string :retention_key, null: false
      t.datetime :pruned_before, null: false
      t.integer :row_count, null: false
      t.bigint :byte_size, null: false

      t.timestamps
    end

    add_index :retention_archives, [ :retention_key, :pruned_before ] unless index_exists?(:retention_archives, [ :retention_key, :pruned_before ])
  end
end
