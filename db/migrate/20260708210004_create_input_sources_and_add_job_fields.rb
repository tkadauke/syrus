class CreateInputSourcesAndAddJobFields < ActiveRecord::Migration[8.1]
  def up
    create_table :input_sources, if_not_exists: true do |t|
      t.string :type, null: false
      t.references :repository, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.boolean :polling_enabled, null: false, default: true
      # JSON column with no DB default (MySQL 8 disallows defaults on JSON columns).
      # BackfillInputSourcesData sets config = '{}' before enforcing NOT NULL.
      t.json :config
      t.text :credentials
      t.timestamps
      t.index [:repository_id, :type], unique: true, name: "index_input_sources_on_repository_and_type"
    end

    add_reference :jobs, :input_source, null: true, foreign_key: { to_table: :input_sources } unless column_exists?(:jobs, :input_source_id)
    add_column :jobs, :external_ref, :string unless column_exists?(:jobs, :external_ref)
  end

  def down
    remove_column :jobs, :external_ref if column_exists?(:jobs, :external_ref)
    remove_reference :jobs, :input_source, foreign_key: { to_table: :input_sources } if column_exists?(:jobs, :input_source_id)
    drop_table :input_sources, if_exists: true
  end
end
