# Native-app push destinations (APNs device tokens). One row per physical
# token; a token re-registered by a different user is re-assigned rather than
# duplicated. `session_id` ties a token to the cookie session that registered
# it so signing out stops pushes to that device.
class CreatePushDevices < ActiveRecord::Migration[8.1]
  def change
    create_table :push_devices, if_not_exists: true do |t|
      t.references :user, null: false, foreign_key: false, index: true
      t.references :session, null: true, foreign_key: false, index: true
      t.string :platform, null: false, default: "ios"
      t.string :token, null: false, limit: 191
      t.string :environment, null: false, default: "production"
      t.string :bundle_id
      t.string :device_name
      t.string :app_version
      t.datetime :last_registered_at, null: false
      t.datetime :disabled_at
      t.string :disabled_reason
      t.timestamps
    end
    add_index :push_devices, [ :platform, :token ], unique: true, name: "index_push_devices_on_platform_and_token" unless index_exists?(:push_devices, [ :platform, :token ], name: "index_push_devices_on_platform_and_token")
  end
end
