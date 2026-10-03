class CreateMacosWorkerDrains < ActiveRecord::Migration[8.1]
  def change
    create_table :macos_worker_drains do |t|
      t.string :worker_storage_key
      t.string :hostname
      t.string :state, null: false
      t.string :desired_git_sha
      t.json :desired_version
      t.datetime :force_terminate_at
      t.datetime :drain_started_at
      t.datetime :update_started_at
      t.datetime :completed_at
      t.datetime :failed_at
      t.text :last_error
      t.json :metadata

      t.timestamps
    end

    add_index :macos_worker_drains, :worker_storage_key, unique: true
    add_index :macos_worker_drains, :hostname, unique: true
    add_index :macos_worker_drains, [ :state, :updated_at ]
  end
end
