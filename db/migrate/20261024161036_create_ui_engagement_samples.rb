class CreateUiEngagementSamples < ActiveRecord::Migration[8.1]
  def change
    create_table :ui_engagement_samples do |t|
      t.references :user, null: false, foreign_key: true
      t.string :route_id, null: false
      t.json :route_params, null: false
      t.datetime :started_at, null: false
      t.datetime :ended_at, null: false
      t.integer :active_ms, null: false
      t.integer :visible_ms, null: false

      t.timestamps
    end

    add_index :ui_engagement_samples, [ :user_id, :started_at ]
  end
end
