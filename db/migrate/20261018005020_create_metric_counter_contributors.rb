class CreateMetricCounterContributors < ActiveRecord::Migration[8.1]
  def up
    create_table :metric_counter_contributors, if_not_exists: true do |t|
      t.string :identity, limit: 191, null: false
      t.bigint :last_applied_sequence, null: false, default: 0
      t.datetime :last_success_at
      t.datetime :last_error_at
      t.string :last_error, limit: 500
      t.timestamps
    end
    unless index_exists?(:metric_counter_contributors, :identity, unique: true)
      add_index :metric_counter_contributors, :identity, unique: true
    end
    unless index_exists?(:metric_counter_contributors, :updated_at)
      add_index :metric_counter_contributors, :updated_at
    end
  end

  def down
    drop_table :metric_counter_contributors, if_exists: true
  end
end
