class CreateUiEngagementSamples < ActiveRecord::Migration[8.1]
  def up
    create_table :ui_engagement_samples, if_not_exists: true do |t|
      t.bigint :user_id, null: false
      t.string :route_id, null: false
      t.json :route_params, null: false
      t.datetime :started_at, null: false
      t.datetime :ended_at, null: false
      t.integer :active_ms, null: false
      t.integer :visible_ms, null: false

      t.timestamps
    end

    add_index :ui_engagement_samples, :user_id unless index_exists?(:ui_engagement_samples, :user_id)
    add_index :ui_engagement_samples, [ :user_id, :started_at ] unless index_exists?(:ui_engagement_samples, [ :user_id, :started_at ])
  end

  def down
    drop_table :ui_engagement_samples if table_exists?(:ui_engagement_samples)
  end
end
