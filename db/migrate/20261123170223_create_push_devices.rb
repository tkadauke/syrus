class CreatePushDevices < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:push_devices)

    create_table :push_devices do |t|
      t.references :user, null: false, index: true
      t.references :session, null: true, index: true
      t.string :platform, null: false, default: "ios"
      t.string :environment, null: false, default: "production"
      t.string :token, null: false, limit: 191
      t.string :bundle_id
      t.string :device_name
      t.string :app_version
      t.datetime :last_registered_at, null: false
      t.datetime :last_delivered_at
      t.datetime :disabled_at
      t.string :disabled_reason
      t.timestamps
    end
    add_index :push_devices, %i[platform token], unique: true, name: "idx_push_devices_platform_token"
  end

  def down
    drop_table :push_devices if table_exists?(:push_devices)
  end
end
