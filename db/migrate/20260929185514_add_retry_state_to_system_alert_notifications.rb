class AddRetryStateToSystemAlertNotifications < ActiveRecord::Migration[8.1]
  def up
    add_column :system_alert_notifications, :delivery_attempts, :integer, default: 0, null: false unless column_exists?(:system_alert_notifications, :delivery_attempts)
    add_column :system_alert_notifications, :next_attempt_at, :datetime unless column_exists?(:system_alert_notifications, :next_attempt_at)
    add_column :system_alert_notifications, :dead_lettered_at, :datetime unless column_exists?(:system_alert_notifications, :dead_lettered_at)
    add_index :system_alert_notifications, [ :delivered_at, :dead_lettered_at, :next_attempt_at ], name: "idx_system_alert_notifications_retry_due" unless index_exists?(:system_alert_notifications, [ :delivered_at, :dead_lettered_at, :next_attempt_at ], name: "idx_system_alert_notifications_retry_due")
  end

  def down
    remove_index :system_alert_notifications, name: "idx_system_alert_notifications_retry_due" if index_exists?(:system_alert_notifications, name: "idx_system_alert_notifications_retry_due")
    remove_column :system_alert_notifications, :dead_lettered_at if column_exists?(:system_alert_notifications, :dead_lettered_at)
    remove_column :system_alert_notifications, :next_attempt_at if column_exists?(:system_alert_notifications, :next_attempt_at)
    remove_column :system_alert_notifications, :delivery_attempts if column_exists?(:system_alert_notifications, :delivery_attempts)
  end
end
