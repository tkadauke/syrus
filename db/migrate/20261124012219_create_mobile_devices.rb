class CreateMobileDevices < ActiveRecord::Migration[8.1]
  def change
    create_table :mobile_devices, if_not_exists: true do |t|
      t.bigint :user_id, null: false
      t.bigint :session_id
      t.string :platform, null: false, default: "ios"
      t.string :token, null: false, limit: 191
      t.string :apns_environment, null: false, default: "production"
      t.string :bundle_id, null: false
      t.string :device_name
      t.string :app_version
      t.string :os_version
      t.datetime :last_registered_at, null: false
      t.datetime :last_delivered_at
      t.datetime :disabled_at
      t.string :disabled_reason

      t.timestamps
    end

    add_index :mobile_devices, %i[platform token], unique: true unless index_exists?(:mobile_devices, %i[platform token], unique: true)
    add_index :mobile_devices, :user_id unless index_exists?(:mobile_devices, :user_id)
    add_index :mobile_devices, :session_id unless index_exists?(:mobile_devices, :session_id)
  end
end
