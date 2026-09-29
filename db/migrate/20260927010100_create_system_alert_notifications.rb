class CreateSystemAlertNotifications < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:system_alert_notifications)

    create_table :system_alert_notifications do |t|
      t.string :dismissal_key, null: false
      t.string :alert_id, null: false
      t.string :severity, null: false
      t.string :title, null: false
      t.json :payload
      t.datetime :delivered_at
      t.string :delivery_error_class
      t.text :delivery_error_message
      t.timestamps

      t.index :dismissal_key, unique: true
      t.index :created_at
    end
  end
end
