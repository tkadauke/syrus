class CreateOperationalLogEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :operational_log_events do |t|
      t.datetime :occurred_at, null: false
      t.string :level, null: false
      t.string :role, null: false
      t.string :hostname, null: false
      t.string :app_revision
      t.integer :pid
      t.string :source, null: false
      t.string :request_id
      t.references :job, foreign_key: true
      t.references :workflow, foreign_key: true
      t.references :run, foreign_key: true
      t.text :message, null: false
      t.json :context, null: false

      t.timestamps
    end

    add_index :operational_log_events, :occurred_at unless index_exists?(:operational_log_events, :occurred_at)
    add_index :operational_log_events, :level unless index_exists?(:operational_log_events, :level)
    add_index :operational_log_events, :role unless index_exists?(:operational_log_events, :role)
    add_index :operational_log_events, :hostname unless index_exists?(:operational_log_events, :hostname)
    add_index :operational_log_events, :request_id unless index_exists?(:operational_log_events, :request_id)
  end
end
