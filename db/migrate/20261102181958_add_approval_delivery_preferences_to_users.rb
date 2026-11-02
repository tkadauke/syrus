class AddApprovalDeliveryPreferencesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :approval_delivery_preferences, :json unless column_exists?(:users, :approval_delivery_preferences)
  end
end
